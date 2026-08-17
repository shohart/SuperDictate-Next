// SuperDictate's C bridge implementation over parakeet.cpp's own C-API
// (upstream/include/parakeet_capi.h). Hand-authored, not vendored — never
// touched by scripts/vendor-parakeet-cpp.sh.
//
// Every entry point catches all C++ exceptions before returning through the
// C ABI (parakeet_capi_* itself already does this internally too, per its
// own header doc comments — this is defense in depth, not a substitute).

#include "superdictate_parakeet.h"
#include "parakeet_capi.h"
#include "parakeet.h"
#include "ggml_graph.hpp" // pk::set_num_threads, pk::global_backend(),
                           // pk::shutdown_backend() — process-global backend
                           // lifecycle. global_backend() is a lazily-created
                           // singleton (see ggml_graph.cpp): it is constructed
                           // on the FIRST graph compute performed by ANY
                           // context in this process, honoring whatever
                           // PARAKEET_DEVICE was set at that moment, and stays
                           // alive until shutdown_backend() resets it — after
                           // which a later compute recreates it fresh from
                           // the then-current PARAKEET_DEVICE. This is what
                           // makes an in-process CPU fallback after a failed
                           // Vulkan attempt possible (see sd_parakeet_warm_up
                           // below): reset, flip the env var, let the next
                           // context's first compute rebuild CPU-only.
#include "backend.hpp"    // pk::Backend::device_name()
#include "ggml.h"          // ggml_backend_dev_* registry (capability probe)
#include "ggml-backend.h"

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <vector>

struct SDParakeetContext {
    parakeet_ctx *native = nullptr;
    SDParakeetDevice device = SD_PARAKEET_DEVICE_CPU; // requested
    std::string device_name; // actual, filled in by warm-up; "" until then
    std::atomic<bool> busy{false};
    std::string last_error;
};

namespace {

// Case-insensitive "does `name` start with `prefix`" — used to recognize any
// Vulkan registry device name ("Vulkan0", "Vulkan1", ...) without hardcoding
// a single-GPU assumption.
bool startsWithCaseInsensitive(const std::string &name, const char *prefix) {
    size_t n = std::strlen(prefix);
    if (name.size() < n) return false;
    for (size_t i = 0; i < n; ++i) {
        if (std::tolower(static_cast<unsigned char>(name[i])) !=
            std::tolower(static_cast<unsigned char>(prefix[i]))) {
            return false;
        }
    }
    return true;
}

} // namespace

namespace {

// Default policy from docs/parakeet-intel-backend.md §10:
// max(2, min(8, activeProcessorCount / 2)). The Swift side
// (ParakeetEngine.init) already computes this using
// ProcessInfo.processInfo.activeProcessorCount and passes it down via
// SDParakeetOptions.num_threads; this fallback only applies if a caller
// passes num_threads <= 0 or a NULL options struct (defensive — every
// current Swift call site does pass an explicit positive value).
int32_t clampThreadCount(int32_t requested) {
    if (requested > 0) {
        return requested;
    }
    return 8; // matches parakeet.cpp's own kDefaultThreads (examples/cli).
}

char *dupUTF8(const std::string &s) {
    char *buf = static_cast<char *>(std::malloc(s.size() + 1));
    if (!buf) return nullptr;
    std::memcpy(buf, s.data(), s.size());
    buf[s.size()] = '\0';
    return buf;
}

// Lifecycle tracking for stale-backend prevention (see sd_parakeet_create):
// how many SDParakeetContext instances are currently alive, and the device
// name the process-global pk::Backend singleton was last requested to use.
std::mutex g_lifecycle_mutex;
int g_live_contexts = 0;
std::string g_last_requested_device;

} // namespace

extern "C" SDParakeetStatus sd_parakeet_create(
    const char *model_path,
    const SDParakeetOptions *options,
    SDParakeetContext **out_context
) {
    if (!out_context) return SD_PARAKEET_ERR_NULL_ARGUMENT;
    *out_context = nullptr;
    if (!model_path) return SD_PARAKEET_ERR_NULL_ARGUMENT;

    SDParakeetDevice device = options ? options->device : SD_PARAKEET_DEVICE_CPU;
    if (device == SD_PARAKEET_DEVICE_VULKAN && sd_parakeet_vulkan_available() == 0) {
        // No Vulkan device is registered at all (CPU-only build, or a build
        // with the Vulkan backend compiled in but no usable device on this
        // machine) — fail fast via the cheap, side-effect-free registry
        // probe rather than paying for a full model load + warm-up compute
        // just to discover the same thing later.
        return SD_PARAKEET_ERR_VULKAN_UNAVAILABLE;
    }

    try {
        int32_t threads = clampThreadCount(options ? options->num_threads : 0);
        pk::set_num_threads(threads);

        // parakeet.cpp's process-global compute backend (pk::global_backend())
        // is constructed lazily on the FIRST graph compute performed by any
        // context in this process (see the ggml_graph.hpp include comment
        // above), driven entirely by the PARAKEET_DEVICE environment
        // variable at that moment. Set it now so whichever context performs
        // that first compute (normally this context's own warm-up, called
        // immediately after create) requests the right device. This does
        // NOT by itself prove the device was actually selected — that is
        // sd_parakeet_warm_up's job.
        // Test-only override: lets a self-test deterministically exercise
        // the "requested device name not found -> upstream silently falls
        // back to CPU -> this bridge must turn that into a hard error"
        // path (see sd_parakeet_warm_up's post-init check) without needing
        // real hardware failure. Never used by any normal (non-test) call
        // site — production always requests "Vulkan0"/"cpu".
        const char *forced_name = std::getenv("SD_PARAKEET_TEST_FORCE_DEVICE_NAME");
        const char *device_name_to_request =
            device == SD_PARAKEET_DEVICE_VULKAN
                ? (forced_name && forced_name[0] != '\0' ? forced_name : "Vulkan0")
                : "cpu";
        setenv("PARAKEET_DEVICE", device_name_to_request, 1);

        // Stale-singleton prevention. pk::global_backend() is a lazily
        // constructed PROCESS-GLOBAL singleton that reads PARAKEET_DEVICE
        // at construction time — not per context. It outlives context
        // destruction (sd_parakeet_destroy does not reset it), so a
        // backend left behind by a previous request (classically: the
        // CPU backend constructed after a mid-session Vulkan-error
        // fallback) would silently keep serving computes for a NEW
        // context created with a different device request. warm_up's
        // post-init check then reports "Vulkan was requested but the
        // actual selected backend is 'cpu'" and the whole session falls
        // back to CPU until the process is restarted — the exact
        // production log signature this guards against. When no live
        // context exists (the app always unloads before reloading with
        // a different device, so their weight buffers are already
        // freed), reset the stale singleton so this context's first
        // compute rebuilds it against the new PARAKEET_DEVICE.
        {
            std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
            const bool device_changed =
                !g_last_requested_device.empty() &&
                g_last_requested_device != device_name_to_request;
            if (device_changed && g_live_contexts == 0) {
                pk::shutdown_backend();
            }
            g_last_requested_device = device_name_to_request;
        }

        parakeet_ctx *native = parakeet_capi_load(model_path);
        if (!native) {
            return SD_PARAKEET_ERR_MODEL_LOAD_FAILED;
        }

        auto *ctx = new (std::nothrow) SDParakeetContext();
        if (!ctx) {
            parakeet_capi_free(native);
            return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
        }
        ctx->native = native;
        ctx->device = device;
        {
            std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
            ++g_live_contexts;
        }
        *out_context = ctx;
        return SD_PARAKEET_OK;
    } catch (...) {
        return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }
}

extern "C" SDParakeetStatus sd_parakeet_warm_up(SDParakeetContext *context) {
    if (!context || !context->native) return SD_PARAKEET_ERR_NULL_ARGUMENT;

    bool expected = false;
    if (!context->busy.compare_exchange_strong(expected, true)) {
        return SD_PARAKEET_ERR_BUSY;
    }

    SDParakeetStatus status = SD_PARAKEET_OK;
    try {
        // A short (0.5s) synthetic silence buffer at 16 kHz — enough to
        // exercise the real mel front end + encoder + decoder graph paths
        // once (forcing allocator/thread-pool warm paths, and — critically
        // — the process-global pk::Backend's construction, which is what
        // actually reads PARAKEET_DEVICE and does device selection; see
        // backend.cpp) without a real recording. An empty/near-empty
        // transcript is expected and NOT an error (spec §11.3):
        // parakeet.cpp legitimately returns "" for silence.
        std::vector<float> silence(8000, 0.0f);
        char *text = parakeet_capi_transcribe_pcm(
            context->native, silence.data(),
            static_cast<int>(silence.size()), 16000, /*decoder=*/0
        );
        if (!text) {
            context->last_error = parakeet_capi_last_error(context->native);
            status = SD_PARAKEET_ERR_INFERENCE_FAILED;
        } else {
            parakeet_capi_free_string(text);
        }

        if (status == SD_PARAKEET_OK) {
            // Post-init device check. pk::global_backend() is now guaranteed
            // constructed (the compute above forced it). Record the actual
            // selected device name regardless of what was requested — it is
            // always useful diagnostics.
            context->device_name = pk::global_backend().device_name();

            if (context->device == SD_PARAKEET_DEVICE_VULKAN &&
                !startsWithCaseInsensitive(context->device_name, "Vulkan")) {
                // Upstream's own default behavior (backend.cpp,
                // Backend::Backend()) is to log
                // "PARAKEET_DEVICE=... not found; falling back to CPU" and
                // then continue with a successful-looking CPU init — no
                // error return, nothing a caller not watching stderr would
                // ever see. That is the opposite of this bridge's contract
                // ("must fail initialization if the actual selected backend
                // is CPU-only when Vulkan was requested — never report
                // Vulkan success merely because the user asked for it").
                // Turn it into a hard, typed error here instead of trusting
                // upstream's silent fallback.
                context->last_error =
                    "Vulkan was requested but the actual selected backend is '" +
                    context->device_name +
                    "' (CPU fallback) — parakeet.cpp's own device selection "
                    "silently fell back; treating this as a Vulkan "
                    "initialization failure per this bridge's device-safety "
                    "contract";
                status = SD_PARAKEET_ERR_VULKAN_UNAVAILABLE;

                // Reset the process-global backend so a FRESH context
                // created afterward (with PARAKEET_DEVICE=cpu) gets a clean
                // CPU-only construction rather than reusing whatever partial
                // state this failed attempt left behind. Safe / intended
                // per ggml_graph.hpp's own doc comment: "a later
                // global_backend() call recreates it."
                pk::shutdown_backend();
            }
        }
    } catch (...) {
        context->last_error = "native exception during warm-up";
        status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }

    context->busy.store(false);
    return status;
}

extern "C" SDParakeetStatus sd_parakeet_transcribe(
    SDParakeetContext *context,
    const float *samples,
    uint64_t sample_count,
    uint32_t sample_rate,
    SDParakeetResult *out_result
) {
    if (!out_result) return SD_PARAKEET_ERR_NULL_ARGUMENT;
    out_result->text = nullptr;
    out_result->total_seconds = 0.0;
    out_result->inference_seconds = 0.0;
    out_result->used_gpu = 0;

    if (!context || !context->native || !samples || sample_rate == 0) {
        return SD_PARAKEET_ERR_NULL_ARGUMENT;
    }
    if (sample_count == 0) {
        return SD_PARAKEET_ERR_EMPTY_AUDIO;
    }
    double durationSeconds = static_cast<double>(sample_count) / static_cast<double>(sample_rate);
    if (durationSeconds > SD_PARAKEET_MAX_AUDIO_SECONDS) {
        return SD_PARAKEET_ERR_AUDIO_TOO_LONG;
    }
    // parakeet_capi_transcribe_pcm takes `int n_samples` — guard the
    // narrowing conversion explicitly rather than relying on silent
    // truncation for pathological inputs (also unreachable in practice given
    // the duration cap above, but validated defensively per the bridge
    // requirements: "validate sample count and integer conversions").
    if (sample_count > static_cast<uint64_t>(INT32_MAX)) {
        return SD_PARAKEET_ERR_AUDIO_TOO_LONG;
    }

    bool expected = false;
    if (!context->busy.compare_exchange_strong(expected, true)) {
        return SD_PARAKEET_ERR_BUSY;
    }

    SDParakeetStatus status = SD_PARAKEET_OK;
    try {
        auto started = std::chrono::steady_clock::now();
        char *text = parakeet_capi_transcribe_pcm(
            context->native, samples, static_cast<int>(sample_count),
            static_cast<int>(sample_rate), /*decoder=*/0
        );
        auto finished = std::chrono::steady_clock::now();
        double seconds = std::chrono::duration<double>(finished - started).count();

        if (!text) {
            context->last_error = parakeet_capi_last_error(context->native);
            status = SD_PARAKEET_ERR_INFERENCE_FAILED;
        } else {
            out_result->text = dupUTF8(std::string(text));
            parakeet_capi_free_string(text);
            if (!out_result->text) {
                status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
            } else {
                out_result->total_seconds = seconds;
                out_result->inference_seconds = seconds;
                out_result->used_gpu =
                    startsWithCaseInsensitive(context->device_name, "Vulkan") ? 1 : 0;
            }
        }
    } catch (...) {
        context->last_error = "native exception during transcription";
        status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }

    context->busy.store(false);
    return status;
}

extern "C" SDParakeetStatus sd_parakeet_transcribe_with_tokens(
    SDParakeetContext *context,
    const float *samples,
    uint64_t sample_count,
    uint32_t sample_rate,
    SDParakeetTokenResult *out_result
) {
    if (!out_result) return SD_PARAKEET_ERR_NULL_ARGUMENT;
    out_result->json = nullptr;
    out_result->total_seconds = 0.0;
    out_result->inference_seconds = 0.0;
    out_result->used_gpu = 0;

    if (!context || !context->native || !samples || sample_rate == 0) {
        return SD_PARAKEET_ERR_NULL_ARGUMENT;
    }
    if (sample_count == 0) {
        return SD_PARAKEET_ERR_EMPTY_AUDIO;
    }
    double durationSeconds = static_cast<double>(sample_count) / static_cast<double>(sample_rate);
    if (durationSeconds > SD_PARAKEET_MAX_AUDIO_SECONDS) {
        return SD_PARAKEET_ERR_AUDIO_TOO_LONG;
    }
    if (sample_count > static_cast<uint64_t>(INT32_MAX)) {
        return SD_PARAKEET_ERR_AUDIO_TOO_LONG;
    }

    bool expected = false;
    if (!context->busy.compare_exchange_strong(expected, true)) {
        return SD_PARAKEET_ERR_BUSY;
    }

    SDParakeetStatus status = SD_PARAKEET_OK;
    try {
        auto started = std::chrono::steady_clock::now();
        int nSamples = static_cast<int>(sample_count);
        char *json = parakeet_capi_transcribe_pcm_batch_json(
            context->native, samples, &nSamples, /*n_clips=*/1,
            static_cast<int>(sample_rate), /*decoder=*/0
        );
        auto finished = std::chrono::steady_clock::now();
        double seconds = std::chrono::duration<double>(finished - started).count();

        if (!json) {
            context->last_error = parakeet_capi_last_error(context->native);
            status = SD_PARAKEET_ERR_INFERENCE_FAILED;
        } else {
            out_result->json = dupUTF8(std::string(json));
            parakeet_capi_free_string(json);
            if (!out_result->json) {
                status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
            } else {
                out_result->total_seconds = seconds;
                out_result->inference_seconds = seconds;
                out_result->used_gpu =
                    startsWithCaseInsensitive(context->device_name, "Vulkan") ? 1 : 0;
            }
        }
    } catch (...) {
        context->last_error = "native exception during token transcription";
        status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }

    context->busy.store(false);
    return status;
}

extern "C" void sd_parakeet_token_result_destroy(SDParakeetTokenResult *result) {
    if (!result) return;
    if (result->json) {
        std::free(result->json);
        result->json = nullptr;
    }
}

extern "C" void sd_parakeet_result_destroy(SDParakeetResult *result) {
    if (!result) return;
    if (result->text) {
        std::free(result->text);
        result->text = nullptr;
    }
}

extern "C" void sd_parakeet_destroy(SDParakeetContext *context) {
    if (!context) return;
    if (context->native) {
        parakeet_capi_free(context->native);
    }
    {
        std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
        if (g_live_contexts > 0) --g_live_contexts;
    }
    delete context;
}

extern "C" SDParakeetDevice sd_parakeet_backend_device(const SDParakeetContext *context) {
    if (!context) return SD_PARAKEET_DEVICE_CPU;
    return context->device;
}

extern "C" const char *sd_parakeet_backend_device_name(const SDParakeetContext *context) {
    if (!context) return "";
    return context->device_name.c_str();
}

extern "C" int32_t sd_parakeet_vulkan_available(void) {
    // ggml's own backend device registry is the source of truth (never
    // infer from IOKit/product-name sniffing). This walks the registry
    // exactly like pk::Backend::Backend() does for auto-select (see
    // backend.cpp), but read-only: it does not call ggml_backend_dev_init
    // on anything and does not touch parakeet.cpp's process-global compute
    // backend, so it is safe to call before any model is loaded (e.g. to
    // decide whether the settings checkbox should be enabled) with zero
    // side effects. In a CPU-only build (no PARAKEET_GGML_VULKAN), the
    // Vulkan backend never registers a device at all, so this naturally
    // returns 0 without any #ifdef here.
    try {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t dev = ggml_backend_dev_get(i);
            const enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
            if (type == GGML_BACKEND_DEVICE_TYPE_GPU ||
                type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                return 1;
            }
        }
    } catch (...) {
        return 0;
    }
    return 0;
}

extern "C" const char *sd_parakeet_vulkan_device_description(void) {
    static thread_local std::string description;
    description.clear();
    try {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t dev = ggml_backend_dev_get(i);
            const enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
            if (type == GGML_BACKEND_DEVICE_TYPE_GPU ||
                type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                const char *desc = ggml_backend_dev_description(dev);
                description = desc ? desc : "";
                break;
            }
        }
    } catch (...) {
        description.clear();
    }
    return description.c_str();
}

extern "C" void sd_parakeet_test_reset_backend(void) {
    pk::shutdown_backend();
    // Keep the stale-device tracker in sync: the singleton is gone, so
    // there is no "last requested device" to protect against anymore.
    std::lock_guard<std::mutex> lock(g_lifecycle_mutex);
    g_last_requested_device.clear();
}

extern "C" const char *sd_parakeet_last_error_message(const SDParakeetContext *context) {
    if (!context) return "";
    return context->last_error.c_str();
}

extern "C" const char *sd_parakeet_runtime_version(void) {
    return parakeet_version();
}

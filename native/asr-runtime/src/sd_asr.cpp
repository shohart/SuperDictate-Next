// C ABI glue (spec §4.1). The only place exceptions are caught and turned
// into status codes + error JSON; nothing ever unwinds across the C ABI.
#include "sd_asr.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>

#include "audio.h"
#include "common.h"
#include "families/family.h"
#include "manifest.h"
#include "ort_session.h"

using sdasr::Error;
using sdasr::json;

struct sd_asr_handle {
    sdasr::Manifest manifest;
    std::unique_ptr<sdasr::SessionFactory> factory;
    std::unique_ptr<sdasr::ModelFamily> family;
    std::string language = "auto";
    double load_seconds = 0;

    std::atomic<bool> busy{false};
    std::mutex request_mutex;  // guards the fields below
    std::string current_request_id;
    Ort::RunOptions *current_run_options = nullptr;
    std::atomic<bool> cancelled{false};

    std::atomic<uint64_t> requests_completed{0};
    std::atomic<uint64_t> requests_failed{0};
    std::atomic<uint64_t> next_request_number{1};
    double last_processing_seconds = 0;
    double last_rtf = 0;
};

namespace {

using Clock = std::chrono::steady_clock;

char *duplicate(const std::string &value) {
    char *out = static_cast<char *>(std::malloc(value.size() + 1));
    if (out) std::memcpy(out, value.c_str(), value.size() + 1);
    return out;
}

void set_out(char **out, const json &value) {
    if (out) *out = duplicate(value.dump(-1, ' ', false, json::error_handler_t::replace));
}

sd_asr_status fail(char **error_json, sd_asr_status status, const std::string &message) {
    set_out(error_json, json{{"category", sd_asr_status_name(status)}, {"message", message}});
    return status;
}

json parse_object(const char *text, const char *what) {
    if (text == nullptr || *text == '\0') return json::object();
    json value = json::parse(text, nullptr, /*allow_exceptions=*/false);
    if (!value.is_object()) throw Error(SD_ASR_INVALID_ARGUMENT, std::string(what) + " is not a JSON object");
    return value;
}

template <typename T>
T get_or(const json &object, const char *key, T fallback) {
    auto it = object.find(key);
    if (it == object.end() || it->is_null()) return fallback;
    try {
        return it->get<T>();
    } catch (const json::exception &) {
        throw Error(SD_ASR_INVALID_ARGUMENT, std::string("config field '") + key + "' has the wrong type");
    }
}

json build_status(sd_asr_handle *h) {
    const auto &m = h->manifest;
    json status = {
        {"api_version", SD_ASR_API_VERSION},
        {"engine", "onnxruntime"},
        {"onnxruntime_version", sdasr::ort_version()},
        {"model_id", m.model_id},
        {"model_family", m.family},
        {"model_revision", m.revision},
        {"model_license", m.license},
        {"quantization", m.quantization},
        {"model_bytes", m.total_bytes},
        {"sample_rate", m.sample_rate},
        {"languages", m.languages},
        {"language", h->language},
        {"capabilities", m.capabilities},
        {"provider_requested", h->factory->resolution().requested},
        {"provider_actual", h->factory->resolution().actual},
        {"available_providers", sdasr::available_providers()},
        {"intra_op_threads", h->factory->intra_op_threads()},
        {"inter_op_threads", h->factory->inter_op_threads()},
        {"allow_spinning", h->factory->allow_spinning()},
        {"load_seconds", h->load_seconds},
        {"requests_completed", h->requests_completed.load()},
        {"requests_failed", h->requests_failed.load()},
    };
    if (!h->factory->resolution().fallback_reason.empty()) {
        status["provider_fallback_reason"] = h->factory->resolution().fallback_reason;
    }
    {
        std::lock_guard<std::mutex> lock(h->request_mutex);
        status["state"] = h->current_run_options != nullptr ? "inference" : "ready";
        if (h->current_run_options != nullptr) status["current_request_id"] = h->current_request_id;
        status["last_processing_seconds"] = h->last_processing_seconds;
        status["last_rtf"] = h->last_rtf;
    }
    return status;
}

}  // namespace

extern "C" {

uint32_t sd_asr_api_version(void) { return SD_ASR_API_VERSION; }

const char *sd_asr_status_name(sd_asr_status status) {
    switch (status) {
        case SD_ASR_OK: return "ok";
        case SD_ASR_INVALID_ARGUMENT: return "invalid_argument";
        case SD_ASR_INVALID_MODEL: return "invalid_model";
        case SD_ASR_UNSUPPORTED_MODEL_FAMILY: return "unsupported_model_family";
        case SD_ASR_INVALID_AUDIO: return "invalid_audio";
        case SD_ASR_PROVIDER_UNAVAILABLE: return "provider_unavailable";
        case SD_ASR_MODEL_LOAD_FAILED: return "model_load_failed";
        case SD_ASR_INFERENCE_FAILED: return "inference_failed";
        case SD_ASR_CANCELLED: return "cancelled";
        case SD_ASR_TIMEOUT: return "timeout";
        case SD_ASR_RUNTIME_CRASHED: return "runtime_crashed";
        case SD_ASR_BUSY: return "busy";
    }
    return "unknown";
}

sd_asr_status sd_asr_create(const char *config_json, sd_asr_handle **out, char **error_json) {
    if (error_json) *error_json = nullptr;
    if (out == nullptr) return fail(error_json, SD_ASR_INVALID_ARGUMENT, "out handle pointer is NULL");
    *out = nullptr;
    try {
        const json config = parse_object(config_json, "config");
        const std::string engine = get_or<std::string>(config, "engine", "onnxruntime");
        if (engine != "onnxruntime") throw Error(SD_ASR_INVALID_ARGUMENT, "unsupported engine '" + engine + "'");
        const std::string model_directory = get_or<std::string>(config, "model_directory", "");
        if (model_directory.empty()) throw Error(SD_ASR_INVALID_ARGUMENT, "config: model_directory is required");
        const std::string assets_directory = get_or<std::string>(config, "assets_directory", "");

        const auto started = Clock::now();
        auto handle = std::make_unique<sd_asr_handle>();
        handle->manifest = sdasr::load_manifest(std::filesystem::u8path(model_directory),
                                                assets_directory.empty() ? std::filesystem::path()
                                                                         : std::filesystem::u8path(assets_directory),
                                                get_or<bool>(config, "verify_checksums", false));
        const std::string expected_id = get_or<std::string>(config, "model_id", "");
        if (!expected_id.empty() && expected_id != handle->manifest.model_id) {
            throw Error(SD_ASR_INVALID_MODEL, "config model_id '" + expected_id + "' does not match manifest '" +
                                                  handle->manifest.model_id + "'");
        }
        const std::string expected_family = get_or<std::string>(config, "model_family", "");
        if (!expected_family.empty() && expected_family != handle->manifest.family) {
            throw Error(SD_ASR_UNSUPPORTED_MODEL_FAMILY, "config model_family '" + expected_family +
                                                             "' does not match manifest '" + handle->manifest.family + "'");
        }
        handle->language = get_or<std::string>(config, "language", "auto");
        if (handle->language != "auto" && !handle->manifest.languages.empty()) {
            bool known = false;
            for (const auto &l : handle->manifest.languages) known = known || l == handle->language;
            if (!known) throw Error(SD_ASR_INVALID_ARGUMENT, "language '" + handle->language + "' not supported by model");
        }

        sdasr::RuntimeOptions options;
        options.provider = get_or<std::string>(config, "provider", "auto");
        options.intra_op_threads = get_or<int>(config, "intra_op_threads", get_or<int>(config, "threads", 0));
        options.inter_op_threads = get_or<int>(config, "inter_op_threads", 1);
        options.allow_unvalidated_providers = get_or<bool>(config, "allow_unvalidated_providers", false);
        options.allow_spinning = get_or<bool>(config, "allow_spinning", true);
        handle->factory = std::make_unique<sdasr::SessionFactory>(options, handle->manifest);
        handle->family = sdasr::create_model_family(handle->manifest, *handle->factory);
        handle->load_seconds = std::chrono::duration<double>(Clock::now() - started).count();
        *out = handle.release();
        return SD_ASR_OK;
    } catch (const Error &e) {
        return fail(error_json, e.status(), e.what());
    } catch (const Ort::Exception &e) {
        return fail(error_json, SD_ASR_MODEL_LOAD_FAILED, e.what());
    } catch (const std::exception &e) {
        return fail(error_json, SD_ASR_MODEL_LOAD_FAILED, e.what());
    } catch (...) {
        return fail(error_json, SD_ASR_MODEL_LOAD_FAILED, "unknown error");
    }
}

sd_asr_status sd_asr_get_status(sd_asr_handle *handle, char **status_json) {
    if (status_json) *status_json = nullptr;
    if (handle == nullptr) return SD_ASR_INVALID_ARGUMENT;
    try {
        set_out(status_json, build_status(handle));
        return SD_ASR_OK;
    } catch (...) {
        return SD_ASR_INFERENCE_FAILED;
    }
}

sd_asr_status sd_asr_transcribe_pcm_f32(sd_asr_handle *handle, const float *mono_samples, uint64_t count,
                                        uint32_t sample_rate, const char *options_json, char **result_json,
                                        char **error_json) {
    if (result_json) *result_json = nullptr;
    if (error_json) *error_json = nullptr;
    if (handle == nullptr) return fail(error_json, SD_ASR_INVALID_ARGUMENT, "handle is NULL");

    bool expected = false;
    if (!handle->busy.compare_exchange_strong(expected, true)) {
        return fail(error_json, SD_ASR_BUSY, "another transcription is running on this handle");
    }
    struct BusyReset {
        sd_asr_handle *h;
        ~BusyReset() {
            std::lock_guard<std::mutex> lock(h->request_mutex);
            h->current_run_options = nullptr;
            h->current_request_id.clear();
            h->busy.store(false);
        }
    } busy_reset{handle};

    std::string request_id;
    try {
        const json options = parse_object(options_json, "options");
        request_id = get_or<std::string>(options, "request_id", "");
        if (request_id.empty()) request_id = std::to_string(handle->next_request_number.fetch_add(1));
        const bool want_timestamps = get_or<bool>(options, "timestamps", true) &&
                                     handle->manifest.has_capability("timestamps");

        // Register the request before any real work, so a cancel issued as
        // soon as the status reports "inference" always finds it.
        Ort::RunOptions run_options;
        {
            std::lock_guard<std::mutex> lock(handle->request_mutex);
            handle->cancelled.store(false);
            handle->current_request_id = request_id;
            handle->current_run_options = &run_options;
        }
        sdasr::RunContext context{&run_options, &handle->cancelled};

        sdasr::CanonicalAudio audio =
            sdasr::canonicalize_audio(mono_samples, count, sample_rate, handle->manifest.sample_rate);

        const auto started = Clock::now();
        sdasr::FamilyResult family_result;
        try {
            family_result = handle->family->transcribe(audio.samples, context);
        } catch (const Ort::Exception &e) {
            if (handle->cancelled.load()) throw Error(SD_ASR_CANCELLED, "request cancelled");
            throw Error(SD_ASR_INFERENCE_FAILED, e.what());
        }
        const double seconds = std::chrono::duration<double>(Clock::now() - started).count();
        const double rtf = audio.input_seconds > 0 ? seconds / audio.input_seconds : 0;

        json result = {
            {"text", family_result.text},
            {"language", handle->language},
            {"model_id", handle->manifest.model_id},
            {"request_id", request_id},
            {"processing_seconds", seconds},
            {"audio_seconds", audio.input_seconds},
            {"rtf", rtf},
            {"provider_requested", handle->factory->resolution().requested},
            {"provider_actual", handle->factory->resolution().actual},
            {"frame_sec", family_result.frame_sec},
        };
        if (!handle->factory->resolution().fallback_reason.empty()) {
            result["provider_fallback_reason"] = handle->factory->resolution().fallback_reason;
        }
        if (want_timestamps) {
            json tokens = json::array();
            for (const auto &t : family_result.tokens) tokens.push_back({{"id", t.id}, {"t", t.t}, {"conf", t.conf}});
            json words = json::array();
            for (const auto &w : family_result.words) {
                words.push_back({{"w", w.w}, {"start", w.start}, {"end", w.end}, {"conf", w.conf}});
            }
            result["tokens"] = std::move(tokens);
            result["words"] = std::move(words);
        }
        if (!audio.warnings.empty()) result["warnings"] = audio.warnings;

        {
            std::lock_guard<std::mutex> lock(handle->request_mutex);
            handle->last_processing_seconds = seconds;
            handle->last_rtf = rtf;
        }
        handle->requests_completed.fetch_add(1);
        set_out(result_json, result);
        return SD_ASR_OK;
    } catch (const Error &e) {
        handle->requests_failed.fetch_add(1);
        return fail(error_json, e.status(), e.what());
    } catch (const std::exception &e) {
        handle->requests_failed.fetch_add(1);
        return fail(error_json, SD_ASR_INFERENCE_FAILED, e.what());
    } catch (...) {
        handle->requests_failed.fetch_add(1);
        return fail(error_json, SD_ASR_INFERENCE_FAILED, "unknown error");
    }
}

sd_asr_status sd_asr_cancel(sd_asr_handle *handle, const char *request_id) {
    if (handle == nullptr) return SD_ASR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lock(handle->request_mutex);
    if (handle->current_run_options == nullptr) return SD_ASR_INVALID_ARGUMENT;
    const bool any = request_id == nullptr || std::strcmp(request_id, "*") == 0;
    if (!any && handle->current_request_id != request_id) return SD_ASR_INVALID_ARGUMENT;
    handle->cancelled.store(true);
    handle->current_run_options->SetTerminate();
    return SD_ASR_OK;
}

void sd_asr_destroy(sd_asr_handle *handle) {
    delete handle;
}

void sd_asr_free(char *buffer) {
    std::free(buffer);
}

}  // extern "C"

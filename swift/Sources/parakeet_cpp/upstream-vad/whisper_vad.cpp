// swift/Sources/parakeet_cpp/upstream-vad/whisper_vad.cpp
//
// Do not hand-edit — re-run scripts/vendor-silero-vad.sh.
//
// This translation unit has two parts:
//
//   1. A small set of GENERIC (non-VAD-specific) helper functions that
//      ggml-org/whisper.cpp's whisper_vad_* implementation calls but that
//      live elsewhere in the ~9,000-line src/whisper.cpp, shared verbatim
//      with whisper.cpp's own (unvendored) ASR/mel/encoder/decoder code:
//      logging macros, a ggml_backend_sched-based graph-compute helper,
//      backend/buffer-type selection (make_buft_list), the whisper_sched
//      wrapper struct, and whisper_context_params + its default-params
//      factory (VAD only reads .use_gpu/.gpu_device from this; the other
//      ASR-specific fields — flash_attn, dtw_* — are carried along
//      unchanged from upstream's struct layout purely for drop-in source
//      fidelity with the extracted VAD functions below, and are otherwise
//      unused here). These are HAND-TRANSCRIBED (not mechanically sed'd,
//      since they are not contiguous with the VAD block below and mixing
//      extraction techniques in one pass would be more fragile, not less)
//      but scripts/vendor-silero-vad.sh greps the freshly fetched upstream
//      source for each one's exact signature before vendoring and FAILS
//      LOUDLY on any mismatch — see that script's
//      REQUIRED_HELPER_SIGNATURES list. Read them side-by-side with
//      PROVENANCE.md's recorded file:line references at the pinned commit
//      to audit.
//
//   2. The whisper_vad_* implementation itself, MECHANICALLY extracted
//      (byte-for-byte, via scripts/vendor-silero-vad.sh's marker-based sed)
//      from the contiguous "Voice Activity Detection (VAD)" section of
//      src/whisper.cpp — struct whisper_vad_hparams through
//      whisper_vad_free_segments(), unmodified except for the
//      #include/logging changes noted where they occur.

#include "include/whisper_vad.h"
#include "whisper_vad_arch.h"

#include "ggml.h"
#include "ggml-cpp.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"

#include <algorithm>
#include <cfloat>
#include <climits>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#ifdef _MSC_VER
#include <codecvt>
#endif

//////////////////////////////////////////////////////////////////////////
// Part 1: hand-transcribed shared helpers (verified against the pinned
// commit by scripts/vendor-silero-vad.sh before this file is written).
//////////////////////////////////////////////////////////////////////////

// -- logging (verbatim from src/whisper.cpp's own logging section) --

static void whisper_log_internal        (ggml_log_level level, const char * format, ...);
static void whisper_log_callback_default(ggml_log_level level, const char * text, void * user_data);

#define WHISPER_LOG_ERROR(...) whisper_log_internal(GGML_LOG_LEVEL_ERROR, __VA_ARGS__)
#define WHISPER_LOG_WARN(...)  whisper_log_internal(GGML_LOG_LEVEL_WARN , __VA_ARGS__)
#define WHISPER_LOG_INFO(...)  whisper_log_internal(GGML_LOG_LEVEL_INFO , __VA_ARGS__)

#define WHISPER_MAX_NODES 4096

// Little-endian only (matches this project's target: Apple Silicon / Intel
// macOS). Upstream guards these behind `#if defined(WHISPER_BIG_ENDIAN)`;
// that macro is never defined by this project's build, so the effective
// (no-op) branch is vendored directly rather than carrying the dead
// big-endian byteswap branch across.
#define BYTESWAP_VALUE(d) do {} while (0)
#define BYTESWAP_TENSOR(t) do {} while (0)

struct whisper_global {
    ggml_log_callback log_callback = whisper_log_callback_default;
    void * log_callback_user_data = nullptr;
};

static whisper_global g_state;

static void whisper_log_internal(ggml_log_level level, const char * format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[1024];
    int len = vsnprintf(buffer, 1024, format, args);
    if (len < 1024) {
        g_state.log_callback(level, buffer, g_state.log_callback_user_data);
    } else {
        char* buffer2 = new char[len+1];
        vsnprintf(buffer2, len+1, format, args);
        buffer2[len] = 0;
        g_state.log_callback(level, buffer2, g_state.log_callback_user_data);
        delete[] buffer2;
    }
    va_end(args);
}

static void whisper_log_callback_default(ggml_log_level level, const char * text, void * user_data) {
    (void) level;
    (void) user_data;
#ifndef WHISPER_DEBUG
    if (level == GGML_LOG_LEVEL_DEBUG) {
        return;
    }
#endif
    fputs(text, stderr);
    fflush(stderr);
}

static std::string format(const char * fmt, ...) {
    va_list ap;
    va_list ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int size = vsnprintf(NULL, 0, fmt, ap);
    GGML_ASSERT(size >= 0 && size < INT_MAX); // NOLINT
    std::vector<char> buf(size + 1);
    int size2 = vsnprintf(buf.data(), size + 1, fmt, ap2);
    GGML_ASSERT(size2 == size);
    va_end(ap2);
    va_end(ap);
    return std::string(buf.data(), size);
}

// -- ggml graph-compute helper (verbatim, ggml_backend_sched_t overload only
//    -- the non-sched overload exists upstream too but is never called by
//    the VAD code path, so it is not vendored) --

static bool ggml_graph_compute_helper(
      ggml_backend_sched_t   sched,
        struct ggml_cgraph * graph,
                       int   n_threads,
                      bool   sched_reset = true) {
    for (int i = 0; i < ggml_backend_sched_get_n_backends(sched); ++i) {
        ggml_backend_t backend = ggml_backend_sched_get_backend(sched, i);
        ggml_backend_dev_t dev = ggml_backend_get_device(backend);
        ggml_backend_reg_t reg = dev ? ggml_backend_dev_backend_reg(dev) : nullptr;

        auto * fn_set_n_threads = (ggml_backend_set_n_threads_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_set_n_threads");
        if (fn_set_n_threads) {
            fn_set_n_threads(backend, n_threads);
        }
    }

    const bool t = (ggml_backend_sched_graph_compute(sched, graph) == GGML_STATUS_SUCCESS);

    if (!t || sched_reset) {
        ggml_backend_sched_reset(sched);
    }

    return t;
}

// -- whisper_sched wrapper (verbatim) --

struct whisper_sched {
    ggml_backend_sched_t sched = nullptr;

    std::vector<uint8_t> meta;
};

static size_t whisper_sched_size(struct whisper_sched & allocr) {
    size_t size = allocr.meta.size();
    for (int i = 0; i < ggml_backend_sched_get_n_backends(allocr.sched); ++i) {
        ggml_backend_t backend = ggml_backend_sched_get_backend(allocr.sched, i);
        size += ggml_backend_sched_get_buffer_size(allocr.sched, backend);
    }
    return size;
}

static bool whisper_sched_graph_init(struct whisper_sched & allocr, std::vector<ggml_backend_t> backends, std::function<struct ggml_cgraph *()> && get_graph) {
    auto & sched = allocr.sched;
    auto & meta  = allocr.meta;

    sched = ggml_backend_sched_new(backends.data(), nullptr, backends.size(), WHISPER_MAX_NODES, false, true);

    meta.resize(ggml_tensor_overhead()*WHISPER_MAX_NODES + ggml_graph_overhead());

    if (!ggml_backend_sched_alloc_graph(sched, get_graph())) {
        WHISPER_LOG_ERROR("%s: failed to allocate the compute buffer\n", __func__);
        return false;
    }

    ggml_backend_sched_reset(sched);

    return true;
}

// -- whisper_context_params (verbatim struct layout from whisper.h) + its
//    default-params factory (verbatim from whisper.cpp). Only .use_gpu and
//    .gpu_device are read by the VAD code below; the rest is carried along
//    unchanged for source fidelity with whisper_backend_init()/
//    whisper_backend_init_gpu()/make_buft_list(), which all take this exact
//    type by reference. --

enum whisper_alignment_heads_preset {
    WHISPER_AHEADS_NONE,
    WHISPER_AHEADS_N_TOP_MOST,
    WHISPER_AHEADS_CUSTOM,
    WHISPER_AHEADS_TINY_EN,
    WHISPER_AHEADS_TINY,
    WHISPER_AHEADS_BASE_EN,
    WHISPER_AHEADS_BASE,
    WHISPER_AHEADS_SMALL_EN,
    WHISPER_AHEADS_SMALL,
    WHISPER_AHEADS_MEDIUM_EN,
    WHISPER_AHEADS_MEDIUM,
    WHISPER_AHEADS_LARGE_V1,
    WHISPER_AHEADS_LARGE_V2,
    WHISPER_AHEADS_LARGE_V3,
    WHISPER_AHEADS_LARGE_V3_TURBO,
};

typedef struct whisper_ahead {
    int n_text_layer;
    int n_head;
} whisper_ahead;

typedef struct whisper_aheads {
    size_t n_heads;
    const whisper_ahead * heads;
} whisper_aheads;

struct whisper_context_params {
    bool  use_gpu;
    bool  flash_attn;
    int   gpu_device;  // CUDA device

    bool dtw_token_timestamps;
    enum whisper_alignment_heads_preset dtw_aheads_preset;

    int dtw_n_top;
    struct whisper_aheads dtw_aheads;

    size_t dtw_mem_size; // TODO: remove (upstream comment, carried verbatim)
};

static struct whisper_context_params whisper_context_default_params() {
    struct whisper_context_params result = {
        /*.use_gpu              =*/ true,
        /*.flash_attn           =*/ true,
        /*.gpu_device           =*/ 0,

        /*.dtw_token_timestamps =*/ false,
        /*.dtw_aheads_preset    =*/ WHISPER_AHEADS_NONE,
        /*.dtw_n_top            =*/ -1,
        /*.dtw_aheads           =*/ {
            /*.n_heads          =*/ 0,
            /*.heads            =*/ NULL,
        },
        /*.dtw_mem_size         =*/ 1024*1024*128,
    };
    return result;
}

// -- backend selection (verbatim) --

using buft_list_t = std::vector<std::pair<ggml_backend_dev_t, ggml_backend_buffer_type_t>>;

static buft_list_t make_buft_list(whisper_context_params & params) {
    // Prio order: GPU -> CPU Extra -> CPU
    buft_list_t buft_list;

    // GPU
    if (params.use_gpu) {
        int cnt = 0;
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t dev = ggml_backend_dev_get(i);
            if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU || ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                if (cnt == params.gpu_device) {
                    auto * buft = ggml_backend_dev_buffer_type(dev);
                    if (buft) {
                        buft_list.emplace_back(dev, buft);
                    }
                }

                if (++cnt > params.gpu_device) {
                    break;
                }
            }
        }
    }

    // CPU Extra
    auto * cpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    auto * cpu_reg = ggml_backend_dev_backend_reg(cpu_dev);
    auto get_extra_bufts_fn = (ggml_backend_dev_get_extra_bufts_t)
        ggml_backend_reg_get_proc_address(cpu_reg, "ggml_backend_dev_get_extra_bufts");
    if (get_extra_bufts_fn) {
        ggml_backend_buffer_type_t * extra_bufts = get_extra_bufts_fn(cpu_dev);
        while (extra_bufts && *extra_bufts) {
            buft_list.emplace_back(cpu_dev, *extra_bufts);
            ++extra_bufts;
        }
    }

    // CPU
    buft_list.emplace_back(cpu_dev, ggml_backend_cpu_buffer_type());

    return buft_list;
}

static ggml_backend_t whisper_backend_init_gpu(const whisper_context_params & params) {
    ggml_log_set(g_state.log_callback, g_state.log_callback_user_data);

    ggml_backend_dev_t dev = nullptr;

    int cnt = 0;
    if (params.use_gpu) {
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            ggml_backend_dev_t dev_cur = ggml_backend_dev_get(i);
            enum ggml_backend_dev_type dev_type = ggml_backend_dev_type(dev_cur);
            const char * dev_name = ggml_backend_dev_name(dev_cur);
            WHISPER_LOG_INFO("%s: device %zu: %s (type: %d)\n", __func__, i, dev_name, dev_type);
            if (dev_type == GGML_BACKEND_DEVICE_TYPE_GPU || dev_type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
                WHISPER_LOG_INFO("%s: found GPU device %zu: %s (type: %d, cnt: %d)\n", __func__, i, dev_name, dev_type, cnt);
                if (cnt == params.gpu_device) {
                    dev = dev_cur;
                }

                if (++cnt > params.gpu_device) {
                    break;
                }
            }
        }
    }

    if (dev == nullptr) {
        WHISPER_LOG_INFO("%s: no GPU found\n", __func__);
        return nullptr;
    }

    WHISPER_LOG_INFO("%s: using %s backend\n", __func__, ggml_backend_dev_name(dev));
    ggml_backend_t result = ggml_backend_dev_init(dev, nullptr);
    if (!result) {
        WHISPER_LOG_ERROR("%s: failed to initialize %s backend\n", __func__, ggml_backend_dev_name(dev));
    }

    return result;
}

static std::vector<ggml_backend_t> whisper_backend_init(const whisper_context_params & params) {
    std::vector<ggml_backend_t> result;

    ggml_backend_t backend_gpu = whisper_backend_init_gpu(params);

    if (backend_gpu) {
        result.push_back(backend_gpu);
    }

    // SuperDictate uses Silero VAD as a small CPU-side segmentation helper.
    // Do not add the registered ACCEL/BLAS backend to this scheduler: on the
    // Intel Accelerate path, short VAD matrix shapes can reach llamafile_sgemm
    // with ldb < k and abort the process. Parakeet keeps its own CPU/Vulkan
    // backend selection; this VAD context intentionally uses the safe CPU
    // backend only.

    ggml_backend_t backend_cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (backend_cpu == nullptr) {
        throw std::runtime_error("failed to initialize CPU backend");
    }
    result.push_back(backend_cpu);

    return result;
}

// -- model-loader read helper (verbatim) --

template<typename T>
static void read_safe(whisper_model_loader * loader, T & dest) {
    loader->read(loader->context, &dest, sizeof(T));
    BYTESWAP_VALUE(dest);
}

//////////////////////////////////////////////////////////////////////////
// Part 2: the whisper_vad_* implementation, mechanically extracted
// (unmodified) from src/whisper.cpp at the pinned commit.
//////////////////////////////////////////////////////////////////////////

struct whisper_vad_hparams {
    int32_t   n_encoder_layers;
    int32_t * encoder_in_channels;
    int32_t * encoder_out_channels;
    int32_t * kernel_sizes;
    int32_t   lstm_input_size;
    int32_t   lstm_hidden_size;
    int32_t   final_conv_in;
    int32_t   final_conv_out;
};

struct whisper_vad_model {
    std::string type;
    std::string version;
    whisper_vad_hparams hparams;

    struct ggml_tensor * stft_forward_basis; // [256, 1, 258]

    // Encoder tensors - 4 convolutional layers
    struct ggml_tensor * encoder_0_weight;  // [3, 129, 128]
    struct ggml_tensor * encoder_0_bias;    // [128]

    // Second encoder layer
    struct ggml_tensor * encoder_1_weight;  // [3, 128, 64]
    struct ggml_tensor * encoder_1_bias;    // [64]

    // Third encoder layer
    struct ggml_tensor * encoder_2_weight;  // [3, 64, 64]
    struct ggml_tensor * encoder_2_bias;    // [64]

    // Fourth encoder layer
    struct ggml_tensor * encoder_3_weight;  // [3, 64, 128]
    struct ggml_tensor * encoder_3_bias;    // [128]

    // LSTM decoder tensors
    struct ggml_tensor * lstm_ih_weight;    // [128, 512] input-to-hidden
    struct ggml_tensor * lstm_ih_bias;      // [512]
    struct ggml_tensor * lstm_hh_weight;    // [128, 512] hidden-to-hidden
    struct ggml_tensor * lstm_hh_bias;      // [512]

    // Final conv layer
    struct ggml_tensor * final_conv_weight; // [128]
    struct ggml_tensor * final_conv_bias;   // [1]

    // ggml contexts
    std::vector<ggml_context *> ctxs;

    // buffer for the model tensors
    std::vector<ggml_backend_buffer_t> buffers;

    // tensors
    int n_loaded;
    std::map<std::string, struct ggml_tensor *> tensors;
};

struct whisper_vad_segment {
    int64_t start;
    int64_t end;
};

struct whisper_vad_segments {
    std::vector<whisper_vad_segment> data;
};

struct whisper_vad_context {
    int64_t t_vad_us = 0;

    int     n_window;
    int     n_context;
    int     n_threads;

    std::vector<ggml_backend_t> backends;
    ggml_backend_buffer_t       buffer = nullptr;
    whisper_context_params      params;
    std::vector<uint8_t>        ctx_buf;
    whisper_sched               sched;

    whisper_vad_model    model;
    std::string          path_model;
    struct ggml_tensor * h_state;
    struct ggml_tensor * c_state;
    std::vector<float>   probs;
};

struct whisper_vad_context_params whisper_vad_default_context_params(void) {
    whisper_vad_context_params result = {
        /*.n_thread                = */ 4,
        /*.use_gpu                 = */ false,
        /*.gpu_device              = */ 0,
    };
    return result;
}

struct whisper_vad_params whisper_vad_default_params(void) {
    whisper_vad_params result = {
        /* threshold               = */ 0.5f,
        /* min_speech_duration_ms  = */ 250,
        /* min_silence_duration_ms = */ 100,
        /* max_speech_duration_s   = */ FLT_MAX,
        /* speech_pad_ms           = */ 30,
        /* samples_overlap         = */ 0.1,
    };
    return result;
}

// Time conversion utility functions for whisper VAD
static int cs_to_samples(int64_t cs) {
    return (int)((cs / 100.0) * WHISPER_SAMPLE_RATE + 0.5);
}

static int64_t samples_to_cs(int samples) {
    return (int64_t)((samples / (double)WHISPER_SAMPLE_RATE) * 100.0 + 0.5);
}

static bool weight_buft_supported(const whisper_vad_hparams & hparams, ggml_tensor * w, ggml_op op, ggml_backend_buffer_type_t buft, ggml_backend_dev_t dev) {
    bool op_supported = true;

    if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU ||
        ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_IGPU ||
        (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_CPU && buft == ggml_backend_cpu_buffer_type())) {
        // GPU and default CPU backend support all operators
        op_supported = true;
    } else {
        switch (op) {
            // The current extra_buffer_type implementations only support GGML_OP_MUL_MAT
            case GGML_OP_MUL_MAT: {
                ggml_init_params params = {
                    /*.mem_size   =*/ 2 * ggml_tensor_overhead(),
                    /*.mem_buffer =*/ nullptr,
                    /*.no_alloc   =*/ true,
                };

                ggml_context_ptr ctx_ptr { ggml_init(params) };
                if (!ctx_ptr) {
                    throw std::runtime_error("failed to create ggml context");
                }
                ggml_context * ctx = ctx_ptr.get();

                ggml_tensor * op_tensor = nullptr;

                int64_t n_ctx = hparams.lstm_hidden_size;
                ggml_tensor * b = ggml_new_tensor_4d(ctx, GGML_TYPE_F32, w->ne[0], n_ctx, w->ne[2], w->ne[3]);
                op_tensor = ggml_mul_mat(ctx, w, b);

                // create a temporary dummy buffer for the weight so that supports_op can check the buffer type
                GGML_ASSERT(w->buffer == nullptr);
                w->buffer = ggml_backend_buft_alloc_buffer(buft, 0);
                op_supported = ggml_backend_dev_supports_op(dev, op_tensor);
                ggml_backend_buffer_free(w->buffer);
                w->buffer = nullptr;
                break;
            }
            default: {
                op_supported = false;
                break;
            }
        };
    }
    return op_supported;
}

static ggml_backend_buffer_type_t select_weight_buft(const whisper_vad_hparams & hparams, ggml_tensor * w, ggml_op op, buft_list_t buft_list) {
    GGML_ASSERT(!buft_list.empty());
    for (const auto & p : buft_list) {
        ggml_backend_dev_t dev = p.first;
        ggml_backend_buffer_type_t buft = p.second;
        if (weight_buft_supported(hparams, w, op, buft, dev)) {
            return buft;
        }
    }

    return nullptr;
}

static ggml_tensor * whisper_vad_build_stft_layer(ggml_context * ctx0,
        const whisper_vad_model & model, ggml_tensor * cur) {
    // Apply reflective padding to the input tensor
    ggml_tensor * padded = ggml_pad_reflect_1d(ctx0, cur, 64, 64);

    struct ggml_tensor * stft = ggml_conv_1d(ctx0, model.stft_forward_basis, padded, model.hparams.lstm_input_size, 0, 1);

    // Calculate cutoff for real/imaginary parts
    int cutoff = model.stft_forward_basis->ne[2] / 2;

    // Extract real part (first half of the STFT output).
    struct ggml_tensor * real_part = ggml_view_2d(ctx0, stft, 4, cutoff, stft->nb[1], 0);
    // Extract imaginary part (second half of the STFT output).
    struct ggml_tensor * img_part = ggml_view_2d(ctx0, stft, 4, cutoff, stft->nb[1], cutoff * stft->nb[1]);

    // Calculate magnitude: sqrt(real^2 + imag^2)
    struct ggml_tensor * real_squared = ggml_mul(ctx0, real_part, real_part);
    struct ggml_tensor * img_squared  = ggml_mul(ctx0, img_part, img_part);
    struct ggml_tensor * sum_squares  = ggml_add(ctx0, real_squared, img_squared);
    struct ggml_tensor * magnitude    = ggml_sqrt(ctx0, sum_squares);
    return magnitude;
}

static ggml_tensor * whisper_vad_build_encoder_layer(ggml_context * ctx0,
        const whisper_vad_model & model, ggml_tensor * cur) {
    // First Conv1D: expands to 128 channels.
    cur = ggml_conv_1d(ctx0, model.encoder_0_weight, cur, 1, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_0_bias, 1, 128, 1));
    cur = ggml_relu(ctx0, cur);

    // Second Conv1D: reduces to 64 channels.
    cur = ggml_conv_1d(ctx0, model.encoder_1_weight, cur, 2, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_1_bias, 1, 64, 1));
    cur = ggml_relu(ctx0, cur);

    // Third Conv1D: maintains 64 channels
    cur = ggml_conv_1d(ctx0, model.encoder_2_weight, cur, 2, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_2_bias, 1, 64, 1));
    cur = ggml_relu(ctx0, cur);

    // Fourth Conv1D: expands to 128 channels
    cur = ggml_conv_1d(ctx0, model.encoder_3_weight, cur, 1, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_3_bias, 1, 128, 1));
    cur = ggml_relu(ctx0, cur);

    return cur;
}

static ggml_tensor * whisper_vad_build_lstm_layer(ggml_context * ctx0,
        const whisper_vad_context & vctx, ggml_tensor * cur, ggml_cgraph * gf) {
    const whisper_vad_model & model = vctx.model;
    const int hdim = model.hparams.lstm_hidden_size;

    struct ggml_tensor * x_t = ggml_transpose(ctx0, cur);

    // Create operations using the input-to-hidden weights.
    struct ggml_tensor * inp_gate = ggml_mul_mat(ctx0, model.lstm_ih_weight, x_t);
    inp_gate = ggml_add(ctx0, inp_gate, model.lstm_ih_bias);

    // Create operations using the hidden-to-hidden weights.
    struct ggml_tensor * hid_gate = ggml_mul_mat(ctx0, model.lstm_hh_weight, vctx.h_state);
    hid_gate = ggml_add(ctx0, hid_gate, model.lstm_hh_bias);

    // Create add operation to get preactivations for all gates.
    struct ggml_tensor * out_gate = ggml_add(ctx0, inp_gate, hid_gate);

    const size_t hdim_size = ggml_row_size(out_gate->type, hdim);

    // Create sigmoid for input gate (using the first 128 bytes from the preactivations).
    struct ggml_tensor * i_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 0 * hdim_size));

    // Create sigmoid for the forget gate (using the second 128 bytes from the preactivations).
    struct ggml_tensor * f_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 1 * hdim_size));

    // Create sigmoid for the cell gate (using the third 128 bytes from the preactivations).
    struct ggml_tensor * g_t = ggml_tanh(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 2 * hdim_size));

    // Create sigmoid for the output gate (using the fourth 128 bytes from the preactivations).
    struct ggml_tensor * o_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 3 * hdim_size));

    // Update cell state
    struct ggml_tensor * c_out = ggml_add(ctx0,
        ggml_mul(ctx0, f_t, vctx.c_state),
        ggml_mul(ctx0, i_t, g_t));
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, c_out, vctx.c_state));

    // Update hidden state
    struct ggml_tensor * out = ggml_mul(ctx0, o_t, ggml_tanh(ctx0, c_out));
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, out,   vctx.h_state));

    return out;
}

static struct ggml_cgraph * whisper_vad_build_graph(whisper_vad_context & vctx) {
    const auto & model = vctx.model;

    struct ggml_init_params params = {
        /*.mem_size   =*/ vctx.sched.meta.size(),
        /*.mem_buffer =*/ vctx.sched.meta.data(),
        /*.no_alloc   =*/ true,
    };

    struct ggml_context * ctx0 = ggml_init(params);

    ggml_cgraph * gf = ggml_new_graph(ctx0);

    struct ggml_tensor * frame = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, vctx.n_window, 1);
    ggml_set_name(frame, "frame");
    ggml_set_input(frame);

    struct ggml_tensor * cur = nullptr;
    {
        cur = whisper_vad_build_stft_layer(ctx0, model, frame);

        cur = whisper_vad_build_encoder_layer(ctx0, model, cur);

        // Extract the first element of the first dimension
        // (equivalent to pytorch's [:, :, 0])
        cur = ggml_view_2d(ctx0, cur, 1, 128, cur->nb[1], 0);

        cur = whisper_vad_build_lstm_layer(ctx0, vctx, cur, gf);
        cur = ggml_relu(ctx0, cur);
        cur = ggml_conv_1d(ctx0, model.final_conv_weight, cur, 1, 0, 1);
        cur = ggml_add(ctx0, cur, model.final_conv_bias);
        cur = ggml_sigmoid(ctx0, cur);
        ggml_set_name(cur, "prob");
        ggml_set_output(cur);
    }

    ggml_build_forward_expand(gf, cur);

    ggml_free(ctx0);

    return gf;
}

static bool whisper_vad_init_context(whisper_vad_context * vctx) {

    auto whisper_context_params = whisper_context_default_params();
    // TODO: GPU VAD is forced disabled until the performance is improved
    //whisper_context_params.use_gpu    = vctx->params.use_gpu;
    whisper_context_params.use_gpu    = false;
    whisper_context_params.gpu_device = vctx->params.gpu_device;

    vctx->backends = whisper_backend_init(whisper_context_params);
    if (vctx->backends.empty()) {
        WHISPER_LOG_ERROR("%s: whisper_backend_init() failed\n", __func__);
        return false;
    }

    const int32_t lstm_hidden_size = vctx->model.hparams.lstm_hidden_size;

    vctx->ctx_buf.resize(2u*ggml_tensor_overhead());

    struct ggml_init_params params = {
        /*.mem_size   =*/ vctx->ctx_buf.size(),
        /*.mem_buffer =*/ vctx->ctx_buf.data(),
        /*.no_alloc   =*/ true,
    };

    ggml_context * ctx = ggml_init(params);
    if (!ctx) {
        WHISPER_LOG_ERROR("%s: failed to init LSTM state ggml context\n", __func__);
        return false;
    }

    // LSTM Hidden state
    vctx->h_state = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, lstm_hidden_size);
    ggml_set_name(vctx->h_state, "h_state");

    // LSTM Cell state
    vctx->c_state = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, lstm_hidden_size);
    ggml_set_name(vctx->c_state, "c_state");

    vctx->buffer = ggml_backend_alloc_ctx_tensors(ctx, vctx->backends[0]);
    ggml_free(ctx);
    if (!vctx->buffer) {
        WHISPER_LOG_ERROR("%s: failed to allocate memory for the VAD state\n", __func__);
        return false;
    }

    {
        bool ok = whisper_sched_graph_init(vctx->sched, vctx->backends,
                [&]() {
                    return whisper_vad_build_graph(*vctx);
                });

        if (!ok) {
            WHISPER_LOG_ERROR("%s: failed to init VAD allocator\n", __func__);
            return false;
        }

        WHISPER_LOG_INFO("%s: compute buffer (VAD)   = %7.2f MB\n", __func__, whisper_sched_size(vctx->sched) / 1e6);
    }

    return true;
}

struct whisper_vad_context * whisper_vad_init_from_file_with_params(
        const char * path_model,
        struct whisper_vad_context_params params) {
    WHISPER_LOG_INFO("%s: loading VAD model from '%s'\n", __func__, path_model);
#ifdef _MSC_VER
    std::wstring_convert<std::codecvt_utf8<wchar_t>> converter;
    std::wstring path_model_wide = converter.from_bytes(path_model);
    auto fin = std::ifstream(path_model_wide, std::ios::binary);
#else
    auto fin = std::ifstream(path_model, std::ios::binary);
#endif
    if (!fin) {
        WHISPER_LOG_ERROR("%s: failed to open VAD model '%s'\n", __func__, path_model);
        return nullptr;
    }

    whisper_model_loader loader = {};
    loader.context = &fin;

    loader.read = [](void * ctx, void * output, size_t read_size) {
        std::ifstream * fin = (std::ifstream*)ctx;
        fin->read((char *)output, read_size);
        return read_size;
    };

    loader.eof = [](void * ctx) {
        std::ifstream * fin = (std::ifstream*)ctx;
        return fin->eof();
    };

    loader.close = [](void * ctx) {
        std::ifstream * fin = (std::ifstream*)ctx;
        fin->close();
    };

    auto ctx = whisper_vad_init_with_params(&loader, params);
    if (!ctx) {
        whisper_vad_free(ctx);
        return nullptr;
    }
    ctx->path_model = path_model;
    return ctx;
}

struct whisper_vad_context * whisper_vad_init_with_params(
            struct whisper_model_loader * loader,
            struct whisper_vad_context_params params) {
    // Read the VAD model
    {
        uint32_t magic;
        read_safe(loader, magic);
        if (magic != GGML_FILE_MAGIC) {
            WHISPER_LOG_ERROR("%s: invalid model data (bad magic)\n", __func__);
            return nullptr;
        }
    }

    whisper_vad_context * vctx = new whisper_vad_context;
    vctx->n_threads = params.n_threads;
    vctx->params.use_gpu = params.use_gpu;
    vctx->params.gpu_device = params.gpu_device;

    auto & model = vctx->model;
    auto & hparams = model.hparams;

    // load model context params.
    {
        int32_t str_len;
        read_safe(loader, str_len);
        std::vector<char> buffer(str_len + 1, 0);
        loader->read(loader->context, buffer.data(), str_len);
        std::string model_type(buffer.data(), str_len);
        model.type = model_type;
        WHISPER_LOG_INFO("%s: model type: %s\n", __func__, model.type.c_str());

        int32_t major, minor, patch;
        read_safe(loader, major);
        read_safe(loader, minor);
        read_safe(loader, patch);
        std::string version_str = std::to_string(major) + "." +
                                  std::to_string(minor) + "." +
                                  std::to_string(patch);
        model.version = version_str;
        WHISPER_LOG_INFO("%s: model version: %s\n", __func__, model.version.c_str());

        read_safe(loader, vctx->n_window);
        read_safe(loader, vctx->n_context);
    }

    // load model hyper params (hparams).
    {
        read_safe(loader, hparams.n_encoder_layers);

        hparams.encoder_in_channels = new int32_t[hparams.n_encoder_layers];
        hparams.encoder_out_channels = new int32_t[hparams.n_encoder_layers];
        hparams.kernel_sizes = new int32_t[hparams.n_encoder_layers];

        for (int32_t i = 0; i < hparams.n_encoder_layers; i++) {
            read_safe(loader, hparams.encoder_in_channels[i]);
            read_safe(loader, hparams.encoder_out_channels[i]);
            read_safe(loader, hparams.kernel_sizes[i]);
        }

        read_safe(loader, hparams.lstm_input_size);
        read_safe(loader, hparams.lstm_hidden_size);
        read_safe(loader, hparams.final_conv_in);
        read_safe(loader, hparams.final_conv_out);

        WHISPER_LOG_INFO("%s: n_encoder_layers = %d\n", __func__, hparams.n_encoder_layers);
        for (int32_t i = 0; i < hparams.n_encoder_layers; i++) {
            WHISPER_LOG_INFO("%s: encoder_in_channels[%d] = %d\n", __func__, i, hparams.encoder_in_channels[i]);
        }
        for (int32_t i = 0; i < hparams.n_encoder_layers; i++) {
            WHISPER_LOG_INFO("%s: encoder_out_channels[%d] = %d\n", __func__, i, hparams.encoder_out_channels[i]);
        }
        WHISPER_LOG_INFO("%s: lstm_input_size = %d\n", __func__, hparams.lstm_input_size);
        WHISPER_LOG_INFO("%s: lstm_hidden_size = %d\n", __func__, hparams.lstm_hidden_size);
        WHISPER_LOG_INFO("%s: final_conv_in = %d\n", __func__, hparams.final_conv_in);
        WHISPER_LOG_INFO("%s: final_conv_out = %d\n", __func__, hparams.final_conv_out);
    }

    // 1 STFT tensor, 4*2 encoder tensors, 4 LSTM tensors, 2 final output tensors
    const size_t n_tensors = hparams.n_encoder_layers * 2 + 4 + 2 + 1;

    std::map<ggml_backend_buffer_type_t, ggml_context *> ctx_map;
    auto get_ctx = [&](ggml_backend_buffer_type_t buft) -> ggml_context * {
        auto it = ctx_map.find(buft);
        if (it == ctx_map.end()) {
            ggml_init_params params = {
                /*.mem_size   =*/ n_tensors * ggml_tensor_overhead(),
                /*.mem_buffer =*/ nullptr,
                /*.no_alloc   =*/ true,
            };

            ggml_context * ctx = ggml_init(params);
            if (!ctx) {
                throw std::runtime_error("failed to create ggml context");
            }

            ctx_map[buft] = ctx;
            model.ctxs.emplace_back(ctx);

            return ctx;
        }

        return it->second;
    };

    whisper_context_params wparams = whisper_context_default_params();
    wparams.use_gpu = params.use_gpu;
    wparams.gpu_device = params.gpu_device;
    buft_list_t buft_list = make_buft_list(wparams);

    auto create_tensor = [&](vad_tensor type, ggml_tensor * meta) -> ggml_tensor * {
        ggml_op op = VAD_TENSOR_OPS.at(type);
        ggml_backend_buffer_type_t buft = select_weight_buft(hparams, meta, op, buft_list);
        if (!buft) {
            throw std::runtime_error(format("failed to find a compatible buffer type for tensor %s", VAD_TENSOR_NAMES.at(type)));
        }
        ggml_context * ctx = get_ctx(buft);
        ggml_tensor * tensor = ggml_dup_tensor(ctx, meta);
        model.tensors[VAD_TENSOR_NAMES.at(type)] = tensor;

        return tensor;
    };

    // create tensors
    {
        ggml_init_params params = {
            /*.mem_size   =*/ n_tensors * ggml_tensor_overhead(),
            /*.mem_buffer =*/ nullptr,
            /*.no_alloc   =*/ true,
        };

        ggml_context * ctx = ggml_init(params);
        const auto & hparams = model.hparams;

        // SFTF precomputed basis matrix
        model.stft_forward_basis = create_tensor(VAD_TENSOR_STFT_BASIS,
            ggml_new_tensor_3d(ctx, GGML_TYPE_F16, 256, 1, 258));

        model.encoder_0_weight = create_tensor(VAD_TENSOR_ENC_0_WEIGHT,
            ggml_new_tensor_3d(
                ctx,
                GGML_TYPE_F16,
                hparams.kernel_sizes[0],
                hparams.encoder_in_channels[0],
                hparams.encoder_out_channels[0]
        ));
        model.encoder_0_bias = create_tensor(VAD_TENSOR_ENC_0_BIAS,
            ggml_new_tensor_1d(ctx, GGML_TYPE_F32, hparams.encoder_out_channels[0]));

        model.encoder_1_weight = create_tensor(VAD_TENSOR_ENC_1_WEIGHT,
            ggml_new_tensor_3d(
                ctx,
                GGML_TYPE_F16,
                hparams.kernel_sizes[1],
                hparams.encoder_in_channels[1],
                hparams.encoder_out_channels[1]
        ));
        model.encoder_1_bias = create_tensor(VAD_TENSOR_ENC_1_BIAS,
            ggml_new_tensor_1d(ctx, GGML_TYPE_F32, hparams.encoder_out_channels[1]));

        model.encoder_2_weight = create_tensor(VAD_TENSOR_ENC_2_WEIGHT,
            ggml_new_tensor_3d(
                ctx,
                GGML_TYPE_F16,
                hparams.kernel_sizes[2],
                hparams.encoder_in_channels[2],
                hparams.encoder_out_channels[2]
        ));
        model.encoder_2_bias = create_tensor(VAD_TENSOR_ENC_2_BIAS,
            ggml_new_tensor_1d(ctx, GGML_TYPE_F32, hparams.encoder_out_channels[2]));

        model.encoder_3_weight = create_tensor(VAD_TENSOR_ENC_3_WEIGHT,
            ggml_new_tensor_3d(
                ctx,
                GGML_TYPE_F16,
                hparams.kernel_sizes[3],
                hparams.encoder_in_channels[3],
                hparams.encoder_out_channels[3]
        ));
        model.encoder_3_bias = create_tensor(VAD_TENSOR_ENC_3_BIAS,
                ggml_new_tensor_1d(ctx, GGML_TYPE_F32, hparams.encoder_out_channels[3]));

        // Hidden State dimension (input gate, forget gate, cell gate, output gate)
        const int hstate_dim = hparams.lstm_hidden_size * 4;

        // LSTM weights - input to hidden
        model.lstm_ih_weight = create_tensor(
            VAD_TENSOR_LSTM_WEIGHT_IH,
            ggml_new_tensor_2d(ctx, GGML_TYPE_F32, hparams.lstm_hidden_size, hstate_dim)
        );
        model.lstm_ih_bias = create_tensor(
            VAD_TENSOR_LSTM_BIAS_IH,
            ggml_new_tensor_1d(ctx, GGML_TYPE_F32, hstate_dim)
        );

        // LSTM weights - hidden to hidden
        model.lstm_hh_weight = create_tensor(
            VAD_TENSOR_LSTM_WEIGHT_HH,
            ggml_new_tensor_2d(ctx, GGML_TYPE_F32, hparams.lstm_hidden_size, hstate_dim)
        );
        model.lstm_hh_bias = create_tensor(
            VAD_TENSOR_LSTM_BIAS_HH,
            ggml_new_tensor_1d(ctx, GGML_TYPE_F32, hstate_dim)
        );

        // Final conv layer weight
        model.final_conv_weight = create_tensor(
            VAD_TENSOR_FINAL_CONV_WEIGHT,
            ggml_new_tensor_2d(ctx, GGML_TYPE_F16, hparams.final_conv_in, 1)
        );
        model.final_conv_bias = create_tensor(
            VAD_TENSOR_FINAL_CONV_BIAS,
            ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 1)
        );

        ggml_free(ctx);
    }

    // allocate tensors in the backend buffers
    for (auto & p : ctx_map) {
        ggml_backend_buffer_type_t buft = p.first;
        ggml_context * ctx = p.second;
        ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, buft);
        if (buf) {
            model.buffers.emplace_back(buf);

            size_t size_main = ggml_backend_buffer_get_size(buf);
            WHISPER_LOG_INFO("%s: %12s total size = %8.2f MB\n", __func__, ggml_backend_buffer_name(buf), size_main / 1e6);
        }
    }

    // load weights
    {
        size_t total_size = 0;
        model.n_loaded = 0;
        std::vector<char> read_buf;

        while (true) {
            int32_t n_dims;
            int32_t length;
            int32_t ttype;

            read_safe(loader, n_dims);
            read_safe(loader, length);
            read_safe(loader, ttype);

            if (loader->eof(loader->context)) {
                break;
            }

            int32_t nelements = 1;
            int32_t ne[4] = { 1, 1, 1, 1 };
            for (int i = 0; i < n_dims; ++i) {
                read_safe(loader, ne[i]);
                nelements *= ne[i];
            }

            std::string name;
            std::vector<char> tmp(length);
            loader->read(loader->context, &tmp[0], tmp.size());
            name.assign(&tmp[0], tmp.size());

            if (model.tensors.find(name) == model.tensors.end()) {
                WHISPER_LOG_ERROR("%s: unknown tensor '%s' in model file\n", __func__, name.data());
                return nullptr;
            }

            auto tensor = model.tensors[name.data()];

            if (ggml_nelements(tensor) != nelements) {
                WHISPER_LOG_ERROR("%s: tensor '%s' has wrong size in model file\n", __func__, name.data());
                WHISPER_LOG_ERROR("%s: shape: [%d, %d, %d], expected: [%d, %d, %d]\n",
                        __func__, ne[0], ne[1], ne[2], (int) tensor->ne[0], (int) tensor->ne[1], (int) tensor->ne[2]);
                return nullptr;
            }

            if (tensor->ne[0] != ne[0] || tensor->ne[1] != ne[1] || tensor->ne[2] != ne[2]) {
                WHISPER_LOG_ERROR("%s: tensor '%s' has wrong shape in model file: got [%d, %d, %d], expected [%d, %d, %d]\n",
                        __func__, name.data(), (int) tensor->ne[0], (int) tensor->ne[1], (int) tensor->ne[2], ne[0], ne[1], ne[2]);
                return nullptr;
            }

            const size_t bpe = ggml_type_size(ggml_type(ttype));

            if ((nelements*bpe)/ggml_blck_size(tensor->type) != ggml_nbytes(tensor)) {
                WHISPER_LOG_ERROR("%s: tensor '%s' has wrong size in model file: got %zu, expected %zu\n",
                        __func__, name.data(), ggml_nbytes(tensor), nelements*bpe);
                return nullptr;
            }

            if (ggml_backend_buffer_is_host(tensor->buffer)) {
                // for the CPU and Metal backend, we can read directly into the tensor
                loader->read(loader->context, tensor->data, ggml_nbytes(tensor));
                BYTESWAP_TENSOR(tensor);
            } else {
                // read into a temporary buffer first, then copy to device memory
                read_buf.resize(ggml_nbytes(tensor));

                loader->read(loader->context, read_buf.data(), read_buf.size());

                ggml_backend_tensor_set(tensor, read_buf.data(), 0, ggml_nbytes(tensor));
            }

            total_size += ggml_nbytes(tensor);
            model.n_loaded++;
        }

        WHISPER_LOG_INFO("%s: model size    = %7.2f MB\n", __func__, total_size/1e6);

        if (model.n_loaded == 0) {
            WHISPER_LOG_WARN("%s: WARN no tensors loaded from model file - assuming empty model for testing\n", __func__);
        } else if (model.n_loaded != (int) model.tensors.size()) {
            WHISPER_LOG_ERROR("%s: ERROR not all tensors loaded from model file - expected %zu, got %d\n", __func__, model.tensors.size(), model.n_loaded);
            return nullptr;
        }

    }

    if (!whisper_vad_init_context(vctx)) {
        whisper_vad_free(vctx);
        return nullptr;
    }

    return vctx;
}

void whisper_vad_reset_state(whisper_vad_context * vctx) {
    ggml_backend_buffer_clear(vctx->buffer, 0);
}

bool whisper_vad_detect_speech_no_reset(
        struct whisper_vad_context * vctx,
        const float * samples,
        int n_samples) {
    int n_chunks = n_samples / vctx->n_window;
    if (n_samples % vctx->n_window != 0) {
        n_chunks += 1;  // Add one more chunk for remaining samples.
    }

    WHISPER_LOG_INFO("%s: detecting speech in %d samples\n", __func__, n_samples);
    WHISPER_LOG_INFO("%s: n_chunks: %d\n", __func__, n_chunks);

    vctx->probs.resize(n_chunks);
    WHISPER_LOG_INFO("%s: props size: %u\n", __func__, n_chunks);

    std::vector<float> window(vctx->n_window, 0.0f);

    auto & sched = vctx->sched.sched;

    ggml_cgraph * gf = whisper_vad_build_graph(*vctx);

    if (!ggml_backend_sched_alloc_graph(sched, gf)) {
        WHISPER_LOG_ERROR("%s: failed to allocate the compute buffer\n", __func__);
        return false;
    }

    struct ggml_tensor * frame = ggml_graph_get_tensor(gf, "frame");
    struct ggml_tensor * prob  = ggml_graph_get_tensor(gf, "prob");

    // we are going to reuse the graph multiple times for each chunk
    const int64_t t_start_vad_us = ggml_time_us();

    for (int i = 0; i < n_chunks; i++) {
        const int idx_start = i * vctx->n_window;
        const int idx_end = std::min(idx_start + vctx->n_window, n_samples);

        const int chunk_len = idx_end - idx_start;

        if (chunk_len < vctx->n_window) {
            WHISPER_LOG_INFO("%s: chunk_len: %d < n_window: %d\n", __func__, chunk_len, vctx->n_window);
            std::vector<float> partial_chunk(vctx->n_window, 0.0f);
            std::copy(samples + idx_start, samples + idx_end, partial_chunk.begin());

            // Copy the zero-padded chunk to the window.
            const int samples_to_copy_max = vctx->n_window;
            const int samples_to_copy_cur = std::min(samples_to_copy_max, (int)partial_chunk.size());
            std::copy(partial_chunk.begin(), partial_chunk.begin() + samples_to_copy_cur, window.begin());
            if (samples_to_copy_cur < samples_to_copy_max) {
                std::fill(window.begin() + samples_to_copy_cur, window.end(), 0.0f);
            }
        } else {
            // Copy current frame samples to the window.
            const int samples_to_copy = std::min(idx_end - idx_start, vctx->n_window);
            std::copy(samples + idx_start, samples + idx_start + samples_to_copy, window.begin());
        }

        // Set the frame tensor data with the samples.
        ggml_backend_tensor_set(frame, window.data(), 0, ggml_nelements(frame) * sizeof(float));

        // do not reset the scheduler - we will reuse the graph in the next chunk
        if (!ggml_graph_compute_helper(sched, gf, vctx->n_threads, false)) {
            WHISPER_LOG_ERROR("%s: failed to compute VAD graph\n", __func__);
            break;
        }

        // Get the probability for this chunk.
        ggml_backend_tensor_get(prob, &vctx->probs[i], 0, sizeof(float));

        //WHISPER_LOG_DEBUG("chunk %d: p = %7.3f\n", i, probs[i]);
    }

    vctx->t_vad_us += ggml_time_us() - t_start_vad_us;
    WHISPER_LOG_INFO("%s: vad time = %.2f ms processing %d samples\n", __func__, 1e-3f * vctx->t_vad_us, n_samples);

    ggml_backend_sched_reset(sched);

    return true;
}

bool whisper_vad_detect_speech(
        struct whisper_vad_context * vctx,
        const float * samples,
        int n_samples) {
    whisper_vad_reset_state(vctx);
    return whisper_vad_detect_speech_no_reset(vctx, samples, n_samples);
}

int whisper_vad_segments_n_segments(struct whisper_vad_segments * segments) {
    return segments->data.size();
}

float whisper_vad_segments_get_segment_t0(struct whisper_vad_segments * segments, int i_segment) {
    return segments->data[i_segment].start;
}

float whisper_vad_segments_get_segment_t1(struct whisper_vad_segments * segments, int i_segment) {
    return segments->data[i_segment].end;
}

int whisper_vad_n_probs(struct whisper_vad_context * vctx) {
    return vctx->probs.size();
}

float * whisper_vad_probs(struct whisper_vad_context * vctx) {
    return vctx->probs.data();
}

struct whisper_vad_segments * whisper_vad_segments_from_probs(
        struct whisper_vad_context *  vctx,
                whisper_vad_params    params) {
    WHISPER_LOG_INFO("%s: detecting speech timestamps using %d probabilities\n", __func__, whisper_vad_n_probs(vctx));

    int     n_probs                 = whisper_vad_n_probs(vctx);
    float * probs                   = whisper_vad_probs(vctx);
    float   threshold               = params.threshold;
    int     min_speech_duration_ms  = params.min_speech_duration_ms;
    int     min_silence_duration_ms = params.min_silence_duration_ms;
    float   max_speech_duration_s   = params.max_speech_duration_s;
    int     speech_pad_ms           = params.speech_pad_ms;
    int     n_window                = vctx->n_window;
    int     sample_rate             = WHISPER_SAMPLE_RATE;
    int     min_silence_samples     = sample_rate * min_silence_duration_ms / 1000;
    int     audio_length_samples    = n_probs * n_window;

    // Min number of samples to be considered valid speech.
    int     min_speech_samples      = sample_rate * min_speech_duration_ms / 1000;
    int     speech_pad_samples      = sample_rate * speech_pad_ms / 1000;

    // Max number of samples that a speech segment can contain before it is
    // split into multiple segments.
    int max_speech_samples;
    if (max_speech_duration_s > 100000.0f) {
        max_speech_samples = INT_MAX / 2;
    } else {
        int64_t temp = (int64_t)sample_rate * (int64_t)(max_speech_duration_s) - n_window - 2 * speech_pad_samples;
        max_speech_samples = (temp > INT_MAX) ? INT_MAX / 2 : (int)temp;
        if (max_speech_samples < 0) {
            max_speech_samples = INT_MAX / 2;
        }
    }
    // Detect silence period that exceeds this value, then that location (sample)
    // is marked as a potential place where the segment could be split if
    // max_speech_samples is reached. The value 98 was taken from the original
    // silaro-vad python implementation:
    //https://github.com/snakers4/silero-vad/blob/0dd45f0bcd7271463c234f3bae5ad25181f9df8b/src/silero_vad/utils_vad.py#L291
    int min_silence_samples_at_max_speech = sample_rate * 98 / 1000;

    // Calculate lower threshold for detecting end of speech segments.
    float neg_threshold = threshold - 0.15f;
    if (neg_threshold < 0.01f) {
        neg_threshold = 0.01f;
    }

    struct speech_segment_t {
        int start;
        int end;
    };

    std::vector<speech_segment_t> speeches;
    speeches.reserve(256);

    bool is_speech_segment = false;
    int  temp_end          = 0;
    int  prev_end          = 0;
    int  next_start        = 0;
    int  curr_speech_start = 0;
    bool has_curr_speech   = false;

    for (int i = 0; i < n_probs; i++) {
        float curr_prob   = probs[i];
        int   curr_sample = n_window * i;

        // Reset temp_end when we get back to speech
        if ((curr_prob >= threshold) && temp_end) {
            temp_end = 0;
            if (next_start < prev_end) {
                next_start = curr_sample;
            }
        }

        // Start a new speech segment when probability exceeds threshold and not already in speech
        if ((curr_prob >= threshold) && !is_speech_segment) {
            is_speech_segment = true;
            curr_speech_start = curr_sample;
            has_curr_speech = true;
            continue;
        }

        // Handle maximum speech duration
        if (is_speech_segment && (curr_sample - curr_speech_start) > max_speech_samples) {
            if (prev_end) {
                speeches.push_back({ curr_speech_start, prev_end });
                has_curr_speech = true;

                if (next_start < prev_end) {  // Previously reached silence and is still not speech
                    is_speech_segment = false;
                    has_curr_speech = false;
                } else {
                    curr_speech_start = next_start;
                }
                prev_end = next_start = temp_end = 0;
            } else {
                speeches.push_back({ curr_speech_start, curr_sample });

                prev_end = next_start = temp_end = 0;
                is_speech_segment = false;
                has_curr_speech = false;
                continue;
            }
        }

        // Handle silence after speech
        if ((curr_prob < neg_threshold) && is_speech_segment) {
            if (!temp_end) {
                temp_end = curr_sample;
            }

            // Track potential segment ends for max_speech handling
            if ((curr_sample - temp_end) > min_silence_samples_at_max_speech) {
                prev_end = temp_end;
            }

            // Check if silence is long enough to end the segment
            if ((curr_sample - temp_end) < min_silence_samples) {
                continue;
            } else {
                // End the segment if it's long enough
                if ((temp_end - curr_speech_start) > min_speech_samples) {
                    speeches.push_back({ curr_speech_start, temp_end });
                }

                prev_end = next_start = temp_end = 0;
                is_speech_segment = false;
                has_curr_speech = false;
                continue;
            }
        }
    }

    // Handle the case if we're still in a speech segment at the end
    if (has_curr_speech && (audio_length_samples - curr_speech_start) > min_speech_samples) {
        speeches.push_back({ curr_speech_start, audio_length_samples });
    }

    // Merge adjacent segments with small gaps in between (post-processing)
    if (speeches.size() > 1) {
        int merged_count = 0;
        for (int i = 0; i < (int) speeches.size() - 1; i++) {
            // Define maximum gap allowed for merging (e.g., 200ms converted to samples)
            int max_merge_gap_samples = sample_rate * 200 / 1000;

            // If the gap between this segment and the next is small enough
            if (speeches[i+1].start - speeches[i].end < max_merge_gap_samples) {
                // Merge by extending current segment to the end of next segment
                speeches[i].end = speeches[i+1].end;
                speeches.erase(speeches.begin() + i + 1);

                i--;
                merged_count++;
            }
        }
        WHISPER_LOG_INFO("%s: Merged %d adjacent segments, now have %d segments\n",
                         __func__, merged_count, (int) speeches.size());
    }

    // Double-check for minimum speech duration
    for (int i = 0; i < (int) speeches.size(); i++) {
        if (speeches[i].end - speeches[i].start < min_speech_samples) {
            WHISPER_LOG_INFO("%s: Removing segment %d (too short: %d samples)\n",
                            __func__, i, speeches[i].end - speeches[i].start);

            speeches.erase(speeches.begin() + i);
            i--;
        }
    }

    WHISPER_LOG_INFO("%s: Final speech segments after filtering: %d\n", __func__, (int) speeches.size());

    // Allocate final segments
    std::vector<whisper_vad_segment> segments;
    if (speeches.size() > 0) {
        try {
            segments.resize(speeches.size());
        } catch (const std::bad_alloc &) {
            WHISPER_LOG_ERROR("%s: failed to allocate memory for final segments\n", __func__);
            return nullptr;
        }
    }

    // Apply padding to segments and copy to final segments
    for (int i = 0; i < (int) speeches.size(); i++) {
        // Apply padding to the start of the first segment
        if (i == 0) {
            speeches[i].start =
                (speeches[i].start > speech_pad_samples) ?
                (speeches[i].start - speech_pad_samples) : 0;
        }

        // Handle spacing between segments
        if (i < (int) speeches.size() - 1) {
            int silence_duration = speeches[i+1].start - speeches[i].end;

            if (silence_duration < 2 * speech_pad_samples) {
                // If segments are close, split the difference
                speeches[i].end += silence_duration / 2;
                speeches[i+1].start =
                    (speeches[i+1].start > silence_duration / 2) ?
                    (speeches[i+1].start - silence_duration / 2) : 0;
            } else {
                // Otherwise, apply full padding to both
                speeches[i].end =
                    (speeches[i].end + speech_pad_samples < audio_length_samples) ?
                    (speeches[i].end + speech_pad_samples) : audio_length_samples;
                speeches[i+1].start =
                    (speeches[i+1].start > speech_pad_samples) ?
                    (speeches[i+1].start - speech_pad_samples) : 0;
            }
        } else {
            // Apply padding to the end of the last segment
            speeches[i].end =
                (speeches[i].end + speech_pad_samples < audio_length_samples) ?
                (speeches[i].end + speech_pad_samples) : audio_length_samples;
        }

        // Convert from samples to centiseconds
        segments[i].start = samples_to_cs(speeches[i].start);
        segments[i].end   = samples_to_cs(speeches[i].end);

        WHISPER_LOG_INFO("%s: VAD segment %d: start = %.2f, end = %.2f (duration: %.2f)\n",
                        __func__, i, segments[i].start/100.0, segments[i].end/100.0, (segments[i].end - segments[i].start)/100.0);
    }

    whisper_vad_segments * vad_segments = new whisper_vad_segments;
    if (vad_segments == NULL) {
        WHISPER_LOG_ERROR("%s: failed to allocate memory for whisper_vad_segments\n", __func__);
        return nullptr;
    }

    vad_segments->data = std::move(segments);

    return vad_segments;
}

struct whisper_vad_segments * whisper_vad_segments_from_samples(
        whisper_vad_context * vctx,
        whisper_vad_params params,
        const float * samples,
        int n_samples) {
    WHISPER_LOG_INFO("%s: detecting speech timestamps in %d samples\n", __func__, n_samples);
    if (!whisper_vad_detect_speech(vctx, samples, n_samples)) {
        WHISPER_LOG_ERROR("%s: failed to detect speech\n", __func__);
        return nullptr;
    }
    return whisper_vad_segments_from_probs(vctx, params);
}

void whisper_vad_free(whisper_vad_context * ctx) {
    if (ctx) {
        if (ctx->buffer) {
            ggml_backend_buffer_free(ctx->buffer);
        }
        for (ggml_context * context : ctx->model.ctxs) {
            ggml_free(context);
        }

        for (ggml_backend_buffer_t buf : ctx->model.buffers) {
            ggml_backend_buffer_free(buf);
        }

        ggml_backend_sched_free(ctx->sched.sched);

        for (auto & backend : ctx->backends) {
            ggml_backend_free(backend);
        }

        delete[] ctx->model.hparams.encoder_in_channels;
        delete[] ctx->model.hparams.encoder_out_channels;
        delete[] ctx->model.hparams.kernel_sizes;

        delete ctx;
    }
}

void whisper_vad_free_segments(whisper_vad_segments * segments) {
    if (segments) {
        delete segments;
    }
}

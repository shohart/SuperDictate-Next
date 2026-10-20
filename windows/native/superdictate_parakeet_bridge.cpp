// SuperDictate — a thin C bridge over whisper.cpp's in-tree Parakeet.
//
// Mirrors the conventions of the macOS build's own bridge
// (swift/Sources/parakeet_cpp/bridge/superdictate_parakeet.cpp), for the
// same reason it exists there: the caller must never see an upstream type.
//
// Upstream's `parakeet_full` takes `parakeet_full_params` BY VALUE — a
// large struct of ints, bools and six function pointers. Binding that from
// Python would mean transcribing its exact layout into ctypes and keeping
// the transcription correct across every upstream change, where a silently
// wrong offset produces not an error but garbage. This file is the answer:
// four functions, only scalars and pointers across the boundary, and the
// struct handled on the side of the wall that has the header.
//
// Everything is wrapped in try/catch: a C++ exception crossing an extern
// "C" boundary is undefined behaviour, and a failed transcription must
// come back as a status code, never as a crashed dictation.

#include "parakeet.h"

#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <new>
#include <string>
#include <vector>

// Our own export macro, NOT parakeet.h's. PARAKEET_API expands to
// __declspec(dllimport) in anything that is not building parakeet itself,
// so reusing it here marked these functions as imports and left the DLL
// with nothing exported at all.
#ifdef _WIN32
#  define SD_API __declspec(dllexport)
#else
#  define SD_API __attribute__((visibility("default")))
#endif

extern "C" {

typedef enum {
    SD_PARAKEET_OK = 0,
    SD_PARAKEET_ERR_NULL_ARGUMENT = 1,
    SD_PARAKEET_ERR_MODEL_LOAD_FAILED = 2,
    SD_PARAKEET_ERR_EMPTY_AUDIO = 3,
    SD_PARAKEET_ERR_INFERENCE_FAILED = 4,
    SD_PARAKEET_ERR_NATIVE_EXCEPTION = 5
} sd_parakeet_status;

// One transcription's output, owned by the bridge until the caller frees it.
// Tokens are returned as a single NUL-separated blob plus a count rather
// than an array of pointers: one allocation, one free, and nothing for the
// caller to walk incorrectly.
typedef struct sd_parakeet_result {
    char *   text;              // NUL-terminated, the whole transcript
    char *   token_blob;        // count NUL-terminated strings, back to back
    int64_t  token_blob_bytes;
    float *  token_times;       // seconds, one per token
    // Upstream tells us outright where a word begins, which beats
    // inferring it from a leading space on the token text: the model knows,
    // and the space convention is a property of the tokenizer that could
    // change under us.
    uint8_t * token_word_start; // 1 where a new word begins
    int32_t  token_count;
} sd_parakeet_result;

struct sd_parakeet_context {
    parakeet_context * ctx = nullptr;
    std::string last_error;
};

SD_API sd_parakeet_status sd_parakeet_create(const char * model_path,
                                                   bool use_gpu,
                                                   int gpu_device,
                                                   sd_parakeet_context ** out_context) {
    if (model_path == nullptr || out_context == nullptr) {
        return SD_PARAKEET_ERR_NULL_ARGUMENT;
    }
    *out_context = nullptr;
    try {
        auto * wrapper = new sd_parakeet_context();
        parakeet_context_params params = parakeet_context_default_params();
        params.use_gpu    = use_gpu;
        params.gpu_device = gpu_device;
        wrapper->ctx = parakeet_init_from_file_with_params(model_path, params);
        if (wrapper->ctx == nullptr) {
            delete wrapper;
            return SD_PARAKEET_ERR_MODEL_LOAD_FAILED;
        }
        *out_context = wrapper;
        return SD_PARAKEET_OK;
    } catch (...) {
        return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }
}

SD_API sd_parakeet_status sd_parakeet_transcribe(sd_parakeet_context * context,
                                                       const float * samples,
                                                       int64_t sample_count,
                                                       int32_t n_threads,
                                                       sd_parakeet_result * out_result) {
    if (context == nullptr || samples == nullptr || out_result == nullptr) {
        return SD_PARAKEET_ERR_NULL_ARGUMENT;
    }
    if (sample_count <= 0) {
        return SD_PARAKEET_ERR_EMPTY_AUDIO;
    }
    std::memset(out_result, 0, sizeof(*out_result));

    try {
        parakeet_full_params params =
            parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
        if (n_threads > 0) {
            params.n_threads = n_threads;
        }
        // Every callback stays null: progress is not wanted here, and a
        // callback into Python from a worker thread would be a second
        // lifetime problem for no benefit.
        if (parakeet_full(context->ctx, params, samples,
                          static_cast<int>(sample_count)) != 0) {
            context->last_error = "parakeet_full failed";
            return SD_PARAKEET_ERR_INFERENCE_FAILED;
        }

        std::string text;
        std::string blob;
        std::vector<float> times;
        std::vector<uint8_t> word_starts;

        const int segments = parakeet_full_n_segments(context->ctx);
        for (int s = 0; s < segments; ++s) {
            const char * segment_text = parakeet_full_get_segment_text(context->ctx, s);
            if (segment_text != nullptr) {
                text += segment_text;
            }
            const int tokens = parakeet_full_n_tokens(context->ctx, s);
            for (int t = 0; t < tokens; ++t) {
                const char * piece = parakeet_full_get_token_text(context->ctx, s, t);
                blob.append(piece == nullptr ? "" : piece);
                blob.push_back('\0');
                // Upstream reports token times in centiseconds relative to
                // the start of the audio; seconds are what every caller
                // actually wants, and converting here keeps the unit from
                // being rediscovered on the other side of the boundary.
                const parakeet_token_data data =
                    parakeet_full_get_token_data(context->ctx, s, t);
                times.push_back(static_cast<float>(data.t0) / 100.0f);
                word_starts.push_back(data.is_word_start ? 1 : 0);
            }
        }

        out_result->text = static_cast<char *>(std::malloc(text.size() + 1));
        if (out_result->text == nullptr) {
            return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
        }
        std::memcpy(out_result->text, text.c_str(), text.size() + 1);

        out_result->token_blob_bytes = static_cast<int64_t>(blob.size());
        out_result->token_blob = static_cast<char *>(std::malloc(blob.size() + 1));
        if (out_result->token_blob == nullptr) {
            std::free(out_result->text);
            out_result->text = nullptr;
            return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
        }
        std::memcpy(out_result->token_blob, blob.data(), blob.size());
        out_result->token_blob[blob.size()] = '\0';

        out_result->token_count = static_cast<int32_t>(times.size());
        if (!times.empty()) {
            out_result->token_times =
                static_cast<float *>(std::malloc(times.size() * sizeof(float)));
            if (out_result->token_times == nullptr) {
                std::free(out_result->text);
                std::free(out_result->token_blob);
                std::memset(out_result, 0, sizeof(*out_result));
                return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
            }
            std::memcpy(out_result->token_times, times.data(),
                        times.size() * sizeof(float));

            out_result->token_word_start =
                static_cast<uint8_t *>(std::malloc(word_starts.size()));
            if (out_result->token_word_start == nullptr) {
                std::free(out_result->text);
                std::free(out_result->token_blob);
                std::free(out_result->token_times);
                std::memset(out_result, 0, sizeof(*out_result));
                return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
            }
            std::memcpy(out_result->token_word_start, word_starts.data(),
                        word_starts.size());
        }
        return SD_PARAKEET_OK;
    } catch (...) {
        context->last_error = "native exception";
        return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }
}

SD_API void sd_parakeet_free_result(sd_parakeet_result * result) {
    if (result == nullptr) {
        return;
    }
    std::free(result->text);
    std::free(result->token_blob);
    std::free(result->token_times);
    std::free(result->token_word_start);
    std::memset(result, 0, sizeof(*result));
}

SD_API void sd_parakeet_destroy(sd_parakeet_context * context) {
    if (context == nullptr) {
        return;
    }
    if (context->ctx != nullptr) {
        parakeet_free(context->ctx);
    }
    delete context;
}

SD_API const char * sd_parakeet_last_error(const sd_parakeet_context * context) {
    return context == nullptr ? "" : context->last_error.c_str();
}

} // extern "C"

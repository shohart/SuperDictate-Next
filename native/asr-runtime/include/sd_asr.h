/*
 * sd_asr.h — SuperDictate cross-platform ASR runtime, C ABI v1.
 *
 * See docs/specs/cross-platform-onnx-asr-spec.md §4. Every function is
 * plain C so it can be consumed from Swift, a Windows native frontend, or
 * the SuperDictateOnnxHost helper process.
 *
 * Memory ownership: every `char **` out-parameter receives either NULL or a
 * NUL-terminated UTF-8 buffer allocated by this library. Release it with
 * sd_asr_free() and nothing else. Any out-parameter may be passed as NULL
 * when the caller does not want it.
 *
 * Concurrency: one handle runs one inference at a time. A transcription
 * call that overlaps another on the same handle returns SD_ASR_BUSY without
 * touching the running one. sd_asr_cancel() and sd_asr_get_status() are safe
 * to call from any thread while a transcription runs. sd_asr_destroy() must
 * not race with any other call on the same handle.
 */
#ifndef SD_ASR_H
#define SD_ASR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(SD_ASR_BUILD_SHARED)
#define SD_ASR_API __declspec(dllexport)
#elif defined(_WIN32) && defined(SD_ASR_USE_SHARED)
#define SD_ASR_API __declspec(dllimport)
#elif defined(__GNUC__) || defined(__clang__)
#define SD_ASR_API __attribute__((visibility("default")))
#else
#define SD_ASR_API
#endif

#define SD_ASR_API_VERSION 1u

typedef enum sd_asr_status {
    SD_ASR_OK = 0,
    SD_ASR_INVALID_ARGUMENT = 1,
    SD_ASR_INVALID_MODEL = 2,
    SD_ASR_UNSUPPORTED_MODEL_FAMILY = 3,
    SD_ASR_INVALID_AUDIO = 4,
    SD_ASR_PROVIDER_UNAVAILABLE = 5,
    SD_ASR_MODEL_LOAD_FAILED = 6,
    SD_ASR_INFERENCE_FAILED = 7,
    SD_ASR_CANCELLED = 8,
    SD_ASR_TIMEOUT = 9,         /* produced by the host/IPC layer */
    SD_ASR_RUNTIME_CRASHED = 10, /* produced by the host/IPC layer */
    SD_ASR_BUSY = 11
} sd_asr_status;

typedef struct sd_asr_handle sd_asr_handle;

/* Returns SD_ASR_API_VERSION of the linked library. */
SD_ASR_API uint32_t sd_asr_api_version(void);

/* Stable snake_case category name for a status ("invalid_audio", ...).
 * The returned pointer is static; never free it. */
SD_ASR_API const char *sd_asr_status_name(sd_asr_status status);

/* Loads a model. `config_json` (spec §4.2) must name `model_directory`
 * containing a manifest.json. On failure `*out` is NULL and `*error_json`
 * is {"category":..., "message":...}. */
SD_ASR_API sd_asr_status sd_asr_create(const char *config_json,
                                       sd_asr_handle **out,
                                       char **error_json);

/* Model/provider/state snapshot as JSON. */
SD_ASR_API sd_asr_status sd_asr_get_status(sd_asr_handle *handle,
                                           char **status_json);

/* Transcribes mono float32 PCM. `options_json` may be NULL or e.g.
 * {"request_id":"42","timestamps":true}. */
SD_ASR_API sd_asr_status sd_asr_transcribe_pcm_f32(sd_asr_handle *handle,
                                                   const float *mono_samples,
                                                   uint64_t count,
                                                   uint32_t sample_rate,
                                                   const char *options_json,
                                                   char **result_json,
                                                   char **error_json);

/* Requests cancellation of the running request whose id equals
 * `request_id`, or of any running request when `request_id` is "*" or
 * NULL. Returns SD_ASR_OK when a running request was signalled and
 * SD_ASR_INVALID_ARGUMENT when nothing matching is running. */
SD_ASR_API sd_asr_status sd_asr_cancel(sd_asr_handle *handle,
                                       const char *request_id);

SD_ASR_API void sd_asr_destroy(sd_asr_handle *handle);

/* Frees a buffer returned by this library. NULL is a no-op. */
SD_ASR_API void sd_asr_free(char *buffer);

#ifdef __cplusplus
}
#endif

#endif /* SD_ASR_H */

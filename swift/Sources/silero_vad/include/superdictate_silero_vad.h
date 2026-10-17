#ifndef SUPERDICTATE_SILERO_VAD_H
#define SUPERDICTATE_SILERO_VAD_H

// SuperDictate's own thin C bridge over Task 1's vendored Silero VAD
// implementation (swift/Sources/silero_vad/upstream-vad/, extracted
// whisper_vad_* functions from ggml-org/whisper.cpp — see
// upstream-vad/PROVENANCE.md). Mirrors superdictate_parakeet.h's
// conventions exactly:
//   - NULL-check every pointer argument first;
//   - an opaque owning context type;
//   - a stable numeric status enum, independent of upstream's own return
//     shapes (upstream returns bool/NULL on failure with no typed reason —
//     this bridge classifies the failure);
//   - every call into the vendored VAD code wrapped in try/catch(...) so no
//     C++ exception ever crosses this extern "C" boundary;
//   - a `last_error` string stored on the context, mirroring
//     SDParakeetContext's own last_error field pattern.
//
// This header exists only to give SuperDictate-specific, stable names
// Swift imports via the silero_vad module — Swift never sees
// `whisper_vad_context` or any other upstream C type directly (same
// boundary rule documented in silero_vad_module.h).
//
// NOT wired into any Swift call site by this task — that is a later task
// (the VAD boundary oracle used to pick the best split point inside an
// overlap window). This bridge only needs to compile and pass its own
// self-tests (see ParakeySelfTest's "silero-vad-bridge" / "silero-vad-real"
// groups in Sources/Parakey/main.swift).

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SDSileroVadContext SDSileroVadContext;

typedef enum {
    SD_SILERO_VAD_OK = 0,
    SD_SILERO_VAD_ERR_NULL_ARGUMENT = 1,
    SD_SILERO_VAD_ERR_MODEL_LOAD_FAILED = 2,
    SD_SILERO_VAD_ERR_EMPTY_AUDIO = 3,
    SD_SILERO_VAD_ERR_INFERENCE_FAILED = 4,
    SD_SILERO_VAD_ERR_NATIVE_EXCEPTION = 5
} SDSileroVadStatus;

// Loads the pinned Silero VAD ggml model once (see upstream-vad/
// PROVENANCE.md for the pinned model URL/SHA-256) and returns an owning
// context, or a non-OK status on failure (this is NOT fatal to callers —
// same design principle as sd_parakeet: a missing/failed VAD model should
// let calling code degrade to a fallback oracle, never block a dictation).
//
// Internally: whisper_vad_init_from_file_with_params(model_path,
// whisper_vad_default_context_params()), plus a one-time, cheap probe
// (a couple of tiny synthetic-buffer inferences) to determine the
// vendored implementation's internal analysis-window size in samples —
// upstream's public header does not expose this value directly (it is
// read from the model file at load time into a private field of the
// opaque whisper_vad_context), so this bridge derives it once at create
// time and caches it on SDSileroVadContext for
// sd_silero_vad_speech_probabilities' out_window_size_samples.
SDSileroVadStatus sd_silero_vad_create(
    const char *model_path,
    SDSileroVadContext **out_context
);

// Runs VAD inference over mono Float32 samples at 16kHz (this project's
// fixed SAMPLE_RATE — no resampling performed here, unlike
// sd_parakeet_transcribe; callers must already be at 16kHz, which every
// caller in this project already is). On success, `out_probabilities` is
// malloc'd (owned by caller, free with sd_silero_vad_free_probabilities),
// one probability per analysis window (whisper_vad_probs' raw per-window
// output, unmodified), `out_count` is the array length, and
// `out_window_size_samples` is the window size in samples (see
// sd_silero_vad_create's doc comment) so Swift-side code can convert a
// window index to a sample offset without hardcoding it. Every output
// pointer is optional (may be NULL if the caller doesn't need that value)
// except `out_probabilities`/`out_count`, which are required together.
SDSileroVadStatus sd_silero_vad_speech_probabilities(
    SDSileroVadContext *context,
    const float *samples,
    uint64_t sample_count,
    float **out_probabilities,
    uint64_t *out_count,
    uint64_t *out_window_size_samples
);

void sd_silero_vad_free_probabilities(float *probabilities);
void sd_silero_vad_destroy(SDSileroVadContext *context);

// Last error message for `context`, or "" if none / context is NULL. Owned
// by the context; valid until the next call on it or until
// sd_silero_vad_destroy.
const char *sd_silero_vad_last_error_message(const SDSileroVadContext *context);

#ifdef __cplusplus
}
#endif

#endif // SUPERDICTATE_SILERO_VAD_H

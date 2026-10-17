// swift/Sources/silero_vad/upstream-vad/include/whisper_vad.h
//
// Public API for the vendored Silero VAD (ggml port), extracted from
// ggml-org/whisper.cpp's include/whisper.h (the `whisper_vad_*` public
// declarations, lines ~192-199 and ~699-750 at the pinned commit — see
// PROVENANCE.md). Trimmed to be self-contained: this header does NOT
// include whisper.cpp's own whisper.h (which pulls in the full ASR API
// surface this project does not vendor); it declares only the types the
// whisper_vad_* functions need.
//
// Do not hand-edit — re-run scripts/vendor-silero-vad.sh.
//
// Usage for Task 2 (the C bridge, not implemented by this vendoring task):
//   1. whisper_vad_init_from_file_with_params(path, whisper_vad_default_context_params())
//      loads the ggml Silero VAD model file (see PROVENANCE.md for the
//      pinned model URL/SHA256).
//   2. whisper_vad_detect_speech(ctx, samples, n_samples) runs inference
//      over mono Float32 16kHz PCM (WHISPER_SAMPLE_RATE below).
//   3. whisper_vad_n_probs(ctx) / whisper_vad_probs(ctx) retrieve the raw
//      per-analysis-window speech probabilities array — this is the
//      primary output the boundary-oracle cascade needs (a probability
//      array, not pre-segmented regions).
//   4. whisper_vad_segments_from_probs(ctx, params) / _from_samples() are
//      also available if pre-segmented [t0,t1] regions are ever wanted
//      instead of raw probabilities.
//   5. whisper_vad_free(ctx) releases everything.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Same macro name as upstream's whisper.h (WHISPER_SAMPLE_RATE) so the
// mechanically extracted VAD block below -- which references
// WHISPER_SAMPLE_RATE verbatim (see cs_to_samples/samples_to_cs/
// whisper_vad_segments_from_probs in whisper_vad.cpp) -- needs no edits.
#define WHISPER_SAMPLE_RATE 16000

// Generic model-loader indirection (verbatim from whisper.h's
// whisper_model_loader) — whisper_vad_init_with_params() reads the model
// through this so callers can supply a custom source (e.g. an in-memory
// buffer) instead of a file path; whisper_vad_init_from_file_with_params()
// is the common case and constructs one of these internally from a path.
typedef struct whisper_model_loader {
    void * context;

    size_t (*read)(void * ctx, void * output, size_t read_size);
    bool   (*eof)(void * ctx);
    void   (*close)(void * ctx);
} whisper_model_loader;

typedef struct whisper_vad_params {
    float threshold;               // Probability threshold to consider as speech.
    int   min_speech_duration_ms;  // Min duration for a valid speech segment.
    int   min_silence_duration_ms; // Min silence duration to consider speech as ended.
    float max_speech_duration_s;   // Max duration of a speech segment before forcing a new segment.
    int   speech_pad_ms;           // Padding added before and after speech segments.
    float samples_overlap;         // Overlap in seconds when copying audio samples from speech segment.
} whisper_vad_params;

struct whisper_vad_context;

struct whisper_vad_params whisper_vad_default_params(void);

struct whisper_vad_context_params {
    int   n_threads;  // The number of threads to use for processing.
    bool  use_gpu;    // NOTE: forced off internally regardless of this value
                       // as of the pinned commit -- upstream comment: "GPU
                       // VAD is forced disabled until the performance is
                       // improved". Kept in the struct for source fidelity
                       // with upstream / forward compatibility.
    int   gpu_device; // CUDA device
};

struct whisper_vad_context_params whisper_vad_default_context_params(void);

struct whisper_vad_context * whisper_vad_init_from_file_with_params(const char * path_model,              struct whisper_vad_context_params params);
struct whisper_vad_context * whisper_vad_init_with_params          (struct whisper_model_loader * loader, struct whisper_vad_context_params params);

bool whisper_vad_detect_speech(
        struct whisper_vad_context * vctx,
                       const float * samples,
                               int   n_samples);

// Like whisper_vad_detect_speech, but does not reset LSTM state.
// Use for streaming: call whisper_vad_reset_state() between utterances.
bool whisper_vad_detect_speech_no_reset(
        struct whisper_vad_context * vctx,
                       const float * samples,
                               int   n_samples);

// Reset LSTM hidden/cell states to zero.
void whisper_vad_reset_state(struct whisper_vad_context * vctx);

int     whisper_vad_n_probs(struct whisper_vad_context * vctx);
float * whisper_vad_probs  (struct whisper_vad_context * vctx);

struct whisper_vad_segments;

struct whisper_vad_segments * whisper_vad_segments_from_probs(
        struct whisper_vad_context * vctx,
        struct whisper_vad_params    params);

struct whisper_vad_segments * whisper_vad_segments_from_samples(
        struct whisper_vad_context * vctx,
        struct whisper_vad_params    params,
                       const float * samples,
                               int   n_samples);

int whisper_vad_segments_n_segments(struct whisper_vad_segments * segments);

float whisper_vad_segments_get_segment_t0(struct whisper_vad_segments * segments, int i_segment);
float whisper_vad_segments_get_segment_t1(struct whisper_vad_segments * segments, int i_segment);

void whisper_vad_free_segments(struct whisper_vad_segments * segments);
void whisper_vad_free         (struct whisper_vad_context  * ctx);

#ifdef __cplusplus
}
#endif

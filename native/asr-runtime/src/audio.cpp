#include "audio.h"

#include <cmath>

#include "common.h"

namespace sdasr {

CanonicalAudio canonicalize_audio(const float *samples, uint64_t count,
                                  uint32_t sample_rate, uint32_t model_sample_rate) {
    if (count == 0) throw Error(SD_ASR_INVALID_AUDIO, "audio is empty");
    if (samples == nullptr) throw Error(SD_ASR_INVALID_ARGUMENT, "samples pointer is NULL");
    if (sample_rate != model_sample_rate) {
        throw Error(SD_ASR_INVALID_AUDIO,
                    "sample rate " + std::to_string(sample_rate) + " Hz is not the model rate " +
                        std::to_string(model_sample_rate) + " Hz (resampling is the caller's job in API v1)");
    }
    const double seconds = double(count) / double(sample_rate);
    if (seconds > kMaxAudioSeconds) {
        throw Error(SD_ASR_INVALID_AUDIO, "audio longer than " + std::to_string(int(kMaxAudioSeconds)) + " s");
    }

    CanonicalAudio out;
    out.input_seconds = seconds;
    const uint64_t min_count = uint64_t(std::ceil(kMinAudioSeconds * sample_rate));
    out.samples.assign(samples, samples + count);

    bool replaced = false;
    bool clipped = false;
    for (float &sample : out.samples) {
        if (!std::isfinite(sample)) {
            sample = 0.0f;
            replaced = true;
        } else if (sample > 1.0f) {
            sample = 1.0f;
            clipped = true;
        } else if (sample < -1.0f) {
            sample = -1.0f;
            clipped = true;
        }
    }
    if (replaced) out.warnings.emplace_back("non_finite_samples_replaced");
    if (clipped) out.warnings.emplace_back("samples_clipped");
    if (count < min_count) {
        out.samples.resize(min_count, 0.0f);
        out.warnings.emplace_back("padded_short_audio");
    }
    return out;
}

}  // namespace sdasr

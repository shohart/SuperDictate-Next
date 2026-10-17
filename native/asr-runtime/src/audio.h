// Canonical audio preprocessing shared by every model family (spec §5,
// steps 1–3). Model-specific feature extraction happens later, inside the
// family adapter.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace sdasr {

inline constexpr double kMaxAudioSeconds = 30.0 * 60.0;
inline constexpr double kMinAudioSeconds = 0.25;

struct CanonicalAudio {
    std::vector<float> samples;   // mono, model rate, finite, in [-1, 1], >= kMinAudioSeconds
    double input_seconds = 0;     // duration of the caller's audio, before padding
    std::vector<std::string> warnings;
};

// Throws Error(SD_ASR_INVALID_AUDIO) for empty input, a sample-rate mismatch
// (API v1 performs no resampling) or audio longer than kMaxAudioSeconds.
CanonicalAudio canonicalize_audio(const float *samples, uint64_t count,
                                  uint32_t sample_rate, uint32_t model_sample_rate);

}  // namespace sdasr

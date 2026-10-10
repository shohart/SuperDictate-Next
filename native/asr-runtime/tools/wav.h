// Minimal RIFF/WAVE reader for tools and tests: PCM16 or float32, any
// channel count (downmixed to mono by averaging). No resampling.
#pragma once

#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace sdasr {

struct WavAudio {
    uint32_t sample_rate = 0;
    std::vector<float> samples;
};

inline bool read_wav_mono(const std::string &path, WavAudio &out, std::string &error) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        error = "cannot open";
        return false;
    }
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    auto u16 = [&](size_t at) { return uint16_t(data[at] | (data[at + 1] << 8)); };
    auto u32 = [&](size_t at) {
        return uint32_t(data[at]) | (uint32_t(data[at + 1]) << 8) | (uint32_t(data[at + 2]) << 16) |
               (uint32_t(data[at + 3]) << 24);
    };
    if (data.size() < 12 || std::memcmp(data.data(), "RIFF", 4) != 0 || std::memcmp(data.data() + 8, "WAVE", 4) != 0) {
        error = "not a RIFF/WAVE file";
        return false;
    }
    uint16_t format = 0, channels = 0, bits = 0;
    size_t offset = 12;
    while (offset + 8 <= data.size()) {
        const uint32_t size = u32(offset + 4);
        const size_t body = offset + 8;
        if (body + size > data.size()) break;
        if (std::memcmp(data.data() + offset, "fmt ", 4) == 0 && size >= 16) {
            format = u16(body);
            channels = u16(body + 2);
            out.sample_rate = u32(body + 4);
            bits = u16(body + 14);
            if (format == 0xFFFE && size >= 26) format = u16(body + 24);  // WAVE_FORMAT_EXTENSIBLE subformat
        } else if (std::memcmp(data.data() + offset, "data", 4) == 0) {
            if (channels == 0) {
                error = "data chunk before fmt chunk";
                return false;
            }
            const bool pcm16 = format == 1 && bits == 16;
            const bool f32 = format == 3 && bits == 32;
            if (!pcm16 && !f32) {
                error = "unsupported WAV encoding (need PCM16 or float32)";
                return false;
            }
            const size_t frame_bytes = size_t(bits / 8) * channels;
            const size_t frames = size / frame_bytes;
            out.samples.assign(frames, 0.0f);
            for (size_t f = 0; f < frames; ++f) {
                float sum = 0;
                for (uint16_t c = 0; c < channels; ++c) {
                    const size_t at = body + f * frame_bytes + c * (bits / 8);
                    if (pcm16) {
                        sum += float(int16_t(u16(at))) / 32768.0f;
                    } else {
                        float v;
                        std::memcpy(&v, data.data() + at, 4);
                        sum += v;
                    }
                }
                out.samples[f] = sum / float(channels);
            }
            return true;
        }
        offset = body + size + (size & 1);
    }
    error = "no data chunk";
    return false;
}

}  // namespace sdasr

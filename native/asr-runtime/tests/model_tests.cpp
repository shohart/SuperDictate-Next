// Real-model tests (spec §11.2). Skipped (exit 77) unless
//   SD_ASR_TEST_MODEL_DIR  — an installed model directory with manifest.json
//   SD_ASR_TEST_GOLDEN_DIR — pairs <name>.wav + <name>.txt, the .txt being the
//                            reference implementation's exact output
//                            (tools/reference_tdt.py; see tests/fixtures/)
// are set. SD_ASR_TEST_PARITY selects the comparison: "exact" (default; the
// machine class that produced the goldens) or "cer:<max>" e.g. "cer:0.02"
// for other CPUs, where int8 MLAS kernels may legitimately flip an argmax.
//   sd_asr_model_tests <assets_dir>
#include <atomic>
#include <chrono>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <thread>

#include "nlohmann/json.hpp"
#include "sd_asr.h"
#include "test_util.h"
#include "wav.h"

namespace fs = std::filesystem;
using nlohmann::json;

namespace {

fs::path g_assets, g_model, g_golden;
sd_asr_handle *g_handle = nullptr;
double g_max_cer = 0.0;  // 0 = exact match required

std::u32string decode_utf8(const std::string &text) {
    std::u32string out;
    for (size_t i = 0; i < text.size();) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        const int length = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : 4;
        char32_t cp = length == 1 ? c : length == 2 ? (c & 0x1F) : length == 3 ? (c & 0x0F) : (c & 0x07);
        for (int k = 1; k < length && i + size_t(k) < text.size(); ++k) cp = (cp << 6) | (text[i + size_t(k)] & 0x3F);
        out.push_back(cp);
        i += size_t(length);
    }
    return out;
}

// Character error rate: Levenshtein distance over code points / reference length.
double character_error_rate(const std::string &reference, const std::string &hypothesis) {
    const std::u32string r = decode_utf8(reference), h = decode_utf8(hypothesis);
    std::vector<size_t> row(h.size() + 1);
    for (size_t j = 0; j <= h.size(); ++j) row[j] = j;
    for (size_t i = 1; i <= r.size(); ++i) {
        size_t diagonal = row[0];
        row[0] = i;
        for (size_t j = 1; j <= h.size(); ++j) {
            const size_t above = row[j];
            row[j] = std::min({row[j] + 1, row[j - 1] + 1, diagonal + (r[i - 1] == h[j - 1] ? 0 : 1)});
            diagonal = above;
        }
    }
    return r.empty() ? (h.empty() ? 0.0 : 1.0) : double(row[h.size()]) / double(r.size());
}

struct Call {
    sd_asr_status status;
    json body;
};

Call transcribe(const std::vector<float> &samples, const json &options = json::object()) {
    char *result = nullptr;
    char *error = nullptr;
    const sd_asr_status status = sd_asr_transcribe_pcm_f32(g_handle, samples.data(), samples.size(), 16000,
                                                           options.dump().c_str(), &result, &error);
    Call call{status, json::parse(status == SD_ASR_OK ? result : error)};
    sd_asr_free(result);
    sd_asr_free(error);
    return call;
}

std::string read_text(const fs::path &path) {
    std::ifstream in(path, std::ios::binary);
    std::stringstream buffer;
    buffer << in.rdbuf();
    std::string text = buffer.str();
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
    return text;
}

std::vector<float> longest_golden_audio() {
    std::vector<float> best;
    for (const auto &entry : fs::directory_iterator(g_golden)) {
        if (entry.path().extension() != ".wav") continue;
        sdasr::WavAudio wav;
        std::string error;
        if (sdasr::read_wav_mono(entry.path().u8string(), wav, error) && wav.samples.size() > best.size()) {
            best = wav.samples;
        }
    }
    return best;
}

}  // namespace

TEST_CASE("status reports model and honest provider") {
    char *status = nullptr;
    CHECK_EQ(sd_asr_get_status(g_handle, &status), SD_ASR_OK);
    const json s = json::parse(status);
    sd_asr_free(status);
    CHECK_EQ(s["state"].get<std::string>(), std::string("ready"));
    CHECK_EQ(s["provider_actual"].get<std::string>(), std::string("cpu"));
    CHECK(s.contains("provider_fallback_reason"));
    CHECK_EQ(s["onnxruntime_version"].get<std::string>(), std::string("1.23.2"));
}

TEST_CASE("golden parity with the reference implementation") {
    int compared = 0;
    for (const auto &entry : fs::directory_iterator(g_golden)) {
        if (entry.path().extension() != ".wav") continue;
        fs::path golden = entry.path();
        golden.replace_extension(".txt");
        if (!fs::exists(golden)) continue;
        sdasr::WavAudio wav;
        std::string error;
        CHECK(sdasr::read_wav_mono(entry.path().u8string(), wav, error));
        CHECK_EQ(wav.sample_rate, 16000u);
        const Call call = transcribe(wav.samples);
        CHECK_EQ(call.status, SD_ASR_OK);
        if (call.status != SD_ASR_OK) continue;
        const std::string expected = read_text(golden);
        const std::string actual = call.body["text"].get<std::string>();
        const double cer = character_error_rate(expected, actual);
        if (actual != expected) {
            std::printf("  %s (CER %.4f)\n    expected: %s\n    actual:   %s\n",
                        entry.path().filename().u8string().c_str(), cer, expected.c_str(), actual.c_str());
        }
        if (g_max_cer == 0.0) {
            CHECK_EQ(actual, expected);
        } else {
            CHECK(cer <= g_max_cer);
        }

        // Words re-join to the text; timestamps are monotonic and in range.
        std::string joined;
        double last_t = -1;
        for (const auto &w : call.body["words"]) {
            joined += (joined.empty() ? "" : " ") + w["w"].get<std::string>();
            CHECK(w["start"].get<double>() <= w["end"].get<double>());
        }
        for (const auto &t : call.body["tokens"]) {
            CHECK(t["t"].get<double>() >= last_t);
            last_t = t["t"].get<double>();
            CHECK(t["conf"].get<double>() > 0.0 && t["conf"].get<double>() <= 1.0);
        }
        CHECK(last_t <= call.body["audio_seconds"].get<double>() + 0.1);
        CHECK_EQ(joined, actual);
        CHECK_EQ(call.body["frame_sec"].get<double>(), 0.08);
        ++compared;
    }
    CHECK(compared > 0);
}

TEST_CASE("silence, short audio and timestamps option") {
    const Call silence = transcribe(std::vector<float>(6400, 0.0f));
    CHECK_EQ(silence.status, SD_ASR_OK);
    const Call tiny = transcribe(std::vector<float>(800, 0.0f));
    CHECK_EQ(tiny.status, SD_ASR_OK);
    CHECK(tiny.body.contains("warnings"));
    const Call bare = transcribe(std::vector<float>(6400, 0.0f), {{"timestamps", false}});
    CHECK(!bare.body.contains("tokens"));
    CHECK_EQ(bare.body["request_id"].get<std::string>().empty(), false);
}

// Regression: nemo128's features_lens is one frame short of the feature
// tensor; passed to the encoder as-is it leaves a padded encoder frame for
// clips of an exact 0.08 s multiple and the int8 encoder returns all-NaN
// (empty transcript). Every prefix of real speech must transcribe.
TEST_CASE("short speech prefixes are never empty") {
    const std::vector<float> audio = longest_golden_audio();
    CHECK(audio.size() >= 16000 * 9);
    if (audio.size() < 16000 * 9) return;
    for (const size_t seconds : {2, 4, 6, 8}) {
        const std::vector<float> prefix(audio.begin(), audio.begin() + long(seconds * 16000));
        const Call call = transcribe(prefix);
        CHECK_EQ(call.status, SD_ASR_OK);
        if (call.status != SD_ASR_OK) continue;
        if (call.body["text"].get<std::string>().empty()) std::printf("empty transcript for a %zu s prefix\n", seconds);
        CHECK(!call.body["text"].get<std::string>().empty());
    }
}

TEST_CASE("second concurrent call is BUSY, cancel interrupts, handle stays usable") {
    const std::vector<float> audio = longest_golden_audio();
    CHECK(!audio.empty());
    std::atomic<int> first_status{-1};
    std::thread first([&] {
        first_status = int(transcribe(audio, {{"request_id", "long-1"}}).status);
    });
    // Wait until the first call is actually inside the engine.
    for (int i = 0; i < 400; ++i) {
        char *status = nullptr;
        sd_asr_get_status(g_handle, &status);
        const bool running = json::parse(status)["state"] == "inference";
        sd_asr_free(status);
        if (running) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK_EQ(transcribe(std::vector<float>(1600, 0.0f)).status, SD_ASR_BUSY);
    CHECK_EQ(sd_asr_cancel(g_handle, "some-other-id"), SD_ASR_INVALID_ARGUMENT);
    CHECK_EQ(sd_asr_cancel(g_handle, "long-1"), SD_ASR_OK);
    first.join();
    CHECK_EQ(first_status.load(), int(SD_ASR_CANCELLED));
    CHECK_EQ(transcribe(std::vector<float>(6400, 0.0f)).status, SD_ASR_OK);
}

int main(int argc, char **argv) {
    const char *model = std::getenv("SD_ASR_TEST_MODEL_DIR");
    const char *golden = std::getenv("SD_ASR_TEST_GOLDEN_DIR");
    if (argc < 2 || !model || !golden) {
        std::printf("SKIP: set SD_ASR_TEST_MODEL_DIR and SD_ASR_TEST_GOLDEN_DIR\n");
        return 77;
    }
    g_assets = fs::u8path(argv[1]);
    g_model = fs::u8path(model);
    g_golden = fs::u8path(golden);
    if (const char *parity = std::getenv("SD_ASR_TEST_PARITY"); parity && std::strncmp(parity, "cer:", 4) == 0) {
        g_max_cer = std::atof(parity + 4);
        std::printf("parity mode: CER <= %.4f\n", g_max_cer);
    }
    const json config = {{"model_directory", g_model.u8string()},
                         {"assets_directory", g_assets.u8string()},
                         {"verify_checksums", true}};
    char *error = nullptr;
    if (sd_asr_create(config.dump().c_str(), &g_handle, &error) != SD_ASR_OK) {
        std::printf("create failed: %s\n", error ? error : "?");
        sd_asr_free(error);
        return 1;
    }
    const int rc = sdtest::run_all();
    sd_asr_destroy(g_handle);
    return rc;
}

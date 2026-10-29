// Real-model tests (spec §11.2). Skipped (exit 77) unless
//   SD_ASR_TEST_MODEL_DIR  — an installed model directory with manifest.json
//   SD_ASR_TEST_GOLDEN_DIR — pairs <name>.wav + <name>.txt, the .txt being the
//                            reference implementation's exact output for the
//                            model's family (tools/reference_tdt.py,
//                            tools/reference_gigaam.py; see tests/fixtures/),
//                            optionally <name>.tokens.json ({"frame_sec",
//                            "tokens": [[id, frame, conf]]}) for token-level
//                            parity
// are set. Any installed model works; the goldens must come from its family's
// reference. Hotword fixtures (docs/specs/asr-hotwords-spec.md §9) live in
// the same directory: hotwords.txt (one phrase per line, the reference's
// --hotwords list at the default score) and, per <name>.wav, <name>.hw.txt +
// <name>.hw.tokens.json written by the reference with --hotwords. SD_ASR_TEST_PARITY selects the comparison: "exact" (default; the
// machine class that produced the goldens) or "cer:<max>" e.g. "cer:0.02"
// for other CPUs, where int8 MLAS kernels may legitimately flip an argmax.
//   sd_asr_model_tests <assets_dir>
#include <atomic>
#include <chrono>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>
#include <thread>

#include "families/family_util.h"
#include "families/hotwords.h"
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
double g_frame_sec = 0.0;  // params.hop_seconds * params.subsampling_factor of the installed model

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

std::vector<float> read_audio(const fs::path &path) {
    sdasr::WavAudio wav;
    std::string error;
    CHECK(sdasr::read_wav_mono(path.u8string(), wav, error));
    CHECK_EQ(wav.sample_rate, 16000u);
    return wav.samples;
}

std::vector<std::string> read_lines(const fs::path &path) {
    std::vector<std::string> lines;
    std::ifstream in(path, std::ios::binary);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.find_first_not_of(" \t") != std::string::npos) lines.push_back(line);
    }
    return lines;
}

// Golden wavs that have a plain <name>.txt golden.
std::vector<fs::path> golden_wavs() {
    std::vector<fs::path> out;
    for (const auto &entry : fs::directory_iterator(g_golden)) {
        fs::path golden = entry.path();
        if (golden.extension() != ".wav" || !fs::exists(golden.replace_extension(".txt"))) continue;
        out.push_back(entry.path());
    }
    std::sort(out.begin(), out.end());
    return out;
}

// Same ids at the same encoder frames with the same confidences (to float
// rounding) as a reference tokens.json; returns the mismatch count.
size_t token_mismatches(const json &tokens, const json &expected_tokens, const std::string &label) {
    size_t mismatched = tokens.size() == expected_tokens.size() ? 0 : 1;
    for (size_t i = 0; i < std::min(tokens.size(), expected_tokens.size()); ++i) {
        const json &a = tokens[i];
        const json &e = expected_tokens[i];
        const double frame = a["t"].get<double>() / g_frame_sec;
        if (a["id"].get<int>() != e[0].get<int>() || std::fabs(frame - e[1].get<double>()) > 1e-6 ||
            std::fabs(a["conf"].get<double>() - e[2].get<double>()) > 1e-5) {
            if (mismatched++ < 3) {
                std::printf("  %s token %zu: actual (%d, %.4f, %.6f) expected %s\n", label.c_str(), i,
                            a["id"].get<int>(), frame, a["conf"].get<double>(), e.dump().c_str());
            }
        }
    }
    return mismatched;
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
        CHECK_EQ(call.body["frame_sec"].get<double>(), g_frame_sec);

        // Token-level parity: same ids at the same encoder frames, same
        // confidences (to float rounding), whenever the reference wrote them.
        fs::path token_golden = entry.path();
        token_golden.replace_extension(".tokens.json");
        if (g_max_cer == 0.0 && fs::exists(token_golden)) {
            const json expected_tokens = json::parse(read_text(token_golden))["tokens"];
            const json &tokens = call.body["tokens"];
            CHECK_EQ(tokens.size(), expected_tokens.size());
            size_t mismatched = 0;
            for (size_t i = 0; i < std::min(tokens.size(), expected_tokens.size()); ++i) {
                const json &a = tokens[i];
                const json &e = expected_tokens[i];
                const double frame = a["t"].get<double>() / g_frame_sec;
                if (a["id"].get<int>() != e[0].get<int>() || std::fabs(frame - e[1].get<double>()) > 1e-6 ||
                    std::fabs(a["conf"].get<double>() - e[2].get<double>()) > 1e-5) {
                    if (mismatched++ < 3) {
                        std::printf("  %s token %zu: actual (%d, %.4f, %.6f) expected %s\n",
                                    entry.path().filename().u8string().c_str(), i, a["id"].get<int>(), frame,
                                    a["conf"].get<double>(), e.dump().c_str());
                    }
                }
            }
            CHECK_EQ(mismatched, size_t(0));
        }
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

// ---- ASR hotwords (docs/specs/asr-hotwords-spec.md §9) --------------------

TEST_CASE("hotwords: wrong option types are invalid_argument") {
    const std::vector<float> silence(6400, 0.0f);
    for (const json &bad : {json{{"hotwords", "DDR4"}}, json{{"hotwords", {1}}}, json{{"hotwords_score", "2"}}}) {
        const Call call = transcribe(silence, bad);
        CHECK_EQ(call.status, SD_ASR_INVALID_ARGUMENT);
        CHECK_EQ(call.body["category"].get<std::string>(), std::string("invalid_argument"));
    }
}

// The unbiased path must stay bit-identical: an empty list (any score) is
// the same request as no list at all, and adds no result fields.
TEST_CASE("hotwords: an empty list leaves the golden transcripts unchanged") {
    int compared = 0;
    for (const fs::path &wav : golden_wavs()) {
        const std::vector<float> audio = read_audio(wav);
        const Call plain = transcribe(audio);
        const Call empty = transcribe(audio, {{"hotwords", json::array()}, {"hotwords_score", 5.0}});
        CHECK_EQ(empty.status, SD_ASR_OK);
        if (plain.status != SD_ASR_OK || empty.status != SD_ASR_OK) continue;
        if (g_max_cer == 0.0) CHECK_EQ(empty.body["text"], json(read_text(fs::path(wav).replace_extension(".txt"))));
        CHECK_EQ(empty.body["text"], plain.body["text"]);
        CHECK_EQ(empty.body["tokens"], plain.body["tokens"]);
        CHECK(!empty.body.contains("hotwords_used") && !empty.body.contains("hotwords_skipped"));
        ++compared;
    }
    CHECK(compared > 0);
}

TEST_CASE("hotwords: exact parity with the reference on the hotword fixtures") {
    const fs::path list_path = g_golden / "hotwords.txt";
    if (!fs::exists(list_path)) {
        std::printf("  no hotwords.txt in the golden directory; hotword parity not checked\n");
        return;
    }
    const std::vector<std::string> phrases = read_lines(list_path);
    int compared = 0;
    for (const auto &entry : fs::directory_iterator(g_golden)) {
        if (entry.path().extension() != ".wav") continue;
        fs::path golden = entry.path();
        golden.replace_extension(".hw.txt");
        if (!fs::exists(golden)) continue;
        const Call call = transcribe(read_audio(entry.path()), {{"hotwords", phrases}});
        CHECK_EQ(call.status, SD_ASR_OK);
        if (call.status != SD_ASR_OK) continue;
        CHECK(call.body["hotwords_used"].get<size_t>() > 0);
        CHECK(!call.body.contains("hotwords_disabled_reason"));
        const std::string expected = read_text(golden);
        const std::string actual = call.body["text"].get<std::string>();
        if (actual != expected) {
            std::printf("  %s (hotwords)\n    expected: %s\n    actual:   %s\n",
                        entry.path().filename().u8string().c_str(), expected.c_str(), actual.c_str());
        }
        if (g_max_cer == 0.0) {
            CHECK_EQ(actual, expected);
            fs::path token_golden = entry.path();
            token_golden.replace_extension(".hw.tokens.json");
            if (fs::exists(token_golden)) {
                const json expected_tokens = json::parse(read_text(token_golden))["tokens"];
                CHECK_EQ(token_mismatches(call.body["tokens"], expected_tokens,
                                          entry.path().filename().u8string() + " (hotwords)"),
                         size_t(0));
            }
        } else {
            CHECK(character_error_rate(expected, actual) <= g_max_cer);
        }
        ++compared;
    }
    std::printf("  %d hotword fixture(s) compared\n", compared);
    CHECK(compared > 0);
}

// Rollback regression: every phrase is a word that is really spoken plus a
// tail that never is, so each boosted match starts, diverges and must be
// rolled back. A greedy decoder without rollback loses the rest of the
// utterance here; with it the output is exactly the unbiased one.
TEST_CASE("hotwords: diverging phrases roll back without losing the tail") {
    int compared = 0;
    for (const fs::path &wav : golden_wavs()) {
        const std::string text = read_text(fs::path(wav).replace_extension(".txt"));
        std::vector<std::string> phrases;
        std::istringstream words(text);
        std::string word;
        while (words >> word && phrases.size() < 300) {
            const size_t first = word.find_first_not_of(".,;:!?\"'()-");
            const size_t last = word.find_last_not_of(".,;:!?\"'()-");
            if (first == std::string::npos || word.find("\xC2\xAB") != std::string::npos ||
                word.find("\xC2\xBB") != std::string::npos) {
                continue;
            }
            phrases.push_back(word.substr(first, last - first + 1) + " ъъъ ыыы ььь");
        }
        const std::vector<float> audio = read_audio(wav);
        const Call plain = transcribe(audio);
        const Call biased = transcribe(audio, {{"hotwords", phrases}, {"hotwords_score", 3.0}});
        CHECK_EQ(biased.status, SD_ASR_OK);
        if (plain.status != SD_ASR_OK || biased.status != SD_ASR_OK) continue;
        CHECK(biased.body["hotwords_used"].get<size_t>() > 0);
        if (biased.body["text"] != plain.body["text"]) {
            std::printf("  %s (diverging hotwords)\n    expected: %s\n    actual:   %s\n",
                        wav.filename().u8string().c_str(), plain.body["text"].get<std::string>().c_str(),
                        biased.body["text"].get<std::string>().c_str());
        }
        CHECK_EQ(biased.body["text"], plain.body["text"]);
        CHECK_EQ(biased.body["tokens"], plain.body["tokens"]);
        ++compared;
    }
    CHECK(compared > 0);
}

// Known segmentations in the installed model's own vocabulary. Expected ids:
// HF `tokenizers` (Parakeet: moondream/parakeet-ultra tokenizer.json;
// GigaAM: Unigram over gigaam_v3_spm.tsv with a Metaspace pre-tokenizer).
TEST_CASE("hotwords: the model's phrase tokenizer matches the HF tokenizer") {
    const json manifest = json::parse(read_text(g_model / "manifest.json"));
    const std::string family = manifest["family"].get<std::string>();
    const int64_t vocab = manifest["params"]["vocab_size"].get<int64_t>();
    const std::vector<std::string> pieces =
        sdasr::load_tokens(g_model / manifest["files"]["tokens"]["path"].get<std::string>(), vocab);
    std::vector<std::pair<std::string, std::vector<int>>> cases;
    std::unique_ptr<sdasr::hotwords::PhraseTokenizer> tokenizer;
    if (family == "nemo_tdt" && vocab == 8193) {  // Parakeet (v3 / Ultra) vocabulary
        tokenizer = std::make_unique<sdasr::hotwords::BpeTokenizer>(pieces);
        cases = {{"DDR4 DIMM", {360, 7942, 7991, 238, 360, 7945, 7937, 7937}},
                 {"Красникову", {1000, 372, 7897, 383, 386, 1563}},
                 {"ЕСИА", {1798, 8034, 8046, 8048}},
                 {"Gmail watcher", {497, 470, 305, 2690, 3274}},
                 {"TickTick", {357, 1413, 7934, 1413}},
                 {"Ничипуренко", {812, 7890, 776, 2000, 3541, 386}},
                 {"High-res", {425, 4720, 7918, 898}}};
    } else if (family == "gigaam_rnnt") {
        tokenizer = std::make_unique<sdasr::hotwords::UnigramTokenizer>(g_assets / "gigaam_v3_spm.tsv", pieces);
        cases = {{"DDR4 DIMM", {521, 982, 499, 408, 521, 570, 894, 894}},
                 {"Красникову", {118, 31, 6, 41, 278, 11}},
                 {"Ничипуренко", {479, 110, 300, 57, 10, 62}}};
    } else {
        std::printf("  no known segmentations for this model\n");
        return;
    }
    for (const auto &c : cases) {
        std::vector<int> ids;
        CHECK(tokenizer->encode(c.first, ids));
        CHECK_EQ(ids, c.second);
    }
}

// GigaAM installs made before the hotword_tokenizer role find the scores
// next to the bundled preprocessor; without them hotwords are disabled
// with a reason and the transcript is unaffected.
TEST_CASE("hotwords: GigaAM without its tokenizer asset reports why and transcribes as usual") {
    const json manifest = json::parse(read_text(g_model / "manifest.json"));
    if (manifest["family"] != "gigaam_rnnt" || manifest["files"].contains("hotword_tokenizer")) return;
    const fs::path assets = fs::temp_directory_path() / ("sd_asr_hw_assets_" + std::to_string(std::rand()));
    fs::create_directories(assets);
    fs::copy_file(g_assets / "gigaam_v3.onnx", assets / "gigaam_v3.onnx");
    const json config = {{"model_directory", g_model.u8string()}, {"assets_directory", assets.u8string()}};
    sd_asr_handle *handle = nullptr;
    char *error = nullptr;
    CHECK_EQ(sd_asr_create(config.dump().c_str(), &handle, &error), SD_ASR_OK);
    sd_asr_free(error);
    if (handle != nullptr) {
        const std::vector<float> audio = read_audio(golden_wavs().front());
        const json options = {{"hotwords", {"ЕСИА"}}};
        char *result = nullptr;
        CHECK_EQ(sd_asr_transcribe_pcm_f32(handle, audio.data(), audio.size(), 16000, options.dump().c_str(), &result,
                                           &error),
                 SD_ASR_OK);
        if (result != nullptr) {
            const json body = json::parse(result);
            CHECK(body.contains("hotwords_disabled_reason"));
            CHECK_EQ(body["hotwords_used"].get<size_t>(), size_t(0));
            const Call plain = transcribe(audio);
            CHECK_EQ(body["text"], plain.body["text"]);
        }
        sd_asr_free(result);
        sd_asr_free(error);
        sd_asr_destroy(handle);
    }
    std::error_code ec;
    fs::remove_all(assets, ec);
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
    {
        const json manifest = json::parse(read_text(g_model / "manifest.json"));
        g_frame_sec = manifest["params"]["hop_seconds"].get<double>() *
                      manifest["params"]["subsampling_factor"].get<double>();
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

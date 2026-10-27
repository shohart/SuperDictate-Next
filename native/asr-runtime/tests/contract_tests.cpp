// C ABI contract tests that need no real model (spec §11.1).
//   sd_asr_contract_tests <assets_dir>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>

#include "audio.h"
#include "common.h"
#include "families/family_util.h"
#include "families/punct_text.h"
#include "manifest.h"
#include "nlohmann/json.hpp"
#include "sd_asr.h"
#include "sha256.h"
#include "test_util.h"

namespace fs = std::filesystem;
using nlohmann::json;

namespace {

fs::path g_assets;

const char *kNemoSha = "5b4a84c52eeaa615dc46d781cc7e4598f9b432184831d57493c48adcd01371a9";
const char *kGigaamPreprocessorSha = "919c3bc8a434b6e733e5fe5dcd247974d0a7b1f2bc5b6995b6ad55f7225e014d";

struct TempDir {
    fs::path path;
    TempDir() {
        path = fs::temp_directory_path() /
               ("sd_asr_test_" + std::to_string(std::rand()) + "_" + std::to_string(std::rand()));
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

void write_file(const fs::path &path, const std::string &content) {
    std::ofstream out(path, std::ios::binary);
    out << content;
}

// A structurally valid manifest whose model files are dummy bytes.
json fake_manifest() {
    const std::string sha(64, '0');
    return {
        {"schema", 1},
        {"model_id", "fake"},
        {"family", "nemo_tdt"},
        {"sample_rate", 16000},
        {"files",
         {{"encoder", {{"path", "encoder.onnx"}, {"size", 5}, {"sha256", sha}}},
          {"decoder", {{"path", "decoder.onnx"}, {"size", 5}, {"sha256", sha}}},
          {"joiner", {{"path", "joiner.onnx"}, {"size", 5}, {"sha256", sha}}},
          {"tokens", {{"path", "tokens.txt"}, {"size", 5}, {"sha256", sha}}},
          {"preprocessor", {{"bundled", "nemo128.onnx"}, {"sha256", kNemoSha}}}}},
        {"params", json::object()},
    };
}

void populate(const fs::path &dir, const json &manifest) {
    for (const char *name : {"encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"}) write_file(dir / name, "dummy");
    write_file(dir / "manifest.json", manifest.dump());
}

// Runs sd_asr_create and returns {status, error category}.
std::pair<sd_asr_status, std::string> create(const json &config) {
    sd_asr_handle *handle = nullptr;
    char *error = nullptr;
    const sd_asr_status status = sd_asr_create(config.dump().c_str(), &handle, &error);
    std::string category;
    if (error) {
        json parsed = json::parse(error, nullptr, false);
        if (parsed.is_object() && parsed.contains("category") && parsed.contains("message")) {
            category = parsed["category"].get<std::string>();
        } else {
            category = "<malformed error json>";
        }
    }
    sd_asr_free(error);
    if (handle) sd_asr_destroy(handle);
    return {status, category};
}

json config_for(const fs::path &dir) {
    return {{"model_directory", dir.u8string()}, {"assets_directory", g_assets.u8string()}, {"provider", "cpu"}};
}

}  // namespace

TEST_CASE("api version and status names") {
    CHECK_EQ(sd_asr_api_version(), 1u);
    CHECK_EQ(std::string(sd_asr_status_name(SD_ASR_INVALID_AUDIO)), std::string("invalid_audio"));
    CHECK_EQ(std::string(sd_asr_status_name(SD_ASR_BUSY)), std::string("busy"));
    sd_asr_free(nullptr);
    sd_asr_destroy(nullptr);
}

TEST_CASE("create rejects bad arguments") {
    char *error = nullptr;
    CHECK_EQ(sd_asr_create("{}", nullptr, &error), SD_ASR_INVALID_ARGUMENT);
    sd_asr_free(error);
    sd_asr_handle *handle = reinterpret_cast<sd_asr_handle *>(0x1);
    CHECK_EQ(sd_asr_create("not json", &handle, nullptr), SD_ASR_INVALID_ARGUMENT);
    CHECK(handle == nullptr);
    CHECK_EQ(create(json::object()).first, SD_ASR_INVALID_ARGUMENT);
    CHECK_EQ(create({{"engine", "ggml"}, {"model_directory", "/x"}}).first, SD_ASR_INVALID_ARGUMENT);
    CHECK_EQ(create({{"model_directory", 42}}).first, SD_ASR_INVALID_ARGUMENT);
}

TEST_CASE("create rejects missing model directory and manifest") {
    TempDir dir;
    CHECK_EQ(create(config_for(dir.path / "nope")), std::make_pair(SD_ASR_INVALID_MODEL, std::string("invalid_model")));
    CHECK_EQ(create(config_for(dir.path)).first, SD_ASR_INVALID_MODEL);
    write_file(dir.path / "manifest.json", "[1,2]");
    CHECK_EQ(create(config_for(dir.path)).first, SD_ASR_INVALID_MODEL);
}

TEST_CASE("manifest: unsupported family and schema") {
    TempDir dir;
    json m = fake_manifest();
    m["family"] = "whisper_aed";
    populate(dir.path, m);
    CHECK_EQ(create(config_for(dir.path)),
             std::make_pair(SD_ASR_UNSUPPORTED_MODEL_FAMILY, std::string("unsupported_model_family")));
    m = fake_manifest();
    m["schema"] = 2;
    populate(dir.path, m);
    CHECK_EQ(create(config_for(dir.path)).first, SD_ASR_INVALID_MODEL);
}

TEST_CASE("manifest: path traversal, absolute paths, symlinks, size mismatch") {
    TempDir dir;
    for (const char *bad : {"../encoder.onnx", "/etc/passwd", "sub/encoder.onnx", "..", "C:evil", "a\\b"}) {
        json m = fake_manifest();
        m["files"]["encoder"]["path"] = bad;
        populate(dir.path, m);
        CHECK_EQ(create(config_for(dir.path)).first, SD_ASR_INVALID_MODEL);
    }
    json m = fake_manifest();
    m["files"]["encoder"]["size"] = 6;
    populate(dir.path, m);
    CHECK_EQ(create(config_for(dir.path)).first, SD_ASR_INVALID_MODEL);
#ifndef _WIN32
    m = fake_manifest();
    populate(dir.path, m);
    fs::remove(dir.path / "encoder.onnx");
    write_file(dir.path / "real.onnx", "dummy");
    fs::create_symlink(dir.path / "real.onnx", dir.path / "encoder.onnx");
    CHECK_EQ(create(config_for(dir.path)).first, SD_ASR_INVALID_MODEL);
#endif
}

TEST_CASE("manifest: checksum verification and bundled assets") {
    TempDir dir;
    json m = fake_manifest();
    populate(dir.path, m);
    json config = config_for(dir.path);
    config["verify_checksums"] = true;
    CHECK_EQ(create(config).first, SD_ASR_INVALID_MODEL);  // dummy bytes do not hash to zeros

    m["files"]["preprocessor"]["sha256"] = std::string(64, 'a');
    populate(dir.path, m);
    CHECK_EQ(create(config_for(dir.path)).first, SD_ASR_INVALID_MODEL);  // bundled assets are always hashed

    m = fake_manifest();
    populate(dir.path, m);
    json no_assets = config_for(dir.path);
    no_assets.erase("assets_directory");
    CHECK_EQ(create(no_assets).first, SD_ASR_INVALID_MODEL);
}

TEST_CASE("providers: unknown and unavailable providers are refused, never relabelled") {
    TempDir dir;
    populate(dir.path, fake_manifest());
    json config = config_for(dir.path);
    config["provider"] = "metal";
    CHECK_EQ(create(config).first, SD_ASR_INVALID_ARGUMENT);
    config["provider"] = "directml";
    CHECK_EQ(create(config).first, SD_ASR_PROVIDER_UNAVAILABLE);
    config["provider"] = "coreml";  // unavailable on Linux/Windows, unvalidated for the model on macOS
    CHECK_EQ(create(config).first, SD_ASR_PROVIDER_UNAVAILABLE);
    config["provider"] = "cpu";
    config["intra_op_threads"] = 500;
    CHECK_EQ(create(config).first, SD_ASR_INVALID_ARGUMENT);
}

TEST_CASE("valid manifest with garbage graphs fails as invalid_model or model_load_failed") {
    TempDir dir;
    populate(dir.path, fake_manifest());
    const auto result = create(config_for(dir.path));
    // Missing nemo_tdt params are detected before any graph is opened.
    CHECK_EQ(result.first, SD_ASR_INVALID_MODEL);

    json m = fake_manifest();
    m["params"] = {{"feature_dim", 128}, {"subsampling_factor", 8}, {"hop_seconds", 0.01},
                   {"vocab_size", 2}, {"blank_id", 1}, {"durations", {0, 1}}, {"max_symbols_per_frame", 10},
                   {"pred_hidden", 4}, {"pred_rnn_layers", 1}};
    populate(dir.path, m);
    write_file(dir.path / "tokens.txt", "a 0\nb 1");  // 7 bytes
    m["files"]["tokens"]["size"] = 7;
    write_file(dir.path / "manifest.json", m.dump());
    CHECK_EQ(create(config_for(dir.path)), std::make_pair(SD_ASR_MODEL_LOAD_FAILED, std::string("model_load_failed")));
}

TEST_CASE("NULL handle calls are rejected") {
    char *result = nullptr;
    char *error = nullptr;
    const float sample = 0;
    CHECK_EQ(sd_asr_transcribe_pcm_f32(nullptr, &sample, 1, 16000, nullptr, &result, &error), SD_ASR_INVALID_ARGUMENT);
    CHECK(result == nullptr);
    CHECK(error != nullptr);
    sd_asr_free(error);
    CHECK_EQ(sd_asr_get_status(nullptr, &result), SD_ASR_INVALID_ARGUMENT);
    CHECK_EQ(sd_asr_cancel(nullptr, "*"), SD_ASR_INVALID_ARGUMENT);
}

TEST_CASE("audio canonicalization") {
    using sdasr::canonicalize_audio;
    auto status_of = [](auto fn) {
        try {
            fn();
        } catch (const sdasr::Error &e) {
            return e.status();
        }
        return SD_ASR_OK;
    };
    const float one = 0.5f;
    CHECK_EQ(status_of([&] { canonicalize_audio(&one, 0, 16000, 16000); }), SD_ASR_INVALID_AUDIO);
    CHECK_EQ(status_of([&] { canonicalize_audio(&one, 1, 44100, 16000); }), SD_ASR_INVALID_AUDIO);
    CHECK_EQ(status_of([&] { canonicalize_audio(nullptr, 1, 16000, 16000); }), SD_ASR_INVALID_ARGUMENT);
    std::vector<float> long_audio(size_t(30 * 60 * 16000) + 1, 0.0f);
    CHECK_EQ(status_of([&] { canonicalize_audio(long_audio.data(), long_audio.size(), 16000, 16000); }),
             SD_ASR_INVALID_AUDIO);

    std::vector<float> dirty = {std::numeric_limits<float>::quiet_NaN(), 2.0f, -3.0f,
                                std::numeric_limits<float>::infinity(), 0.25f};
    const auto audio = canonicalize_audio(dirty.data(), dirty.size(), 16000, 16000);
    CHECK_EQ(audio.samples.size(), size_t(4000));  // padded to 0.25 s
    CHECK_EQ(audio.samples[0], 0.0f);
    CHECK_EQ(audio.samples[1], 1.0f);
    CHECK_EQ(audio.samples[2], -1.0f);
    CHECK_EQ(audio.samples[3], 0.0f);
    CHECK_EQ(audio.samples[4], 0.25f);
    CHECK(std::abs(audio.input_seconds - 5.0 / 16000.0) < 1e-12);
    CHECK_EQ(audio.warnings.size(), size_t(3));
}

TEST_CASE("safe file names") {
    CHECK(sdasr::is_safe_file_name("encoder.int8.onnx"));
    CHECK(sdasr::is_safe_file_name("tokens.txt"));
    CHECK(!sdasr::is_safe_file_name(""));
    CHECK(!sdasr::is_safe_file_name(".."));
    CHECK(!sdasr::is_safe_file_name("a/b"));
    CHECK(!sdasr::is_safe_file_name("a\\b"));
    CHECK(!sdasr::is_safe_file_name("C:x"));
}

TEST_CASE("sha256 known answers") {
    sdasr::Sha256 empty;
    CHECK_EQ(empty.hex_digest(), std::string("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    sdasr::Sha256 abc;
    abc.update("abc", 3);
    CHECK_EQ(abc.hex_digest(), std::string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    sdasr::Sha256 two_blocks;
    const std::string msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    two_blocks.update(msg.data(), msg.size());
    CHECK_EQ(two_blocks.hex_digest(), std::string("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
    CHECK_EQ(sdasr::sha256_file(g_assets / "nemo128.onnx"), std::string(kNemoSha));
    CHECK_EQ(sdasr::sha256_file(g_assets / "gigaam_v3.onnx"), std::string(kGigaamPreprocessorSha));
}

TEST_CASE("gigaam_rnnt is a supported family; missing params are invalid_model") {
    TempDir dir;
    json m = fake_manifest();
    m["family"] = "gigaam_rnnt";
    m["files"]["preprocessor"] = {{"bundled", "gigaam_v3.onnx"}, {"sha256", kGigaamPreprocessorSha}};
    populate(dir.path, m);
    CHECK_EQ(create(config_for(dir.path)), std::make_pair(SD_ASR_INVALID_MODEL, std::string("invalid_model")));
    CHECK(sdasr::is_supported_family("gigaam_rnnt"));
}

// Expected strings come from onnx-asr's DECODE_SPACE_PATTERN in Python:
//   re.sub(r"\A\s|\s\B|(\s)\b", lambda m: " " if m.group(1) else "", "".join(pieces).replace("\u2581", " "))
TEST_CASE("gigaam space rule matches onnx-asr text, words re-join to it") {
    const std::vector<std::string> pieces = {"\u2581при", "вет", ",", "\u2581мир", "\u2581", ".", "\u2581«",
                                             "да",          "»",   "\u258150", "\u2581—", "1", "ü_x"};
    auto run = [&](const std::vector<int> &ids) {
        sdasr::FamilyResult result;
        result.frame_sec = 0.04;
        for (size_t i = 0; i < ids.size(); ++i) result.tokens.push_back({ids[i], double(i) * 0.04, 0.5 + 0.01 * double(i)});
        sdasr::build_text_and_words_space_rule(result, pieces, 10.0);
        return result;
    };
    auto words_of = [](const sdasr::FamilyResult &r) {
        std::vector<std::string> out;
        for (const auto &w : r.words) out.push_back(w.w);
        return out;
    };

    sdasr::FamilyResult a = run({0, 1, 2, 3, 4, 5});
    CHECK_EQ(a.text, std::string("привет, мир."));
    CHECK_EQ(words_of(a), (std::vector<std::string>{"привет,", "мир."}));
    CHECK_EQ(a.words.size(), size_t(2));
    if (a.words.size() == 2) {
        CHECK(std::fabs(a.words[0].start - 0.0) < 1e-12 && std::fabs(a.words[0].end - 0.12) < 1e-12);
        CHECK(std::fabs(a.words[1].start - 0.12) < 1e-12 && std::fabs(a.words[1].end - 0.24) < 1e-12);
        CHECK(std::fabs(a.words[0].conf - 0.5) < 1e-12 && std::fabs(a.words[1].conf - 0.53) < 1e-12);
    }

    sdasr::FamilyResult b = run({6, 7, 8, 10, 3, 4, 11});
    CHECK_EQ(b.text, std::string("«да»— мир 1"));
    CHECK_EQ(words_of(b), (std::vector<std::string>{"«да»—", "мир", "1"}));
    if (b.words.size() == 3) CHECK(std::fabs(b.words[2].start - 0.20) < 1e-12);  // the bare U+2581 token

    CHECK_EQ(run({9, 4, 2, 12, 4}).text, std::string("50,ü_x"));
    CHECK_EQ(run({4, 4, 7}).text, std::string(" да"));  // only the very first space is "\A\s"
    CHECK_EQ(run({}).text, std::string());

    CHECK(sdasr::is_word_code_point(U'ё') && sdasr::is_word_code_point(U'Я') && sdasr::is_word_code_point(U'_'));
    CHECK(sdasr::is_word_code_point(U'²') && sdasr::is_word_code_point(U'ß'));
    for (char32_t cp : {U'«', U'»', U'—', U'€', U'₽', U'°', U'\u2581', U'-', U'.', U'×'}) {
        CHECK(!sdasr::is_word_code_point(cp));
    }
    CHECK(sdasr::is_space_code_point(U' ') && sdasr::is_space_code_point(U'\u00A0') && !sdasr::is_space_code_point(U'\u2581'));
}

TEST_CASE("punctuation merge keeps sentence ends, applies the model elsewhere") {
    auto run = [](const std::string &text, const std::vector<std::string> &labels) {
        return sdasr::merge_punct_labels(sdasr::split_punct_words(text), labels);
    };
    // New marks; the word after a new sentence end is capitalised.
    CHECK_EQ(run("привет как дела", {".", "0", "?"}), std::string("привет. Как дела?"));
    // An existing "!" survives the model's "."; a lone "." may become "?".
    CHECK_EQ(run("Ура! пошли.", {".", "?"}), std::string("Ура! Пошли?"));
    // Existing commas the model disagrees with go away; ";" stays.
    CHECK_EQ(run("раз, два; три", {"0", ",", "."}), std::string("раз два; три."));
    // An abbreviation the model does not end a sentence at keeps the next word.
    CHECK_EQ(run("т.е. мы", {"0", "."}), std::string("т.е. мы."));
    // Standalone dashes: kept as typed, new ones are em dashes in Cyrillic.
    CHECK_EQ(run("вот - это", {".", "0"}), std::string("вот - это"));
    CHECK_EQ(run("вот это", {"-", "0"}), std::string("вот \u2014 это"));
    CHECK_EQ(run("so this", {"-", "."}), std::string("so - this."));
    // Detached marks join the word before; numbers keep inner marks.
    CHECK_EQ(run("слово ? 3.14", {"0", "0"}), std::string("слово? 3.14"));
    CHECK_EQ(run("«да» ушёл", {".", "0"}), std::string("«да». Ушёл"));
    CHECK(sdasr::split_punct_words("  \t ").empty());
    CHECK_EQ(sdasr::capitalize_first_letter("«ёлка"), std::string("«Ёлка"));
    CHECK_EQ(sdasr::capitalize_first_letter("123"), std::string("123"));
}

TEST_CASE("modernbert_punct is a supported text family without sample_rate") {
    CHECK(sdasr::is_supported_family("modernbert_punct"));
    CHECK(sdasr::is_text_family("modernbert_punct"));
    CHECK(!sdasr::is_text_family("nemo_tdt"));
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: sd_asr_contract_tests <assets_dir>\n");
        return 64;
    }
    g_assets = fs::u8path(argv[1]);
    return sdtest::run_all();
}

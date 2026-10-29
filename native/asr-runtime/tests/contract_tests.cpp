// C ABI contract tests that need no real model (spec §11.1).
//   sd_asr_contract_tests <assets_dir>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>

#include "audio.h"
#include "common.h"
#include "families/family_util.h"
#include "families/hotwords.h"
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

// ---- ASR hotwords (docs/specs/asr-hotwords-spec.md §4-§5, §7) -------------

namespace {

// One token per byte (id = byte value); '#' is "outside the vocabulary".
class ByteTokenizer final : public sdasr::hotwords::PhraseTokenizer {
public:
    bool encode(const std::string &phrase, std::vector<int> &ids) const override {
        ids.clear();
        for (unsigned char c : phrase) {
            if (c == '#') return false;
            ids.push_back(int(c));
        }
        return !ids.empty();
    }
};

std::vector<int> encoded(const sdasr::hotwords::PhraseTokenizer &tokenizer, const std::string &phrase) {
    std::vector<int> ids;
    if (!tokenizer.encode(phrase, ids)) return {-1};
    return ids;
}

sd_asr_status parse_status(const json &options, std::vector<std::string> &phrases, double &score) {
    try {
        sdasr::hotwords::parse_options(options, phrases, score);
    } catch (const sdasr::Error &e) {
        return e.status();
    }
    return SD_ASR_OK;
}

}  // namespace

TEST_CASE("manifest: the bundled hotword_tokenizer role is optional, but verified when present") {
    TempDir dir;
    json m = fake_manifest();
    m["files"]["hotword_tokenizer"] = {{"bundled", "not-shipped.tsv"}, {"sha256", std::string(64, 'a')}};
    populate(dir.path, m);
    const sdasr::Manifest loaded = sdasr::load_manifest(dir.path, g_assets, false);
    CHECK(loaded.files.count("hotword_tokenizer") == 0);
    CHECK(loaded.files.count("preprocessor") == 1);

    m["files"]["hotword_tokenizer"] = {{"bundled", "gigaam_v3_spm.tsv"}, {"sha256", std::string(64, 'a')}};
    populate(dir.path, m);
    bool refused = false;
    try {
        sdasr::load_manifest(dir.path, g_assets, false);
    } catch (const sdasr::Error &e) {
        refused = e.status() == SD_ASR_INVALID_MODEL;
    }
    CHECK(refused);  // present but not the pinned bytes

    m["files"]["hotword_tokenizer"]["sha256"] = sdasr::sha256_file(g_assets / "gigaam_v3_spm.tsv");
    populate(dir.path, m);
    CHECK(sdasr::load_manifest(dir.path, g_assets, false).files.count("hotword_tokenizer") == 1);
    CHECK(!sdasr::is_optional_bundled_role("preprocessor"));
}

TEST_CASE("hotwords: phrase normalization and word boundaries") {
    using sdasr::hotwords::is_boundary_piece;
    using sdasr::hotwords::normalize_phrase;
    CHECK_EQ(normalize_phrase("  DDR4 \t DIMM\n"),
             (std::vector<std::string>{"▁", "D", "D", "R", "4", "▁", "D", "I", "M", "M"}));
    CHECK_EQ(normalize_phrase("ЕСИА"), (std::vector<std::string>{"▁", "Е", "С", "И", "А"}));
    CHECK(normalize_phrase(" \t ").empty());
    CHECK(is_boundary_piece("▁при") && is_boundary_piece("▁") && is_boundary_piece("-"));
    CHECK(is_boundary_piece(",") && is_boundary_piece("«") && is_boundary_piece("_x") && is_boundary_piece("<unk>"));
    CHECK(!is_boundary_piece("вет") && !is_boundary_piece("M") && !is_boundary_piece("4") && !is_boundary_piece("ё"));
}

TEST_CASE("hotwords: SentencePiece BPE merges the lowest-id pair") {
    const std::vector<std::string> pieces = {"<unk>", "▁", "a", "b", "c", "ab", "▁a", "bc", "▁ab", "<blk>"};
    const sdasr::hotwords::BpeTokenizer bpe(pieces);
    // ▁ a b c: "ab" (5) beats "▁a" (6) and "bc" (7); then "▁ab" (8).
    CHECK_EQ(encoded(bpe, "abc"), (std::vector<int>{8, 4}));
    CHECK_EQ(encoded(bpe, "a  b"), (std::vector<int>{6, 1, 3}));
    CHECK_EQ(encoded(bpe, "c"), (std::vector<int>{1, 4}));
    CHECK_EQ(encoded(bpe, "ax"), (std::vector<int>{-1}));      // 'x' is not in the vocabulary
    CHECK_EQ(encoded(bpe, "<blk>"), (std::vector<int>{-1}));   // control pieces are never matched
    CHECK_EQ(encoded(bpe, "   "), (std::vector<int>{-1}));
}

// Expected ids: HF `tokenizers` Unigram over the same piece scores with a
// Metaspace("▁", prepend always) pre-tokenizer, i.e. SentencePiece unigram.
TEST_CASE("hotwords: unigram over the bundled GigaAM scores matches SentencePiece") {
    std::vector<std::string> pieces;
    {
        std::ifstream in(g_assets / "gigaam_v3_spm.tsv", std::ios::binary);
        std::string line;
        while (std::getline(in, line)) pieces.push_back(line.substr(0, line.find('\t')));
    }
    CHECK_EQ(pieces.size(), size_t(1024));
    pieces.push_back("<blk>");
    const sdasr::hotwords::UnigramTokenizer unigram(g_assets / "gigaam_v3_spm.tsv", pieces);
    CHECK_EQ(encoded(unigram, "DDR4 DIMM"), (std::vector<int>{521, 982, 499, 408, 521, 570, 894, 894}));
    CHECK_EQ(encoded(unigram, "Красникову"), (std::vector<int>{118, 31, 6, 41, 278, 11}));
    CHECK_EQ(encoded(unigram, "ЕСИА"), (std::vector<int>{348, 268, 531, 615}));
    CHECK_EQ(encoded(unigram, "Gmail watcher"), (std::vector<int>{613, 252, 85, 733, 3, 618, 85, 134, 349, 290, 421}));
    CHECK_EQ(encoded(unigram, "TickTick"), (std::vector<int>{621, 684, 372, 934, 684, 372}));
    CHECK_EQ(encoded(unigram, "Ничипуренко"), (std::vector<int>{479, 110, 300, 57, 10, 62}));
    CHECK_EQ(encoded(unigram, "High-res"), (std::vector<int>{3, 710, 116, 350, 290, 25, 190, 79, 132}));
    CHECK_EQ(encoded(unigram, "Alien_skaarj"), (std::vector<int>{-1}));  // '_' is not a piece

    // A scores file that is not in the model's vocabulary order is refused.
    std::vector<std::string> shifted(pieces.begin() + 1, pieces.end());
    bool refused = false;
    try {
        sdasr::hotwords::UnigramTokenizer bad(g_assets / "gigaam_v3_spm.tsv", shifted);
    } catch (const std::runtime_error &) {
        refused = true;
    }
    CHECK(refused);
}

TEST_CASE("hotwords: trie, duplicates and limits") {
    using namespace sdasr::hotwords;
    const ByteTokenizer bytes;
    const std::string long_phrase(kMaxPhraseTokens + 1, 'z');
    Compiled c = compile({"ab", "ab", "ac", "a#", "", long_phrase, "a", std::string(kMaxPhraseTokens, 'y')}, 2.0, bytes);
    CHECK_EQ(c.used, size_t(4));
    CHECK_EQ(c.skipped, (std::vector<std::string>{"a#", "", long_phrase}));
    const Trie &trie = c.trie;
    CHECK(!trie.empty());
    const int a = trie.child(0, 'a');
    CHECK(a > 0);
    if (a > 0) {
        CHECK(trie.node(a).is_end);  // "a" is itself a phrase
        CHECK_EQ(trie.node(a).token_score, 2.0);
        CHECK_EQ(trie.node(a).children.size(), size_t(2));
        CHECK(trie.child(a, 'b') > 0 && trie.node(trie.child(a, 'b')).is_end);
        CHECK_EQ(trie.child(a, 'd'), -1);
    }
    CHECK_EQ(trie.child(0, 'b'), -1);
    CHECK_EQ(trie.node(0).children.size(), size_t(2));  // 'a', 'y'

    std::vector<std::string> many;
    for (size_t i = 0; i < kMaxPhrases + 5; ++i) many.push_back("p" + std::to_string(i));
    Compiled capped = compile(many, 2.0, bytes);
    CHECK_EQ(capped.used, kMaxPhrases);
    CHECK_EQ(capped.skipped.size(), size_t(5));
    CHECK_EQ(capped.skipped.front(), "p" + std::to_string(kMaxPhrases));
    CHECK(compile({"#"}, 2.0, bytes).trie.empty());
}

TEST_CASE("hotwords: matcher boosts children, commits at a boundary, rolls back otherwise") {
    using namespace sdasr::hotwords;
    using Step = Matcher::Step;
    Trie trie;
    trie.insert({5, 6}, 2.0);
    // Unbiased argmax is 1; token 5 is 1.5 below it, token 6 is 3 below it.
    const std::vector<float> logits = {0.0f, 1.0f, 0.0f, 0.0f, 0.0f, -0.5f, -2.0f, 0.0f};
    {
        Matcher m(trie);
        CHECK_EQ(m.biased_argmax(logits.data(), logits.size(), 0, 0), int64_t(5));
        CHECK(m.step(5, true, 0, 0) == Step::kAcceptAndSnapshot);
        CHECK_EQ(m.biased_argmax(logits.data(), logits.size(), 0, 1), int64_t(1));  // only 6 is boosted now: 0.0 < 1.0
        CHECK(m.step(1, false, 0, 1) == Step::kRollback);
        m.rolled_back(0, 0);
        CHECK_EQ(m.biased_argmax(logits.data(), logits.size(), 0, 0), int64_t(1));  // root boost suppressed here
        CHECK(m.step(5, true, 0, 0) == Step::kAccept);                              // ... and no new match starts
        CHECK_EQ(m.biased_argmax(logits.data(), logits.size(), 0, 1), int64_t(5));  // boosted again elsewhere
        CHECK(!m.finish());
    }
    {
        Matcher m(trie);
        CHECK(m.step(5, true, 0, 0) == Step::kAcceptAndSnapshot);
        CHECK(m.step(6, false, 0, 1) == Step::kAccept);       // complete, pending a word boundary
        CHECK(m.step(3, false, 1, 2) == Step::kRollback);     // the word goes on: not the phrase
        m.rolled_back(0, 0);
        CHECK(m.step(5, true, 1, 1) == Step::kAcceptAndSnapshot);
        CHECK(m.step(6, false, 1, 2) == Step::kAccept);
        CHECK(m.step(5, true, 2, 3) == Step::kAcceptAndSnapshot);  // boundary: commit, the next match starts
        CHECK(m.finish());                                         // ... unfinished at the end: roll back
    }
    {
        Matcher m(trie);
        CHECK(m.step(5, true, 0, 0) == Step::kAcceptAndSnapshot);
        CHECK(m.step(6, false, 0, 1) == Step::kAccept);
        CHECK(!m.finish());  // pending at the end commits
    }
}

TEST_CASE("hotwords: TRANSCRIBE options validation and score clamp") {
    using sdasr::hotwords::kDefaultScore;
    std::vector<std::string> phrases;
    double score = kDefaultScore;
    CHECK_EQ(parse_status(json::object(), phrases, score), SD_ASR_OK);
    CHECK(phrases.empty() && score == kDefaultScore);
    CHECK_EQ(parse_status({{"hotwords", nullptr}, {"hotwords_score", nullptr}}, phrases, score), SD_ASR_OK);
    CHECK_EQ(parse_status({{"hotwords", {"DDR4 DIMM", "ЕСИА"}}, {"hotwords_score", 3}}, phrases, score), SD_ASR_OK);
    CHECK_EQ(phrases, (std::vector<std::string>{"DDR4 DIMM", "ЕСИА"}));
    CHECK_EQ(score, 3.0);
    CHECK_EQ(parse_status({{"hotwords_score", 10.5}}, phrases, score), SD_ASR_OK);
    CHECK_EQ(score, 5.0);
    CHECK_EQ(parse_status({{"hotwords_score", 0.1}}, phrases, score), SD_ASR_OK);
    CHECK_EQ(score, 0.5);
    for (const json &bad : {json{{"hotwords", "DDR4"}}, json{{"hotwords", {1, 2}}}, json{{"hotwords", {{"a", 1}}}},
                            json{{"hotwords_score", "2"}}, json{{"hotwords_score", true}}}) {
        std::vector<std::string> p;
        double s = kDefaultScore;
        CHECK_EQ(parse_status(bad, p, s), SD_ASR_INVALID_ARGUMENT);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: sd_asr_contract_tests <assets_dir>\n");
        return 64;
    }
    g_assets = fs::u8path(argv[1]);
    return sdtest::run_all();
}

// Punctuation-model parity (modernbert_punct). Skipped (exit 77) unless
//   SD_ASR_TEST_PUNCT_MODEL_DIR — an installed punct-small-int8 or
//                                 punct-base-int8 directory with manifest.json
// is set. Compares, for every line of tests/fixtures/punct_golden_<size>.jsonl
// (tools/reference_punct.py on tests/fixtures/punct_cases.txt), the token
// ids of each word with Hugging Face `tokenizers` and the final text with the
// reference merge.
//   sd_asr_punct_tests <fixtures_dir>
#include <cstdlib>
#include <filesystem>
#include <fstream>

#include "families/bpe_tokenizer.h"
#include "families/punct_text.h"
#include "nlohmann/json.hpp"
#include "sd_asr.h"
#include "test_util.h"

namespace fs = std::filesystem;
using nlohmann::json;

namespace {

fs::path g_model, g_fixtures;

std::vector<json> load_golden() {
    json manifest = json::parse(std::ifstream(g_model / "manifest.json"));
    const std::string id = manifest["model_id"];  // punct-<size>-int8
    const std::string size = id.substr(6, id.size() - 6 - 5);
    std::ifstream in(g_fixtures / ("punct_golden_" + size + ".jsonl"));
    std::vector<json> lines;
    for (std::string line; std::getline(in, line);) {
        if (!line.empty()) lines.push_back(json::parse(line));
    }
    return lines;
}

TEST_CASE("tokenizer matches Hugging Face tokenizers word by word") {
    sdasr::BpeTokenizer tokenizer(g_model / "tokenizer.json");
    CHECK_EQ(tokenizer.vocab_size(), size_t(256000));
    const auto golden = load_golden();
    CHECK(!golden.empty());
    size_t words = 0;
    for (const auto &line : golden) {
        const auto split = sdasr::split_punct_words(line["text"].get<std::string>());
        CHECK_EQ(split.size(), line["ids"].size());
        for (size_t i = 0; i < split.size() && i < line["ids"].size(); ++i) {
            const auto ids = tokenizer.encode_word(split[i].core);
            const auto expected = line["ids"][i].get<std::vector<int64_t>>();
            if (ids != expected) std::printf("  word '%s' differs\n", split[i].core.c_str());
            CHECK(ids == expected);
            ++words;
        }
    }
    std::printf("  %zu words\n", words);
}

TEST_CASE("punctuated text matches the reference") {
    json config = {{"model_directory", g_model.u8string()}, {"intra_op_threads", 1}};
    sd_asr_handle *handle = nullptr;
    char *error = nullptr;
    CHECK_EQ(sd_asr_create(config.dump().c_str(), &handle, &error), SD_ASR_OK);
    if (!handle) {
        std::printf("  %s\n", error ? error : "?");
        sd_asr_free(error);
        return;
    }
    for (const auto &line : load_golden()) {
        char *result = nullptr;
        const std::string text = line["text"];
        CHECK_EQ(sd_asr_punctuate_utf8(handle, text.c_str(), nullptr, &result, &error), SD_ASR_OK);
        if (!result) continue;
        const std::string got = json::parse(result)["text"];
        if (got != line["output"].get<std::string>()) std::printf("  got  %s\n  want %s\n", got.c_str(),
                                                                 line["output"].get<std::string>().c_str());
        CHECK_EQ(got, line["output"].get<std::string>());
        sd_asr_free(result);
    }
    // A punctuation model refuses audio.
    const float silence[16] = {};
    char *result = nullptr;
    CHECK_EQ(sd_asr_transcribe_pcm_f32(handle, silence, 16, 16000, nullptr, &result, &error),
             SD_ASR_INVALID_ARGUMENT);
    sd_asr_free(error);
    sd_asr_destroy(handle);
}

}  // namespace

int main(int argc, char **argv) {
    const char *model = std::getenv("SD_ASR_TEST_PUNCT_MODEL_DIR");
    if (!model || !*model || argc < 2) {
        std::printf("SKIP: set SD_ASR_TEST_PUNCT_MODEL_DIR\n");
        return 77;
    }
    g_model = fs::u8path(model);
    g_fixtures = fs::u8path(argv[1]);
    return sdtest::run_all();
}

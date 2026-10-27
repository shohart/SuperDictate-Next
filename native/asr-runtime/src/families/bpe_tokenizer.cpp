#include "bpe_tokenizer.h"

#include <cstdio>
#include <fstream>
#include <limits>

#include "../common.h"
#include "family_util.h"

namespace sdasr {

namespace {

[[noreturn]] void invalid(const std::string &message) {
    throw Error(SD_ASR_INVALID_MODEL, "tokenizer.json: " + message);
}

// Collects only what the BPE needs; every other part of the document is
// skipped as it streams past.
class TokenizerSax : public nlohmann::json_sax<json> {
public:
    std::unordered_map<std::string, int64_t> vocab;
    std::vector<std::pair<std::string, std::string>> merges;
    std::string model_type, normalizer_type, normalizer_pattern, normalizer_content;
    std::string pre_type, pre_replacement, pre_prepend, unk_token;
    bool pre_split = false, byte_fallback = false, has_prefix = false, has_suffix = false;

    bool null() override { return true; }
    bool boolean(bool value) override {
        if (at({"", "model"}) && key_ == "byte_fallback") byte_fallback = value;
        if (at({"", "pre_tokenizer"}) && key_ == "split") pre_split = value;
        return true;
    }
    bool number_integer(number_integer_t value) override { return number(int64_t(value)); }
    bool number_unsigned(number_unsigned_t value) override {
        if (value > uint64_t(std::numeric_limits<int64_t>::max())) return true;
        return number(int64_t(value));
    }
    bool number_float(number_float_t, const string_t &) override { return true; }
    bool string(string_t &value) override {
        if (at({"", "model", "merges"})) {
            // Legacy "a b" form.
            const size_t space = value.find(' ');
            if (space == std::string::npos) invalid("merge without a space: " + value);
            merges.emplace_back(value.substr(0, space), value.substr(space + 1));
        } else if (at({"", "model", "merges", ""})) {
            pair_.push_back(value);
        } else if (at({"", "model"})) {
            if (key_ == "type") model_type = value;
            if (key_ == "unk_token") unk_token = value;
            if (key_ == "continuing_subword_prefix") has_prefix = !value.empty();
            if (key_ == "end_of_word_suffix") has_suffix = !value.empty();
        } else if (at({"", "normalizer"})) {
            if (key_ == "type") normalizer_type = value;
            if (key_ == "content") normalizer_content = value;
        } else if (at({"", "normalizer", "pattern"})) {
            if (key_ == "String") normalizer_pattern = value;
        } else if (at({"", "pre_tokenizer"})) {
            if (key_ == "type") pre_type = value;
            if (key_ == "replacement") pre_replacement = value;
            if (key_ == "prepend_scheme") pre_prepend = value;
        }
        return true;
    }
    bool binary(binary_t &) override { return true; }
    bool start_object(std::size_t) override { return open(); }
    bool key(string_t &value) override {
        key_ = value;
        return true;
    }
    bool end_object() override { return close(); }
    bool start_array(std::size_t) override {
        if (at({"", "model", "merges"})) pair_.clear();
        return open();
    }
    bool end_array() override {
        if (at({"", "model", "merges", ""})) {
            if (pair_.size() != 2) invalid("a merge is not a pair");
            merges.emplace_back(std::move(pair_[0]), std::move(pair_[1]));
            pair_.clear();
        }
        return close();
    }
    bool parse_error(std::size_t position, const std::string &, const nlohmann::detail::exception &e) override {
        invalid("parse error at byte " + std::to_string(position) + ": " + e.what());
    }

private:
    bool number(int64_t value) {
        if (at({"", "model", "vocab"})) vocab[key_] = value;
        return true;
    }
    bool at(std::initializer_list<const char *> path) const {
        if (path.size() != stack_.size()) return false;
        size_t i = 0;
        for (const char *p : path) {
            if (stack_[i++] != p) return false;
        }
        return true;
    }
    bool open() {
        stack_.push_back(key_);
        key_.clear();
        return true;
    }
    bool close() {
        if (!stack_.empty()) stack_.pop_back();
        key_.clear();
        return true;
    }

    std::vector<std::string> stack_;
    std::string key_;
    std::vector<std::string> pair_;
};

}  // namespace

BpeTokenizer::BpeTokenizer(const std::filesystem::path &tokenizer_json) {
    std::ifstream in(tokenizer_json, std::ios::binary);
    if (!in) throw Error(SD_ASR_INVALID_MODEL, "cannot open tokenizer " + tokenizer_json.u8string());
    TokenizerSax sax;
    json::sax_parse(in, &sax);

    if (sax.model_type != "BPE") invalid("model type '" + sax.model_type + "' is not BPE");
    if (!sax.byte_fallback) invalid("BPE without byte_fallback is not supported");
    if (sax.has_prefix || sax.has_suffix) invalid("continuing_subword_prefix / end_of_word_suffix are not supported");
    if (sax.normalizer_type != "Replace" || sax.normalizer_pattern != " " || sax.normalizer_content != kWordStartPiece) {
        invalid("normalizer must be Replace(\" \" -> U+2581)");
    }
    if (sax.pre_type != "Metaspace" || sax.pre_replacement != kWordStartPiece || sax.pre_prepend != "always" ||
        !sax.pre_split) {
        invalid("pre-tokenizer must be Metaspace(U+2581, prepend always, split)");
    }
    if (sax.vocab.empty()) invalid("empty vocabulary");

    vocab_ = std::move(sax.vocab);
    if (auto it = vocab_.find(sax.unk_token); it != vocab_.end()) unk_id_ = it->second;
    if (unk_id_ < 0) invalid("unk_token is not in the vocabulary");
    for (int b = 0; b < 256; ++b) {
        char name[8];
        std::snprintf(name, sizeof(name), "<0x%02X>", b);
        // Bytes whose character is a regular token (Gemma has "\t", not
        // "<0x09>") have no fallback token.
        auto it = vocab_.find(name);
        byte_ids_[b] = it == vocab_.end() ? -1 : it->second;
    }
    merges_.reserve(sax.merges.size());
    int rank = 0;
    for (const auto &[a, b] : sax.merges) {
        auto ia = vocab_.find(a), ib = vocab_.find(b), im = vocab_.find(a + b);
        if (ia != vocab_.end() && ib != vocab_.end() && im != vocab_.end()) {
            merges_.emplace(pair_key(ia->second, ib->second), Merge{rank, im->second});
        }
        ++rank;
    }
}

std::vector<int64_t> BpeTokenizer::encode_word(const std::string &word) const {
    const std::string text = std::string(kWordStartPiece) + word;
    std::vector<int64_t> symbols;
    for (size_t i = 0; i < text.size();) {
        const size_t start = i;
        next_code_point(text, i);
        const std::string ch = text.substr(start, i - start);
        if (auto it = vocab_.find(ch); it != vocab_.end()) {
            symbols.push_back(it->second);
        } else {
            // Like `tokenizers`: the character's bytes, or <unk> when any
            // of them has no fallback token.
            bool all_bytes = true;
            for (unsigned char byte : ch) all_bytes = all_bytes && byte_ids_[byte] >= 0;
            if (all_bytes) {
                for (unsigned char byte : ch) symbols.push_back(byte_ids_[byte]);
            } else {
                symbols.push_back(unk_id_);
            }
        }
    }
    // Lowest rank first, leftmost among equal ranks — the order of the
    // reference's priority queue.
    for (;;) {
        int best_rank = std::numeric_limits<int>::max();
        size_t best = 0;
        int64_t merged = 0;
        for (size_t i = 0; i + 1 < symbols.size(); ++i) {
            auto it = merges_.find(pair_key(symbols[i], symbols[i + 1]));
            if (it != merges_.end() && it->second.rank < best_rank) {
                best_rank = it->second.rank;
                best = i;
                merged = it->second.merged;
            }
        }
        if (best_rank == std::numeric_limits<int>::max()) break;
        symbols[best] = merged;
        symbols.erase(symbols.begin() + long(best) + 1);
    }
    return symbols;
}

}  // namespace sdasr

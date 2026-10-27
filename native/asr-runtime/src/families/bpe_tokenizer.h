// Hugging Face `tokenizers` BPE, the subset the punctuation models use
// (Gemma-style tokenizer.json of mmBERT): normalizer Replace(" " -> U+2581),
// pre-tokenizer Metaspace(U+2581, prepend "always", split), BPE with byte
// fallback and no continuing-subword prefix. Anything else is refused as
// SD_ASR_INVALID_MODEL rather than tokenized differently from the reference.
//
// Reference: `tokenizers.Tokenizer.from_file(...).encode(word,
// add_special_tokens=False)`; native/asr-runtime/tools/reference_punct.py
// writes the parity goldens.
#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <unordered_map>
#include <vector>

namespace sdasr {

class BpeTokenizer {
public:
    // Streams the JSON (SAX): the 34 MB file never becomes a DOM.
    explicit BpeTokenizer(const std::filesystem::path &tokenizer_json);

    // Ids for one whitespace-free word, as Metaspace sees it ("▁" + word).
    std::vector<int64_t> encode_word(const std::string &word) const;

    size_t vocab_size() const { return vocab_.size(); }

private:
    struct Merge {
        int rank;
        int64_t merged;
    };
    static uint64_t pair_key(int64_t a, int64_t b) { return (uint64_t(uint32_t(a)) << 32) | uint32_t(b); }

    std::unordered_map<std::string, int64_t> vocab_;
    std::unordered_map<uint64_t, Merge> merges_;
    int64_t byte_ids_[256];  // -1: no <0xXX> token for this byte
    int64_t unk_id_ = -1;
};

}  // namespace sdasr

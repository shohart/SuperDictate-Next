// ASR hotwords (vocabulary biasing), spec docs/specs/asr-hotwords-spec.md
// §4-§5: phrase tokenizers in the model's own pieces, the boosting trie, and
// the greedy-decoder match bookkeeping with rollback shared by the
// transducer families. The families own their decoder state and its
// snapshot; the Matcher only tells them when to take or restore it.
//
// Reference implementation: native/asr-runtime/tools/reference_hotwords.py
// (used by reference_tdt.py and reference_gigaam.py). The two must decode
// identically.
#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "../common.h"

namespace sdasr {
namespace hotwords {

inline constexpr size_t kMaxPhrases = 1000;
inline constexpr size_t kMaxPhraseTokens = 32;
// Phrases longer than this many code points are skipped before tokenizing
// (no vocabulary piece is long enough for them to fit in 32 tokens anyway;
// it bounds the BPE merge loop).
inline constexpr size_t kMaxPhraseCodePoints = 512;
inline constexpr double kDefaultScore = 2.0;
inline constexpr double kMinScore = 0.5;
inline constexpr double kMaxScore = 5.0;

double clamp_score(double score);

// TRANSCRIBE options "hotwords" (array of strings) and "hotwords_score"
// (number, clamped); spec §7. Absent or null fields leave the outputs
// untouched; a wrong type throws Error(SD_ASR_INVALID_ARGUMENT).
void parse_options(const json &options, std::vector<std::string> &phrases, double &score);

// Spec §5 normalization as code points (UTF-8 each): whitespace runs
// collapse to U+2581 and a leading U+2581 is added; no case folding. Empty
// when the phrase has no non-space character.
std::vector<std::string> normalize_phrase(const std::string &phrase);

// §4.3 boundary(token): the piece starts with U+2581, or its first code
// point is not a letter or digit (Python str.isalnum).
bool is_boundary_piece(const std::string &piece);

class PhraseTokenizer {
public:
    virtual ~PhraseTokenizer() = default;
    // False when the phrase cannot be expressed in the vocabulary.
    virtual bool encode(const std::string &phrase, std::vector<int> &ids) const = 0;
};

// SentencePiece BPE (Parakeet, tokens.txt alone): start from single code
// points, then repeatedly merge the leftmost adjacent pair whose
// concatenation is a vocabulary piece with the lowest id.
class BpeTokenizer final : public PhraseTokenizer {
public:
    explicit BpeTokenizer(const std::vector<std::string> &pieces);
    bool encode(const std::string &phrase, std::vector<int> &ids) const override;

private:
    std::unordered_map<std::string, int> ids_;
};

// SentencePiece unigram (GigaAM): Viterbi segmentation maximising the sum of
// piece scores. The scores come from a "<piece>\t<score>" file in vocabulary
// order (tools/spm_to_tsv.py); piece i must be the model's piece i.
class UnigramTokenizer final : public PhraseTokenizer {
public:
    // Throws std::runtime_error with a human-readable reason.
    UnigramTokenizer(const std::filesystem::path &scores_tsv, const std::vector<std::string> &pieces);
    bool encode(const std::string &phrase, std::vector<int> &ids) const override;

private:
    std::unordered_map<std::string, std::pair<double, int>> pieces_;  // piece -> (score, id)
    size_t max_code_points_ = 0;
};

// Trie of token ids. Node 0 is the root; every edge carries token_score.
class Trie {
public:
    struct Node {
        std::vector<std::pair<int, int>> children;  // (token id, node index), sorted by token id
        double token_score = 0;
        bool is_end = false;
    };

    Trie();
    void insert(const std::vector<int> &tokens, double score);
    // Child node index for `token`, or -1.
    int child(int node, int token) const;
    const Node &node(int index) const { return nodes_[size_t(index)]; }
    bool empty() const { return nodes_[0].children.empty(); }
    size_t size() const { return nodes_.size(); }

private:
    std::vector<Node> nodes_;
};

struct Compiled {
    Trie trie;
    size_t used = 0;                    // phrases in the trie
    std::vector<std::string> skipped;   // phrases that could not be used, as given
};

// Duplicates (exact string) are merged; empty phrases, phrases the
// tokenizer rejects, phrases over kMaxPhraseTokens tokens and everything
// past kMaxPhrases accepted phrases are skipped. `score` must be clamped.
Compiled compile(const std::vector<std::string> &phrases, double score, const PhraseTokenizer &tokenizer);

// Greedy-decoder match bookkeeping (spec §4.2-§4.3). Positions are
// (encoder frame t, number of tokens emitted so far).
class Matcher {
public:
    enum class Step {
        kAccept,              // emit the token
        kAcceptAndSnapshot,   // save the decoder state first, then emit
        kRollback,            // restore the snapshot, call rolled_back(), re-run that step
    };

    explicit Matcher(const Trie &trie) : trie_(trie) {}

    // argmax over logits[0, count) with token_score added to the children
    // of the current node (none at a suppressed root). Equal to the argmax
    // of log_softmax + boost: the log-sum-exp shift does not change it.
    int64_t biased_argmax(const float *logits, size_t count, int64_t t, size_t emitted) const;

    // For every emitted non-blank token.
    Step step(int token, bool boundary, int64_t t, size_t emitted);

    // At the end of the frames: commits a pending match; true when an
    // unfinished match must be rolled back.
    bool finish();

    void rolled_back(int64_t t, size_t emitted);

private:
    bool root_suppressed(int64_t t, size_t emitted) const {
        return node_ == 0 && has_suppress_ && suppress_t_ == t && suppress_emitted_ == emitted;
    }

    const Trie &trie_;
    int node_ = 0;
    bool pending_ = false;
    bool has_snapshot_ = false;
    bool has_suppress_ = false;
    int64_t suppress_t_ = 0;
    size_t suppress_emitted_ = 0;
};

}  // namespace hotwords
}  // namespace sdasr

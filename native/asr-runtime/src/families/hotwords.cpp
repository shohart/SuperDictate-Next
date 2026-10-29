#include "hotwords.h"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <unordered_set>

#include "family_util.h"

namespace sdasr {
namespace hotwords {

double clamp_score(double score) {
    return std::min(kMaxScore, std::max(kMinScore, score));
}

void parse_options(const json &options, std::vector<std::string> &phrases, double &score) {
    auto list = options.find("hotwords");
    if (list != options.end() && !list->is_null()) {
        if (!list->is_array()) throw Error(SD_ASR_INVALID_ARGUMENT, "options field 'hotwords' must be an array of strings");
        for (const auto &phrase : *list) {
            if (!phrase.is_string()) {
                throw Error(SD_ASR_INVALID_ARGUMENT, "options field 'hotwords' must be an array of strings");
            }
            phrases.push_back(phrase.get<std::string>());
        }
    }
    auto value = options.find("hotwords_score");
    if (value != options.end() && !value->is_null()) {
        if (!value->is_number()) throw Error(SD_ASR_INVALID_ARGUMENT, "options field 'hotwords_score' must be a number");
        score = clamp_score(value->get<double>());
    }
}

std::vector<std::string> normalize_phrase(const std::string &phrase) {
    // "▁" + "▁".join(phrase.split())
    std::vector<std::string> out;
    bool in_space = true;
    for (size_t i = 0; i < phrase.size();) {
        const size_t start = i;
        const char32_t cp = next_code_point(phrase, i);
        if (is_space_code_point(cp)) {
            in_space = true;
            continue;
        }
        if (in_space) out.push_back(kWordStartPiece);
        in_space = false;
        out.push_back(phrase.substr(start, i - start));
    }
    return out;
}

bool is_boundary_piece(const std::string &piece) {
    if (piece.empty()) return true;
    size_t i = 0;
    const char32_t cp = next_code_point(piece, i);
    if (cp == 0x2581) return true;
    return !(is_word_code_point(cp) && cp != U'_');  // \w minus "_" == str.isalnum()
}

// ---------------------------------------------------------------------------

BpeTokenizer::BpeTokenizer(const std::vector<std::string> &pieces) {
    for (size_t id = 0; id < pieces.size(); ++id) {
        if (!is_control_piece(pieces[id])) ids_[pieces[id]] = int(id);
    }
}

bool BpeTokenizer::encode(const std::string &phrase, std::vector<int> &ids) const {
    ids.clear();
    std::vector<std::string> symbols = normalize_phrase(phrase);
    if (symbols.empty() || symbols.size() > kMaxPhraseCodePoints + 1) return false;
    for (const std::string &symbol : symbols) {
        if (ids_.find(symbol) == ids_.end()) return false;  // a character outside the vocabulary
    }
    std::string merged;
    while (symbols.size() > 1) {
        int best = std::numeric_limits<int>::max();
        size_t best_index = symbols.size();
        for (size_t i = 0; i + 1 < symbols.size(); ++i) {
            merged.assign(symbols[i]).append(symbols[i + 1]);
            auto it = ids_.find(merged);
            if (it != ids_.end() && it->second < best) {
                best = it->second;
                best_index = i;
            }
        }
        if (best_index == symbols.size()) break;
        symbols[best_index] += symbols[best_index + 1];
        symbols.erase(symbols.begin() + long(best_index) + 1);
    }
    for (const std::string &symbol : symbols) ids.push_back(ids_.at(symbol));
    return true;
}

// ---------------------------------------------------------------------------

UnigramTokenizer::UnigramTokenizer(const std::filesystem::path &scores_tsv, const std::vector<std::string> &pieces) {
    std::ifstream in(scores_tsv, std::ios::binary);
    if (!in) throw std::runtime_error("cannot open hotword tokenizer " + scores_tsv.filename().u8string());
    std::string line;
    size_t index = 0;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        const size_t tab = line.find('\t');
        if (tab == std::string::npos) throw std::runtime_error("malformed hotword tokenizer line " + std::to_string(index));
        const std::string piece = line.substr(0, tab);
        if (index >= pieces.size() || pieces[index] != piece) {
            throw std::runtime_error("hotword tokenizer does not match the model vocabulary at piece " +
                                     std::to_string(index));
        }
        const std::string score_text = line.substr(tab + 1);
        char *end = nullptr;
        const double score = std::strtod(score_text.c_str(), &end);
        if (score_text.empty() || end != score_text.c_str() + score_text.size()) {
            throw std::runtime_error("malformed hotword tokenizer score at piece " + std::to_string(index));
        }
        if (!is_control_piece(piece)) {
            pieces_.emplace(piece, std::make_pair(score, int(index)));
            size_t code_points = 0;
            for (size_t i = 0; i < piece.size(); ++code_points) next_code_point(piece, i);
            max_code_points_ = std::max(max_code_points_, code_points);
        }
        ++index;
    }
    if (pieces_.empty()) throw std::runtime_error("hotword tokenizer is empty");
}

bool UnigramTokenizer::encode(const std::string &phrase, std::vector<int> &ids) const {
    ids.clear();
    const std::vector<std::string> text = normalize_phrase(phrase);
    const size_t n = text.size();
    if (n == 0 || n > kMaxPhraseCodePoints + 1) return false;
    // best[j] = (score of the best segmentation of text[0, j), its last cut).
    constexpr double kUnreached = -1e30;
    std::vector<std::pair<double, size_t>> best(n + 1, {kUnreached, 0});
    best[0] = {0.0, 0};
    std::string candidate;
    for (size_t i = 0; i < n; ++i) {
        if (best[i].first <= -1e29) continue;
        candidate.clear();
        for (size_t j = i + 1; j <= std::min(n, i + max_code_points_); ++j) {
            candidate += text[j - 1];
            auto it = pieces_.find(candidate);
            if (it != pieces_.end() && best[i].first + it->second.first > best[j].first) {
                best[j] = {best[i].first + it->second.first, i};
            }
        }
    }
    if (best[n].first <= -1e29) return false;
    for (size_t j = n; j > 0;) {
        const size_t i = best[j].second;
        candidate.clear();
        for (size_t k = i; k < j; ++k) candidate += text[k];
        ids.push_back(pieces_.at(candidate).second);
        j = i;
    }
    std::reverse(ids.begin(), ids.end());
    return true;
}

// ---------------------------------------------------------------------------

Trie::Trie() : nodes_(1) {}

void Trie::insert(const std::vector<int> &tokens, double score) {
    int node = 0;
    for (size_t k = 0; k < tokens.size(); ++k) {
        const int token = tokens[k];
        int next = child(node, token);
        if (next < 0) {
            next = int(nodes_.size());
            nodes_.emplace_back();
            nodes_.back().token_score = score;
            auto &children = nodes_[size_t(node)].children;
            const auto at = std::lower_bound(children.begin(), children.end(), std::make_pair(token, 0));
            children.insert(at, {token, next});
        } else {
            nodes_[size_t(next)].token_score = std::max(nodes_[size_t(next)].token_score, score);
        }
        if (k + 1 == tokens.size()) nodes_[size_t(next)].is_end = true;
        node = next;
    }
}

int Trie::child(int node, int token) const {
    const auto &children = nodes_[size_t(node)].children;
    const auto it = std::lower_bound(children.begin(), children.end(), std::make_pair(token, 0));
    return it != children.end() && it->first == token ? it->second : -1;
}

Compiled compile(const std::vector<std::string> &phrases, double score, const PhraseTokenizer &tokenizer) {
    Compiled compiled;
    std::unordered_set<std::string> seen;
    std::vector<int> ids;
    for (const std::string &phrase : phrases) {
        if (!seen.insert(phrase).second) continue;
        if (compiled.used >= kMaxPhrases || !tokenizer.encode(phrase, ids) || ids.empty() ||
            ids.size() > kMaxPhraseTokens) {
            compiled.skipped.push_back(phrase);
            continue;
        }
        compiled.trie.insert(ids, score);
        ++compiled.used;
    }
    return compiled;
}

// ---------------------------------------------------------------------------

int64_t Matcher::biased_argmax(const float *logits, size_t count, int64_t t, size_t emitted) const {
    static const std::vector<std::pair<int, int>> kNone;
    const auto &children = root_suppressed(t, emitted) ? kNone : trie_.node(node_).children;
    auto child = children.begin();
    size_t best = 0;
    double best_value = -std::numeric_limits<double>::infinity();
    for (size_t i = 0; i < count; ++i) {
        double value = logits[i];
        while (child != children.end() && size_t(child->first) < i) ++child;
        if (child != children.end() && size_t(child->first) == i) value += trie_.node(child->second).token_score;
        if (value > best_value || i == 0) {
            best_value = value;
            best = i;
        }
    }
    return int64_t(best);
}

Matcher::Step Matcher::step(int token, bool boundary, int64_t t, size_t emitted) {
    int next = trie_.child(node_, token);
    if (pending_ && next < 0) {
        if (!boundary) return Step::kRollback;
        // The phrase is complete at a word boundary: commit it.
        node_ = 0;
        pending_ = false;
        has_snapshot_ = false;
        next = trie_.child(0, token);
    }
    if (next >= 0 && !root_suppressed(t, emitted)) {
        const bool snapshot = node_ == 0;
        node_ = next;
        pending_ = trie_.node(next).is_end;
        if (snapshot) has_snapshot_ = true;
        return snapshot ? Step::kAcceptAndSnapshot : Step::kAccept;
    }
    return node_ != 0 ? Step::kRollback : Step::kAccept;
}

bool Matcher::finish() {
    if (pending_) {
        pending_ = false;
        has_snapshot_ = false;
    }
    return has_snapshot_;
}

void Matcher::rolled_back(int64_t t, size_t emitted) {
    node_ = 0;
    pending_ = false;
    has_snapshot_ = false;
    has_suppress_ = true;
    suppress_t_ = t;
    suppress_emitted_ = emitted;
}

}  // namespace hotwords
}  // namespace sdasr

// Text side of punctuation restoration: splitting a finished dictation into
// words for the model and merging the model's per-word labels back in.
//
// The model sees the words without their trailing marks and predicts, after
// each word, one of: none, "." "," "?" "-" ":". The merge is conservative
// about what the earlier stages (ASR, correction, rewrite) already decided:
//   * an existing sentence end (. ! ? …, or several) is kept; a lone "."
//     becomes "?" when the model says it is a question;
//   * an existing ";" is kept, and so is whatever stands before an existing
//     standalone dash;
//   * everywhere else the model's label wins: commas, colons and dashes are
//     added or removed, and new sentence ends are added;
//   * the word after a new sentence end, or after an existing one the
//     model agrees with, gets a capital first letter; nothing is ever
//     lowercased (proper nouns cannot be told apart);
//   * a standalone dash ("-", "–", "—") in the input is kept as it was; a
//     new one is "—" in text with Cyrillic letters, "-" otherwise.
// Mirrored by native/asr-runtime/tools/reference_punct.py.
#pragma once

#include <string>
#include <vector>

namespace sdasr {

struct PunctWord {
    std::string core;  // the word as the model sees it
    std::string end;   // trailing marks it had in the input
    std::string dash;  // a standalone dash that followed it in the input
};

std::vector<PunctWord> split_punct_words(const std::string &text);

// `labels[i]` is the model's label after word i ("0", ".", ",", "?", "-",
// ":"); `labels.size() == words.size()`.
std::string merge_punct_labels(const std::vector<PunctWord> &words, const std::vector<std::string> &labels);

// First letter (after leading quotes/brackets) in upper case; Latin,
// Latin-1, Greek and Cyrillic.
std::string capitalize_first_letter(const std::string &word);

}  // namespace sdasr

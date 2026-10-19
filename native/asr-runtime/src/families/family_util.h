// Helpers shared by the model-family adapters: manifest params, tokens files,
// graph I/O checks, cancellation and the transcript text/word rules.
#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "family.h"

namespace sdasr {

inline constexpr const char *kWordStartPiece = "\xE2\x96\x81";  // U+2581 "▁"

// Throw SD_ASR_INVALID_MODEL naming the family when the param is missing or
// has the wrong type.
int64_t int_param(const Manifest &manifest, const char *key);
double number_param(const Manifest &manifest, const char *key);

// Pieces such as <unk>, <pad>, <|nospeech|> never reach the transcript.
bool is_control_piece(const std::string &piece);

// "<piece> <id>" per line, every id in [0, expected_count) exactly once.
std::vector<std::string> load_tokens(const std::filesystem::path &path, int64_t expected_count);

std::vector<int64_t> output_shape(Ort::Session &session, size_t index);
void expect_names(Ort::Session &session, bool inputs, const std::vector<std::string> &expected, const char *graph);

void check_cancelled(const RunContext &context);

// Softmax probability of logits[token] over logits[0, count).
double softmax_probability(const float *logits, size_t count, size_t token);

// Unicode classes as Python's `re` sees them (str patterns): \w is
// str.isalnum() or "_", \s is str.isspace(). Exact for U+0000..U+052F
// (ASCII, Latin, Greek, Cyrillic) and for every character of the shipped
// vocabularies (incl. « » — € ₽ ° U+2581); other scripts use a coarse
// block-level approximation.
bool is_word_code_point(char32_t cp);
bool is_space_code_point(char32_t cp);

// Decodes one UTF-8 code point at text[i] (advancing i). Malformed bytes
// decode as themselves.
char32_t next_code_point(const std::string &text, size_t &i);

// Builds result.text and result.words from result.tokens with the pieces
// joined, U+2581 -> space, then onnx-asr's DECODE_SPACE_PATTERN
// r"\A\s|\s\B|(\s)\b": a space survives only when it is not the first
// character and the next character is a word character. Words are split at
// exactly the surviving spaces, so they re-join (with " ") to the text; a
// word starts at the token that carries its space, its confidence is the
// minimum over its tokens.
void build_text_and_words_space_rule(FamilyResult &result, const std::vector<std::string> &pieces,
                                     double audio_end);

}  // namespace sdasr

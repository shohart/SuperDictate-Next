#include "family_util.h"

#include <algorithm>
#include <cmath>
#include <fstream>

namespace sdasr {

int64_t int_param(const Manifest &manifest, const char *key) {
    auto it = manifest.params.find(key);
    if (it == manifest.params.end() || !it->is_number_integer()) {
        throw Error(SD_ASR_INVALID_MODEL,
                    "manifest: " + manifest.family + " requires integer params." + std::string(key));
    }
    return it->get<int64_t>();
}

double number_param(const Manifest &manifest, const char *key) {
    auto it = manifest.params.find(key);
    if (it == manifest.params.end() || !it->is_number()) {
        throw Error(SD_ASR_INVALID_MODEL,
                    "manifest: " + manifest.family + " requires numeric params." + std::string(key));
    }
    return it->get<double>();
}

bool is_control_piece(const std::string &piece) {
    return piece.size() >= 2 && piece.front() == '<' && piece.back() == '>';
}

std::vector<std::string> load_tokens(const std::filesystem::path &path, int64_t expected_count) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw Error(SD_ASR_INVALID_MODEL, "cannot open tokens file");
    std::vector<std::string> pieces(static_cast<size_t>(expected_count));
    std::vector<bool> seen(static_cast<size_t>(expected_count), false);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        const size_t space = line.rfind(' ');
        if (space == std::string::npos || space == 0) throw Error(SD_ASR_INVALID_MODEL, "malformed tokens line: " + line);
        long long id = -1;
        try {
            id = std::stoll(line.substr(space + 1));
        } catch (...) {
            throw Error(SD_ASR_INVALID_MODEL, "malformed token id: " + line);
        }
        if (id < 0 || id >= expected_count) throw Error(SD_ASR_INVALID_MODEL, "token id out of range: " + line);
        pieces[size_t(id)] = line.substr(0, space);
        seen[size_t(id)] = true;
    }
    for (int64_t i = 0; i < expected_count; ++i) {
        if (!seen[size_t(i)]) throw Error(SD_ASR_INVALID_MODEL, "tokens file is missing id " + std::to_string(i));
    }
    return pieces;
}

std::vector<int64_t> output_shape(Ort::Session &session, size_t index) {
    return session.GetOutputTypeInfo(index).GetTensorTypeAndShapeInfo().GetShape();
}

void expect_names(Ort::Session &session, bool inputs, const std::vector<std::string> &expected, const char *graph) {
    Ort::AllocatorWithDefaultOptions allocator;
    const size_t count = inputs ? session.GetInputCount() : session.GetOutputCount();
    if (count != expected.size()) {
        throw Error(SD_ASR_INVALID_MODEL, std::string(graph) + ": unexpected " + (inputs ? "input" : "output") +
                                              " count " + std::to_string(count));
    }
    for (size_t i = 0; i < count; ++i) {
        auto name = inputs ? session.GetInputNameAllocated(i, allocator) : session.GetOutputNameAllocated(i, allocator);
        if (expected[i] != name.get()) {
            throw Error(SD_ASR_INVALID_MODEL, std::string(graph) + ": expected " + (inputs ? "input " : "output ") +
                                                  expected[i] + ", found " + name.get());
        }
    }
}

void check_cancelled(const RunContext &context) {
    if (context.cancelled && context.cancelled->load()) throw Error(SD_ASR_CANCELLED, "request cancelled");
}

double softmax_probability(const float *logits, size_t count, size_t token) {
    const float max_logit = *std::max_element(logits, logits + count);
    double sum = 0;
    for (size_t i = 0; i < count; ++i) sum += std::exp(double(logits[i] - max_logit));
    return std::exp(double(logits[token] - max_logit)) / sum;
}

bool is_space_code_point(char32_t cp) {
    return (cp >= 0x09 && cp <= 0x0D) || (cp >= 0x1C && cp <= 0x20) || cp == 0x85 || cp == 0xA0 || cp == 0x1680 ||
           (cp >= 0x2000 && cp <= 0x200A) || cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F ||
           cp == 0x3000;
}

bool is_word_code_point(char32_t cp) {
    if (cp < 0x80) {
        return (cp >= '0' && cp <= '9') || (cp >= 'A' && cp <= 'Z') || (cp >= 'a' && cp <= 'z') || cp == '_';
    }
    if (cp < 0x100) {  // Latin-1: ª ² ³ µ ¹ º ¼ ½ ¾ and the letters, minus × ÷
        return cp == 0xAA || cp == 0xB2 || cp == 0xB3 || cp == 0xB5 || cp == 0xB9 || cp == 0xBA ||
               (cp >= 0xBC && cp <= 0xBE) || (cp >= 0xC0 && cp != 0xD7 && cp != 0xF7);
    }
    if (cp < 0x2C2) return true;                      // Latin Extended-A/B, IPA letters
    if (cp < 0x370) return cp == 0x2EC || cp == 0x2EE || (cp >= 0x2C6 && cp <= 0x2D1) || (cp >= 0x2E0 && cp <= 0x2E4);
    if (cp < 0x400) {                                  // Greek and Coptic
        return !(cp == 0x375 || cp == 0x37E || cp == 0x384 || cp == 0x385 || cp == 0x387 || cp == 0x3F6 ||
                 cp == 0x378 || cp == 0x379 || (cp >= 0x380 && cp <= 0x383) || cp == 0x38B || cp == 0x38D ||
                 cp == 0x3A2);
    }
    if (cp < 0x530) return cp < 0x482 || cp > 0x489;  // Cyrillic (+Supplement), minus ҂ and combining marks
    if (cp >= 0x2000 && cp < 0x2C00) {                 // punctuation, currency, symbols, arrows, ▁ ...
        return cp == 0x2071 || cp == 0x207F || (cp >= 0x2070 && cp <= 0x2079 && cp != 0x2072 && cp != 0x2073) ||
               (cp >= 0x2080 && cp <= 0x2089) || (cp >= 0x2150 && cp <= 0x2189) || (cp >= 0x2460 && cp <= 0x249B) ||
               (cp >= 0x24EA && cp <= 0x24FF);
    }
    if (cp >= 0x3000 && cp < 0x3040) return cp == 0x3005 || cp == 0x3006 || cp == 0x3007 || (cp >= 0x3021 && cp <= 0x3029);
    if (cp >= 0xFE30 && cp < 0xFE70) return cp == 0xFE33 || cp == 0xFE34 || (cp >= 0xFE4D && cp <= 0xFE4F);
    if (cp >= 0xFF00 && cp < 0xFF10) return false;     // fullwidth punctuation
    return true;                                       // letters of other scripts
}

char32_t next_code_point(const std::string &text, size_t &i) {
    const unsigned char c = static_cast<unsigned char>(text[i]);
    int length = 1;
    char32_t cp = c;
    if ((c >> 5) == 0x6) {
        length = 2;
        cp = c & 0x1F;
    } else if ((c >> 4) == 0xE) {
        length = 3;
        cp = c & 0x0F;
    } else if ((c >> 3) == 0x1E) {
        length = 4;
        cp = c & 0x07;
    }
    if (length > 1) {
        if (i + size_t(length) > text.size()) {
            ++i;
            return c;
        }
        for (int k = 1; k < length; ++k) {
            const unsigned char cont = static_cast<unsigned char>(text[i + size_t(k)]);
            if ((cont >> 6) != 0x2) {
                ++i;
                return c;
            }
            cp = (cp << 6) | (cont & 0x3F);
        }
    }
    i += size_t(length);
    return cp;
}

void build_text_and_words_space_rule(FamilyResult &result, const std::vector<std::string> &pieces,
                                     double audio_end) {
    // Flatten to (code point bytes, owning token) with U+2581 -> ' '.
    struct Char {
        std::string bytes;
        char32_t cp;
        size_t token;
    };
    std::vector<Char> chars;
    for (size_t k = 0; k < result.tokens.size(); ++k) {
        const std::string &piece = pieces[size_t(result.tokens[k].id)];
        for (size_t i = 0; i < piece.size();) {
            const size_t start = i;
            const char32_t cp = next_code_point(piece, i);
            if (cp == 0x2581) {
                chars.push_back({" ", U' ', k});
            } else {
                chars.push_back({piece.substr(start, i - start), cp, k});
            }
        }
    }

    std::string text;
    size_t word_last_token = 0;
    auto start_word = [&](size_t k) {
        const DecodedToken &token = result.tokens[k];
        if (!result.words.empty()) result.words.back().end = std::min(result.words.back().end, token.t);
        result.words.push_back({std::string(), token.t, token.t + result.frame_sec, token.conf});
        word_last_token = k;
    };
    for (size_t i = 0; i < chars.size(); ++i) {
        const Char &ch = chars[i];
        if (is_space_code_point(ch.cp)) {
            // r"\A\s|\s\B|(\s)\b": only "(\s)\b" keeps a space, i.e. not at
            // the very start and followed by a word character.
            const bool kept = i > 0 && i + 1 < chars.size() && is_word_code_point(chars[i + 1].cp);
            if (!kept) continue;
            text += ' ';
            start_word(ch.token);
            continue;
        }
        if (result.words.empty()) start_word(ch.token);
        DecodedWord &word = result.words.back();
        if (ch.token != word_last_token) {
            const DecodedToken &token = result.tokens[ch.token];
            word.end = token.t + result.frame_sec;
            word.conf = std::min(word.conf, token.conf);
            word_last_token = ch.token;
        }
        word.w += ch.bytes;
        text += ch.bytes;
    }
    if (!result.words.empty()) result.words.back().end = std::min(result.words.back().end, audio_end);
    result.words.erase(std::remove_if(result.words.begin(), result.words.end(),
                                      [](const DecodedWord &w) { return w.w.empty(); }),
                       result.words.end());
    result.text = std::move(text);
}

}  // namespace sdasr

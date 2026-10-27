#include "punct_text.h"

#include "family_util.h"

namespace sdasr {

namespace {

const std::string kEllipsis = "\xE2\x80\xA6";  // …
const std::string kEnDash = "\xE2\x80\x93";    // –
const std::string kEmDash = "\xE2\x80\x94";    // —

bool ends_with(const std::string &s, const std::string &suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool is_dash_token(const std::string &token) {
    if (token.empty()) return false;
    for (size_t i = 0; i < token.size();) {
        if (token[i] == '-') {
            ++i;
        } else if (token.compare(i, 3, kEnDash) == 0 || token.compare(i, 3, kEmDash) == 0) {
            i += 3;
        } else {
            return false;
        }
    }
    return true;
}

// Splits the trailing marks the model predicts or that end a sentence.
void strip_trailing_marks(std::string &core, std::string &end) {
    for (;;) {
        if (ends_with(core, kEllipsis)) {
            end.insert(0, kEllipsis);
            core.resize(core.size() - kEllipsis.size());
            continue;
        }
        if (core.empty()) return;
        const char c = core.back();
        if (c == '.' || c == ',' || c == '?' || c == ':' || c == ';' || c == '!') {
            end.insert(end.begin(), c);
            core.pop_back();
            continue;
        }
        return;
    }
}

bool has_sentence_end(const std::string &marks) {
    return marks.find_first_of(".!?") != std::string::npos || marks.find(kEllipsis) != std::string::npos;
}

bool has_cyrillic(const std::string &text) {
    for (size_t i = 0; i < text.size();) {
        const char32_t cp = next_code_point(text, i);
        if (cp >= 0x0400 && cp <= 0x04FF) return true;
    }
    return false;
}

char32_t upper(char32_t cp) {
    if (cp >= 'a' && cp <= 'z') return cp - 0x20;
    if (cp >= 0x00E0 && cp <= 0x00FE && cp != 0x00F7) return cp - 0x20;
    if (cp >= 0x03B1 && cp <= 0x03C9 && cp != 0x03C2) return cp - 0x20;
    if (cp >= 0x0430 && cp <= 0x044F) return cp - 0x20;
    if (cp >= 0x0450 && cp <= 0x045F) return cp - 0x50;
    return cp;
}

void append_utf8(std::string &out, char32_t cp) {
    if (cp < 0x80) {
        out += char(cp);
    } else if (cp < 0x800) {
        out += char(0xC0 | (cp >> 6));
        out += char(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += char(0xE0 | (cp >> 12));
        out += char(0x80 | ((cp >> 6) & 0x3F));
        out += char(0x80 | (cp & 0x3F));
    } else {
        out += char(0xF0 | (cp >> 18));
        out += char(0x80 | ((cp >> 12) & 0x3F));
        out += char(0x80 | ((cp >> 6) & 0x3F));
        out += char(0x80 | (cp & 0x3F));
    }
}

}  // namespace

std::string capitalize_first_letter(const std::string &word) {
    for (size_t i = 0; i < word.size();) {
        const size_t start = i;
        const char32_t cp = next_code_point(word, i);
        if (is_word_code_point(cp)) {
            const char32_t up = upper(cp);
            if (up == cp) return word;
            std::string out = word.substr(0, start);
            append_utf8(out, up);
            out += word.substr(i);
            return out;
        }
    }
    return word;
}

std::vector<PunctWord> split_punct_words(const std::string &text) {
    std::vector<PunctWord> words;
    size_t i = 0;
    while (i < text.size()) {
        while (i < text.size()) {
            size_t next = i;
            if (!is_space_code_point(next_code_point(text, next))) break;
            i = next;
        }
        size_t end = i;
        while (end < text.size()) {
            size_t next = end;
            if (is_space_code_point(next_code_point(text, next))) break;
            end = next;
        }
        if (end == i) break;
        std::string token = text.substr(i, end - i);
        i = end;

        if (is_dash_token(token)) {
            if (!words.empty() && words.back().dash.empty()) words.back().dash = token;
            continue;
        }
        PunctWord word;
        word.core = std::move(token);
        strip_trailing_marks(word.core, word.end);
        if (word.core.empty()) {
            // A detached mark ("слово ?") belongs to the word before it.
            if (!words.empty()) words.back().end += word.end;
            continue;
        }
        words.push_back(std::move(word));
    }
    return words;
}

std::string merge_punct_labels(const std::vector<PunctWord> &words, const std::vector<std::string> &labels) {
    std::string joined;
    for (const auto &w : words) joined += w.core + " ";
    const std::string new_dash = has_cyrillic(joined) ? kEmDash : "-";

    std::string out;
    bool capitalize_next = false;
    for (size_t i = 0; i < words.size(); ++i) {
        const PunctWord &w = words[i];
        const std::string &label = i < labels.size() ? labels[i] : std::string("0");
        std::string mark;
        std::string dash = w.dash;
        bool new_sentence_end = false;
        if (has_sentence_end(w.end)) {
            mark = (w.end == "." && label == "?") ? "?" : w.end;
            // The model agreeing that a sentence ends here rules out an
            // abbreviation ("т.е.", "и т.д.").
            new_sentence_end = label == "." || label == "?";
        } else if (w.end.find(';') != std::string::npos || !dash.empty()) {
            // A dash the input already has decides this boundary.
            mark = w.end;
        } else if (label == "." || label == "?") {
            mark = label;
            new_sentence_end = true;
        } else if (label == "," || label == ":") {
            mark = label;
        } else if (label == "-") {
            if (dash.empty()) dash = new_dash;
        }

        if (!out.empty()) out += ' ';
        out += capitalize_next ? capitalize_first_letter(w.core) : w.core;
        out += mark;
        if (!dash.empty()) out += " " + dash;
        capitalize_next = new_sentence_end;
    }
    return out;
}

}  // namespace sdasr

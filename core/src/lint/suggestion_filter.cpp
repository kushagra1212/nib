#include "lint/suggestion_filter.hpp"

#include <algorithm>
#include <numeric>
#include "text/unicode.hpp"

namespace nib::suggestion_filter {
namespace {

bool is_apostrophe(char32_t c) { return c == U'\'' || c == U'’'; }

// A Swift Character answers letter/case questions from its first scalar for
// every character nib meets in practice.
bool grapheme_is_letter(const std::u16string& g) { return is_letter(first_code_point(g)); }
bool grapheme_is_upper(const std::u16string& g) { return is_uppercase(first_code_point(g)); }

bool in_set(char32_t c, std::u16string_view set) {
    for (char32_t s : code_points(set)) {
        if (s == c) return true;
    }
    return false;
}

std::vector<std::u16string> letters_of(const std::u16string& s) {
    std::vector<std::u16string> out;
    for (auto& g : graphemes(s)) {
        if (grapheme_is_letter(g)) out.push_back(std::move(g));
    }
    return out;
}

bool lacks_vowel(const std::vector<std::u16string>& letters) {
    if (letters.size() < 2) return false;
    for (const auto& g : letters) {
        for (char32_t c : code_points(lowercased(g))) {
            if (in_set(c, u"aeiouy")) return false;
        }
    }
    return true;
}

// A capital letter after the first character marks camelCase and PascalCase
// but not an ordinary capitalised word.
bool has_medial_capital(const std::u16string& token) {
    const auto chars = graphemes(token);
    if (chars.size() <= 1) return false;
    return std::any_of(chars.begin() + 1, chars.end(), grapheme_is_upper);
}

bool starts_sentence(int32_t location, const std::u16string& text) {
    for (int32_t index = location - 1; index >= 0; --index) {
        const char16_t unit = text[static_cast<size_t>(index)];
        // Swift made a Character out of one UTF-16 unit; a lone surrogate
        // becomes U+FFFD, which is neither space nor punctuation.
        const char32_t c = (unit >= 0xD800 && unit <= 0xDFFF) ? 0xFFFD : unit;
        // A line break ends a sentence as surely as a full stop does, and in
        // chat it is the usual way people end one.
        if (is_newline(c)) return true;
        if (is_whitespace(c)) continue;
        return c == U'.' || c == U'!' || c == U'?';
    }
    return true;
}

int32_t word_count(const std::u16string& s) {
    return static_cast<int32_t>(split_whitespace(s).size());
}

std::u16string without_apostrophes(const std::u16string& s) {
    std::u16string out;
    for (char16_t u : s) {
        if (u != u'\'' && u != u'’') out.push_back(u);
    }
    return out;
}

std::u16string concat(const std::vector<std::u16string>& words) {
    std::u16string out;
    for (const auto& w : words) out += w;
    return out;
}

}  // namespace

std::vector<Suggestion> apply(const std::vector<Suggestion>& suggestions,
                              const std::u16string& text) {
    std::vector<Suggestion> out;
    for (const auto& s : suggestions) {
        if (auto refined = refine(s, text)) out.push_back(std::move(*refined));
    }
    return out;
}

bool keep(const Suggestion& suggestion, const std::u16string& text) {
    return refine(suggestion, text).has_value();
}

std::optional<Suggestion> refine(const Suggestion& suggestion, const std::u16string& text) {
    const auto token = suggestion.excerpt(text);
    if (!token) return std::nullopt;

    // These say the word is not a mistake, so the mark goes too.
    if (looks_like_code(*token)) return std::nullopt;
    if (is_surrounded_by_code(suggestion.range, text)) return std::nullopt;

    if (suggestion.replacements.empty()) return suggestion;
    const auto& first = suggestion.replacements.front();

    // Both guards below ask "did the writer mean this word", which only makes
    // sense for a word harper does not know. Its grammar rules fire on words
    // that are in the dictionary -- their/there, its/it's -- and those must
    // still be corrected wherever they appear.
    if (is_spelling_check(suggestion.message)) {
        if (is_proper_noun(suggestion.range, text)) return std::nullopt;
        if (repeats_deliberately(*token, text, first)) return std::nullopt;
    }

    // Every replacement, not just the first: "optioaa -> optical | optimal".
    std::vector<std::u16string> plausible;
    for (const auto& r : suggestion.replacements) {
        if (is_plausible_correction(*token, r)) plausible.push_back(r);
    }
    auto usable = rank(plausible, *token);
    // Nothing worth offering. A spelling lint still marks the word -- harper
    // does not know it, so something is wrong with it. Any other rule fired on
    // dictionary words and has simply misfired: "bugs" is not misspelled.
    if (usable.empty() && !is_spelling_check(suggestion.message)) return std::nullopt;

    Suggestion out = suggestion;
    out.replacements = std::move(usable);
    return out;
}

bool is_spelling_check(const std::u16string& message) {
    return contains(lowercased(message), u"spell");
}

bool is_proper_noun(nib_range range, const std::u16string& text) {
    const int32_t n = static_cast<int32_t>(text.size());
    if (range.location < 0 || range.length <= 0 || range_end(range) > n) return false;
    const auto word = text.substr(static_cast<size_t>(range.location),
                                  static_cast<size_t>(range.length));
    const auto chars = graphemes(word);
    if (chars.empty() || !grapheme_is_upper(chars.front())) return false;
    // A capital only means a name away from the start of a sentence.
    return !starts_sentence(range.location, text);
}

bool repeats_deliberately(const std::u16string& token, const std::u16string& text,
                          const std::u16string& replacement) {
    const auto word = trimmed(token);
    // Below four letters the odds of an unrelated collision are too high, and
    // short words are where genuine repeated typos live.
    if (grapheme_count(word) < 4) return false;
    for (char32_t c : code_points(word)) {
        if (is_whitespace(c)) return false;
    }
    // Transpositions repeat too -- `teh` twice is still `the`.
    if (is_transposition(word, replacement)) return false;
    return occurrences(word, text) >= 2;
}

int32_t occurrences(const std::u16string& word, const std::u16string& text) {
    const auto target = lowercased(word);
    int32_t count = 0;
    std::u16string current;
    auto flush = [&] {
        if (!current.empty() && lowercased(current) == target) ++count;
        current.clear();
    };
    for (const auto& g : graphemes(text)) {
        const char32_t c = first_code_point(g);
        if (is_letter(c) || is_apostrophe(c)) {
            current += g;
        } else {
            flush();
        }
    }
    flush();
    return count;
}

bool is_transposition(const std::u16string& a, const std::u16string& b) {
    const auto left = graphemes(lowercased(a));
    const auto right = graphemes(lowercased(b));
    if (left.size() != right.size() || left.size() < 2) return false;

    std::vector<size_t> differing;
    for (size_t i = 0; i < left.size(); ++i) {
        if (left[i] != right[i]) differing.push_back(i);
    }
    if (differing.size() != 2) return false;
    const size_t i = differing[0], j = differing[1];
    if (j != i + 1) return false;
    return left[i] == right[j] && left[j] == right[i];
}

bool looks_like_code(const std::u16string& token) {
    const auto t = trimmed(token);
    if (t.empty()) return true;

    // Digits never appear in ordinary words: UTF-16, RN86, h264.
    for (char32_t c : code_points(t)) {
        if (is_decimal_digit(c)) return true;
    }

    // Identifier punctuation: snake_case, kebab-case, NSString.length, paths.
    static constexpr std::u16string_view identifier = u"_./\\(){}[]<>:@#$%^&*+=|~";
    for (const auto& g : graphemes(t)) {
        if (g.size() == 1 && identifier.find(g[0]) != std::u16string_view::npos) return true;
    }

    const auto letters = letters_of(t);
    if (letters.empty()) return true;

    // An acronym: two or more letters, all capitals. UTF, ZWJ, API.
    if (letters.size() >= 2 && std::all_of(letters.begin(), letters.end(), grapheme_is_upper)) {
        return true;
    }
    // Medial capitals: NSString, TextEdit, didApply, iOS.
    if (has_medial_capital(t)) return true;
    // No vowel: gpt, npm, ssh, jwt. This is what catches lowercase product
    // names, which edit distance cannot -- "gpt" to "get" is one substitution.
    if (lacks_vowel(letters)) return true;
    return false;
}

bool is_surrounded_by_code(nib_range range, const std::u16string& text) {
    const int32_t n = static_cast<int32_t>(text.size());
    if (range.location < 0 || range_end(range) > n) return false;

    static constexpr std::u16string_view adjacent = u"._/\\@#$(){}[]<>";
    if (range.location > 0
        && adjacent.find(text[static_cast<size_t>(range.location - 1)]) != std::u16string_view::npos) {
        return true;
    }
    if (range_end(range) < n
        && adjacent.find(text[static_cast<size_t>(range_end(range))]) != std::u16string_view::npos) {
        return true;
    }
    return is_inside_backticks(range, text);
}

bool is_inside_backticks(nib_range range, const std::u16string& text) {
    const int32_t n = static_cast<int32_t>(text.size());
    if (range.location < 0 || range.location > n) return false;
    // An odd number of backticks before the token opened a span not yet closed.
    const auto count = std::count(text.begin(), text.begin() + range.location, u'`');
    return count % 2 == 1;
}

std::vector<std::u16string> rank(const std::vector<std::u16string>& replacements,
                                 const std::u16string& original) {
    const int32_t original_words = word_count(original);
    std::vector<size_t> order(replacements.size());
    std::iota(order.begin(), order.end(), size_t{0});
    // Same shape as what was typed first; stable, so harper's own ordering
    // still decides between equals.
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        const int sa = word_count(replacements[a]) == original_words ? 0 : 1;
        const int sb = word_count(replacements[b]) == original_words ? 0 : 1;
        return sa < sb;
    });
    std::vector<std::u16string> out;
    out.reserve(order.size());
    for (size_t i : order) out.push_back(replacements[i]);
    return out;
}

bool is_plausible_correction(const std::u16string& original, const std::u16string& replacement) {
    if (original == replacement) return false;

    const auto a = lowercased(original);
    const auto b = lowercased(replacement);
    // A change of capitals and nothing else is a real correction: "chatgpt" to
    // "ChatGPT", "i" to "I".
    if (a == b) return true;

    if (adds_words(a, b)) return false;
    if (invents_possessive(a, b)) return false;

    // A phrase is judged by words, not letters. "could of" to "could have" is
    // four character edits but one word replaced.
    const auto before = split_whitespace(a);
    const auto after = split_whitespace(b);
    if (before.size() > 1 || after.size() > 1) {
        // Splitting or joining a word keeps the letters: "cannotbe" to
        // "cannot be". Compare with the spaces taken out.
        if (before.size() != after.size()) {
            return edit_distance(concat(before), concat(after)) <= 2;
        }
        int32_t changed = 0;
        for (size_t i = 0; i < before.size(); ++i) {
            if (before[i] != after[i]) ++changed;
        }
        return changed == 1;
    }
    // Two edits, flat, rather than a proportion of the word. Measured: the
    // kept and refused groups do not overlap and do not scale with length.
    return edit_distance(a, b) <= 2;
}

bool adds_words(const std::u16string& original, const std::u16string& replacement) {
    return word_count(replacement) > word_count(original) + 1;
}

bool invents_possessive(const std::u16string& original, const std::u16string& replacement) {
    auto has = [](const std::u16string& s) {
        return s.find(u'\'') != std::u16string::npos || s.find(u'’') != std::u16string::npos;
    };
    if (has(original) || !has(replacement)) return false;
    return without_apostrophes(original) != without_apostrophes(replacement);
}

int32_t edit_distance(const std::u16string& a, const std::u16string& b) {
    const auto source = graphemes(a);
    const auto target = graphemes(b);
    if (source.empty()) return static_cast<int32_t>(target.size());
    if (target.empty()) return static_cast<int32_t>(source.size());

    std::vector<int32_t> previous(target.size() + 1), current(target.size() + 1);
    std::iota(previous.begin(), previous.end(), 0);
    for (size_t i = 1; i <= source.size(); ++i) {
        current[0] = static_cast<int32_t>(i);
        for (size_t j = 1; j <= target.size(); ++j) {
            const int32_t substitution = previous[j - 1] + (source[i - 1] == target[j - 1] ? 0 : 1);
            current[j] = std::min({previous[j] + 1, current[j - 1] + 1, substitution});
        }
        std::swap(previous, current);
    }
    return previous[target.size()];
}

}  // namespace nib::suggestion_filter

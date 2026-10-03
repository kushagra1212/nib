#include "lint/word_diff.hpp"

#include <algorithm>
#include "text/unicode.hpp"

namespace nib::word_diff {
namespace {

u16view view_of(const std::u16string& s) {
    return u16view(reinterpret_cast<const uint16_t*>(s.data()),
                   static_cast<int32_t>(s.size()));
}

// Letters and numbers only -- narrower than the tokenizer's word characters,
// because this decides how far an underline grows, not what a word is. A lone
// surrogate is not a scalar, so it is never a word character.
bool is_word_character(char16_t unit) {
    if (unit >= 0xD800 && unit <= 0xDFFF) return false;
    return is_letter(unit) || is_number(unit);
}

std::vector<std::u16string> texts(const std::vector<Token>& tokens) {
    std::vector<std::u16string> out;
    out.reserve(tokens.size());
    for (const auto& t : tokens) out.push_back(t.text);
    return out;
}

std::u16string join(const std::vector<std::u16string>& words) {
    std::u16string out;
    for (size_t i = 0; i < words.size(); ++i) {
        if (i) out.push_back(u' ');
        out += words[i];
    }
    return out;
}

std::optional<TextEdit> make_edit(const std::vector<Token>& deleted,
                                  const std::vector<std::u16string>& inserted,
                                  const std::u16string& original) {
    const std::u16string replacement = join(inserted);
    // Pure insertion: nothing to anchor an underline to, and a zero-width mark
    // cannot be hovered, so these are dropped rather than shown unusably.
    if (deleted.empty()) return std::nullopt;

    const nib_range range{deleted.front().range.location,
                          range_end(deleted.back().range) - deleted.front().range.location};
    std::u16string expected = original.substr(static_cast<size_t>(range.location),
                                              static_cast<size_t>(range.length));
    if (expected == replacement) return std::nullopt;
    return TextEdit{range, replacement, std::move(expected)};
}

bool same_tokens(const std::vector<Token>& a, const std::vector<Token>& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (a[i].text != b[i].text || !(a[i].range == b[i].range)) return false;
    }
    return true;
}

}  // namespace

std::vector<Token> tokenize(const std::u16string& text) {
    return nib::tokenize(view_of(text));
}

std::vector<TextEdit> edits(const std::u16string& original,
                            const std::u16string& corrected) {
    const auto source = tokenize(original);
    const auto target = tokenize(corrected);
    const auto source_words = texts(source);
    const auto target_words = texts(target);

    // Same words, different text: the change is punctuation or spacing, which
    // word tokens cannot see. Fall back to a character-level span.
    if (source_words == target_words) {
        if (original == corrected) return {};
        auto edit = character_edit(original, corrected);
        return edit ? std::vector<TextEdit>{*edit} : std::vector<TextEdit>{};
    }
    if (same_tokens(source, target)) return {};

    const auto common = longest_common_subsequence(source_words, target_words);
    std::vector<TextEdit> out;
    size_t i = 0, j = 0;

    for (size_t k = 0; k <= common.size(); ++k) {
        const std::u16string* anchor = k < common.size() ? &common[k] : nullptr;
        std::vector<Token> deleted;
        std::vector<std::u16string> inserted;

        while (i < source.size() && (!anchor || source[i].text != *anchor)) {
            deleted.push_back(source[i]);
            ++i;
        }
        while (j < target.size() && (!anchor || target[j].text != *anchor)) {
            inserted.push_back(target[j].text);
            ++j;
        }
        if (anchor) { ++i; ++j; }

        if (deleted.empty() && inserted.empty()) continue;
        if (auto edit = make_edit(deleted, inserted, original)) out.push_back(*edit);
    }
    return out;
}

std::optional<TextEdit> character_edit(const std::u16string& a, const std::u16string& b) {
    const int32_t alen = static_cast<int32_t>(a.size());
    const int32_t blen = static_cast<int32_t>(b.size());

    int32_t prefix = 0;
    while (prefix < alen && prefix < blen && a[static_cast<size_t>(prefix)] == b[static_cast<size_t>(prefix)]) {
        ++prefix;
    }
    int32_t suffix = 0;
    while (suffix < alen - prefix && suffix < blen - prefix
           && a[static_cast<size_t>(alen - 1 - suffix)] == b[static_cast<size_t>(blen - 1 - suffix)]) {
        ++suffix;
    }

    // Grow outwards to word boundaries so the mark covers a word.
    int32_t start = prefix;
    while (start > 0 && is_word_character(a[static_cast<size_t>(start - 1)])) --start;
    int32_t end = alen - suffix;
    while (end < alen && is_word_character(a[static_cast<size_t>(end)])) ++end;
    if (end <= start) return std::nullopt;

    const nib_range range{start, end - start};
    const int32_t replacement_length = blen - suffix - start;
    if (replacement_length < 0 || start + replacement_length > blen) return std::nullopt;
    std::u16string replacement = b.substr(static_cast<size_t>(start),
                                          static_cast<size_t>(replacement_length));
    // Re-attach the trailing word characters that were grown into.
    const int32_t grown = end - (alen - suffix);
    if (grown > 0) {
        replacement += a.substr(static_cast<size_t>(alen - suffix), static_cast<size_t>(grown));
    }

    std::u16string expected = a.substr(static_cast<size_t>(range.location),
                                       static_cast<size_t>(range.length));
    if (expected == replacement) return std::nullopt;
    return TextEdit{range, std::move(replacement), std::move(expected)};
}

std::vector<Suggestion> suggestions(const std::u16string& original,
                                    const std::u16string& corrected,
                                    const std::u16string& message,
                                    SuggestionSource source) {
    std::vector<Suggestion> out;
    for (auto& edit : edits(original, corrected)) {
        Suggestion s;
        s.source = source;
        s.range = edit.range;
        s.message = message;
        s.replacements = {std::move(edit.replacement)};
        out.push_back(std::move(s));
    }
    return out;
}

std::vector<std::u16string> longest_common_subsequence(
    const std::vector<std::u16string>& a, const std::vector<std::u16string>& b) {
    if (a.empty() || b.empty()) return {};
    const size_t n = a.size(), m = b.size();
    // One flat table: a vector of vectors costs an allocation per row, and
    // this runs on every rewrite.
    std::vector<int32_t> table((n + 1) * (m + 1), 0);
    auto at = [&](size_t i, size_t j) -> int32_t& { return table[i * (m + 1) + j]; };

    for (size_t i = 1; i <= n; ++i) {
        for (size_t j = 1; j <= m; ++j) {
            at(i, j) = a[i - 1] == b[j - 1] ? at(i - 1, j - 1) + 1
                                            : std::max(at(i - 1, j), at(i, j - 1));
        }
    }

    std::vector<std::u16string> result;
    size_t i = n, j = m;
    while (i > 0 && j > 0) {
        if (a[i - 1] == b[j - 1]) {
            result.push_back(a[i - 1]);
            --i; --j;
        } else if (at(i - 1, j) >= at(i, j - 1)) {
            --i;
        } else {
            --j;
        }
    }
    std::reverse(result.begin(), result.end());
    return result;
}

}  // namespace nib::word_diff

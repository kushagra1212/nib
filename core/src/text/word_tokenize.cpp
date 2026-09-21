#include "text/word_tokenize.hpp"
#include <unicode/uchar.h>

namespace nib {
namespace {

// Mirrors the Swift exactly, including its limits.
//
// The Swift builds a UnicodeScalar from one UTF-16 code unit, which returns
// nil for a lone surrogate -- so a surrogate is a separator and an emoji
// contributes no tokens at all. Reproduced deliberately: the goldens record
// it, and changing it here would move behaviour that macOS ships today.
bool is_word_character(uint16_t unit) {
    if (is_high_surrogate(unit) || is_low_surrogate(unit)) return false;

    const UChar32 c = static_cast<UChar32>(unit);

    // CharacterSet.nonBaseCharacters -- combining marks belong to the letter
    // they attach to. Indic viramas and vowel signs sit mid-word, and treating
    // them as separators gives every piece its own underline.
    if (u_hasBinaryProperty(c, UCHAR_GRAPHEME_EXTEND)) return true;
    const int8_t category = static_cast<int8_t>(u_charType(c));
    if (category == U_NON_SPACING_MARK || category == U_COMBINING_SPACING_MARK
        || category == U_ENCLOSING_MARK) {
        return true;
    }

    if (u_isalpha(c) || u_isdigit(c)) return true;

    return c == u'\'' || c == u'’' || c == u'-' || c == u'_';
}

}  // namespace

std::vector<Token> tokenize(u16view text) {
    std::vector<Token> tokens;
    int32_t start = -1;
    int32_t index = 0;

    auto push = [&](int32_t from, int32_t to) {
        nib_range r{from, to - from};
        tokens.push_back(Token{text.slice(r.location, r.length).to_string(), r});
    };

    while (index < text.size) {
        if (is_word_character(text[index])) {
            if (start < 0) start = index;
        } else if (start >= 0) {
            push(start, index);
            start = -1;
        }
        ++index;
    }
    if (start >= 0) push(start, text.size);

    return tokens;
}

}  // namespace nib

#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>
#include <unicode/umachine.h>

// Swift's Character and String helpers, answered by ICU.
//
// Swift asks these questions of a Character, which is a grapheme cluster; ICU
// asks them of a code point. For a cluster the Swift answer comes from its
// first scalar for the letter/case properties nib uses, so these take the
// first code point of whatever they are given. Where nib counts or compares
// characters -- edit distance, String.count -- the grapheme functions below
// do the cluster split explicitly, because counting code points instead would
// make "é" written with a combining accent two characters long.

namespace nib {

// Code point properties, matching Character.isLetter / isUppercase / etc.
bool is_letter(char32_t c);
bool is_number(char32_t c);
bool is_decimal_digit(char32_t c);
bool is_uppercase(char32_t c);
bool is_whitespace(char32_t c);       // Character.isWhitespace (includes newlines)
bool is_newline(char32_t c);          // Character.isNewline

// First code point of a UTF-16 string, or 0 when empty.
char32_t first_code_point(std::u16string_view s);

// Every code point, in order. Lone surrogates come back as themselves.
std::vector<char32_t> code_points(std::u16string_view s);

// Grapheme clusters, which is what Swift's Character is.
std::vector<std::u16string> graphemes(std::u16string_view s);
// String.count.
int32_t grapheme_count(std::u16string_view s);

// String.lowercased(): locale-independent full case mapping.
std::u16string lowercased(std::u16string_view s);

// trimmingCharacters(in: .whitespacesAndNewlines)
std::u16string trimmed(std::u16string_view s);

// split(whereSeparator: \.isWhitespace), omitting empty pieces.
std::vector<std::u16string> split_whitespace(std::u16string_view s);

bool contains(std::u16string_view haystack, std::u16string_view needle);
bool starts_with(std::u16string_view s, std::u16string_view prefix);
bool ends_with(std::u16string_view s, std::u16string_view suffix);

std::u16string utf8_to_utf16(std::string_view s);
std::string    utf16_to_utf8(std::u16string_view s);

// The bare minimum for writing a number into UTF-16 text.
std::u16string to_u16(int64_t value);

}  // namespace nib

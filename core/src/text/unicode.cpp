#include "text/unicode.hpp"

#include <memory>
#include <unicode/brkiter.h>
#include <unicode/uchar.h>
#include <unicode/unistr.h>
#include <unicode/ustring.h>
#include <unicode/utf16.h>

namespace nib {

bool is_letter(char32_t c) { return u_isalpha(static_cast<UChar32>(c)); }

// Character.isNumber is the Unicode Numeric_Type property being anything
// other than None, which covers fractions and Roman numerals as well as
// digits. u_isdigit would be the narrower Nd.
bool is_number(char32_t c) {
    return u_getIntPropertyValue(static_cast<UChar32>(c), UCHAR_NUMERIC_TYPE)
           != U_NT_NONE;
}

bool is_decimal_digit(char32_t c) { return u_isdigit(static_cast<UChar32>(c)); }

// Character.isUppercase is the Uppercase property, which includes letters
// like U+2160 that u_isupper (category Lu) leaves out.
bool is_uppercase(char32_t c) { return u_isUUppercase(static_cast<UChar32>(c)); }

bool is_whitespace(char32_t c) {
    return u_hasBinaryProperty(static_cast<UChar32>(c), UCHAR_WHITE_SPACE);
}

bool is_newline(char32_t c) {
    switch (c) {
    case 0x0A: case 0x0B: case 0x0C: case 0x0D:
    case 0x85: case 0x2028: case 0x2029:
        return true;
    default:
        return false;
    }
}

char32_t first_code_point(std::u16string_view s) {
    if (s.empty()) return 0;
    UChar32 c;
    int32_t i = 0;
    U16_NEXT(reinterpret_cast<const UChar*>(s.data()), i,
             static_cast<int32_t>(s.size()), c);
    return static_cast<char32_t>(c);
}

std::vector<char32_t> code_points(std::u16string_view s) {
    std::vector<char32_t> out;
    out.reserve(s.size());
    const auto* p = reinterpret_cast<const UChar*>(s.data());
    const int32_t n = static_cast<int32_t>(s.size());
    for (int32_t i = 0; i < n;) {
        UChar32 c;
        U16_NEXT(p, i, n, c);
        out.push_back(static_cast<char32_t>(c));
    }
    return out;
}

namespace {

// One iterator per thread. Creating a BreakIterator loads rule data and costs
// far more than the split itself, and these are called per word.
icu::BreakIterator* character_iterator() {
    thread_local std::unique_ptr<icu::BreakIterator> it = [] {
        UErrorCode status = U_ZERO_ERROR;
        std::unique_ptr<icu::BreakIterator> made(
            icu::BreakIterator::createCharacterInstance(icu::Locale::getRoot(), status));
        if (U_FAILURE(status)) made.reset();
        return made;
    }();
    return it.get();
}

}  // namespace

std::vector<std::u16string> graphemes(std::u16string_view s) {
    std::vector<std::u16string> out;
    if (s.empty()) return out;
    auto* it = character_iterator();
    if (!it) {
        for (char16_t u : s) out.emplace_back(1, u);
        return out;
    }
    icu::UnicodeString text(false, reinterpret_cast<const UChar*>(s.data()),
                            static_cast<int32_t>(s.size()));
    it->setText(text);
    int32_t start = it->first();
    for (int32_t end = it->next(); end != icu::BreakIterator::DONE;
         start = end, end = it->next()) {
        out.emplace_back(s.substr(static_cast<size_t>(start),
                                  static_cast<size_t>(end - start)));
    }
    return out;
}

int32_t grapheme_count(std::u16string_view s) {
    if (s.empty()) return 0;
    auto* it = character_iterator();
    if (!it) return static_cast<int32_t>(s.size());
    icu::UnicodeString text(false, reinterpret_cast<const UChar*>(s.data()),
                            static_cast<int32_t>(s.size()));
    it->setText(text);
    int32_t count = 0;
    it->first();
    while (it->next() != icu::BreakIterator::DONE) ++count;
    return count;
}

std::u16string lowercased(std::u16string_view s) {
    if (s.empty()) return {};
    std::u16string out(s.size() + 8, u'\0');
    UErrorCode status = U_ZERO_ERROR;
    int32_t n = u_strToLower(reinterpret_cast<UChar*>(out.data()),
                             static_cast<int32_t>(out.size()),
                             reinterpret_cast<const UChar*>(s.data()),
                             static_cast<int32_t>(s.size()), "", &status);
    if (status == U_BUFFER_OVERFLOW_ERROR) {
        out.assign(static_cast<size_t>(n), u'\0');
        status = U_ZERO_ERROR;
        n = u_strToLower(reinterpret_cast<UChar*>(out.data()), n,
                         reinterpret_cast<const UChar*>(s.data()),
                         static_cast<int32_t>(s.size()), "", &status);
    }
    if (U_FAILURE(status)) return std::u16string(s);
    out.resize(static_cast<size_t>(n));
    return out;
}

std::u16string trimmed(std::u16string_view s) {
    const auto* p = reinterpret_cast<const UChar*>(s.data());
    const int32_t n = static_cast<int32_t>(s.size());
    int32_t start = 0;
    while (start < n) {
        int32_t next = start;
        UChar32 c;
        U16_NEXT(p, next, n, c);
        if (!is_whitespace(static_cast<char32_t>(c))) break;
        start = next;
    }
    int32_t end = n;
    while (end > start) {
        int32_t prev = end;
        UChar32 c;
        U16_PREV(p, 0, prev, c);
        if (!is_whitespace(static_cast<char32_t>(c))) break;
        end = prev;
    }
    return std::u16string(s.substr(static_cast<size_t>(start),
                                   static_cast<size_t>(end - start)));
}

std::vector<std::u16string> split_whitespace(std::u16string_view s) {
    std::vector<std::u16string> out;
    const auto* p = reinterpret_cast<const UChar*>(s.data());
    const int32_t n = static_cast<int32_t>(s.size());
    int32_t start = -1;
    for (int32_t i = 0; i < n;) {
        const int32_t at = i;
        UChar32 c;
        U16_NEXT(p, i, n, c);
        if (is_whitespace(static_cast<char32_t>(c))) {
            if (start >= 0) {
                out.emplace_back(s.substr(static_cast<size_t>(start),
                                          static_cast<size_t>(at - start)));
                start = -1;
            }
        } else if (start < 0) {
            start = at;
        }
    }
    if (start >= 0) out.emplace_back(s.substr(static_cast<size_t>(start)));
    return out;
}

bool contains(std::u16string_view haystack, std::u16string_view needle) {
    return haystack.find(needle) != std::u16string_view::npos;
}

bool starts_with(std::u16string_view s, std::u16string_view prefix) {
    return s.size() >= prefix.size() && s.substr(0, prefix.size()) == prefix;
}

bool ends_with(std::u16string_view s, std::u16string_view suffix) {
    return s.size() >= suffix.size()
           && s.substr(s.size() - suffix.size()) == suffix;
}

std::u16string utf8_to_utf16(std::string_view s) {
    std::u16string out;
    out.reserve(s.size());
    const auto* p = reinterpret_cast<const uint8_t*>(s.data());
    const int32_t n = static_cast<int32_t>(s.size());
    for (int32_t i = 0; i < n;) {
        UChar32 c;
        U8_NEXT(p, i, n, c);
        if (c < 0) c = 0xFFFD;
        if (c <= 0xFFFF) {
            out.push_back(static_cast<char16_t>(c));
        } else {
            out.push_back(static_cast<char16_t>(U16_LEAD(c)));
            out.push_back(static_cast<char16_t>(U16_TRAIL(c)));
        }
    }
    return out;
}

std::string utf16_to_utf8(std::u16string_view s) {
    std::string out;
    out.reserve(s.size());
    const auto* p = reinterpret_cast<const UChar*>(s.data());
    const int32_t n = static_cast<int32_t>(s.size());
    for (int32_t i = 0; i < n;) {
        UChar32 c;
        U16_NEXT(p, i, n, c);
        // A lone surrogate cannot be written as UTF-8.
        if (U_IS_SURROGATE(c)) c = 0xFFFD;
        uint8_t buf[4];
        int32_t len = 0;
        UBool error = false;
        U8_APPEND(buf, len, 4, c, error);
        out.append(reinterpret_cast<const char*>(buf), static_cast<size_t>(len));
    }
    return out;
}

std::u16string to_u16(int64_t value) {
    const std::string ascii = std::to_string(value);
    return std::u16string(ascii.begin(), ascii.end());
}

}  // namespace nib

#include "golden_loader.hpp"
#include <unicode/unistr.h>

std::u16string utf8_to_utf16(const std::string& in) {
    icu::UnicodeString u = icu::UnicodeString::fromUTF8(in);
    return std::u16string(reinterpret_cast<const char16_t*>(u.getBuffer()),
                          static_cast<size_t>(u.length()));
}

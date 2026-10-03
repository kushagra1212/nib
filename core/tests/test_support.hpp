#pragma once
// Shared by the suites ported from macos/Tests/nibTests. Each ported case
// keeps its Swift name so a failure here can be read against the original.
#include <catch2/catch_test_macros.hpp>
#include <ostream>
#include <string>
#include "lint/suggestion.hpp"
#include "text/unicode.hpp"

inline nib_range R(int32_t location, int32_t length) { return nib_range{location, length}; }

namespace Catch {
template <> struct StringMaker<std::u16string> {
    static std::string convert(const std::u16string& s) { return '"' + nib::utf16_to_utf8(s) + '"'; }
};
template <> struct StringMaker<nib_range> {
    static std::string convert(nib_range r) {
        return "{" + std::to_string(r.location) + ", " + std::to_string(r.length) + "}";
    }
};
}  // namespace Catch

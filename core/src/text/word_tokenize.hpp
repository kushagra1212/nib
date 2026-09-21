#pragma once
#include <string>
#include <vector>
#include "nib/nib_core.h"
#include "text/utf16.hpp"

namespace nib {

struct Token {
    std::u16string text;
    nib_range      range;
};

// Port of WordDiff.tokenize. Separators are skipped for matching, but their
// offsets survive in the ranges, so an edit spanning several words covers the
// spaces between them too.
std::vector<Token> tokenize(u16view text);

}  // namespace nib

#pragma once
#include <string>
#include <vector>
#include "nib/nib_core.h"
#include "text/utf16.hpp"

namespace nib {

struct Sentence {
    std::u16string text;
    nib_range      range;  // UTF-16 offsets into the source
};

// Port of SentenceSplitter.sentences. Fragments shorter than minimum_words are
// dropped -- the model has nothing useful to say about "Thanks!", and a mark
// under it is noise.
//
// The locale is a parameter rather than a constant because the Swift asks for
// enumerateSubstrings(.localized), which segments using the user's locale. Two
// people running nib on the same paragraph can legitimately get different
// sentences. Passing null takes ICU's default, which is right for a probe and
// wrong for the app -- the platform layer knows the user's locale and should
// say so.
std::vector<Sentence> sentences(u16view text,
                                int32_t minimum_words = 5,
                                const char* locale = nullptr);

}  // namespace nib

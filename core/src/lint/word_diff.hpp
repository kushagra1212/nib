#pragma once
#include <optional>
#include <string>
#include <vector>
#include "lint/edit_planner.hpp"
#include "lint/suggestion.hpp"
#include "text/word_tokenize.hpp"

namespace nib {

// Port of WordDiff: turns a rewritten sentence back into localized edits.
//
// A model returns a whole corrected sentence, and replacing the user's text
// wholesale is not what an underline does. Diffing the rewrite against the
// original recovers individual edits, each with a real range.
namespace word_diff {

std::vector<Token> tokenize(const std::u16string& text);

// Edits that turn `original` into `corrected`. Adjacent changes merge into one
// edit, so "could of" becoming "could have" is a single suggestion.
std::vector<TextEdit> edits(const std::u16string& original,
                            const std::u16string& corrected);

// One edit covering the span between the first and last differing character,
// widened to whole words, for when only punctuation moved.
std::optional<TextEdit> character_edit(const std::u16string& original,
                                       const std::u16string& corrected);

std::vector<Suggestion> suggestions(const std::u16string& original,
                                    const std::u16string& corrected,
                                    const std::u16string& message = u"Suggested rewrite",
                                    SuggestionSource source = SuggestionSource::model);

std::vector<std::u16string> longest_common_subsequence(
    const std::vector<std::u16string>& a, const std::vector<std::u16string>& b);

}  // namespace word_diff
}  // namespace nib

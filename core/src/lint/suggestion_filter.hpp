#pragma once
#include <optional>
#include <string>
#include <vector>
#include "lint/suggestion.hpp"

namespace nib {

// Port of SuggestionFilter: discards suggestions a dictionary matcher produces
// but a reader would never want.
//
// harper compares words against a word list. It has no idea that `NSString` is
// a type, `UTF` an acronym, or `gpt` a product, so it offers the nearest
// dictionary neighbour: UTF -> Uhf, NSString -> Nesting, gpt -> get. One guard
// reads the flagged token (code is not prose); the other reads the proposed
// replacement (a correction is a near neighbour of what was typed).
namespace suggestion_filter {

std::vector<Suggestion> apply(const std::vector<Suggestion>& suggestions,
                              const std::u16string& text);
bool keep(const Suggestion& suggestion, const std::u16string& text);

// Judges the flagged word and its replacements separately. A word with no
// usable fix keeps its mark and offers nothing.
std::optional<Suggestion> refine(const Suggestion& suggestion, const std::u16string& text);

bool is_spelling_check(const std::u16string& message);
bool is_proper_noun(nib_range range, const std::u16string& text);
bool repeats_deliberately(const std::u16string& token, const std::u16string& text,
                          const std::u16string& replacement);
int32_t occurrences(const std::u16string& word, const std::u16string& text);
bool is_transposition(const std::u16string& a, const std::u16string& b);
bool looks_like_code(const std::u16string& token);
bool is_surrounded_by_code(nib_range range, const std::u16string& text);
bool is_inside_backticks(nib_range range, const std::u16string& text);
std::vector<std::u16string> rank(const std::vector<std::u16string>& replacements,
                                 const std::u16string& original);
bool is_plausible_correction(const std::u16string& original,
                             const std::u16string& replacement);
bool adds_words(const std::u16string& original, const std::u16string& replacement);
bool invents_possessive(const std::u16string& original, const std::u16string& replacement);
// Levenshtein distance over grapheme clusters, matching Swift's Character.
int32_t edit_distance(const std::u16string& a, const std::u16string& b);

}  // namespace suggestion_filter
}  // namespace nib

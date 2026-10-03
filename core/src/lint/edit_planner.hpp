#pragma once
#include <optional>
#include <string>
#include <vector>
#include "lint/suggestion.hpp"

namespace nib {

// A single replacement: swap `range` for `replacement`.
//
// `expected` records what the range held when the edit was planned. Accepting
// a suggestion is not instantaneous -- the user can keep typing between the
// lint and the click -- so the edit carries what it assumed, and that is
// checked before anything is written.
struct TextEdit {
    nib_range      range{0, 0};
    std::u16string replacement;
    // Text the range is expected to contain. Empty means "do not check".
    std::u16string expected;

    // Change in UTF-16 length once applied. Negative when text shrinks.
    int32_t delta() const {
        return static_cast<int32_t>(replacement.size()) - range.length;
    }

    friend bool operator==(const TextEdit& a, const TextEdit& b) {
        return a.range == b.range && a.replacement == b.replacement
               && a.expected == b.expected;
    }
};

// Port of EditPlanner. Every offset is a UTF-16 offset: an emoji is one
// Character but two UTF-16 units, and conflating the two corrupts text.
namespace edit_planner {

// Applies an edit, or nullopt if it does not fit the text.
std::optional<std::u16string> apply(const TextEdit& edit, const std::u16string& text);

// Whether a range lies within the text. Rejects negative locations and lengths.
bool is_in_bounds(nib_range range, const std::u16string& text);

// In bounds, and the range holds what the edit expected.
bool is_valid(const TextEdit& edit, const std::u16string& text);

// Finds where the expected text moved to after edits elsewhere, searching
// outward from the original location so the nearest match wins.
std::optional<TextEdit> relocate(const TextEdit& edit, const std::u16string& text,
                                 int32_t window = 80);

// Moves the remaining suggestions to where they sit after `edit` lands:
// before it unchanged, overlapping it DROPPED, after it shifted by the delta.
std::vector<Suggestion> reanchor(const std::vector<Suggestion>& suggestions,
                                 const TextEdit& edit);

// Drops suggestions that no longer fit the text.
std::vector<Suggestion> prune_out_of_bounds(const std::vector<Suggestion>& suggestions,
                                            const std::u16string& text);

}  // namespace edit_planner
}  // namespace nib

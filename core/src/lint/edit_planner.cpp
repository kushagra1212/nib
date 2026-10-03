#include "lint/edit_planner.hpp"

#include <algorithm>
#include <cstdlib>

namespace nib::edit_planner {

bool is_in_bounds(nib_range range, const std::u16string& text) {
    if (range.location < 0 || range.length < 0) return false;
    const int32_t length = static_cast<int32_t>(text.size());
    if (range.location > length) return false;
    return range.location + range.length <= length;
}

std::optional<std::u16string> apply(const TextEdit& edit, const std::u16string& text) {
    if (!is_in_bounds(edit.range, text)) return std::nullopt;
    std::u16string out = text;
    out.replace(static_cast<size_t>(edit.range.location),
                static_cast<size_t>(edit.range.length), edit.replacement);
    return out;
}

bool is_valid(const TextEdit& edit, const std::u16string& text) {
    if (!is_in_bounds(edit.range, text)) return false;
    if (edit.expected.empty()) return true;
    return text.compare(static_cast<size_t>(edit.range.location),
                        static_cast<size_t>(edit.range.length), edit.expected) == 0;
}

std::optional<TextEdit> relocate(const TextEdit& edit, const std::u16string& text,
                                 int32_t window) {
    if (is_valid(edit, text)) return edit;
    if (edit.expected.empty()) return std::nullopt;

    const int32_t length = static_cast<int32_t>(text.size());
    const int32_t expected_length = static_cast<int32_t>(edit.expected.size());
    if (expected_length <= 0 || length < expected_length) return std::nullopt;

    const int32_t anchor = std::min(std::max(0, edit.range.location), length);
    const int32_t low = std::max(0, anchor - window);
    const int32_t high = std::min(length - expected_length, anchor + window);
    if (low > high) return std::nullopt;

    std::optional<int32_t> best;
    for (int32_t candidate = low; candidate <= high; ++candidate) {
        if (text.compare(static_cast<size_t>(candidate),
                         static_cast<size_t>(expected_length), edit.expected) != 0) {
            continue;
        }
        if (!best || std::abs(candidate - anchor) < std::abs(*best - anchor)) {
            best = candidate;
        }
    }
    if (!best) return std::nullopt;
    return TextEdit{{*best, expected_length}, edit.replacement, edit.expected};
}

std::vector<Suggestion> reanchor(const std::vector<Suggestion>& suggestions,
                                 const TextEdit& edit) {
    const int32_t edit_start = edit.range.location;
    const int32_t edit_end = range_end(edit.range);
    const int32_t delta = edit.delta();

    std::vector<Suggestion> out;
    out.reserve(suggestions.size());
    for (const auto& suggestion : suggestions) {
        const int32_t start = suggestion.range.location;
        const int32_t end = range_end(suggestion.range);

        if (end <= edit_start) {
            out.push_back(suggestion);
        } else if (start >= edit_end) {
            const int32_t moved = start + delta;
            if (moved < 0) continue;
            Suggestion shifted = suggestion;
            shifted.range.location = moved;
            out.push_back(std::move(shifted));
        }
        // Otherwise it overlaps the edited span, including a zero-length range
        // sitting inside it. The description no longer matches the text.
    }
    return out;
}

std::vector<Suggestion> prune_out_of_bounds(const std::vector<Suggestion>& suggestions,
                                            const std::u16string& text) {
    std::vector<Suggestion> out;
    for (const auto& s : suggestions) {
        if (is_in_bounds(s.range, text)) out.push_back(s);
    }
    return out;
}

}  // namespace nib::edit_planner

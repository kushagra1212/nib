#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
#include <nlohmann/json_fwd.hpp>
#include "nib/nib_core.h"

// nib_range is the C ABI's struct, declared outside any namespace, so its
// operators live there too or argument lookup cannot find them.
inline bool operator==(nib_range a, nib_range b) {
    return a.location == b.location && a.length == b.length;
}
inline bool operator!=(nib_range a, nib_range b) { return !(a == b); }

namespace nib {

// Port of Suggestion.swift.
//
// Kept apart because they warrant different confidence. A misspelling is
// wrong; a wordy sentence is a matter of taste, and marking both the same way
// would make the advice feel like an error report.
enum class SuggestionKind { correction, clarity };

// What produced a suggestion. harper matched a word against a dictionary; the
// model wrote a sentence and nib diffed it. A reader deciding whether to
// accept a change is entitled to know which of those they are looking at.
enum class SuggestionSource { harper, model };

struct Suggestion {
    // Identity across reanchoring. Swift used a UUID; a process-wide counter
    // gives the same guarantee without a random source.
    uint64_t         id = next_id();
    SuggestionKind   kind = SuggestionKind::correction;
    SuggestionSource source = SuggestionSource::harper;
    // Range within the linted text, in UTF-16 offsets.
    nib_range        range{0, 0};
    // harper's description, e.g. "Did you mean `there`?".
    std::u16string   message;
    // Replacement texts, best first. Empty until replacements are fetched,
    // and for advisory-only lints.
    std::vector<std::u16string> replacements;

    static uint64_t next_id();

    // The substring this suggestion covers, or nullopt if the range no longer
    // fits the text.
    std::optional<std::u16string> excerpt(const std::u16string& text) const;

    // Matches Swift: identity and kind do not take part.
    friend bool operator==(const Suggestion& a, const Suggestion& b) {
        return a.range.location == b.range.location
               && a.range.length == b.range.length
               && a.message == b.message && a.replacements == b.replacements;
    }
};

inline int32_t range_end(nib_range r) { return r.location + r.length; }

// Converts LSP line/character positions into UTF-16 offsets.
//
// LSP counts characters in UTF-16 code units, which matches NSRange, but
// addresses them as (line, character) pairs. Walks the text once to build a
// line-start index so lookups are cheap.
class PositionMapper {
public:
    explicit PositionMapper(const std::u16string& text);

    // UTF-16 offset for an LSP position, clamped to the end of its own line --
    // not merely to the end of the text, which let an out-of-range character
    // on an early line resolve to an offset on a later one.
    int32_t offset(int32_t line, int32_t character) const;

    // Range for an LSP range object, or nullopt if it inverts, falls outside
    // the text, or is malformed.
    std::optional<nib_range> range(const nlohmann::json& lsp) const;

private:
    std::vector<int32_t> line_starts_;
    int32_t              length_ = 0;
};

}  // namespace nib

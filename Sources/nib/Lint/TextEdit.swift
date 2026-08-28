import Foundation

/// A single replacement: swap `range` for `replacement`.
///
/// `expected` records what the range held when the edit was planned. Accepting
/// a suggestion is not instantaneous — the user can keep typing between the
/// lint and the click — so the edit carries what it assumed, and that
/// assumption is checked before anything is written.
struct TextEdit: Equatable {
    let range: NSRange
    let replacement: String
    /// Text the range is expected to contain. Empty means "do not check".
    let expected: String

    /// Change in UTF-16 length once applied. Negative when text shrinks.
    var delta: Int {
        (replacement as NSString).length - range.length
    }
}

/// Pure text-editing logic, deliberately free of AppKit and Accessibility so it
/// can be tested directly. Every offset here is a UTF-16 offset, matching
/// NSRange and NSString.length rather than Swift's Character count: an emoji is
/// one Character but two UTF-16 units, and conflating the two corrupts text.
enum EditPlanner {
    /// Applies an edit, or returns nil if it does not fit the text.
    static func apply(_ edit: TextEdit, to text: String) -> String? {
        let ns = text as NSString
        guard isInBounds(edit.range, in: text) else { return nil }
        return ns.replacingCharacters(in: edit.range, with: edit.replacement)
    }

    /// Whether a range lies within the text. Rejects negative locations and
    /// lengths, which NSString would trap on rather than return nil.
    static func isInBounds(_ range: NSRange, in text: String) -> Bool {
        guard range.location >= 0, range.length >= 0 else { return false }
        let length = (text as NSString).length
        guard range.location <= length else { return false }
        return range.location + range.length <= length
    }

    /// Whether the edit still applies: in bounds, and the range holds what the
    /// edit expected. Guards against the text having changed since the lint.
    static func isValid(_ edit: TextEdit, in text: String) -> Bool {
        guard isInBounds(edit.range, in: text) else { return false }
        guard !edit.expected.isEmpty else { return true }
        return (text as NSString).substring(with: edit.range) == edit.expected
    }

    /// Finds where the expected text moved to after edits elsewhere.
    ///
    /// Searches outward from the original location so the nearest match wins;
    /// a common word like "the" appears many times and the closest occurrence
    /// is almost always the one meant.
    static func relocate(_ edit: TextEdit, in text: String, window: Int = 80) -> TextEdit? {
        if isValid(edit, in: text) { return edit }
        guard !edit.expected.isEmpty else { return nil }

        let ns = text as NSString
        let expectedLength = (edit.expected as NSString).length
        guard expectedLength > 0, ns.length >= expectedLength else { return nil }

        let anchor = min(max(0, edit.range.location), ns.length)
        let low = max(0, anchor - window)
        let high = min(ns.length - expectedLength, anchor + window)
        guard low <= high else { return nil }

        var best: Int?
        for candidate in low...high {
            let range = NSRange(location: candidate, length: expectedLength)
            guard ns.substring(with: range) == edit.expected else { continue }
            if best == nil || abs(candidate - anchor) < abs(best! - anchor) {
                best = candidate
            }
        }
        guard let location = best else { return nil }
        return TextEdit(range: NSRange(location: location, length: expectedLength),
                        replacement: edit.replacement,
                        expected: edit.expected)
    }

    /// Moves the remaining suggestions to where they sit after `edit` lands.
    ///
    /// Three cases, and the middle one is what previous versions got wrong:
    ///   - entirely before the edit: unchanged
    ///   - overlapping the edit: DROPPED, since the text it described is gone
    ///     and shifting it would point at an arbitrary span
    ///   - entirely after: shifted by the length delta
    static func reanchor(_ suggestions: [Suggestion], after edit: TextEdit) -> [Suggestion] {
        let editStart = edit.range.location
        let editEnd = NSMaxRange(edit.range)
        let delta = edit.delta

        return suggestions.compactMap { suggestion -> Suggestion? in
            let start = suggestion.range.location
            let end = NSMaxRange(suggestion.range)

            if end <= editStart { return suggestion }
            if start >= editEnd {
                let moved = start + delta
                guard moved >= 0 else { return nil }
                return Suggestion(id: suggestion.id,
                                  range: NSRange(location: moved,
                                                 length: suggestion.range.length),
                                  message: suggestion.message,
                                  replacements: suggestion.replacements)
            }
            // Overlaps the edited span, including a zero-length range sitting
            // inside it. The description no longer matches the text.
            return nil
        }
    }

    /// Drops suggestions that no longer fit the text, after reanchoring.
    static func pruneOutOfBounds(_ suggestions: [Suggestion], in text: String) -> [Suggestion] {
        suggestions.filter { isInBounds($0.range, in: text) }
    }
}

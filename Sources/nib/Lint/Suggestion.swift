import Foundation

/// One problem harper found, resolved to offsets in the original Swift string.
/// What kind of change a suggestion proposes, which decides how it is drawn.
///
/// Kept apart because they warrant different confidence. A misspelling is
/// wrong; a wordy sentence is a matter of taste, and marking both the same way
/// would make the advice feel like an error report.
enum SuggestionKind: Equatable {
    /// A definite mistake: spelling, agreement, a missing word.
    case correction
    /// The sentence works but could read better.
    case clarity
}

struct Suggestion: Identifiable, Equatable {
    let id: UUID
    let kind: SuggestionKind
    /// Range within the linted text, in UTF-16 offsets (what NSTextView uses).
    let range: NSRange
    /// Harper's description, e.g. "Did you mean `there`?".
    let message: String
    /// Replacement texts, best first. Empty until `HarperEngine.replacements`
    /// has been called for this suggestion, and for advisory-only lints.
    let replacements: [String]

    init(id: UUID = UUID(), kind: SuggestionKind = .correction,
         range: NSRange, message: String, replacements: [String]) {
        self.id = id
        self.kind = kind
        self.range = range
        self.message = message
        self.replacements = replacements
    }

    /// The substring this suggestion covers, or nil if the range no longer fits.
    func excerpt(in text: String) -> String? {
        guard let r = Range(range, in: text) else { return nil }
        return String(text[r])
    }

    static func == (a: Suggestion, b: Suggestion) -> Bool {
        a.range == b.range && a.message == b.message && a.replacements == b.replacements
    }
}

/// Converts LSP line/character positions into UTF-16 offsets.
///
/// LSP counts characters in UTF-16 code units per the spec, which matches
/// NSRange, but it addresses them as (line, character) pairs. This walks the
/// text once and builds a line-start index so lookups are cheap.
struct PositionMapper {
    private let lineStarts: [Int]
    private let utf16Length: Int

    init(text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { // \n
                starts.append(offset)
            }
        }
        self.lineStarts = starts
        self.utf16Length = offset
    }

    /// UTF-16 offset for an LSP position, clamped into the text.
    ///
    /// The character is clamped to the END OF ITS OWN LINE, not merely to the
    /// end of the text. Clamping only against the total length let an
    /// out-of-range character on an early line resolve to an offset on a later
    /// line, which marks the wrong row rather than failing.
    func offset(line: Int, character: Int) -> Int {
        guard line >= 0 else { return 0 }
        guard line < lineStarts.count else { return utf16Length }

        let start = lineStarts[line]
        // Line ends just before the next line's start, which is the newline
        // itself; the last line runs to the end of the text.
        let end = line + 1 < lineStarts.count
            ? max(start, lineStarts[line + 1] - 1)
            : utf16Length
        return min(start + max(0, character), end)
    }

    /// NSRange for an LSP range, or nil if it inverts or falls outside the text.
    func range(from lsp: [String: Any]) -> NSRange? {
        guard let start = lsp["start"] as? [String: Any],
              let end = lsp["end"] as? [String: Any],
              let sl = start["line"] as? Int, let sc = start["character"] as? Int,
              let el = end["line"] as? Int, let ec = end["character"] as? Int
        else { return nil }

        let from = offset(line: sl, character: sc)
        let to = offset(line: el, character: ec)
        guard to >= from, to <= utf16Length else { return nil }
        return NSRange(location: from, length: to - from)
    }
}

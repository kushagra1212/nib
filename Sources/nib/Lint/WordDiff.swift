import Foundation

/// Turns a rewritten sentence back into localized edits.
///
/// A language model reads the whole sentence, which is what gives it the
/// context a dictionary lacks — it knows `NSString` is a type and leaves it
/// alone. But it returns a whole corrected sentence, and replacing the user's
/// text wholesale is not what an underline does.
///
/// Grammarly resolves this by running a sequence-to-sequence rewrite alongside
/// a system that tags individual edits, so they keep sentence-level context and
/// still point at single words. Diffing the rewrite against the original
/// recovers the same thing: each changed span becomes one suggestion with a
/// real range.
enum WordDiff {
    /// A word and where it sits in the source, in UTF-16 offsets.
    struct Token: Equatable {
        let text: String
        let range: NSRange
    }

    /// Splits text into word tokens, keeping each one's range.
    ///
    /// Separators are skipped for matching but their offsets are preserved by
    /// the ranges, so an edit that spans several words covers the spaces too.
    static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var index = 0
        var start = -1

        func isWordCharacter(_ scalar: unichar) -> Bool {
            let character = Character(UnicodeScalar(scalar) ?? " ")
            return character.isLetter || character.isNumber
                || character == "'" || character == "’"
                || character == "-" || character == "_"
        }

        while index < ns.length {
            if isWordCharacter(ns.character(at: index)) {
                if start < 0 { start = index }
            } else if start >= 0 {
                let range = NSRange(location: start, length: index - start)
                tokens.append(Token(text: ns.substring(with: range), range: range))
                start = -1
            }
            index += 1
        }
        if start >= 0 {
            let range = NSRange(location: start, length: ns.length - start)
            tokens.append(Token(text: ns.substring(with: range), range: range))
        }
        return tokens
    }

    /// Computes edits that turn `original` into `corrected`.
    ///
    /// Adjacent changes are merged into one edit, so "could of" becoming "could
    /// have" is a single suggestion rather than two confusing ones.
    static func edits(from original: String, to corrected: String) -> [TextEdit] {
        let source = tokenize(original)
        let target = tokenize(corrected)
        guard source != target else { return [] }

        let common = longestCommonSubsequence(source.map(\.text), target.map(\.text))
        var edits: [TextEdit] = []
        var i = 0, j = 0

        for anchor in common + [nil] {
            var deleted: [Token] = []
            var inserted: [String] = []

            while i < source.count, anchor == nil || source[i].text != anchor! {
                deleted.append(source[i]); i += 1
            }
            while j < target.count, anchor == nil || target[j].text != anchor! {
                inserted.append(target[j].text); j += 1
            }
            if anchor != nil { i += 1; j += 1 }

            guard !deleted.isEmpty || !inserted.isEmpty else { continue }
            if let edit = makeEdit(deleted: deleted, inserted: inserted,
                                   source: source, original: original) {
                edits.append(edit)
            }
        }
        return edits
    }

    private static func makeEdit(
        deleted: [Token], inserted: [String], source: [Token], original: String
    ) -> TextEdit? {
        let replacement = inserted.joined(separator: " ")

        guard let first = deleted.first, let last = deleted.last else {
            // Pure insertion. Without a deleted token there is nothing to
            // anchor an underline to, and a zero-width mark cannot be hovered,
            // so these are dropped rather than shown unusably.
            return nil
        }

        let range = NSRange(location: first.range.location,
                            length: NSMaxRange(last.range) - first.range.location)
        let expected = (original as NSString).substring(with: range)
        guard expected != replacement else { return nil }

        return TextEdit(range: range, replacement: replacement, expected: expected)
    }

    /// Converts edits into suggestions the UI can render.
    static func suggestions(
        from original: String, to corrected: String, message: String = "Suggested rewrite"
    ) -> [Suggestion] {
        edits(from: original, to: corrected).map { edit in
            Suggestion(range: edit.range,
                       message: message,
                       replacements: [edit.replacement])
        }
    }

    /// Standard dynamic-programming LCS over word strings.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1),
                          count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }

        var result: [String] = []
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1]); i -= 1; j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }
}

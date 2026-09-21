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
            guard let unicode = UnicodeScalar(scalar) else { return false }
            // Combining marks belong to the letter they attach to. Devanagari
            // and other Indic scripts carry viramas and vowel signs mid-word,
            // and treating those as separators splits a single word into
            // several, giving every piece its own underline.
            if CharacterSet.nonBaseCharacters.contains(unicode) { return true }

            let character = Character(unicode)
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

        // Same words, different text: the change is punctuation or spacing.
        // Word tokens cannot see it, so a missing comma or apostrophe produced
        // no suggestion at all. Fall back to a character-level span.
        if source.map(\.text) == target.map(\.text) {
            return original == corrected
                ? []
                : [characterEdit(from: original, to: corrected)].compactMap { $0 }
        }
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

    /// One edit covering the span between the first and last differing
    /// character, used when the words match and only punctuation moved.
    ///
    /// Widened to whole words at both ends, so the underline sits under
    /// something clickable rather than under a bare comma.
    static func characterEdit(from original: String, to corrected: String) -> TextEdit? {
        let a = original as NSString
        let b = corrected as NSString

        var prefix = 0
        while prefix < a.length, prefix < b.length,
              a.character(at: prefix) == b.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.length - prefix, suffix < b.length - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }

        // Grow outwards to word boundaries so the mark covers a word.
        var start = prefix
        while start > 0, isWordCharacter(a.character(at: start - 1)) { start -= 1 }
        var end = a.length - suffix
        while end < a.length, isWordCharacter(a.character(at: end)) { end += 1 }
        guard end > start else { return nil }

        let range = NSRange(location: start, length: end - start)
        let replacementLength = b.length - suffix - start
        guard replacementLength >= 0,
              start + replacementLength <= b.length else { return nil }
        var replacement = b.substring(with: NSRange(location: start, length: replacementLength))
        // Re-attach the trailing word characters that were grown into.
        let grown = end - (a.length - suffix)
        if grown > 0 {
            replacement += a.substring(with: NSRange(location: a.length - suffix,
                                                     length: grown))
        }

        let expected = a.substring(with: range)
        guard expected != replacement else { return nil }
        return TextEdit(range: range, replacement: replacement, expected: expected)
    }

    private static func isWordCharacter(_ scalar: unichar) -> Bool {
        guard let unicode = UnicodeScalar(scalar) else { return false }
        let character = Character(unicode)
        return character.isLetter || character.isNumber
    }

    /// Converts edits into suggestions the UI can render.
    static func suggestions(
        from original: String, to corrected: String,
        message: String = "Suggested rewrite",
        source: SuggestionSource = .model
    ) -> [Suggestion] {
        edits(from: original, to: corrected).map { edit in
            Suggestion(source: source,
                       range: edit.range,
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

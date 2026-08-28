import Foundation

/// Discards suggestions that a dictionary matcher produces but a reader would
/// never want.
///
/// Harper compares words against a word list. It has no idea that `NSString` is
/// a type, `UTF` an acronym, or `gpt` a product, so it offers the nearest
/// dictionary neighbour and produces damage:
///
///     UTF      -> Uhf
///     NSString -> Nesting
///     gpt      -> get
///     bugs     -> thing
///
/// Two independent guards catch these. The first reads the flagged token: text
/// shaped like code is not prose and should not be spell-checked. The second
/// reads the proposed replacement: a spelling correction is a near neighbour of
/// what you typed, so a "fix" that shares almost nothing with the original is
/// not a fix.
enum SuggestionFilter {
    /// Removes suggestions whose flagged text or replacement looks wrong.
    static func apply(_ suggestions: [Suggestion], in text: String) -> [Suggestion] {
        suggestions.filter { keep($0, in: text) }
    }

    static func keep(_ suggestion: Suggestion, in text: String) -> Bool {
        guard let token = suggestion.excerpt(in: text) else { return false }

        if looksLikeCode(token) { return false }
        if isSurroundedByCode(suggestion.range, in: text) { return false }

        // Advisory lints with no replacement are only ever shown as a note.
        guard let replacement = suggestion.replacements.first else { return true }
        return isPlausibleCorrection(from: token, to: replacement)
    }

    // MARK: - Shape of the flagged token

    /// Whether a token reads as code or a proper noun rather than prose.
    static func looksLikeCode(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Digits never appear in ordinary words: UTF-16, RN86, h264.
        if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { return true }

        // Identifier punctuation: snake_case, kebab-case, NSString.length,
        // paths, calls.
        if trimmed.contains(where: { "_./\\(){}[]<>:@#$%^&*+=|~".contains($0) }) {
            return true
        }

        let letters = trimmed.filter(\.isLetter)
        guard !letters.isEmpty else { return true }

        // An acronym: two or more letters, all capitals. UTF, ZWJ, RN, API.
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return true }

        // Medial capitals: NSString, TextEdit, didApply, iOS.
        if hasMedialCapital(trimmed) { return true }

        // No vowel: gpt, npm, ssh, jwt, sql, ctx. English words of two letters
        // or more essentially always carry one, so a token without any is an
        // abbreviation. This is what catches lowercase product names, which
        // edit distance cannot: "gpt" to "get" is a single substitution and
        // looks like a perfectly ordinary correction.
        if lacksVowel(letters) { return true }

        return false
    }

    private static func lacksVowel(_ letters: String) -> Bool {
        guard letters.count >= 2 else { return false }
        let vowels = Set("aeiouy")
        return !letters.lowercased().contains { vowels.contains($0) }
    }

    /// A capital letter appearing after the first character, which marks
    /// camelCase and PascalCase but not an ordinary capitalised word.
    private static func hasMedialCapital(_ token: String) -> Bool {
        let characters = Array(token)
        guard characters.count > 1 else { return false }
        return characters.dropFirst().contains { $0.isUppercase }
    }

    /// Whether the flagged span sits inside code punctuation, so the token is
    /// part of an expression even when it looks like a word on its own.
    ///
    /// Catches the `length` in `NSString.length`, which is an ordinary word
    /// until you notice the dot in front of it.
    static func isSurroundedByCode(_ range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return false }

        let adjacent = CharacterSet(charactersIn: "._/\\@#$(){}[]<>")
        if range.location > 0 {
            let before = ns.substring(with: NSRange(location: range.location - 1, length: 1))
            if before.rangeOfCharacter(from: adjacent) != nil { return true }
        }
        if NSMaxRange(range) < ns.length {
            let after = ns.substring(with: NSRange(location: NSMaxRange(range), length: 1))
            if after.rangeOfCharacter(from: adjacent) != nil { return true }
        }
        return isInsideBackticks(range, in: text)
    }

    /// Whether the range falls inside a backtick span, which marks code even in
    /// plain text.
    static func isInsideBackticks(_ range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        guard range.location >= 0, range.location <= ns.length else { return false }
        let before = ns.substring(to: range.location)
        // An odd number of backticks before the token means it opened a span
        // that has not closed yet.
        return before.filter { $0 == "`" }.count % 2 == 1
    }

    // MARK: - Shape of the replacement

    /// Whether a replacement is close enough to be a correction rather than a
    /// different word.
    ///
    /// Short words need an absolute allowance: "a" to "an" is one edit out of
    /// one character, which any ratio would reject, and it is a real fix.
    static func isPlausibleCorrection(from original: String, to replacement: String) -> Bool {
        let a = original.lowercased()
        let b = replacement.lowercased()
        if a == b { return false }

        guard !addsWords(from: a, to: b) else { return false }
        guard !inventsPossessive(from: a, to: b) else { return false }

        let distance = editDistance(a, b)
        if distance <= 1 { return true }

        let longest = max(a.count, b.count)
        guard longest > 0 else { return false }
        return Double(distance) / Double(longest) <= 0.5
    }

    /// Whether a replacement pads the phrase out rather than correcting it.
    ///
    /// Harper's grammar rules sometimes expand a phrase into something longer
    /// and wrong -- "both needing" became "both pieces of needing". Shrinking
    /// is fine, since joining a split word is a real fix, but a correction
    /// should not bring new words with it.
    static func addsWords(from original: String, to replacement: String) -> Bool {
        let before = original.split(whereSeparator: \.isWhitespace).count
        let after = replacement.split(whereSeparator: \.isWhitespace).count
        return after > before + 1
    }

    /// Whether a replacement turns a word into a possessive or contraction it
    /// never resembled.
    ///
    /// "Frontmost" became "Front's". Adding an apostrophe is a real fix when
    /// the letters are otherwise unchanged -- "its" to "it's" -- so the test
    /// is whether the letters survive, not whether an apostrophe appeared.
    static func inventsPossessive(from original: String, to replacement: String) -> Bool {
        let hadApostrophe = original.contains { $0 == "'" || $0 == "’" }
        let hasApostrophe = replacement.contains { $0 == "'" || $0 == "’" }
        guard !hadApostrophe, hasApostrophe else { return false }

        let strip: (String) -> String = { text in
            String(text.filter { $0 != "'" && $0 != "’" })
        }
        return strip(original) != strip(replacement)
    }

    /// Levenshtein distance, two rows rather than a full matrix.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let source = Array(a), target = Array(b)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for i in 1...source.count {
            current[0] = i
            for j in 1...target.count {
                let substitution = previous[j - 1] + (source[i - 1] == target[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }
}

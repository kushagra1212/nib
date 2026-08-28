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
    /// Removes suggestions that are not mistakes, and bad fixes for ones that
    /// are.
    static func apply(_ suggestions: [Suggestion], in text: String) -> [Suggestion] {
        suggestions.compactMap { refine($0, in: text) }
    }

    /// Whether a suggestion survives at all, in any form.
    static func keep(_ suggestion: Suggestion, in text: String) -> Bool {
        refine(suggestion, in: text) != nil
    }

    /// Judges the flagged word and its replacements separately.
    ///
    /// These are two different questions and the answers do not travel
    /// together. "Is this a mistake?" decides whether to mark the word at all.
    /// "Is this a good fix?" decides what to offer for it. Answering the first
    /// with the second is why a plainly misspelled word could end up with no
    /// underline: harper's best guess was too far from what was typed, the
    /// whole suggestion went in the bin, and the mistake went unreported.
    ///
    /// A word with no usable fix keeps its mark and offers nothing, which is
    /// what advisory lints have always done.
    static func refine(_ suggestion: Suggestion, in text: String) -> Suggestion? {
        guard let token = suggestion.excerpt(in: text) else { return nil }

        // These say the word is not a mistake, so the mark goes too.
        if looksLikeCode(token) { return nil }
        if isSurroundedByCode(suggestion.range, in: text) { return nil }

        guard let first = suggestion.replacements.first else { return suggestion }

        // Both guards below ask "did the writer mean this word", which only
        // makes sense for a word Harper does not know. Its grammar rules fire
        // on words that are in the dictionary -- their/there, its/it's -- and
        // those must still be corrected wherever they appear.
        if isSpellingCheck(suggestion.message) {
            if isProperNoun(suggestion.range, in: text) { return nil }
            if repeatsDeliberately(token, in: text, replacement: first) { return nil }
        }

        // Every replacement, not just the first. Harper offers up to three and
        // ranks them by its own lights: judging only the first threw away good
        // second choices, and "optioaa -> optical | optimal" is exactly that
        // shape.
        let usable = suggestion.replacements.filter {
            isPlausibleCorrection(from: token, to: $0)
        }
        if usable.isEmpty {
            // Nothing worth offering. Whether to still mark the word depends
            // on what kind of lint it was.
            //
            // A spelling lint means harper does not know the word, so
            // something is wrong with it whatever the suggested fix looked
            // like -- mark it and offer nothing. Any other rule fired on words
            // that are in the dictionary: "bugs" is not misspelled, and a rule
            // that wanted to make it "thing" has simply misfired. Marking that
            // would be inventing an error.
            guard isSpellingCheck(suggestion.message) else { return nil }
        }
        return Suggestion(id: suggestion.id, kind: suggestion.kind,
                          range: suggestion.range, message: suggestion.message,
                          replacements: usable)
    }

    /// Whether the lint is "I do not know this word" rather than a grammar rule.
    static func isSpellingCheck(_ message: String) -> Bool {
        message.lowercased().contains("spell")
    }

    // MARK: - Words the writer meant

    /// Whether the flagged word is a name rather than a misspelling.
    ///
    /// Harper offered `Kushagra -> Bukhara` and `Rathore -> Rather`: it has no
    /// name list, so every unfamiliar name becomes the nearest dictionary word.
    /// Suggesting a different name for someone's name is worse than saying
    /// nothing, and the message being typed is usually addressed to them.
    ///
    /// A capital only means a name away from the start of a sentence, so the
    /// position is what is tested, not the letter.
    static func isProperNoun(_ range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        guard range.location >= 0, range.length > 0,
              NSMaxRange(range) <= ns.length else { return false }
        guard let first = ns.substring(with: range).first, first.isUppercase else {
            return false
        }
        return !startsSentence(at: range.location, in: ns)
    }

    private static func startsSentence(at location: Int, in ns: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = Character(ns.substring(with: NSRange(location: index, length: 1)))
            // A line break ends a sentence as surely as a full stop does, and
            // in chat it is the usual way people end one.
            if character.isNewline { return true }
            if character.isWhitespace { index -= 1; continue }
            return ".!?".contains(character)
        }
        return true
    }

    /// Whether a word is used consistently enough to be deliberate.
    ///
    /// `rects` appeared twice in the same message and Harper offered `rests`
    /// for it. Jargon, product names and abbreviations repeat; a slip of the
    /// fingers usually does not land the same way twice.
    ///
    /// Transpositions are the exception. Swapping two adjacent letters is the
    /// most common typing error there is, and it does repeat, so `teh` twice
    /// still gets corrected to `the`.
    static func repeatsDeliberately(
        _ token: String,
        in text: String,
        replacement: String
    ) -> Bool {
        let word = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Below four letters the odds of an unrelated collision are too high,
        // and short words are where genuine repeated typos live.
        guard word.count >= 4, !word.contains(where: \.isWhitespace) else { return false }
        guard !isTransposition(word, replacement) else { return false }
        return occurrences(of: word, in: text) >= 2
    }

    /// Counts whole-word matches, case-insensitively.
    static func occurrences(of word: String, in text: String) -> Int {
        let target = word.lowercased()
        return text
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .reduce(into: 0) { count, candidate in
                if candidate.lowercased() == target { count += 1 }
            }
    }

    /// Whether two words differ only by one pair of swapped adjacent letters.
    ///
    /// `teh` to `the` and `adn` to `and` are two edits over three characters,
    /// which every ratio test rejects. They were being rejected: the two most
    /// common typos in English produced no fix at all.
    static func isTransposition(_ a: String, _ b: String) -> Bool {
        let left = Array(a.lowercased()), right = Array(b.lowercased())
        guard left.count == right.count, left.count >= 2 else { return false }

        let differing = zip(left, right).enumerated()
            .filter { $0.element.0 != $0.element.1 }
            .map(\.offset)
        guard differing.count == 2 else { return false }

        let (i, j) = (differing[0], differing[1])
        guard j == i + 1 else { return false }
        return left[i] == right[j] && left[j] == right[i]
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

        // A phrase is judged by words, not by letters. "could of" to "could
        // have" is four character edits but one word replaced, and any
        // character threshold loose enough to allow that also allows real
        // damage on single words.
        let before = a.split(whereSeparator: \.isWhitespace)
        let after = b.split(whereSeparator: \.isWhitespace)
        if before.count > 1 || after.count > 1 {
            // Splitting or joining a word changes the word count while keeping
            // the letters: "cannotbe" to "cannot be", "along side" to
            // "alongside". Compare with the spaces taken out.
            guard before.count == after.count else {
                let joinedBefore = before.joined()
                let joinedAfter = after.joined()
                return editDistance(joinedBefore, joinedAfter) <= 2
            }
            return zip(before, after).filter { $0 != $1 }.count == 1
        }

        // Two edits, flat, rather than a proportion of the word.
        //
        // Measured over every correction this app has been asked to make or
        // refuse, the two groups do not overlap and do not scale with length:
        //
        //   keep    their -> there (2)      recieve -> receive (2)
        //           erors -> errors (1)     accomodate -> accommodate (1)
        //           teh -> the (2)          seperate -> separate (1)
        //   refuse  Kushagra -> Bukhara (3) subrole -> sublime (3)
        //           bugs -> thing (5)       cat -> house (5)
        //
        // A ratio gets this wrong at both ends: it rejects "teh" to "the",
        // two edits over three letters, and accepts "Kushagra" to "Bukhara",
        // three over eight.
        return editDistance(a, b) <= 2
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

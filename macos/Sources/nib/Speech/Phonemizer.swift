import Foundation

/// Where phonemes come from. espeak in the app; recorded output in tests, so
/// the assembly around it can be checked without loading a library.
///
/// Outside `Phonemizer` because Swift does not allow a protocol inside a type.
protocol PhonemeSource {
    /// espeak's own answer for one chunk: IPA with `_` between phonemes and a
    /// space between words.
    func phonemes(for text: String) throws -> String
}

/// Turns written text into the phoneme string Kokoro is fed.
///
/// The whole path, in the order phonemizer runs it:
///
///   1. Punctuation is taken out, because espeak drops it and the model wants
///      it. `PhonemePunctuation` keeps a note of what came out and where.
///   2. Each remaining chunk goes to espeak on its own.
///   3. espeak's output is tidied -- it separates phonemes with underscores,
///      and those are not part of the answer.
///   4. The punctuation goes back in.
///   5. Anything the model has never been trained on is dropped, and runs of
///      whitespace collapse to one space.
///
/// Step 5 is silent by design and worth knowing about: an unknown symbol is not
/// an error, it simply is not spoken. `[brackets]` come out as `bɹˈækɪts` with
/// the brackets gone, because square brackets are not in the vocabulary while
/// round ones are.
enum Phonemizer {
    /// phonemizer's defaults, which are also kokoro's: words separated by a
    /// space, nothing between phonemes, and the trailing separator left on.
    static let wordSeparator = " "
    static let phoneSeparator = ""

    /// The phonemes a sentence becomes, ready to tokenise.
    static func phonemes(of text: String, using source: PhonemeSource) throws -> String {
        let raw = try phonemize(text, using: source)
        // kokoro filters to the vocabulary and strips, then collapses
        // whitespace in _prepare. Newlines are not in the vocabulary, so
        // without the collapse two lines run together with no gap to breathe.
        let known = raw.filter { KokoroVocab.table[String($0)] != nil }
        return known.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The same thing before filtering, which is what phonemizer returns.
    /// Separate so a divergence can be located: this or the vocabulary.
    static func phonemize(_ text: String, using source: PhonemeSource) throws -> String {
        let (chunks, marks) = PhonemePunctuation.preserve(text)
        let spoken = try chunks.map { chunk in
            tidy(try source.phonemes(for: chunk))
        }
        // Joined with a newline, not with nothing: restoration returns one entry
        // per line and phonemizer puts the lines back together the way they
        // arrived. The newline is dropped by the vocabulary filter afterwards,
        // but it is what stops the last word of one line running into the first
        // word of the next.
        return PhonemePunctuation.restore(spoken, marks: marks,
                                          separator: wordSeparator, strip: false)
            .joined(separator: "\n")
    }

    /// Cleans up one chunk of espeak output.
    ///
    /// espeak writes `ð_ə k_w_ˈɪ_k`: underscores between the phonemes of a
    /// word, spaces between words. The underscores are a separator nib does not
    /// use, so they come out. It also emits doubled underscores at the end of
    /// some words, which is an espeak-ng bug rather than meaning -- see
    /// espeak-ng issue 694.
    static func tidy(_ line: String, strip: Bool = false) -> String {
        var line = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            // One pass, not until stable: three spaces become two, as in
            // phonemizer. Left as it is because the collapse in `phonemes`
            // finishes the job and matching the engine matters more.
            .replacingOccurrences(of: "  ", with: " ")

        line = collapseUnderscores(line)
        line = line.replacingOccurrences(of: "_ ", with: " ")
        guard !line.isEmpty else { return "" }

        var result = ""
        for word in line.components(separatedBy: " ") {
            var word = word.trimmingCharacters(in: .whitespacesAndNewlines)
            // The separator espeak would have put after the last phoneme of the
            // word, added so removing separators removes this one too.
            if !strip { word += "_" }
            result += word.replacingOccurrences(of: "_", with: phoneSeparator)
                + wordSeparator
        }
        if strip, !wordSeparator.isEmpty {
            result.removeLast(wordSeparator.count)
        }
        return result
    }

    /// `_+` to a single `_`, without a regular expression.
    private static func collapseUnderscores(_ line: String) -> String {
        var result = ""
        var previousWasUnderscore = false
        for character in line {
            if character == "_" {
                if previousWasUnderscore { continue }
                previousWasUnderscore = true
            } else {
                previousWasUnderscore = false
            }
            result.append(character)
        }
        return result
    }
}

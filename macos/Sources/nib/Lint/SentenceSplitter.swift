import Foundation

/// Splits text into sentences, keeping each one's range.
///
/// Clarity suggestions apply to a whole sentence, so the mark under them has to
/// cover exactly that sentence and no more. Splitting on "." alone breaks on
/// "e.g.", "3.5" and "NSString.length", which matters here because the text
/// being checked is often technical.
enum SentenceSplitter {
    struct Sentence: Equatable {
        let text: String
        /// Range in the source, in UTF-16 offsets.
        let range: NSRange
    }

    /// Sentences long enough to be worth a clarity suggestion.
    ///
    /// Short fragments are skipped: the model has nothing useful to say about
    /// "Thanks!" and a mark under it is noise.
    static func sentences(in text: String, minimumWords: Int = 5) -> [Sentence] {
        let ns = text as NSString
        var found: [Sentence] = []

        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.bySentences, .localized]
        ) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Trim the range to match the trimmed text, so the mark does not
            // extend across the blank space after a sentence.
            guard let tight = tighten(range, in: ns) else { return }
            guard WordDiff.tokenize(trimmed).count >= minimumWords else { return }

            found.append(Sentence(text: ns.substring(with: tight), range: tight))
        }
        return found
    }

    /// Shrinks a range to exclude leading and trailing whitespace.
    private static func tighten(_ range: NSRange, in ns: NSString) -> NSRange? {
        var start = range.location
        var end = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines

        while start < end,
              let scalar = UnicodeScalar(ns.character(at: start)),
              whitespace.contains(scalar) {
            start += 1
        }
        while end > start,
              let scalar = UnicodeScalar(ns.character(at: end - 1)),
              whitespace.contains(scalar) {
            end -= 1
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

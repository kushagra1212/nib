import CNibCore
import Foundation

/// Swift's view of the C++ core.
///
/// The shape matches the Swift this replaced, so callers do not change. That is
/// deliberate: one file moves, and the suite that already covered it is what
/// judges the move.
enum SentenceSplitter {
    struct Sentence: Equatable {
        let text: String
        /// Range in the source, in UTF-16 offsets.
        let range: NSRange
    }

    /// Sentences long enough to be worth a clarity suggestion.
    ///
    /// The locale is passed rather than left to the core. Foundation segmented
    /// with the user's locale, and dropping that would quietly change how text
    /// splits for anyone not on the machine the core was built on.
    static func sentences(in text: String, minimumWords: Int = 5) -> [Sentence] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        return units.withUnsafeBufferPointer { buffer -> [Sentence] in
            let input = nib_str(data: buffer.baseAddress,
                                length: Int32(buffer.count))
            guard let list = nib_sentences(input,
                                           Int32(minimumWords),
                                           Locale.current.identifier)
            else { return [] }
            defer { nib_sentence_list_free(list) }

            let count = Int(nib_sentence_count(list))
            var found: [Sentence] = []
            found.reserveCapacity(count)

            for index in 0..<count {
                let range = nib_sentence_range(list, Int32(index))
                // Sized first, then filled. The core reports the full length
                // either way, so a short buffer would be caught rather than
                // silently truncating a sentence.
                let length = Int(nib_sentence_text(list, Int32(index), nil, 0))
                var scratch = [UInt16](repeating: 0, count: length)
                _ = scratch.withUnsafeMutableBufferPointer {
                    nib_sentence_text(list, Int32(index),
                                      $0.baseAddress, Int32(length))
                }
                found.append(Sentence(
                    text: String(decoding: scratch, as: UTF16.self),
                    range: NSRange(location: Int(range.location),
                                   length: Int(range.length))))
            }
            return found
        }
    }
}

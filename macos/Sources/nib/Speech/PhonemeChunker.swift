import Foundation

/// Splits a long phoneme string into batches the model can speak in one pass.
///
/// The model's context is 510 phonemes. Anything longer has to be cut, and
/// where it is cut is audible: a break mid-word is a stutter, a break at a full
/// stop is a pause that was going to be there anyway. So the cut is taken at
/// the least disruptive boundary available -- sentence, then clause, then word,
/// and only as a last resort mid-word.
///
/// The second thing it does is less obvious and matters more. Filling each
/// batch to 510 leaves a short remainder, and a short batch is spoken at a
/// different rate and loudness than its neighbours -- the last few words of a
/// long paragraph come out noticeably faster. So the batches are balanced
/// instead: the smallest limit that still needs no extra pass over the text.
///
/// Ported from `kokoro_onnx/chunker.py` and checked against it, entry by entry,
/// in `Tests/Fixtures/phonemes-golden.json`.
enum PhonemeChunker {
    /// Marks that end a sentence, and the best place to cut.
    static let sentenceMarks: Set<Character> = [".", "!", "?", "…"]
    /// Marks that end a clause. Second best.
    static let clauseMarks: Set<Character> = [",", ";", ":"]

    /// Least to most disruptive. Punctuation stays with the text before it,
    /// which is how the model was trained.
    private static let boundaries: [Set<Character>?] = [
        sentenceMarks, clauseMarks, nil,   // nil is any whitespace
    ]

    /// A shorter limit for the first batch only.
    ///
    /// Nothing is spoken until the first batch is synthesised, so its length is
    /// the wait before the first word. At the full 510 that is 11 seconds of
    /// silence on a long selection, which reads as broken. At 180 it is about
    /// three, and only the opening is cut more finely than the rest.
    ///
    /// Not smaller: every batch is trimmed and rejoined, so a very short lead-in
    /// buys a second at the cost of an audible seam in the first sentence.
    static let leadIn = 180

    /// Splits with a shorter first batch, so speech can start sooner.
    ///
    /// The remainder is batched normally. Only the opening pays for the finer
    /// cut, and by the time it has played there is a full batch ready behind it.
    static func streaming(_ phonemes: String,
                          limit: Int = KokoroVocab.maxPhonemes,
                          leadIn: Int = leadIn) -> [String] {
        let batches = split(phonemes, limit: limit)
        guard batches.count > 1, let first = batches.first else { return batches }
        return split(first, limit: leadIn) + batches.dropFirst()
    }

    static func split(_ phonemes: String,
                      limit: Int = KokoroVocab.maxPhonemes) -> [String] {
        let atoms = self.atoms(phonemes.trimmed(), limit: limit)
        guard !atoms.isEmpty else { return [] }

        let lengths = atoms.map(\.count)
        let fewest = pack(lengths, limit: limit).count

        // The smallest limit that still yields `fewest` batches. Binary search
        // rather than a scan: the batch count is monotonic in the limit, so
        // halving the range is exact rather than approximate.
        var low = lengths.max() ?? limit
        var high = limit
        while low < high {
            let middle = (low + high) / 2
            if pack(lengths, limit: middle).count <= fewest {
                high = middle
            } else {
                low = middle + 1
            }
        }

        return pack(lengths, limit: low).map { range in
            atoms[range.start..<range.end].joined(separator: " ")
        }
    }

    /// Seconds of silence a batch ending in this text should be followed by.
    ///
    /// Trimming removes the silence the model leaves at a batch end, so the
    /// pause the punctuation calls for is added back when the batches are
    /// joined. Without it, a full stop at a batch boundary disappears.
    static func pause(after phonemes: String,
                      sentence: Double, clause: Double) -> Double {
        guard let mark = phonemes.trimmedTrailing().last else { return 0 }
        if sentenceMarks.contains(mark) { return sentence }
        if clauseMarks.contains(mark) { return clause }
        return 0
    }

    // MARK: - Pieces

    /// Pieces of `phonemes`, none longer than `limit`.
    ///
    /// Descends one boundary at a time: if splitting at sentences leaves a
    /// piece that is still too long, that piece is split at clauses, and so on.
    /// `level` is what stops it retrying a boundary that already failed.
    private static func atoms(_ phonemes: String, limit: Int,
                              level: Int = 0) -> [String] {
        if phonemes.count <= limit {
            return phonemes.isEmpty ? [] : [phonemes]
        }

        for index in level..<boundaries.count {
            let pieces = separate(phonemes, after: boundaries[index])
            guard pieces.count > 1 else { continue }
            return pieces.flatMap {
                atoms($0.trimmed(), limit: limit, level: index + 1)
            }
        }

        // One unbroken run longer than the context -- a word with no spaces in
        // it. Sliced rather than dropped, because losing the tail is silent.
        return stride(from: 0, to: phonemes.count, by: limit).map { start in
            let from = phonemes.index(phonemes.startIndex, offsetBy: start)
            let to = phonemes.index(from, offsetBy: limit,
                                    limitedBy: phonemes.endIndex) ?? phonemes.endIndex
            return String(phonemes[from..<to])
        }
    }

    /// Splits on runs of whitespace, optionally only those following a mark.
    ///
    /// Matches Python's `re.split` on `(?<=[marks])\s+`: the whitespace goes
    /// away and the mark stays with the text before it.
    private static func separate(_ text: String,
                                 after marks: Set<Character>?) -> [String] {
        var pieces: [String] = []
        var current = ""
        var previous: Character?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character.isWhitespace else {
                current.append(character)
                previous = character
                index = text.index(after: index)
                continue
            }

            // The whole run of whitespace, so "a.  b" splits once rather than
            // producing an empty piece between the two spaces.
            var run = index
            while run < text.endIndex, text[run].isWhitespace {
                run = text.index(after: run)
            }

            let qualifies = marks.map { previous.map($0.contains) ?? false } ?? true
            if qualifies {
                pieces.append(current)
                current = ""
                previous = nil
            } else {
                current += text[index..<run]
            }
            index = run
        }

        pieces.append(current)
        return pieces
    }

    // MARK: - Packing

    private struct Batch {
        let start: Int
        let end: Int
    }

    /// Groups consecutive pieces into batches within `limit`.
    ///
    /// The `+ 1` is the space that will rejoin two pieces, and leaving it out
    /// produces batches one character over the model's context for every join.
    private static func pack(_ lengths: [Int], limit: Int) -> [Batch] {
        var batches: [Batch] = []
        var start = 0
        var size = 0

        for (index, length) in lengths.enumerated() {
            let candidate = index == start ? length : size + 1 + length
            if candidate > limit, index > start {
                batches.append(Batch(start: start, end: index))
                start = index
                size = length
            } else {
                size = candidate
            }
        }

        if !lengths.isEmpty {
            batches.append(Batch(start: start, end: lengths.count))
        }
        return batches
    }
}

private extension String {
    /// Python's `str.strip()`: whitespace from both ends, nothing else.
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trimmedTrailing() -> String {
        var copy = self
        while let last = copy.last, last.isWhitespace { copy.removeLast() }
        return copy
    }
}

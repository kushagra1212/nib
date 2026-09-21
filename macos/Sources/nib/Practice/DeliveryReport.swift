import Foundation

/// What a spoken answer sounded like, measured rather than remembered.
///
/// Pure: segments in, numbers out, no clock and no disk. Everything here is
/// something you cannot hear in your own voice while you are producing it --
/// people reliably underestimate their own filler and overestimate their own
/// pace, which is why practising without a recording mostly rehearses the
/// mistakes.
///
/// It does not grade content. Whether the answer was *good* is a judgement;
/// this is the part a machine can count.
struct DeliveryReport: Equatable {
    let duration: TimeInterval
    let wordCount: Int
    /// Words per minute over the whole take, silence included.
    let pace: Double
    /// Filler word, and how many times it appeared.
    let fillers: [(word: String, count: Int)]
    let fillerTotal: Int
    /// Gaps longer than `pauseThreshold`, as (seconds into the take, length).
    let longPauses: [(at: TimeInterval, length: TimeInterval)]
    /// Words in the longest sentence. A spoken sentence past ~30 is one the
    /// listener has already lost.
    let longestSentence: Int
    /// Whether the take ends on something that lands, or trails off.
    let trailsOff: Bool

    static func == (a: DeliveryReport, b: DeliveryReport) -> Bool {
        a.duration == b.duration && a.wordCount == b.wordCount
            && a.fillerTotal == b.fillerTotal && a.longestSentence == b.longestSentence
            && a.trailsOff == b.trailsOff
    }

    // MARK: - What counts as a problem

    /// A gap this long reads as hesitation rather than a breath.
    ///
    /// Two seconds, not one. Ordinary speech is full of sub-second gaps and
    /// flagging them would bury the real ones; at two the listener has started
    /// wondering whether you are stuck.
    static let pauseThreshold: TimeInterval = 2.0

    /// Interview pace. Below this you sound unsure, above it you sound rushed
    /// and the listener stops retaining detail.
    static let comfortablePace: ClosedRange<Double> = 130...165

    /// Filler wherever it appears. These words have no other job.
    static let fillerWords = [
        "um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm",
    ]

    /// Filler only at the start of a sentence.
    ///
    /// Split out after a test caught the obvious version marking "the **right**
    /// call" as filler. Every word here is a real filler in one position and an
    /// ordinary word in every other: "so" opening a sentence is a verbal throat
    /// clear, "so that the index is used" is a conjunction doing its job.
    /// Counting them everywhere reports a problem the speaker does not have,
    /// and advice aimed at the wrong thing is worse than none.
    static let openingFillers = [
        "so", "right", "okay", "yeah", "well", "now",
        "basically", "actually", "literally", "obviously", "essentially",
    ]

    /// Stands in for a phrase already counted, so the run detection still
    /// sees a filler where it was. Not a word anyone says.
    static let marker = "\u{00B7}filler\u{00B7}"

    static let fillerPhrases = [
        "you know", "i mean", "sort of", "kind of", "you see",
        "and stuff", "or something", "and all",
    ]

    /// Endings that leave the listener unsure whether you have finished.
    static let trailingEndings = [
        "so yeah", "yeah so", "something like that", "or something",
        "and stuff", "or whatever", "that's it i guess", "i guess",
        "you know", "and so on", "etc",
    ]

    // MARK: - Building

    init(segments: [SpokenSegment], duration: TimeInterval) {
        self.duration = duration

        let text = segments.map(\.text).joined(separator: " ")
        let normalised = Self.normalise(text)
        let words = normalised.split(separator: " ").map(String.init)
        wordCount = words.count
        pace = duration > 0 ? Double(words.count) / duration * 60 : 0

        // Counted per sentence, because position decides whether half of
        // these are filler at all.
        //
        // The rule: an unambiguous filler counts anywhere. A positional one
        // counts if it opens the sentence, or if it follows another filler --
        // "um, so basically" is one hesitation with three words in it, and
        // stopping at the "um" would report a third of what the listener heard.
        var counts: [String: Int] = [:]
        for sentence in Self.sentences(in: text) {
            var working = Self.normalise(sentence)

            // Phrases first, replaced by a marker rather than deleted, so the
            // run detection below still sees a filler in that position.
            for phrase in Self.fillerPhrases {
                let hits = Self.occurrences(of: phrase, in: working)
                guard hits > 0 else { continue }
                counts[phrase, default: 0] += hits
                working = working.replacingOccurrences(of: phrase,
                                                       with: " \(Self.marker) ")
            }

            var previousWasFiller = false
            for (index, token) in working.split(separator: " ")
                .map(String.init).enumerated() {
                if token == Self.marker {
                    previousWasFiller = true
                    continue
                }
                if Self.fillerWords.contains(token) {
                    counts[token, default: 0] += 1
                    previousWasFiller = true
                } else if Self.openingFillers.contains(token),
                          index == 0 || previousWasFiller {
                    counts[token, default: 0] += 1
                    previousWasFiller = true
                } else {
                    previousWasFiller = false
                }
            }
        }
        fillers = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (word: $0.key, count: $0.value) }
        fillerTotal = counts.values.reduce(0, +)

        // The gap *between* segments, not their own length. whisper ends a
        // segment where the speech stops, so the space to the next one is the
        // silence.
        var pauses: [(at: TimeInterval, length: TimeInterval)] = []
        for (previous, next) in zip(segments, segments.dropFirst()) {
            let gap = next.start - previous.end
            if gap >= Self.pauseThreshold {
                pauses.append((at: previous.end, length: gap))
            }
        }
        longPauses = pauses

        longestSentence = Self.sentences(in: text)
            .map { $0.split(separator: " ").count }
            .max() ?? 0

        let tail = normalised.split(separator: " ").suffix(4).joined(separator: " ")
        trailsOff = Self.trailingEndings.contains { tail.hasSuffix($0) }
    }

    // MARK: - Text handling

    /// Lowercased, punctuation gone, single-spaced.
    ///
    /// Filler matching has to survive "Um," and "um." being the same word, and
    /// a phrase match has to survive a comma landing inside it.
    static func normalise(_ text: String) -> String {
        let stripped = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "'" ? character : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Verdicts

    var paceVerdict: String {
        switch pace {
        case ..<110: return "too slow -- you sound unsure"
        case 110..<Self.comfortablePace.lowerBound: return "a little slow"
        case Self.comfortablePace: return "good"
        case Self.comfortablePace.upperBound...185: return "a little fast"
        default: return "rushing -- the listener stops retaining detail"
        }
    }

    /// Fillers per minute, which is comparable across takes of different length.
    var fillerRate: Double {
        duration > 0 ? Double(fillerTotal) / duration * 60 : 0
    }

    var fillerVerdict: String {
        switch fillerRate {
        case ..<3: return "clean"
        case 3..<6: return "noticeable"
        default: return "distracting"
        }
    }
}

import Foundation

/// How much is wrong with a piece of writing, as a number.
///
/// For someone who cannot yet judge their own English, "looks good" and "here
/// is a rewrite" are both unsatisfying: one says nothing and the other hands
/// over an answer without saying what was wrong with the question. A count
/// says where you are, and changes as you improve.
///
/// Counted by Harper rather than judged by the model, deliberately. Harper is
/// deterministic, answers in about 30ms, and every point it takes off is an
/// underline you can click to see the rule. A model's score for the same
/// sentence moves between runs and cannot be pointed at.
///
/// The limit is honest and worth stating: this counts grammar, spelling and
/// punctuation. It says nothing about whether the sentence sounds natural,
/// which is what `RewriteMode.native` is for.
struct WritingScore: Equatable {
    let issues: Int
    let words: Int

    /// Errors per hundred words, which is what makes two pieces of writing
    /// comparable. Three mistakes in a tweet and three in an essay are not the
    /// same standard.
    var rate: Double {
        guard words > 0 else { return 0 }
        return Double(issues) * 100 / Double(words)
    }

    /// What the bar shows.
    ///
    /// The count first, because that is the fact; the rate second, because it
    /// is the comparison. Below twenty words the rate is not reported at all:
    /// one mistake in six words is "17 per 100", which sounds like a verdict on
    /// the writing rather than on one short sentence.
    var summary: String {
        guard words > 0 else { return "" }
        guard issues > 0 else { return "no mistakes in \(words) words" }

        let plural = issues == 1 ? "mistake" : "mistakes"
        guard words >= Self.minimumWordsForRate else {
            return "\(issues) \(plural)"
        }
        return "\(issues) \(plural) · \(formatted(rate)) per 100 words"
    }

    /// Short enough for the menu bar or a cramped row.
    var compact: String {
        guard words > 0 else { return "" }
        return issues == 0 ? "clean" : "\(issues)"
    }

    /// Below this, a rate is arithmetic rather than information.
    static let minimumWordsForRate = 20

    /// Where the writing sits, for colouring the number.
    ///
    /// The thresholds are stated rather than tuned: under 2 per 100 is roughly
    /// a clean piece of writing, over 8 is one worth a second pass. They exist
    /// to colour a label, not to grade anyone.
    enum Standing {
        case clean, few, many
    }

    var standing: Standing {
        if issues == 0 { return .clean }
        if words < Self.minimumWordsForRate { return issues <= 1 ? .few : .many }
        return rate < 8 ? .few : .many
    }

    /// Words, counted the way a person would: runs of non-space.
    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    init(issues: Int, words: Int) {
        self.issues = max(0, issues)
        self.words = max(0, words)
    }

    init(suggestions: [Suggestion], text: String) {
        self.init(issues: suggestions.count, words: Self.wordCount(of: text))
    }

    private func formatted(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
}

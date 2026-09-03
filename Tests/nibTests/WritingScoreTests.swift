import XCTest
@testable import nib

/// The number shown against a selection.
///
/// It exists for someone who cannot yet judge their own English, so the two
/// things that matter are that it is honest about what it counts and that it
/// never reads as a verdict on the writer.
final class WritingScoreTests: XCTestCase {
    func testCleanWritingSaysSo() {
        let score = WritingScore(issues: 0, words: 40)
        XCTAssertEqual(score.summary, "no mistakes in 40 words")
        XCTAssertEqual(score.standing, .clean)
    }

    func testTheRateIsPerHundredWords() {
        XCTAssertEqual(WritingScore(issues: 5, words: 100).rate, 5, accuracy: 0.001)
        XCTAssertEqual(WritingScore(issues: 5, words: 50).rate, 10, accuracy: 0.001)
        XCTAssertEqual(WritingScore(issues: 3, words: 200).rate, 1.5, accuracy: 0.001)
    }

    /// Three mistakes in a tweet and three in an essay are not the same
    /// standard, which is the whole reason for a rate.
    func testTheSameCountRatesDifferentlyByLength() {
        let short = WritingScore(issues: 3, words: 30)
        let long = WritingScore(issues: 3, words: 300)
        XCTAssertGreaterThan(short.rate, long.rate)
        XCTAssertEqual(short.standing, .many)
        XCTAssertEqual(long.standing, .few)
    }

    /// One mistake in six words is "17 per 100", which sounds like a judgement
    /// on the writer rather than on one short sentence.
    func testShortTextGetsNoRate() {
        let score = WritingScore(issues: 1, words: 6)
        XCTAssertEqual(score.summary, "1 mistake")
        XCTAssertFalse(score.summary.contains("per 100"))
    }

    func testLongerTextGetsTheRate() {
        let score = WritingScore(issues: 2, words: 40)
        XCTAssertTrue(score.summary.contains("2 mistakes"))
        XCTAssertTrue(score.summary.contains("per 100 words"))
    }

    func testOneMistakeIsSingular() {
        XCTAssertTrue(WritingScore(issues: 1, words: 50).summary.hasPrefix("1 mistake ·"))
        XCTAssertTrue(WritingScore(issues: 2, words: 50).summary.hasPrefix("2 mistakes"))
    }

    /// Empty input has no score rather than a perfect one. "No mistakes in 0
    /// words" is true and useless, and green on an empty field reads as praise.
    func testEmptyTextHasNoSummary() {
        XCTAssertEqual(WritingScore(issues: 0, words: 0).summary, "")
        XCTAssertEqual(WritingScore(issues: 0, words: 0).compact, "")
        XCTAssertEqual(WritingScore(issues: 0, words: 0).rate, 0)
    }

    func testWordsAreCountedAsRunsOfNonSpace() {
        XCTAssertEqual(WritingScore.wordCount(of: "the quick brown fox"), 4)
        XCTAssertEqual(WritingScore.wordCount(of: "  spaced   out  "), 2)
        XCTAssertEqual(WritingScore.wordCount(of: "line one\nline two"), 4)
        XCTAssertEqual(WritingScore.wordCount(of: ""), 0)
    }

    func testItIsBuiltFromHarpersSuggestions()  {
        let found = [
            Suggestion(range: NSRange(location: 0, length: 5), message: "a",
                       replacements: ["A"]),
            Suggestion(range: NSRange(location: 6, length: 3), message: "b",
                       replacements: ["B"]),
        ]
        let score = WritingScore(suggestions: found, text: "the quick brown fox")
        XCTAssertEqual(score.issues, 2)
        XCTAssertEqual(score.words, 4)
    }

    /// Negative counts cannot happen, and a score that trusted them would show
    /// "-1 mistakes".
    func testNegativeInputIsClamped() {
        XCTAssertEqual(WritingScore(issues: -3, words: -9).issues, 0)
        XCTAssertEqual(WritingScore(issues: -3, words: -9).words, 0)
    }

    /// Colour is the first thing read, so each standing must be distinct.
    func testEachStandingHasItsOwnColour() {
        let colours = [WritingScore.Standing.clean, .few, .many]
            .map(SelectionBar.colour(for:))
        XCTAssertEqual(Set(colours).count, 3)
    }
}

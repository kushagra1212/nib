import XCTest
@testable import nib

/// A clarity mark spans a whole sentence, so a wrong range here underlines
/// across a sentence boundary or leaves a trailing space highlighted.
final class SentenceSplitterTests: XCTestCase {
    private func split(_ text: String, minimumWords: Int = 5)
        -> [SentenceSplitter.Sentence] {
        SentenceSplitter.sentences(in: text, minimumWords: minimumWords)
    }

    func testSingleSentence() {
        let result = split("The quick brown fox jumps over the dog.")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "The quick brown fox jumps over the dog.")
        XCTAssertEqual(result[0].range.location, 0)
    }

    func testTwoSentencesGetSeparateRanges() {
        let text = "The quick brown fox jumps over it. Another long sentence follows here."
        let result = split(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].range.location, 0)
        XCTAssertTrue(result[1].range.location > NSMaxRange(result[0].range) - 1)
    }

    func testRangesExcludeTrailingWhitespace() {
        let text = "The quick brown fox jumps here.    Second long sentence goes here."
        let result = split(text)
        let first = (text as NSString).substring(with: result[0].range)
        XCTAssertFalse(first.hasSuffix(" "), "got: \(first.debugDescription)")
    }

    func testRangesMapBackToTheOriginal() {
        let text = "The quick brown fox jumps. Another sentence lives right here."
        for sentence in split(text) {
            XCTAssertEqual((text as NSString).substring(with: sentence.range),
                           sentence.text)
        }
    }

    func testShortFragmentsAreSkipped() {
        // "Thanks!" is not worth a clarity mark.
        XCTAssertTrue(split("Thanks!").isEmpty)
        XCTAssertTrue(split("Yes. No. Maybe.").isEmpty)
    }

    func testMinimumWordsIsRespected() {
        let text = "One two three."
        XCTAssertTrue(split(text, minimumWords: 5).isEmpty)
        XCTAssertEqual(split(text, minimumWords: 3).count, 1)
    }

    func testAbbreviationsDoNotSplitTheSentence() {
        let text = "We tested e.g. the login flow and it worked well."
        let result = split(text)
        XCTAssertEqual(result.count, 1, "got: \(result.map(\.text))")
    }

    func testDecimalsDoNotSplitTheSentence() {
        let text = "The build takes 3.5 minutes on this machine now."
        XCTAssertEqual(split(text).count, 1)
    }

    func testDottedIdentifiersDoNotSplitTheSentence() {
        let text = "We should check NSString.length before we index into it."
        XCTAssertEqual(split(text).count, 1)
    }

    func testEmptyText() {
        XCTAssertTrue(split("").isEmpty)
        XCTAssertTrue(split("    \n  ").isEmpty)
    }

    func testTextWithoutTerminatingPunctuation() {
        let result = split("this is a sentence without a full stop")
        XCTAssertEqual(result.count, 1)
    }

    func testRangesAreCorrectAfterAnEmoji() {
        let text = "😀 The quick brown fox jumps over it."
        let result = split(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual((text as NSString).substring(with: result[0].range),
                       result[0].text)
    }

    func testNewlineSeparatedSentences() {
        let text = "The first sentence lives here.\nThe second one lives here."
        XCTAssertEqual(split(text).count, 2)
    }
}

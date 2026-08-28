import XCTest
@testable import nib

/// Covers combining harper's word-level marks with the model's.
///
/// The reported bug: precise error marks vanished and a band appeared across
/// the line. A sentence-level rewrite diffs into one wide span, and that span
/// was replacing several exact words.
@MainActor
final class MergeTests: XCTestCase {
    private func suggestion(_ text: String, _ word: String,
                            kind: SuggestionKind = .correction) -> Suggestion {
        Suggestion(kind: kind, range: (text as NSString).range(of: word),
                   message: "m", replacements: ["x"])
    }

    func testHarperMarksSurvive() {
        let text = "Their is many erors here"
        let harper = [suggestion(text, "Their"), suggestion(text, "erors")]
        let model = [suggestion(text, "Their is many erors")]

        let merged = LiveChecker.merge(harper: harper, model: model, in: text)
        XCTAssertEqual(merged.compactMap { $0.excerpt(in: text) }, ["Their", "erors"])
    }

    func testWideModelSpanIsRejected() {
        // Five words is a rewrite of the phrase, not a fix to a word, and
        // marking it as an error claims a certainty the model does not have.
        let text = "one two three four five six"
        let model = [suggestion(text, "one two three four five")]
        XCTAssertTrue(LiveChecker.merge(harper: [], model: model, in: text).isEmpty)
    }

    func testNarrowModelSpanIsAccepted() {
        let text = "it could of worked"
        let model = [suggestion(text, "could of")]
        XCTAssertEqual(LiveChecker.merge(harper: [], model: model, in: text).count, 1)
    }

    func testModelFillsWhatHarperMissed() {
        let text = "Their is many erors here"
        let harper = [suggestion(text, "Their")]
        let model = [suggestion(text, "erors")]

        let merged = LiveChecker.merge(harper: harper, model: model, in: text)
        XCTAssertEqual(merged.compactMap { $0.excerpt(in: text) }, ["Their", "erors"])
    }

    func testOverlappingModelSpanIsDropped() {
        // Harper's range is tighter, so it wins where the two disagree.
        let text = "Their is many here"
        let harper = [suggestion(text, "Their")]
        let model = [suggestion(text, "Their is")]

        let merged = LiveChecker.merge(harper: harper, model: model, in: text)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].excerpt(in: text), "Their")
    }

    func testResultIsOrderedByPosition() {
        let text = "alpha beta gamma delta"
        let harper = [suggestion(text, "gamma")]
        let model = [suggestion(text, "alpha"), suggestion(text, "delta")]

        let merged = LiveChecker.merge(harper: harper, model: model, in: text)
        XCTAssertEqual(merged.compactMap { $0.excerpt(in: text) },
                       ["alpha", "gamma", "delta"])
    }

    func testEmptyModelKeepsHarperUntouched() {
        let text = "Their is here"
        let harper = [suggestion(text, "Their")]
        XCTAssertEqual(
            LiveChecker.merge(harper: harper, model: [], in: text).count, 1)
    }

    func testEmptyHarperKeepsNarrowModelResults() {
        let text = "it could of worked"
        let model = [suggestion(text, "could of")]
        XCTAssertEqual(
            LiveChecker.merge(harper: [], model: model, in: text).count, 1)
    }

    func testBothEmpty() {
        XCTAssertTrue(LiveChecker.merge(harper: [], model: [], in: "text").isEmpty)
    }

    func testSpanAtExactlyTheWordLimitIsKept() {
        let text = "one two three four five"
        let model = [suggestion(text, "one two three four")]
        XCTAssertEqual(LiveChecker.merge(harper: [], model: model, in: text).count, 1)
    }
}

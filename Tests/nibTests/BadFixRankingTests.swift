import XCTest
@testable import nib

/// Fixes that were offered for real words, and the order they arrive in.
final class BadFixRankingTests: XCTestCase {
    private func suggestion(_ text: String, _ token: String,
                            _ message: String, _ replacements: [String]) -> Suggestion {
        Suggestion(range: (text as NSString).range(of: token),
                   message: message, replacements: replacements)
    }

    // MARK: - Capitalisation is a correction

    /// "chatgpt" was offered "catgut". Harper's own message names `ChatGPT` as
    /// the fix, but comparing lowercased made "chatgpt" and "ChatGPT" look
    /// identical, so the right answer was discarded as "no change" and the
    /// junk second choice was all that survived.
    func testCapitalisationFixIsOffered() {
        XCTAssertTrue(
            SuggestionFilter.isPlausibleCorrection(from: "chatgpt", to: "ChatGPT"))
        XCTAssertTrue(
            SuggestionFilter.isPlausibleCorrection(from: "i", to: "I"))
        XCTAssertTrue(
            SuggestionFilter.isPlausibleCorrection(from: "iphone", to: "iPhone"))
    }

    func testIdenticalTextIsStillNoCorrection() {
        XCTAssertFalse(
            SuggestionFilter.isPlausibleCorrection(from: "ChatGPT", to: "ChatGPT"))
    }

    func testCapitalisationFixLeadsTheList() {
        let text = "I found the chatgpt issue"
        let refined = SuggestionFilter.refine(
            suggestion(text, "chatgpt",
                       "The canonical dictionary spelling is `ChatGPT`.",
                       ["ChatGPT", "catgut"]),
            in: text)
        XCTAssertEqual(refined?.replacements.first, "ChatGPT")
    }

    // MARK: - Splitting a word is a last resort

    /// "wheather" was offered "wheat her" ahead of "weather". Splitting a word
    /// in two is right often enough to keep -- "cannotbe" is "cannot be" --
    /// but it is a strange thing to do to one misspelled word.
    func testOneWordFixOutranksASplit() {
        XCTAssertEqual(
            SuggestionFilter.rank(["wheat her", "weather", "whether"],
                                  for: "wheather"),
            ["weather", "whether", "wheat her"])
    }

    func testSplitSurvivesWhenNothingElseDoes() {
        XCTAssertEqual(
            SuggestionFilter.rank(["cannot be"], for: "cannotbe"), ["cannot be"])
    }

    /// Harper's own order decides between fixes of the same shape.
    func testRankingIsStableWithinAGroup() {
        XCTAssertEqual(
            SuggestionFilter.rank(["optical", "optimal"], for: "optioaa"),
            ["optical", "optimal"])
    }

    func testJoiningIsRankedTheSameWay() {
        // The original is two words here, so the two-word fix leads.
        XCTAssertEqual(
            SuggestionFilter.rank(["alongside", "along sides"], for: "along side"),
            ["along sides", "alongside"])
    }
}

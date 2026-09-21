import XCTest
@testable import nib

/// Bad suggestions reported from real use, each with the good corrections of
/// the same shape that must keep working.
final class BadFixTests: XCTestCase {
    private func plausible(_ from: String, _ to: String) -> Bool {
        SuggestionFilter.isPlausibleCorrection(from: from, to: to)
    }

    // MARK: - invented possessives

    func testProperNounIsNotTurnedIntoAPossessive() {
        XCTAssertFalse(plausible("Frontmost", "Front's"))
    }

    func testWordIsNotTurnedIntoAContraction() {
        // The letters change, so this is a different word wearing an
        // apostrophe rather than a missing one being added.
        XCTAssertFalse(plausible("cannot", "can't"))
        XCTAssertFalse(plausible("Frontmost", "Front's"))
    }

    func testAddingAMissingPossessiveIsAllowed() {
        // "wells" to "well's" leaves every letter in place, so the apostrophe
        // is the entire change and this is a real suggestion.
        XCTAssertTrue(plausible("wells", "well's"))
    }

    func testRealApostropheFixesSurvive() {
        // The letters are unchanged, so the apostrophe is the whole fix.
        XCTAssertTrue(plausible("its", "it's"))
        XCTAssertTrue(plausible("dont", "don't"))
        XCTAssertTrue(plausible("wont", "won't"))
        XCTAssertTrue(plausible("theyre", "they're"))
    }

    func testApostropheInBothIsNotAffected() {
        XCTAssertTrue(plausible("it's", "its'") || !plausible("it's", "its'"),
                      "either answer is fine; this must not crash or throw")
    }

    func testInventsPossessiveDirectly() {
        XCTAssertTrue(SuggestionFilter.inventsPossessive(from: "frontmost", to: "front's"))
        XCTAssertFalse(SuggestionFilter.inventsPossessive(from: "its", to: "it's"))
        XCTAssertFalse(SuggestionFilter.inventsPossessive(from: "cat", to: "hat"))
    }

    // MARK: - replacements that pad rather than correct

    func testExpansionIntoExtraWordsIsRejected() {
        XCTAssertFalse(plausible("both needing", "both pieces of needing"))
    }

    func testLongExpansionIsRejected() {
        XCTAssertFalse(plausible("data", "pieces of data information"))
    }

    func testOneExtraWordIsAllowed() {
        // Splitting a run-together word is a real fix.
        XCTAssertTrue(plausible("cannotbe", "cannot be"))
    }

    func testJoiningWordsIsAllowed() {
        XCTAssertTrue(plausible("t he", "the"))
        XCTAssertTrue(plausible("along side", "alongside"))
    }

    func testSameLengthPhraseFixIsAllowed() {
        XCTAssertTrue(plausible("could of", "could have"))
        XCTAssertTrue(plausible("would of", "would have"))
    }

    func testAddsWordsDirectly() {
        XCTAssertTrue(SuggestionFilter.addsWords(from: "both needing",
                                                 to: "both pieces of needing"))
        XCTAssertFalse(SuggestionFilter.addsWords(from: "could of", to: "could have"))
        XCTAssertFalse(SuggestionFilter.addsWords(from: "teh", to: "the"))
        XCTAssertFalse(SuggestionFilter.addsWords(from: "cannotbe", to: "cannot be"))
    }

    // MARK: - the corrections that matter must still survive

    func testOrdinaryMisspellingsAreKept() {
        XCTAssertTrue(plausible("erors", "errors"))
        XCTAssertTrue(plausible("sentance", "sentence"))
        XCTAssertTrue(plausible("recieve", "receive"))
        XCTAssertTrue(plausible("their", "there"))
        XCTAssertTrue(plausible("a", "an"))
    }

    // MARK: - end to end through the filter

    func testBadSuggestionsAreFilteredOut() {
        let text = "Diagnose Frontmost App and both needing you"
        let bad = [
            Suggestion(range: (text as NSString).range(of: "Frontmost"),
                       message: "spelling", replacements: ["Front's"]),
            Suggestion(range: (text as NSString).range(of: "both needing"),
                       message: "mass noun", replacements: ["both pieces of needing"]),
        ]
        XCTAssertTrue(SuggestionFilter.apply(bad, in: text).isEmpty)
    }

    func testGoodSuggestionSurvivesTheFilter() {
        let text = "many erors here"
        let good = [Suggestion(range: (text as NSString).range(of: "erors"),
                               message: "spelling", replacements: ["errors"])]
        XCTAssertEqual(SuggestionFilter.apply(good, in: text).count, 1)
    }
}

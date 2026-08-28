import XCTest
@testable import nib

/// Every case reported from real use is here as a named test, alongside the
/// good corrections that must survive. The filter is worthless if it silences
/// the errors you actually want caught.
final class SuggestionFilterTests: XCTestCase {
    private func suggestion(_ text: String, _ token: String,
                            _ replacement: String) -> Suggestion {
        let range = (text as NSString).range(of: token)
        return Suggestion(range: range, message: "Did you mean to spell `\(token)` this way?",
                          replacements: [replacement])
    }

    private func kept(_ text: String, _ token: String, _ replacement: String) -> Bool {
        SuggestionFilter.keep(suggestion(text, token, replacement), in: text)
    }

    // MARK: - Reported damage

    func testAcronymIsNotCorrected() {
        XCTAssertFalse(kept("UTF-16 traps are covered", "UTF", "Uhf"))
    }

    func testTypeNameIsNotCorrected() {
        XCTAssertFalse(kept("NSString length vs Swift", "NSString", "Nesting"))
    }

    func testProductNameIsNotCorrected() {
        XCTAssertFalse(kept("how the chat gpt corrects", "gpt", "get"))
    }

    func testReplacementThatChangesMeaningIsRejected() {
        XCTAssertFalse(kept("this kind of bugs and how", "bugs", "thing"))
    }

    func testShortAcronymIsNotCorrected() {
        XCTAssertFalse(kept("looking for bugs (RN 86)", "RN", "RUN"))
    }

    func testZWJAcronymIsNotCorrected() {
        XCTAssertFalse(kept("ZWJ family sequences", "ZWJ", "ZW"))
    }

    // MARK: - Real corrections must survive

    func testTheirToThereIsKept() {
        XCTAssertTrue(kept("Their is many errors", "Their", "There"))
    }

    func testMisspellingIsKept() {
        XCTAssertTrue(kept("many erors here", "erors", "errors"))
    }

    func testLongerMisspellingIsKept() {
        XCTAssertTrue(kept("this sentance is wrong", "sentance", "sentence"))
    }

    func testIndefiniteArticleIsKept() {
        XCTAssertTrue(kept("a erors here", "a", "an"))
    }

    func testCouldOfIsKept() {
        XCTAssertTrue(kept("could of been shorter", "could of", "could have"))
    }

    func testCapitalisedOrdinaryWordIsKept() {
        // Sentence-initial capitals are not camelCase.
        XCTAssertTrue(kept("Recieve the parcel", "Recieve", "Receive"))
    }

    // MARK: - looksLikeCode

    func testDigitsMarkCode() {
        XCTAssertTrue(SuggestionFilter.looksLikeCode("UTF16"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("h264"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("rn86"))
    }

    func testUnderscoreAndDotMarkCode() {
        XCTAssertTrue(SuggestionFilter.looksLikeCode("snake_case"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("NSString.length"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("a/b"))
    }

    func testMedialCapitalsMarkCode() {
        XCTAssertTrue(SuggestionFilter.looksLikeCode("NSString"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("didApply"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("iOS"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("TextEdit"))
    }

    func testAllCapsMarksCode() {
        XCTAssertTrue(SuggestionFilter.looksLikeCode("API"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("AX"))
    }

    func testSingleCapitalIsNotCode() {
        // "I" is a word, not an acronym.
        XCTAssertFalse(SuggestionFilter.looksLikeCode("I"))
    }

    func testOrdinaryWordsAreNotCode() {
        XCTAssertFalse(SuggestionFilter.looksLikeCode("their"))
        XCTAssertFalse(SuggestionFilter.looksLikeCode("Their"))
        XCTAssertFalse(SuggestionFilter.looksLikeCode("sentance"))
    }

    func testEmptyTokenIsTreatedAsCode() {
        XCTAssertTrue(SuggestionFilter.looksLikeCode(""))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("   "))
    }

    // MARK: - surrounding context

    func testWordAfterADotIsSkipped() {
        // "length" is a word, until you see NSString.length.
        XCTAssertFalse(kept("NSString.length vs Swift", "length", "lengths"))
    }

    func testWordBeforeADotIsSkipped() {
        XCTAssertFalse(kept("teh.property here", "teh", "the"))
    }

    func testWordInsideBackticksIsSkipped() {
        XCTAssertFalse(kept("the `erors` constant", "erors", "errors"))
    }

    func testWordAfterClosedBackticksIsChecked() {
        XCTAssertTrue(kept("`code` and erors here", "erors", "errors"))
    }

    func testOrdinaryWordAfterAFullStopIsStillSkipped() {
        // Accepted cost: a sentence-initial word preceded by "." is skipped.
        // Losing one correction beats corrupting an identifier.
        XCTAssertFalse(kept("Done.teh cat", "teh", "the"))
    }

    // MARK: - plausibility

    func testNearMissIsPlausible() {
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "erors", to: "errors"))
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "their", to: "there"))
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "a", to: "an"))
    }

    func testDifferentWordIsNotPlausible() {
        XCTAssertFalse(SuggestionFilter.isPlausibleCorrection(from: "bugs", to: "thing"))
        XCTAssertFalse(SuggestionFilter.isPlausibleCorrection(from: "cat", to: "house"))
    }

    func testEditDistanceAloneCannotRejectGptToGet() {
        // One substitution, so it reads as an ordinary correction. The vowel
        // rule is what rejects it, not plausibility.
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "gpt", to: "get"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("gpt"))
    }

    func testVowellessTokensAreAbbreviations() {
        XCTAssertTrue(SuggestionFilter.looksLikeCode("npm"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("ssh"))
        XCTAssertTrue(SuggestionFilter.looksLikeCode("jwt"))
    }

    func testSingleLetterWordsAreNotAbbreviations() {
        XCTAssertFalse(SuggestionFilter.looksLikeCode("a"))
    }

    func testWordsWithYAsTheOnlyVowelAreWords() {
        XCTAssertFalse(SuggestionFilter.looksLikeCode("myth"))
        XCTAssertFalse(SuggestionFilter.looksLikeCode("try"))
    }

    func testIdenticalIsRejected() {
        XCTAssertFalse(SuggestionFilter.isPlausibleCorrection(from: "word", to: "word"))
        XCTAssertFalse(SuggestionFilter.isPlausibleCorrection(from: "Word", to: "word"),
                       "case-only changes are handled by other linters")
    }

    func testEditDistance() {
        XCTAssertEqual(SuggestionFilter.editDistance("", ""), 0)
        XCTAssertEqual(SuggestionFilter.editDistance("abc", ""), 3)
        XCTAssertEqual(SuggestionFilter.editDistance("", "abc"), 3)
        XCTAssertEqual(SuggestionFilter.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(SuggestionFilter.editDistance("erors", "errors"), 1)
        XCTAssertEqual(SuggestionFilter.editDistance("their", "there"), 2)
    }

    // MARK: - advisory lints

    func testAdvisoryLintWithNoReplacementSurvives() {
        let text = "This sentence is long."
        let advisory = Suggestion(range: (text as NSString).range(of: "sentence"),
                                  message: "Consider rewording.", replacements: [])
        XCTAssertTrue(SuggestionFilter.keep(advisory, in: text))
    }

    func testAdvisoryLintOnCodeIsStillDropped() {
        let text = "The NSString is long."
        let advisory = Suggestion(range: (text as NSString).range(of: "NSString"),
                                  message: "Consider rewording.", replacements: [])
        XCTAssertFalse(SuggestionFilter.keep(advisory, in: text))
    }

    // MARK: - batch

    /// `Their` sits at the start, which is where it sits in the sentence this
    /// case came from: "Their is many erors". It used to sit mid-text, which
    /// asked the filter to accept a spelling lint on a capitalised word in the
    /// middle of a sentence -- the shape of a name, and something Harper does
    /// not emit for a word it knows.
    func testApplyKeepsOnlyTheGoodOnes() {
        let text = "Their erors and UTF-16"
        let all = [
            suggestion(text, "UTF", "Uhf"),
            suggestion(text, "Their", "There"),
            suggestion(text, "erors", "errors"),
        ]
        let kept = SuggestionFilter.apply(all, in: text)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.compactMap { $0.excerpt(in: text) }.sorted(),
                       ["Their", "erors"])
    }

    /// A grammar lint carries a different message from a spelling one, and the
    /// name guard must not touch it: "their" is in the dictionary, so a
    /// capital mid-sentence says nothing about whether it is a name.
    func testGrammarLintOnACapitalisedKnownWordIsKept() {
        let text = "I think Their is a problem"
        let range = (text as NSString).range(of: "Their")
        let grammar = Suggestion(range: range,
                                 message: "Use `There` to refer to a place.",
                                 replacements: ["There"])
        XCTAssertTrue(SuggestionFilter.keep(grammar, in: text))
    }

    func testOutOfBoundsSuggestionIsDropped() {
        let bogus = Suggestion(range: NSRange(location: 500, length: 3),
                               message: "m", replacements: ["x"])
        XCTAssertFalse(SuggestionFilter.keep(bogus, in: "short"))
    }
}

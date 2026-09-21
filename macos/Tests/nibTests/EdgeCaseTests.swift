import XCTest
@testable import nib

/// Cases found by auditing the paths that had no coverage, rather than by
/// reproducing a report. Several of these were real defects.
final class EdgeCaseTests: XCTestCase {

    // MARK: - fields nib must never read

    func testPasswordFieldIsRefused() {
        // A password field is an ordinary AXTextField wearing a secure
        // subrole, so checking the role alone reads passwords.
        XCTAssertFalse(FieldEligibility.mayRead(
            role: kAXTextFieldRole,
            subrole: kAXSecureTextFieldSubrole as String,
            label: nil))
    }

    func testOrdinaryTextFieldIsAllowed() {
        XCTAssertTrue(FieldEligibility.mayRead(
            role: kAXTextFieldRole, subrole: nil, label: nil))
    }

    func testTextAreaIsAllowed() {
        XCTAssertTrue(FieldEligibility.mayRead(
            role: kAXTextAreaRole, subrole: nil, label: nil))
    }

    func testNonTextRolesAreRefused() {
        for role in [kAXButtonRole, kAXStaticTextRole, kAXImageRole, kAXMenuRole] {
            XCTAssertFalse(FieldEligibility.mayRead(role: role, subrole: nil, label: nil),
                           "\(role) should not be read")
        }
    }

    func testMissingRoleIsRefused() {
        XCTAssertFalse(FieldEligibility.mayRead(role: nil, subrole: nil, label: nil))
    }

    func testFieldsLabelledAsSecretsAreRefused() {
        // Web and Electron password inputs often expose no subrole, leaving
        // the label as the only signal.
        let labels = ["Password", "Enter your passphrase", "API Key",
                      "Card number", "CVV", "One-time code (OTP)",
                      "Client secret", "Private key", "PIN"]
        for label in labels {
            XCTAssertFalse(
                FieldEligibility.mayRead(role: kAXTextFieldRole, subrole: nil, label: label),
                "\(label) should not be read")
        }
    }

    func testSecretDetectionIsCaseInsensitive() {
        XCTAssertTrue(FieldEligibility.mentionsSecret("PASSWORD"))
        XCTAssertTrue(FieldEligibility.mentionsSecret("Your Api Key here"))
    }

    func testOrdinaryLabelsAreAllowed() {
        for label in ["Message", "Subject", "Search", "Notes", "Comment",
                      "Compose your reply"] {
            XCTAssertTrue(
                FieldEligibility.mayRead(role: kAXTextAreaRole, subrole: nil, label: label),
                "\(label) should be readable")
        }
    }

    func testUnknownSubroleOnATextFieldIsAllowed() {
        XCTAssertTrue(FieldEligibility.mayRead(
            role: kAXTextFieldRole, subrole: "AXSearchField", label: nil))
    }

    // MARK: - punctuation-only changes

    func testAddingACommaProducesASuggestion() {
        // Words are identical, so the word diff sees nothing; without the
        // character fallback a missing comma was silently invisible.
        let edits = WordDiff.edits(from: "However it worked", to: "However, it worked")
        XCTAssertEqual(edits.count, 1)
        XCTAssertTrue(edits[0].replacement.contains(","), edits[0].replacement)
    }

    func testAddingAnApostropheProducesASuggestion() {
        let edits = WordDiff.edits(from: "its raining", to: "it's raining")
        XCTAssertEqual(edits.count, 1)
    }

    func testChangingAFullStopToAQuestionMark() {
        let edits = WordDiff.edits(from: "are you sure.", to: "are you sure?")
        XCTAssertEqual(edits.count, 1)
    }

    func testIdenticalTextStillProducesNothing() {
        XCTAssertTrue(WordDiff.edits(from: "no change here", to: "no change here").isEmpty)
    }

    func testPunctuationEditAppliesCleanly() {
        let original = "However it worked"
        let edits = WordDiff.edits(from: original, to: "However, it worked")
        XCTAssertEqual(EditPlanner.apply(edits[0], to: original), "However, it worked")
    }

    func testWhitespaceOnlyChangeIsHandled() {
        let original = "double  space"
        let edits = WordDiff.edits(from: original, to: "double space")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(EditPlanner.apply(edits[0], to: original), "double space")
    }

    // MARK: - unusual text

    func testTabsAndNewlinesSeparateWords() {
        XCTAssertEqual(WordDiff.tokenize("one\ttwo\nthree").map(\.text),
                       ["one", "two", "three"])
    }

    func testVeryLongSingleWord() {
        let long = String(repeating: "a", count: 5000)
        let tokens = WordDiff.tokenize(long)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].range.length, 5000)
    }

    func testTextOfOnlyPunctuation() {
        XCTAssertTrue(WordDiff.tokenize("!!! ... ???").isEmpty)
        XCTAssertTrue(WordDiff.edits(from: "!!!", to: "!!!").isEmpty)
    }

    func testAccentedWordsAreSingleTokens() {
        XCTAssertEqual(WordDiff.tokenize("café naïve résumé").map(\.text),
                       ["café", "naïve", "résumé"])
    }

    func testNonLatinScriptIsTokenised() {
        // Devanagari: letters, so they form word tokens rather than vanishing.
        XCTAssertEqual(WordDiff.tokenize("नमस्ते दुनिया").count, 2)
    }

    func testRightToLeftTextIsTokenised() {
        XCTAssertEqual(WordDiff.tokenize("مرحبا بالعالم").count, 2)
    }

    func testEmojiOnlyTextHasNoWords() {
        XCTAssertTrue(WordDiff.tokenize("😀 🎉 🚀").isEmpty)
    }

    // MARK: - filter must not eat ordinary writing

    func testCommonWordsSurviveTheCodeFilter() {
        for word in ["the", "and", "writing", "sentence", "Hello", "Their"] {
            XCTAssertFalse(SuggestionFilter.looksLikeCode(word), word)
        }
    }

    func testAccentedWordIsNotCode() {
        XCTAssertFalse(SuggestionFilter.looksLikeCode("café"))
    }

    func testRomanNumeralsAreTreatedAsAcronyms() {
        // "III" is all caps; skipping it costs nothing and avoids nonsense.
        XCTAssertTrue(SuggestionFilter.looksLikeCode("III"))
    }

    func testContractionsAreNotCode() {
        XCTAssertFalse(SuggestionFilter.looksLikeCode("don't"))
        XCTAssertFalse(SuggestionFilter.looksLikeCode("it's"))
    }

    // MARK: - edit planner boundaries

    func testEditAtTheVeryEndOfText() {
        let edit = TextEdit(range: NSRange(location: 5, length: 0),
                            replacement: "!", expected: "")
        XCTAssertEqual(EditPlanner.apply(edit, to: "hello"), "hello!")
    }

    func testEditOnEmptyTextWithNonZeroRangeIsRejected() {
        let edit = TextEdit(range: NSRange(location: 0, length: 1),
                            replacement: "x", expected: "")
        XCTAssertNil(EditPlanner.apply(edit, to: ""))
    }

    func testRelocateWithRepeatedWordsPicksTheNearestOccurrence() {
        let text = "the the the the"
        let stale = TextEdit(range: NSRange(location: 100, length: 3),
                             replacement: "THE", expected: "the")
        // The location is past the end, so it clamps to the end of the text
        // and takes the closest match, which is the last "the".
        let moved = EditPlanner.relocate(stale, in: text)
        XCTAssertEqual(moved?.range.location, 12)
        XCTAssertEqual(EditPlanner.apply(moved!, to: text), "the the the THE")
    }

    func testRelocateRefusesWhenTheTextIsFarAway() {
        let text = String(repeating: "x ", count: 200) + "the"
        let stale = TextEdit(range: NSRange(location: 0, length: 3),
                             replacement: "THE", expected: "the")
        XCTAssertNil(EditPlanner.relocate(stale, in: text))
    }

    func testReanchorWithManySuggestions() {
        let many = (0..<100).map {
            Suggestion(range: NSRange(location: $0 * 10, length: 3),
                       message: "m", replacements: [])
        }
        let edit = TextEdit(range: NSRange(location: 500, length: 3),
                            replacement: "longer", expected: "abc")
        let result = EditPlanner.reanchor(many, after: edit)
        // One overlapped the edit and was dropped.
        XCTAssertEqual(result.count, 99)
    }

    // MARK: - sentence splitting

    func testSentenceWithUrlDoesNotSplitOnDots() {
        let text = "Visit https://example.com/path for the full documentation."
        XCTAssertEqual(SentenceSplitter.sentences(in: text).count, 1)
    }

    func testEllipsisDoesNotProduceEmptySentences() {
        let text = "We waited... and then we finally left the building."
        let result = SentenceSplitter.sentences(in: text)
        XCTAssertTrue(result.allSatisfy { !$0.text.isEmpty })
    }

    func testQuestionAndExclamationEndSentences() {
        let text = "Did it work correctly here? It really did work well!"
        XCTAssertEqual(SentenceSplitter.sentences(in: text).count, 2)
    }
}

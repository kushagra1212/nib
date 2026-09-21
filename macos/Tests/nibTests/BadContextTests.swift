import XCTest
@testable import nib

/// Suggestions that were reported as damaging in real messages.
///
/// Each test names the exact text that produced it, so a future change that
/// re-breaks one says which message it broke rather than which assertion.
final class BadContextTests: XCTestCase {
    private func suggestion(
        _ range: NSRange,
        _ replacement: String,
        message: String = "spelling"
    ) -> Suggestion {
        Suggestion(id: UUID(), range: range,
                   message: message, replacements: [replacement])
    }

    // MARK: - Names are not misspellings

    /// "label: Message to Kushagra Rathore eligible: yes"
    /// Harper offered `Kushagra -> Bukhara`, replacing a name with a city.
    func testDoesNotRenameAPerson() {
        let text = "label: Message to Kushagra Rathore eligible: yes"
        let range = (text as NSString).range(of: "Kushagra")
        XCTAssertFalse(SuggestionFilter.keep(suggestion(range, "Bukhara"), in: text))
    }

    /// Same message, second name: `Rathore -> Rather`. Edit distance 2 over 7
    /// characters, so distance alone never catches it.
    func testDoesNotRenameASurname() {
        let text = "label: Message to Kushagra Rathore eligible: yes"
        let range = (text as NSString).range(of: "Rathore")
        XCTAssertFalse(SuggestionFilter.keep(suggestion(range, "Rather"), in: text))
    }

    /// A capital at the start of a sentence is capitalisation, not a name, so
    /// the first word must still be spell-checked.
    func testStillCorrectsTheFirstWordOfASentence() {
        let text = "Recieve the parcel tomorrow."
        let range = (text as NSString).range(of: "Recieve")
        XCTAssertTrue(SuggestionFilter.keep(suggestion(range, "Receive"), in: text))
    }

    /// Chat messages end sentences with a newline rather than a full stop.
    func testTreatsALineBreakAsASentenceStart() {
        let text = "sounds good\nRecieve it tomorrow"
        let range = (text as NSString).range(of: "Recieve")
        XCTAssertTrue(SuggestionFilter.keep(suggestion(range, "Receive"), in: text))
    }

    func testCorrectsAfterAFullStop() {
        let text = "Thanks. Seperate them please."
        let range = (text as NSString).range(of: "Seperate")
        XCTAssertTrue(SuggestionFilter.keep(suggestion(range, "Separate"), in: text))
    }

    /// A lowercase word mid-sentence is unaffected by the name rule.
    func testLowercaseMidSentenceIsStillChecked() {
        let text = "please seperate them"
        let range = (text as NSString).range(of: "seperate")
        XCTAssertTrue(SuggestionFilter.keep(suggestion(range, "separate"), in: text))
    }

    // MARK: - Words used consistently are meant

    /// "lint returned: 1 rects resolved: 0 rects visible: 0"
    /// `rects` twice, and Harper offered `rests` for it. Distance 1, so the
    /// plausibility test passes it happily.
    func testKeepsAWordTheWriterUsesTwice() {
        let text = "lint returned: 1 rects resolved: 0 rects visible: 0"
        let range = (text as NSString).range(of: "rects")
        XCTAssertFalse(SuggestionFilter.keep(suggestion(range, "rests"), in: text))
    }

    /// One use is not a pattern, so a single occurrence is still corrected.
    func testCorrectsAWordUsedOnlyOnce() {
        let text = "the sentance is wrong"
        let range = (text as NSString).range(of: "sentance")
        XCTAssertTrue(SuggestionFilter.keep(suggestion(range, "sentence"), in: text))
    }

    /// A repeated transposition is still a typo, not a term of art.
    func testCorrectsARepeatedTransposition() {
        let text = "recieve teh parcel and teh invoice"
        let range = (text as NSString).range(of: "teh")
        XCTAssertTrue(SuggestionFilter.keep(suggestion(range, "the"), in: text))
    }

    func testCountsWholeWordsOnly() {
        // "rect" must not be counted twice by matching inside "rects".
        XCTAssertEqual(SuggestionFilter.occurrences(of: "rect", in: "rects rects"), 0)
        XCTAssertEqual(SuggestionFilter.occurrences(of: "rects", in: "rects rects"), 2)
        XCTAssertEqual(SuggestionFilter.occurrences(of: "rects", in: "Rects rects"), 2)
    }

    // MARK: - The commonest typos in English

    /// Two edits over three characters is a ratio of 0.67, so every threshold
    /// rejected it. `teh` produced no fix at all before this.
    func testCorrectsTeh() {
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "teh", to: "the"))
    }

    func testCorrectsAdn() {
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "adn", to: "and"))
    }

    func testCorrectsLongerTranspositions() {
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "recieve", to: "receive"))
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "freind", to: "friend"))
    }

    func testTranspositionNeedsAdjacentLetters() {
        // First and last swapped is a different word, not a slip of the fingers.
        XCTAssertFalse(SuggestionFilter.isTransposition("abc", "cba"))
        // Two separate substitutions, not one swap.
        XCTAssertFalse(SuggestionFilter.isTransposition("rects", "rests"))
        // Adjacent swaps, which is what fingers actually do.
        XCTAssertTrue(SuggestionFilter.isTransposition("form", "from"))
        XCTAssertTrue(SuggestionFilter.isTransposition("fro", "for"))
    }

    func testTranspositionRejectsUnequalLengths() {
        XCTAssertFalse(SuggestionFilter.isTransposition("the", "there"))
    }

    func testTranspositionRejectsIdenticalWords() {
        XCTAssertFalse(SuggestionFilter.isTransposition("the", "the"))
    }

    // MARK: - How far a correction may travel

    /// `subrole -> sublime`: 3 edits over 7 characters, 0.43 of the word.
    func testRejectsACorrectionThatTravelsTooFar() {
        XCTAssertFalse(
            SuggestionFilter.isPlausibleCorrection(from: "subrole", to: "sublime"))
    }

    func testRejectsAtThirtyEightPercent() {
        // Kushagra -> Bukhara, 3 edits over 8.
        XCTAssertFalse(
            SuggestionFilter.isPlausibleCorrection(from: "Kushagra", to: "Bukhara"))
    }

    /// The worst real misspelling measured, at 0.29 of the word.
    func testKeepsRealMisspellings() {
        let pairs = [
            ("sentance", "sentence"),
            ("erors", "errors"),
            ("definately", "definitely"),
            ("occured", "occurred"),
            ("seperate", "separate"),
            ("accomodate", "accommodate"),
        ]
        for (typo, fix) in pairs {
            XCTAssertTrue(
                SuggestionFilter.isPlausibleCorrection(from: typo, to: fix),
                "\(typo) -> \(fix) should be offered")
        }
    }

    /// Short words keep their absolute one-edit allowance: "a" to "an" is a
    /// whole character of a one-character word.
    func testKeepsSingleEditOnShortWords() {
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "a", to: "an"))
        XCTAssertTrue(SuggestionFilter.isPlausibleCorrection(from: "i", to: "in"))
    }

    // MARK: - Guards that were already there stay working

    func testStillRejectsCodeTokens() {
        let text = "the AXTextArea element"
        let range = (text as NSString).range(of: "AXTextArea")
        XCTAssertFalse(SuggestionFilter.keep(suggestion(range, "Attracted"), in: text))
    }

    func testAdvisoryLintWithNoFixSurvivesEveryGuard() {
        let text = "label: Message to Kushagra Rathore"
        let range = (text as NSString).range(of: "Kushagra")
        let note = Suggestion(id: UUID(), range: range,
                              message: "Consider rephrasing", replacements: [])
        XCTAssertTrue(SuggestionFilter.keep(note, in: text))
    }
}

import XCTest
@testable import nib

/// Covers the edit path end to end, including the two bugs that shipped:
/// applying a stale edit after the text moved, and mis-shifting the remaining
/// suggestions afterwards.
final class EditPlannerTests: XCTestCase {
    private func edit(_ location: Int, _ length: Int, _ replacement: String,
                      expecting expected: String = "") -> TextEdit {
        TextEdit(range: NSRange(location: location, length: length),
                 replacement: replacement, expected: expected)
    }

    private func suggestion(_ location: Int, _ length: Int,
                            _ message: String = "m") -> Suggestion {
        Suggestion(range: NSRange(location: location, length: length),
                   message: message, replacements: [])
    }

    // MARK: - apply

    func testReplacesInTheMiddle() {
        // "Their is many": "is" occupies offsets 6..<8.
        XCTAssertEqual(EditPlanner.apply(edit(6, 2, "was"), to: "Their is many"),
                       "Their was many")
    }

    func testReplacesAtTheStart() {
        XCTAssertEqual(EditPlanner.apply(edit(0, 5, "There"), to: "Their is many"),
                       "There is many")
    }

    func testReplacesAtTheEnd() {
        XCTAssertEqual(EditPlanner.apply(edit(9, 4, "much"), to: "Their is many"),
                       "Their is much")
    }

    func testReplacementLongerThanOriginal() {
        XCTAssertEqual(EditPlanner.apply(edit(0, 1, "aaa"), to: "abc"), "aaabc")
    }

    func testReplacementShorterThanOriginal() {
        XCTAssertEqual(EditPlanner.apply(edit(0, 3, "x"), to: "abc"), "x")
    }

    func testEmptyReplacementDeletes() {
        XCTAssertEqual(EditPlanner.apply(edit(3, 4, ""), to: "one two three"),
                       "one three")
    }

    func testDeletionRemovesExactlyTheRange() {
        XCTAssertEqual(EditPlanner.apply(edit(0, 4, ""), to: "abcdefg"), "efg")
    }

    func testZeroLengthRangeInserts() {
        XCTAssertEqual(EditPlanner.apply(edit(3, 0, "-"), to: "abcdef"), "abc-def")
    }

    func testInsertAtEndOfText() {
        XCTAssertEqual(EditPlanner.apply(edit(3, 0, "!"), to: "abc"), "abc!")
    }

    func testReplaceEntireText() {
        XCTAssertEqual(EditPlanner.apply(edit(0, 3, "xyz"), to: "abc"), "xyz")
    }

    func testEmptyTextWithZeroRange() {
        XCTAssertEqual(EditPlanner.apply(edit(0, 0, "hi"), to: ""), "hi")
    }

    // MARK: - bounds

    func testRangeBeyondEndIsRejected() {
        XCTAssertNil(EditPlanner.apply(edit(10, 5, "x"), to: "short"))
    }

    func testRangeStraddlingTheEndIsRejected() {
        XCTAssertNil(EditPlanner.apply(edit(3, 10, "x"), to: "short"))
    }

    func testNegativeLocationIsRejected() {
        XCTAssertNil(EditPlanner.apply(edit(-1, 2, "x"), to: "abc"))
    }

    func testNegativeLengthIsRejected() {
        XCTAssertNil(EditPlanner.apply(edit(1, -2, "x"), to: "abc"))
    }

    func testLocationExactlyAtEndIsAllowedForInsertion() {
        XCTAssertTrue(EditPlanner.isInBounds(NSRange(location: 3, length: 0), in: "abc"))
    }

    func testRangeExactlyCoveringTheTextIsAllowed() {
        XCTAssertTrue(EditPlanner.isInBounds(NSRange(location: 0, length: 3), in: "abc"))
    }

    // MARK: - UTF-16 offsets

    func testEmojiBeforeRangeCountsAsTwoUnits() {
        // "😀" is one Character but two UTF-16 units, so "bad" starts at 3.
        let text = "😀 bad"
        XCTAssertEqual(EditPlanner.apply(edit(3, 3, "good"), to: text), "😀 good")
    }

    func testEmojiInsideReplacedRange() {
        let text = "a😀b"
        XCTAssertEqual(EditPlanner.apply(edit(1, 2, "X"), to: text), "aXb")
    }

    func testCombiningAccentIsTwoUnits() {
        // "e" + combining acute, not the precomposed "é".
        let text = "cafe\u{0301} time"
        XCTAssertEqual(EditPlanner.apply(edit(6, 4, "hour"), to: text),
                       "cafe\u{0301} hour")
    }

    func testFamilyEmojiLengthIsCountedInUTF16() {
        let family = "👨‍👩‍👧"
        let text = "\(family) here"
        let familyLength = (family as NSString).length
        XCTAssertEqual(EditPlanner.apply(
            edit(familyLength + 1, 4, "there"), to: text), "\(family) there")
    }

    // MARK: - isValid

    func testValidWhenRangeHoldsExpected() {
        XCTAssertTrue(EditPlanner.isValid(
            edit(0, 5, "There", expecting: "Their"), in: "Their is"))
    }

    func testInvalidWhenTextChangedUnderneath() {
        // The user typed "Oh " at the front after the lint ran.
        XCTAssertFalse(EditPlanner.isValid(
            edit(0, 5, "There", expecting: "Their"), in: "Oh Their is"))
    }

    func testInvalidWhenRangeOutOfBounds() {
        XCTAssertFalse(EditPlanner.isValid(
            edit(50, 5, "There", expecting: "Their"), in: "Their is"))
    }

    func testEmptyExpectedSkipsTheContentCheck() {
        XCTAssertTrue(EditPlanner.isValid(edit(0, 5, "There"), in: "Their is"))
    }

    // MARK: - relocate

    func testRelocateFindsTextShiftedRight() {
        let stale = edit(0, 5, "There", expecting: "Their")
        let moved = EditPlanner.relocate(stale, in: "Oh Their is")
        XCTAssertEqual(moved?.range, NSRange(location: 3, length: 5))
        XCTAssertEqual(moved?.replacement, "There")
    }

    func testRelocateFindsTextShiftedLeft() {
        let stale = edit(10, 5, "There", expecting: "Their")
        let moved = EditPlanner.relocate(stale, in: "Their is here")
        XCTAssertEqual(moved?.range, NSRange(location: 0, length: 5))
    }

    func testRelocateReturnsUnchangedWhenAlreadyValid() {
        let good = edit(0, 5, "There", expecting: "Their")
        XCTAssertEqual(EditPlanner.relocate(good, in: "Their is"), good)
    }

    func testRelocatePrefersTheNearestOccurrence() {
        // "the" appears three times; the one nearest the old location wins.
        let text = "the cat and the dog and the bird"
        let stale = TextEdit(range: NSRange(location: 12, length: 3),
                             replacement: "THE", expected: "the")
        let moved = EditPlanner.relocate(stale, in: text)
        XCTAssertEqual(moved?.range.location, 12)
    }

    func testRelocateFailsWhenTextIsGone() {
        let stale = edit(0, 5, "There", expecting: "Their")
        XCTAssertNil(EditPlanner.relocate(stale, in: "completely different"))
    }

    func testRelocateFailsBeyondTheSearchWindow() {
        let padding = String(repeating: "x", count: 500)
        let stale = edit(0, 5, "There", expecting: "Their")
        XCTAssertNil(EditPlanner.relocate(stale, in: padding + "Their"))
    }

    func testRelocateWithNoExpectedTextFails() {
        XCTAssertNil(EditPlanner.relocate(edit(99, 5, "x"), in: "short"))
    }

    // MARK: - reanchor

    func testSuggestionAfterEditShiftsByPositiveDelta() {
        // "t he" (4) -> "the" (3): delta -1.
        let result = EditPlanner.reanchor([suggestion(20, 6)],
                                          after: edit(13, 4, "the"))
        XCTAssertEqual(result.first?.range, NSRange(location: 19, length: 6))
    }

    func testSuggestionAfterEditShiftsByNegativeDelta() {
        let result = EditPlanner.reanchor([suggestion(20, 6)],
                                          after: edit(13, 3, "these"))
        XCTAssertEqual(result.first?.range, NSRange(location: 22, length: 6))
    }

    func testSuggestionBeforeEditIsUntouched() {
        let result = EditPlanner.reanchor([suggestion(0, 5)],
                                          after: edit(13, 4, "the"))
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: 5))
    }

    func testSuggestionEndingExactlyAtEditStartIsUntouched() {
        let result = EditPlanner.reanchor([suggestion(8, 5)],
                                          after: edit(13, 4, "the"))
        XCTAssertEqual(result.first?.range, NSRange(location: 8, length: 5))
    }

    func testSuggestionStartingExactlyAtEditEndShifts() {
        let result = EditPlanner.reanchor([suggestion(17, 3)],
                                          after: edit(13, 4, "the"))
        XCTAssertEqual(result.first?.range, NSRange(location: 16, length: 3))
    }

    func testOverlappingSuggestionIsDropped() {
        // This is the case the old code got wrong: it shifted overlapping
        // ranges instead of discarding them, producing garbage spans.
        let result = EditPlanner.reanchor([suggestion(15, 5)],
                                          after: edit(13, 4, "the"))
        XCTAssertTrue(result.isEmpty)
    }

    func testSuggestionEnclosingTheEditIsDropped() {
        let result = EditPlanner.reanchor([suggestion(10, 20)],
                                          after: edit(13, 4, "the"))
        XCTAssertTrue(result.isEmpty)
    }

    func testSuggestionIdenticalToTheEditIsDropped() {
        let result = EditPlanner.reanchor([suggestion(13, 4)],
                                          after: edit(13, 4, "the"))
        XCTAssertTrue(result.isEmpty)
    }

    func testSuggestionStartingAtEditStartButLongerIsDropped() {
        let result = EditPlanner.reanchor([suggestion(13, 9)],
                                          after: edit(13, 4, "the"))
        XCTAssertTrue(result.isEmpty)
    }

    func testZeroLengthSuggestionInsideEditIsDropped() {
        let result = EditPlanner.reanchor([suggestion(15, 0)],
                                          after: edit(13, 4, "the"))
        XCTAssertTrue(result.isEmpty)
    }

    func testSameLengthReplacementLeavesEverythingInPlace() {
        let all = [suggestion(0, 3), suggestion(13, 4), suggestion(20, 6)]
        let result = EditPlanner.reanchor(all, after: edit(13, 4, "thee"))
        XCTAssertEqual(result.map(\.range),
                       [NSRange(location: 0, length: 3), NSRange(location: 20, length: 6)])
    }

    func testLargeDeletionShiftsLaterSuggestionsBackwards() {
        let result = EditPlanner.reanchor([suggestion(11, 2)],
                                          after: edit(0, 10, ""))
        XCTAssertEqual(result.first?.range, NSRange(location: 1, length: 2))
    }

    func testShiftThatWouldGoNegativeDropsTheSuggestion() {
        // Contrived, but a delta must never yield a negative location: NSRange
        // is unsigned underneath and would wrap to an enormous offset.
        let result = EditPlanner.reanchor([suggestion(5, 2)],
                                          after: TextEdit(
                                            range: NSRange(location: 0, length: 5),
                                            replacement: "", expected: ""))
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: 2))
    }

    func testIdentityAndMessageSurviveReanchoring() {
        let original = suggestion(20, 6, "keep me")
        let result = EditPlanner.reanchor([original], after: edit(0, 2, "x"))
        XCTAssertEqual(result.first?.id, original.id)
        XCTAssertEqual(result.first?.message, "keep me")
    }

    func testMultipleSuggestionsKeepTheirOrder() {
        let all = [suggestion(0, 2), suggestion(20, 2), suggestion(30, 2)]
        let result = EditPlanner.reanchor(all, after: edit(10, 4, "x"))
        XCTAssertEqual(result.map(\.range.location), [0, 17, 27])
    }

    func testEmptyInput() {
        XCTAssertTrue(EditPlanner.reanchor([], after: edit(0, 1, "x")).isEmpty)
    }

    // MARK: - pruning

    func testPruneDropsRangesPastTheEnd() {
        let kept = EditPlanner.pruneOutOfBounds(
            [suggestion(0, 3), suggestion(90, 5)], in: "short text")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.range.location, 0)
    }

    // MARK: - sequences

    func testAcceptingTwoFixesInSequenceStaysConsistent() {
        var text = "Their is many erors here"
        var pending = [
            suggestion(0, 5, "Their"),   // -> There
            suggestion(14, 5, "erors"),  // -> errors
        ]

        let first = TextEdit(range: pending[0].range,
                             replacement: "There", expected: "Their")
        text = EditPlanner.apply(first, to: text)!
        pending = EditPlanner.reanchor(pending, after: first)
        XCTAssertEqual(text, "There is many erors here")
        XCTAssertEqual(pending.count, 1)

        let second = TextEdit(range: pending[0].range,
                              replacement: "errors", expected: "erors")
        XCTAssertTrue(EditPlanner.isValid(second, in: text),
                      "the second range must still point at 'erors'")
        text = EditPlanner.apply(second, to: text)!
        XCTAssertEqual(text, "There is many errors here")
    }

    func testAcceptingRightToLeftAlsoStaysConsistent() {
        var text = "Their is many erors here"
        let later = TextEdit(range: NSRange(location: 14, length: 5),
                             replacement: "errors", expected: "erors")
        text = EditPlanner.apply(later, to: text)!
        XCTAssertEqual(text, "Their is many errors here")

        // An edit before the previous one needs no reanchoring at all.
        let earlier = TextEdit(range: NSRange(location: 0, length: 5),
                               replacement: "There", expected: "Their")
        XCTAssertTrue(EditPlanner.isValid(earlier, in: text))
        XCTAssertEqual(EditPlanner.apply(earlier, to: text),
                       "There is many errors here")
    }

    func testStaleEditIsRejectedThenRecoveredByRelocate() {
        // The user typed at the front between the lint and the click.
        let text = "Oh, Their is many"
        let stale = TextEdit(range: NSRange(location: 0, length: 5),
                             replacement: "There", expected: "Their")
        XCTAssertFalse(EditPlanner.isValid(stale, in: text))

        let fixed = EditPlanner.relocate(stale, in: text)
        XCTAssertNotNil(fixed)
        XCTAssertEqual(EditPlanner.apply(fixed!, to: text), "Oh, There is many")
    }

    func testRepeatedWordEditsDoNotDrift() {
        var text = "the the the"
        // Replace the middle one only.
        let middle = TextEdit(range: NSRange(location: 4, length: 3),
                              replacement: "THE", expected: "the")
        text = EditPlanner.apply(middle, to: text)!
        XCTAssertEqual(text, "the THE the")
    }
}

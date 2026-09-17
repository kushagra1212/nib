import XCTest
@testable import nib

/// An empty field reporting its placeholder as its value.
///
/// ChatGPT's composer, untouched, reports "Ask anything". nib linted that,
/// found a missing full stop, and offered to correct the placeholder. The
/// wrong suggestion was the smaller half of it: the field looked occupied, so
/// nothing the user actually typed was ever checked.
final class PlaceholderTests: XCTestCase {
    func testChatGPTComposerIsTreatedAsEmpty() {
        XCTAssertTrue(AXElement.isPlaceholder(
            value: "Ask anything", anyOf: ["Ask anything"]))
    }

    func testSlackComposerIsTreatedAsEmpty() {
        XCTAssertTrue(AXElement.isPlaceholder(
            value: "Message to Kushagra Rathore",
            anyOf: [nil, "Message to Kushagra Rathore"]))
    }

    /// Chromium reports it through one attribute for an input and another for
    /// a contenteditable, so both are offered and either may be nil.
    func testAnyOfTheOfferedAttributesCanMatch() {
        XCTAssertTrue(AXElement.isPlaceholder(value: "Search", anyOf: [nil, "Search"]))
        XCTAssertTrue(AXElement.isPlaceholder(value: "Search", anyOf: ["Search", nil]))
        XCTAssertFalse(AXElement.isPlaceholder(value: "Search", anyOf: [nil, nil]))
    }

    func testWhitespaceAroundEitherSideStillMatches() {
        XCTAssertTrue(AXElement.isPlaceholder(
            value: "  Ask anything  ", anyOf: ["Ask anything"]))
        XCTAssertTrue(AXElement.isPlaceholder(
            value: "Ask anything", anyOf: ["  Ask anything\n"]))
    }

    func testEmptyValueIsEmpty() {
        XCTAssertTrue(AXElement.isPlaceholder(value: "", anyOf: [nil]))
        XCTAssertTrue(AXElement.isPlaceholder(value: "   \n ", anyOf: [nil]))
    }

    // MARK: - Real text must survive

    /// The match is exact, so text that merely starts with the placeholder is
    /// still checked. Anything looser would discard what someone wrote the
    /// moment they began with the same word.
    func testTextBeginningWithThePlaceholderIsKept() {
        XCTAssertFalse(AXElement.isPlaceholder(
            value: "Ask anything you like about the report",
            anyOf: ["Ask anything"]))
    }

    func testDifferentTextIsKept() {
        XCTAssertFalse(AXElement.isPlaceholder(
            value: "there is a bug in the cart", anyOf: ["Ask anything"]))
    }

    func testAnEmptyPlaceholderNeverMatchesRealText() {
        XCTAssertFalse(AXElement.isPlaceholder(value: "hello", anyOf: ["", "   "]))
    }

    /// Case is not normalised: "ask anything" typed in lower case is something
    /// the user wrote, and the placeholder reads "Ask anything".
    func testCaseDifferenceCountsAsRealText() {
        XCTAssertFalse(AXElement.isPlaceholder(
            value: "ask anything", anyOf: ["Ask anything"]))
    }
}

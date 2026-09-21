import XCTest
@testable import nib

/// Small models ignore "reply with only the text" a good fraction of the time.
/// These cover the shapes actually seen from Gemma and Qwen at this size.
final class RewriteCleanTests: XCTestCase {
    func testPlainTextPassesThrough() {
        XCTAssertEqual(RewriteEngine.clean("There are many errors."),
                       "There are many errors.")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(RewriteEngine.clean("\n  Fixed text.  \n"), "Fixed text.")
    }

    func testStripsThinkBlock() {
        let raw = "<think>The user wants grammar fixed. Their -> There.</think>\nThere are errors."
        XCTAssertEqual(RewriteEngine.clean(raw), "There are errors.")
    }

    func testStripsPreambleLine() {
        let raw = "Here is the corrected text:\nThere are many errors."
        XCTAssertEqual(RewriteEngine.clean(raw), "There are many errors.")
    }

    func testStripsCodeFence() {
        let raw = "```\nThere are many errors.\n```"
        XCTAssertEqual(RewriteEngine.clean(raw), "There are many errors.")
    }

    func testStripsWrappingQuotes() {
        XCTAssertEqual(RewriteEngine.clean("\"There are many errors.\""),
                       "There are many errors.")
        XCTAssertEqual(RewriteEngine.clean("“There are many errors.”"),
                       "There are many errors.")
    }

    func testKeepsInternalQuotes() {
        let raw = "She said \"hello\" to him."
        XCTAssertEqual(RewriteEngine.clean(raw), raw)
    }

    func testKeepsUnbalancedLeadingQuote() {
        // A quote that opens but never closes is part of the text, not a wrapper.
        let raw = "\"Stop there, he said."
        XCTAssertEqual(RewriteEngine.clean(raw), raw)
    }

    func testDoesNotStripSentenceThatMerelyStartsWithHere() {
        // "Here is the plan" without a trailing colon is real content.
        let raw = "Here is the plan\nWe ship on Friday."
        XCTAssertEqual(RewriteEngine.clean(raw), raw)
    }

    func testMultilineBodyIsPreserved() {
        let raw = "First paragraph.\n\nSecond paragraph."
        XCTAssertEqual(RewriteEngine.clean(raw), raw)
    }
}

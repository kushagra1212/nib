import XCTest
@testable import nib

/// The word-level diff shown behind the Diff button.
///
/// The assertions read the rendered string rather than the styling, since what
/// matters is which words appear and in what order -- a diff that shows the
/// right colours over the wrong words is worse than none.
final class DiffTextRenderTests: XCTestCase {
    private func rendered(_ a: String, _ b: String) -> String {
        DiffText.attributed(from: a, to: b).string
    }

    /// Struck-through and added words both appear, so a substitution reads as
    /// "this became that" rather than as one or the other.
    private func styled(_ a: String, _ b: String)
        -> [(word: String, removed: Bool, added: Bool)] {
        let text = DiffText.attributed(from: a, to: b)
        var out: [(String, Bool, Bool)] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) {
            attributes, range, _ in
            let word = (text.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return }
            out.append((word,
                        attributes[.strikethroughStyle] != nil,
                        attributes[.underlineStyle] != nil))
        }
        return out.map { (word: $0.0, removed: $0.1, added: $0.2) }
    }

    func testUnchangedTextShowsNoMarks() {
        let text = "the cart is empty"
        let marks = styled(text, text)
        XCTAssertEqual(rendered(text, text), text)
        XCTAssertTrue(marks.allSatisfy { !$0.removed && !$0.added })
    }

    func testASubstitutionShowsBothWords() {
        let marks = styled("their is a bug", "there is a bug")
        XCTAssertEqual(marks.first(where: { $0.removed })?.word, "their")
        XCTAssertEqual(marks.first(where: { $0.added })?.word, "there")
    }

    func testAnInsertionIsMarkedAsAdded() {
        let marks = styled("fix the bug", "fix the small bug")
        XCTAssertEqual(marks.filter(\.added).map(\.word), ["small"])
        XCTAssertTrue(marks.filter(\.removed).isEmpty)
    }

    func testADeletionIsMarkedAsRemoved() {
        let marks = styled("fix the small bug", "fix the bug")
        XCTAssertEqual(marks.filter(\.removed).map(\.word), ["small"])
        XCTAssertTrue(marks.filter(\.added).isEmpty)
    }

    /// Every word of both versions has to appear somewhere, or the diff is
    /// hiding part of what would happen.
    func testNothingIsLostFromEitherSide() {
        let before = "can also scroll to top of the catalog so that after navigation"
        let after = "Can also scroll to the top of the catalogue after navigating"
        let shown = rendered(before, after).lowercased()
        for word in before.split(separator: " ") + after.split(separator: " ") {
            XCTAssertTrue(shown.contains(word.lowercased()),
                          "\(word) is missing from the diff")
        }
    }

    /// Case-only changes are real edits and must be visible as such.
    func testACapitalisationChangeIsShown() {
        let marks = styled("i use chatgpt daily", "I use ChatGPT daily")
        XCTAssertEqual(marks.filter(\.removed).map(\.word), ["i", "chatgpt"])
        XCTAssertEqual(marks.filter(\.added).map(\.word), ["I", "ChatGPT"])
    }

    func testEmptySidesDoNotCrash() {
        XCTAssertEqual(rendered("", ""), "")
        XCTAssertEqual(rendered("", "hello"), "hello")
        XCTAssertEqual(rendered("hello", ""), "hello")
    }

    func testAWholeSentenceReplacedShowsBoth() {
        let marks = styled("one two three", "four five six")
        XCTAssertEqual(marks.filter(\.removed).map(\.word), ["one", "two", "three"])
        XCTAssertEqual(marks.filter(\.added).map(\.word), ["four", "five", "six"])
    }
}

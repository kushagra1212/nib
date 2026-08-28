import XCTest
@testable import nib

/// Covers the LSP position to NSRange conversion. Harper reports (line,
/// character) pairs; every range in the app is a UTF-16 offset. A mistake here
/// underlines the wrong word rather than failing loudly.
final class PositionMapperTests: XCTestCase {
    private func lsp(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int) -> [String: Any] {
        ["start": ["line": sl, "character": sc],
         "end": ["line": el, "character": ec]]
    }

    func testSingleLineRange() {
        let mapper = PositionMapper(text: "Their is many")
        XCTAssertEqual(mapper.range(from: lsp(0, 0, 0, 5)),
                       NSRange(location: 0, length: 5))
    }

    func testSecondLineOffsetIncludesTheNewline() {
        let mapper = PositionMapper(text: "abc\ndef")
        // Line 1 starts at offset 4: three characters plus the newline.
        XCTAssertEqual(mapper.range(from: lsp(1, 0, 1, 3)),
                       NSRange(location: 4, length: 3))
    }

    func testThirdLine() {
        let mapper = PositionMapper(text: "a\nbb\nccc")
        XCTAssertEqual(mapper.range(from: lsp(2, 0, 2, 3)),
                       NSRange(location: 5, length: 3))
    }

    func testRangeSpanningTwoLines() {
        let mapper = PositionMapper(text: "abc\ndef")
        XCTAssertEqual(mapper.range(from: lsp(0, 1, 1, 2)),
                       NSRange(location: 1, length: 5))
    }

    func testEmptyRange() {
        let mapper = PositionMapper(text: "abc")
        XCTAssertEqual(mapper.range(from: lsp(0, 1, 0, 1)),
                       NSRange(location: 1, length: 0))
    }

    func testEmojiCountsAsTwoUTF16Units() {
        let mapper = PositionMapper(text: "😀 bad")
        // LSP characters are UTF-16 units, so "bad" starts at character 3.
        XCTAssertEqual(mapper.range(from: lsp(0, 3, 0, 6)),
                       NSRange(location: 3, length: 3))
    }

    func testEmojiOnAnEarlierLineShiftsLaterLines() {
        let mapper = PositionMapper(text: "😀\nbad")
        XCTAssertEqual(mapper.range(from: lsp(1, 0, 1, 3)),
                       NSRange(location: 3, length: 3))
    }

    func testCharacterBeyondLineEndClampsToThatLine() {
        // A character offset past the end of its line must not bleed into the
        // next one; that would underline text on a different row.
        let mapper = PositionMapper(text: "ab\ncdef")
        let range = mapper.range(from: lsp(0, 99, 0, 99))
        XCTAssertEqual(range?.location, 2, "clamped to the end of line 0")
        XCTAssertEqual(range?.length, 0)
    }

    func testLineBeyondEndClampsToTextEnd() {
        let mapper = PositionMapper(text: "abc")
        XCTAssertEqual(mapper.offset(line: 99, character: 0), 3)
    }

    func testNegativeLineClampsToZero() {
        let mapper = PositionMapper(text: "abc")
        XCTAssertEqual(mapper.offset(line: -1, character: 0), 0)
    }

    func testNegativeCharacterClampsToLineStart() {
        let mapper = PositionMapper(text: "ab\ncd")
        XCTAssertEqual(mapper.offset(line: 1, character: -5), 3)
    }

    func testInvertedRangeIsRejected() {
        let mapper = PositionMapper(text: "abcdef")
        XCTAssertNil(mapper.range(from: lsp(0, 4, 0, 2)))
    }

    func testMalformedPayloadIsRejected() {
        let mapper = PositionMapper(text: "abc")
        XCTAssertNil(mapper.range(from: ["start": ["line": 0]]))
        XCTAssertNil(mapper.range(from: [:]))
    }

    func testEmptyText() {
        let mapper = PositionMapper(text: "")
        XCTAssertEqual(mapper.range(from: lsp(0, 0, 0, 0)),
                       NSRange(location: 0, length: 0))
    }

    func testTrailingNewlineCreatesAnEmptyLastLine() {
        let mapper = PositionMapper(text: "abc\n")
        XCTAssertEqual(mapper.offset(line: 1, character: 0), 4)
    }

    func testWindowsLineEndings() {
        // \r\n: the \r belongs to the preceding line, so line 1 starts after \n.
        let mapper = PositionMapper(text: "ab\r\ncd")
        XCTAssertEqual(mapper.offset(line: 1, character: 0), 4)
    }
}

import XCTest
@testable import nib

final class MessageFramerTests: XCTestCase {
    private func frame(_ json: String) -> Data {
        MessageFramer.encode(Data(json.utf8))
    }

    func testSingleCompleteMessage() {
        var framer = MessageFramer()
        let out = framer.push(frame(#"{"id":1}"#))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(String(decoding: out[0], as: UTF8.self), #"{"id":1}"#)
    }

    func testTwoMessagesInOneChunk() {
        var framer = MessageFramer()
        var data = frame(#"{"a":1}"#)
        data.append(frame(#"{"b":2}"#))
        let out = framer.push(data)
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) },
                       [#"{"a":1}"#, #"{"b":2}"#])
    }

    func testMessageSplitAcrossChunks() {
        var framer = MessageFramer()
        let full = frame(#"{"hello":"world"}"#)
        let cut = full.count - 5

        XCTAssertTrue(framer.push(full.prefix(cut)).isEmpty,
                      "partial body must not yield a message")

        let out = framer.push(full.suffix(from: cut))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(String(decoding: out[0], as: UTF8.self), #"{"hello":"world"}"#)
    }

    func testHeaderSplitMidway() {
        var framer = MessageFramer()
        let full = frame(#"{"x":1}"#)
        // Cut inside "Content-Length:" itself.
        XCTAssertTrue(framer.push(full.prefix(8)).isEmpty)
        let out = framer.push(full.suffix(from: 8))
        XCTAssertEqual(out.count, 1)
    }

    func testByteAtATimeDelivery() {
        var framer = MessageFramer()
        let full = frame(#"{"drip":true}"#)
        var received: [Data] = []
        for byte in full {
            received += framer.push(Data([byte]))
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(String(decoding: received[0], as: UTF8.self), #"{"drip":true}"#)
    }

    func testUnicodeBodyLengthIsBytesNotCharacters() {
        var framer = MessageFramer()
        // "café — naïve" is longer in bytes than in characters; a character-based
        // length would truncate the body and desync every later message.
        let json = #"{"t":"café — naïve"}"#
        let out = framer.push(frame(json))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(String(decoding: out[0], as: UTF8.self), json)
    }

    func testTrailingPartialMessageIsHeldNotDropped() {
        var framer = MessageFramer()
        var data = frame(#"{"first":1}"#)
        data.append(frame(#"{"second":2}"#).prefix(10))
        let out = framer.push(data)
        XCTAssertEqual(out.count, 1, "only the complete message surfaces")
        XCTAssertEqual(String(decoding: out[0], as: UTF8.self), #"{"first":1}"#)
    }

    func testEncodeUsesByteCount() {
        let encoded = MessageFramer.encode(Data("é".utf8))
        let header = String(decoding: encoded.prefix(30), as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("Content-Length: 2"), "got: \(header)")
    }
}

import XCTest
@testable import nib

/// What nib says when llama-server refuses.
///
/// Every one of these used to surface as "could not parse the model's
/// response", which is true only in the sense that there was no response to
/// parse. It sent an afternoon looking for a parsing bug when the server had
/// plainly said what was wrong.
final class ServerErrorTests: XCTestCase {
    private func failure(_ status: Int, _ body: String,
                         log: String = "") -> RewriteError {
        RewriteEngine.failure(status: status, body: Data(body.utf8), log: log)
    }

    /// What actually comes back from running a 2.2GB model on a busy 16GB
    /// machine: a body saying nothing, and the reason on stderr.
    ///
    /// Measured, not imagined. The first version of this checked the body for
    /// the Metal text and passed, while the real failure went on reporting
    /// "llama-server answered 500: Compute error." -- the test agreed with the
    /// code and both were wrong about the server.
    func testMetalOutOfMemoryIsNamedFromTheLog() {
        let body = #"{"error":{"code":500,"message":"Compute error.","type":"server_error"}}"#
        let log = """
        0.02.088.285 E ggml_metal_synchronize: error: command buffer 0 failed \
        with status 5
        0.02.088.288 E error: Insufficient Memory \
        (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
        """
        guard case .outOfMemory = failure(500, body, log: log) else {
            return XCTFail("the reason is on stderr and must be read from there")
        }
    }

    /// Without the log there is nothing to go on, and inventing a cause would
    /// be worse than naming the status.
    func testTheSameBodyAloneIsNotGuessedAtDetail() {
        let body = #"{"error":{"code":500,"message":"Compute error.","type":"server_error"}}"#
        guard case let .rejected(status, detail) = failure(500, body) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(detail, "Compute error.")
    }

    /// The advice has to name the fix, which is a smaller model rather than
    /// trying the same thing again.
    func testTheOutOfMemoryMessageSuggestsWhatToDo() {
        let text = String(describing: RewriteError.outOfMemory)
        XCTAssertTrue(text.contains("smaller"), text)
    }

    func testOutOfMemoryIsRecognisedInAnyCasing() {
        for text in ["Insufficient Memory", "out of memory", "OutOfMemory",
                     "kIOGPUCommandBufferCallbackErrorOutOfMemory"] {
            guard case .outOfMemory = failure(500, text) else {
                return XCTFail("\(text) in the body must read as out of memory")
            }
            guard case .outOfMemory = failure(500, "Compute error.", log: text) else {
                return XCTFail("\(text) in the log must read as out of memory")
            }
        }
    }

    /// The log is the tail of a long-lived server, so a failure from ten
    /// minutes ago must not be attributed to this request.
    func testTheLogIsBoundedAndClearable() {
        let log = ServerErrorLog()
        log.append(String(repeating: "x", count: 20_000))
        XCTAssertLessThanOrEqual(log.recent.count, 8_000)
        log.clear()
        XCTAssertTrue(log.recent.isEmpty)
    }

    func testTheLogKeepsTheMostRecentText() {
        let log = ServerErrorLog()
        log.append(String(repeating: "old", count: 4_000))
        log.append("Insufficient Memory")
        XCTAssertTrue(log.recent.hasSuffix("Insufficient Memory"),
                      "the newest lines are the ones that explain the failure")
    }

    func testAStructuredErrorReportsItsMessage() {
        let body = #"{"error":{"message":"context size exceeded"}}"#
        guard case let .rejected(status, detail) = failure(400, body) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(detail, "context size exceeded")
    }

    func testAPlainTextErrorIsKept() {
        guard case let .rejected(_, detail) = failure(503, "server overloaded") else {
            return XCTFail("expected .rejected")
        }
        XCTAssertEqual(detail, "server overloaded")
    }

    /// An HTML error page would otherwise fill the card with markup.
    func testALongBodyIsTruncated() {
        let body = String(repeating: "x", count: 5000)
        guard case let .rejected(_, detail) = failure(502, body) else {
            return XCTFail("expected .rejected")
        }
        XCTAssertLessThanOrEqual(detail.count, 200)
    }

    func testAnEmptyBodyStillNamesTheStatus() {
        let text = String(describing: failure(500, ""))
        XCTAssertTrue(text.contains("500"), text)
    }

    func testTheStatusIsNotLostForAStructuredError() {
        let text = String(describing:
            failure(429, #"{"error":{"message":"slow down"}}"#))
        XCTAssertTrue(text.contains("429"), text)
        XCTAssertTrue(text.contains("slow down"), text)
    }
}

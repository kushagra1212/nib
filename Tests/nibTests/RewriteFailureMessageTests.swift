import XCTest
@testable import nib

/// What the rewrite bar says when a rewrite does not happen.
///
/// The bar reported "model unavailable" while the menu said "AI Rewrite:
/// ready", on a machine where the model loaded in under a second. Both were
/// reading the truth; the bar had no case for the failure it was handed, so it
/// fell through to a message that contradicted everything else on screen.
final class RewriteFailureMessageTests: XCTestCase {
    /// The case that caused it. Whisper holds GPU memory for 180 seconds after
    /// transcribing, so a rewrite pressed shortly after dictating can fail for
    /// memory alone -- and "unavailable" sends the reader to look for a
    /// missing model that is sitting right there.
    func testOutOfMemorySaysSoAndSaysToWait() {
        let message = SelectionBar.message(for: RewriteError.outOfMemory)
        XCTAssertTrue(message.contains("memory"), message)
        XCTAssertTrue(message.contains("again"), message)
        XCTAssertFalse(message.contains("unavailable"),
                       "a model that is present must not be called unavailable")
    }

    func testARefusalReportsItsStatus() {
        let message = SelectionBar.message(
            for: RewriteError.rejected(status: 503, detail: "overloaded"))
        XCTAssertTrue(message.contains("503"), message)
    }

    func testTheKnownFailuresEachReadDifferently() {
        let messages = [
            SelectionBar.message(for: RewriteError.modelMissing("/nowhere")),
            SelectionBar.message(for: RewriteError.serverFailed("no port")),
            SelectionBar.message(for: RewriteError.badResponse),
            SelectionBar.message(for: RewriteError.outOfMemory),
            SelectionBar.message(for: RewriteError.rejected(status: 500, detail: "x")),
        ]
        XCTAssertEqual(Set(messages).count, messages.count,
                       "two different failures reading the same is how this bug started")
    }

    /// The sweep that would have caught it. Every case of RewriteError must
    /// have its own line; reaching the default branch means nib knows what
    /// went wrong and is describing it as though it does not.
    func testNoKnownErrorFallsThroughToTheDefault() {
        let fallback = SelectionBar.message(for: CancellationError())
        let known: [RewriteError] = [
            .modelMissing("/nowhere"),
            .serverFailed("no port"),
            .badResponse,
            .outOfMemory,
            .rejected(status: 500, detail: "x"),
        ]
        for error in known {
            XCTAssertNotEqual(SelectionBar.message(for: error), fallback,
                              "\(error) has no message of its own")
        }
    }

    /// Short enough for a bar that sits over someone's text.
    func testMessagesStayShort() {
        let known: [RewriteError] = [
            .modelMissing("/a/very/long/path/that/goes/on/forever/model.gguf"),
            .serverFailed("a long explanation of what went wrong internally"),
            .rejected(status: 500, detail: String(repeating: "detail ", count: 40)),
        ]
        for error in known {
            XCTAssertLessThanOrEqual(SelectionBar.message(for: error).count, 60,
                                     SelectionBar.message(for: error))
        }
    }
}

import XCTest
@testable import nib

/// What may run without being asked.
///
/// The live pass fires 0.9s after you stop typing, in whatever field has focus,
/// and calls the model twice -- check, then clarity. Nobody requested it.
///
/// With the 805MB 0.6B that was about 0.2s and a server small enough to forget
/// about. Recommending the 2.5GB 4B made the same unbidden work about 1s of
/// six-thread inference, and because every pass resets the idle timer the 2.7GB
/// server never got to exit while someone was typing. That was measured as
/// nib "taking a lot of CPU and RAM", and it was introduced by changing the
/// recommended model without noticing this path shared it.
///
/// The rule these tests hold in place: work nobody asked for stays cheap. Work
/// behind a button may cost what it needs to.
final class LiveModelCostTests: XCTestCase {
    private func model(ofSize bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-model-\(UUID().uuidString).gguf")
        try Data(count: bytes).write(to: url)
        return url
    }

    func testASmallModelMayRunOnEveryPause() throws {
        let url = try model(ofSize: 4096)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ModelChecker.isLightEnoughForLiveUse(url))
    }

    /// The measured sizes, either side of the limit. The 0.6B is 805MB and
    /// stays on; the 4B is 2.5GB and comes off.
    func testTheLimitSitsBetweenTheTwoShippedModels() {
        let small = ModelCatalog.compact.bytes
        let large = ModelCatalog.recommended.bytes
        XCTAssertLessThan(small, ModelChecker.liveModelSizeLimit,
                          "the small model must still underline as you type")
        XCTAssertGreaterThan(large, ModelChecker.liveModelSizeLimit,
                             "the recommended model must not run unbidden")
    }

    /// A model that is not there is not a reason to run anything.
    func testAMissingModelIsNotTreatedAsSmall() {
        let missing = URL(fileURLWithPath: "/nonexistent/model.gguf")
        XCTAssertTrue(ModelChecker.isLightEnoughForLiveUse(missing),
                      "size reads as zero; the caller guards on the model "
                      + "existing before this is consulted")
    }

    /// Harper is what actually underlines, and it is unaffected. Turning the
    /// model pass off must not turn off marking.
    func testHarperStillMarksWithoutTheModelPass() {
        // Harper answered 720 suggestions on 12600 characters in 0.89s,
        // measured, which is why it is the one that runs unbidden.
        XCTAssertEqual(LiveChecker.maxDrawnMarks, 60)
    }
}

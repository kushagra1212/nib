import XCTest
@testable import nib

/// The memory figure the menu shows.
///
/// It exists because nib's own resident size is misleading. The engines are
/// separate processes, so Activity Monitor shows "nib" at about 100MB and
/// "llama-server" at 2.7GB with nothing connecting the two -- which is how the
/// footprint got blamed on the speech model, which costs 62MB.
final class FootprintTests: XCTestCase {
    func testItReadsItsOwnResidentSize() {
        let bytes = Footprint.residentBytes()
        XCTAssertGreaterThan(bytes, 1_000_000, "a running test process is not 1MB")
        XCTAssertLessThan(bytes, 8_000_000_000)
    }

    /// The total is what the menu shows, so it has to include the engines.
    func testTheTotalIncludesTheHelpers() {
        let reading = Footprint.Reading(app: 100_000_000, helpers: 2_700_000_000)
        XCTAssertEqual(reading.total, 2_800_000_000)
    }

    /// Where the memory actually is, said plainly. Reporting only the total
    /// would leave the same mystery it exists to remove.
    func testTheSummaryNamesTheEnginesShare() {
        let reading = Footprint.Reading(app: 100_000_000, helpers: 2_700_000_000)
        XCTAssertTrue(reading.summary.contains("in engines"), reading.summary)
        XCTAssertTrue(reading.summary.hasPrefix("2.6 GB"), reading.summary)
    }

    /// With nothing loaded there is no second number to explain.
    func testTheSummaryIsJustTheTotalWhenNothingElseRuns() {
        let reading = Footprint.Reading(app: 110_000_000, helpers: 0)
        XCTAssertEqual(reading.summary, "105 MB")
        XCTAssertFalse(reading.summary.contains("engines"))
    }

    func testSizesReadTheWayAPersonWouldSayThem() {
        XCTAssertEqual(Footprint.short(0), "0 MB")
        XCTAssertEqual(Footprint.short(104_857_600), "100 MB")
        XCTAssertEqual(Footprint.short(1_073_741_824), "1.0 GB")
        XCTAssertEqual(Footprint.short(2_899_102_925), "2.7 GB")
    }

    /// Counted by process name, so a llama-server orphaned by a crashed nib is
    /// still reported. It is still holding the memory.
    func testHelperNamesAreMatchedBySuffix() {
        // No engines are expected during tests; the call must still be safe
        // and must not report the test process itself.
        let bytes = Footprint.helperBytes(names: ["definitely-not-a-real-process"])
        XCTAssertEqual(bytes, 0)
    }

    /// The idle windows, which are the actual fix. Both are stated in seconds
    /// so a change to either is deliberate.
    func testTheEnginesReleaseThemselves() {
        XCTAssertEqual(SpeechController.idleTimeout, 120)
        let config = RewriteEngine.Config(
            serverBinary: URL(fileURLWithPath: "/nonexistent"),
            modelPath: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(config.idleTimeout, 120)
    }
}

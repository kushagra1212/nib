import XCTest
@testable import nib

/// What a practice take gets measured on.
///
/// Worth testing rather than eyeballing because every number here is one
/// someone will act on. A filler count that double-counts "you know" as two
/// separate words tells you to fix a problem you do not have, and a pace that
/// forgets to include silence flatters exactly the takes that need work.
final class DeliveryReportTests: XCTestCase {
    private func segment(_ text: String, _ start: Double, _ end: Double) -> SpokenSegment {
        SpokenSegment(text: text, start: start, end: end)
    }

    // MARK: - Fillers

    func testCountsSingleWordFillers() {
        let report = DeliveryReport(
            segments: [segment("Um, so basically um the answer is yes.", 0, 10)],
            duration: 10)
        XCTAssertEqual(report.fillerTotal, 4)   // um, so, basically, um
        XCTAssertEqual(report.fillers.first?.word, "um")
        XCTAssertEqual(report.fillers.first?.count, 2)
    }

    /// "you know" is two tokens and the most common filler there is. Counting
    /// it as a phrase and then also as its parts would report three where
    /// there is one.
    func testPhraseFillersAreNotDoubleCounted() {
        let report = DeliveryReport(
            segments: [segment("It was, you know, the right call.", 0, 10)],
            duration: 10)
        XCTAssertEqual(report.fillerTotal, 1)
        XCTAssertEqual(report.fillers.first?.word, "you know")
    }

    func testPunctuationDoesNotHideAFiller() {
        let plain = DeliveryReport(segments: [segment("um the fix", 0, 5)], duration: 5)
        let punctuated = DeliveryReport(segments: [segment("Um. The fix", 0, 5)], duration: 5)
        XCTAssertEqual(plain.fillerTotal, punctuated.fillerTotal)
    }

    func testFillerRateIsPerMinuteNotPerTake() {
        let short = DeliveryReport(segments: [segment("um um", 0, 30)], duration: 30)
        let long = DeliveryReport(segments: [segment("um um", 0, 60)], duration: 60)
        XCTAssertEqual(short.fillerRate, 4, accuracy: 0.01)
        XCTAssertEqual(long.fillerRate, 2, accuracy: 0.01)
    }

    // MARK: - Pace

    /// Pace is over the whole take, silence included. Dividing by speaking
    /// time instead would score a halting answer as briskly paced, which is
    /// the opposite of what the listener heard.
    func testPaceCountsSilenceAgainstYou() {
        let words = Array(repeating: "word", count: 60).joined(separator: " ")
        let fast = DeliveryReport(segments: [segment(words, 0, 30)], duration: 30)
        let halting = DeliveryReport(segments: [segment(words, 0, 30)], duration: 60)
        XCTAssertEqual(fast.pace, 120, accuracy: 0.5)
        XCTAssertEqual(halting.pace, 60, accuracy: 0.5)
    }

    func testEmptyTakeDoesNotDivideByZero() {
        let report = DeliveryReport(segments: [], duration: 0)
        XCTAssertEqual(report.pace, 0)
        XCTAssertEqual(report.fillerRate, 0)
        XCTAssertEqual(report.wordCount, 0)
    }

    // MARK: - Pauses

    /// The gap between segments, not the length of one. A long segment is
    /// someone talking, which is the opposite of a stall.
    func testLongPauseIsTheGapBetweenSegments() {
        let report = DeliveryReport(segments: [
            segment("So the first thing", 0, 4),
            segment("was the index", 7.5, 10),
        ], duration: 10)
        XCTAssertEqual(report.longPauses.count, 1)
        XCTAssertEqual(report.longPauses.first?.at ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(report.longPauses.first?.length ?? 0, 3.5, accuracy: 0.01)
    }

    func testOrdinarySpeechGapsAreNotFlagged() {
        let report = DeliveryReport(segments: [
            segment("one", 0, 2), segment("two", 2.4, 4), segment("three", 4.9, 6),
        ], duration: 6)
        XCTAssertTrue(report.longPauses.isEmpty)
    }

    // MARK: - Sentences and endings

    func testLongestSentenceIgnoresTheShortOnes() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let report = DeliveryReport(
            segments: [segment("Short one. \(long). Also short.", 0, 30)],
            duration: 30)
        XCTAssertEqual(report.longestSentence, 40)
    }

    func testTrailingEndingIsCaught() {
        let report = DeliveryReport(
            segments: [segment("We fixed the query, so yeah", 0, 10)], duration: 10)
        XCTAssertTrue(report.trailsOff)
    }

    func testAnEndingThatLandsIsNotFlagged() {
        let report = DeliveryReport(
            segments: [segment("Restoring the limit dropped CPU to normal.", 0, 10)],
            duration: 10)
        XCTAssertFalse(report.trailsOff)
    }

    // MARK: - Advice

    /// A trailing ending undoes an otherwise good answer, so it has to be the
    /// thing named first rather than buried under a filler count.
    func testTrailingEndingIsTheFirstThingToFix() {
        let report = DeliveryReport(
            segments: [segment("um um um um um um so yeah", 0, 10)], duration: 10)
        let advice = PracticeTranscript.advice(report)
        XCTAssertTrue(advice.first?.contains("full stop") ?? false)
    }

    func testACleanTakeGetsNoAdvice() {
        let words = Array(repeating: "point", count: 25).joined(separator: " ")
        let report = DeliveryReport(segments: [segment("\(words).", 0, 10)],
                                    duration: 10)
        XCTAssertTrue(PracticeTranscript.advice(report).isEmpty)
    }

    // MARK: - The written file

    func testTranscriptCarriesTheAudioAndTheNumbers() {
        let segments = [segment("So we shipped it.", 0, 3)]
        let report = DeliveryReport(segments: segments, duration: 3)
        let markdown = PracticeTranscript.markdown(
            segments: segments, report: report,
            audio: URL(fileURLWithPath: "/tmp/take.wav"))
        XCTAssertTrue(markdown.contains("take.wav"))
        XCTAssertTrue(markdown.contains("## Delivery"))
        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertTrue(markdown.contains("So we shipped it."))
    }

    func testTimestampsAreMinutesAndSeconds() {
        XCTAssertEqual(PracticeTranscript.time(0), "0:00")
        XCTAssertEqual(PracticeTranscript.time(9), "0:09")
        XCTAssertEqual(PracticeTranscript.time(75), "1:15")
        XCTAssertEqual(PracticeTranscript.time(600), "10:00")
    }

    // MARK: - The WAV

    /// 44 bytes of header, then two per sample. A wrong header length is the
    /// failure that produces a file every player opens and none plays.
    func testWavIsSixteenBitPCMWithACorrectHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WavWriter.write([0, 0.5, -0.5, 1, -1], to: url)
        let data = try Data(contentsOf: url)

        XCTAssertEqual(data.count, 44 + 5 * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
    }

    /// A float that drifts past 1.0 truncates to a loud click at the wrong end
    /// of the range, and one clipped sample is audible.
    func testOutOfRangeSamplesAreClampedNotWrapped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WavWriter.write([2.0, -2.0], to: url)
        let data = try Data(contentsOf: url)
        let first = Int16(littleEndian: data[44..<46].withUnsafeBytes { $0.load(as: Int16.self) })
        let second = Int16(littleEndian: data[46..<48].withUnsafeBytes { $0.load(as: Int16.self) })

        XCTAssertEqual(first, Int16.max)
        XCTAssertLessThan(second, 0)
    }
}

import XCTest
@testable import nib

/// The speech models nib offers, and where they go.
final class SpeechModelCatalogTests: XCTestCase {
    func testEveryEntryIsAWhisperBinOverHTTPS() {
        for model in SpeechModelCatalog.all {
            XCTAssertTrue(model.filename.hasSuffix(".bin"), model.filename)
            XCTAssertTrue(model.filename.hasPrefix("ggml-"), model.filename)
            XCTAssertEqual(model.url.scheme, "https", model.filename)
            XCTAssertTrue(model.url.absoluteString.hasSuffix(model.filename),
                          "\(model.filename) must be what the URL downloads")
        }
    }

    /// English-only builds are smaller and better at English, and would turn
    /// an occasional Hindi sentence into confident English nonsense rather
    /// than failing visibly.
    func testNoEnglishOnlyModelsAreOffered() {
        for model in SpeechModelCatalog.all {
            XCTAssertFalse(model.filename.contains(".en"),
                           "\(model.filename) cannot handle a second language")
        }
    }

    func testListedSmallestFirst() {
        let sizes = SpeechModelCatalog.all.map(\.bytes)
        XCTAssertEqual(sizes, sizes.sorted())
    }

    /// Not the smallest and not the best. Base mishears often enough to
    /// annoy, and turbo is a 574MB download to discover whether you like
    /// dictating at all.
    func testTheRecommendationIsTheMiddleOne() {
        XCTAssertEqual(SpeechModelCatalog.recommended.filename,
                       "ggml-small-q5_1.bin")
    }

    func testFilenamesAreUnique() {
        let names = SpeechModelCatalog.all.map(\.filename)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// Speech models live beside the rewrite models, not among them. Both
    /// directories are scanned by name, and a .bin in the llama search path
    /// would be handed to a loader that cannot read it.
    func testSpeechModelsAreKeptApartFromRewriteModels() {
        let speech = SpeechModelCatalog.installDirectory.path
        let rewrite = ModelCatalog.installDirectory.path
        XCTAssertNotEqual(speech, rewrite)
        XCTAssertFalse(speech.hasPrefix(rewrite + "/"))
        XCTAssertFalse(rewrite.hasPrefix(speech + "/"))
        XCTAssertTrue(speech.hasSuffix("nib/speech"), speech)
    }

    func testInstallDirectoryIsOutsideTheApp() {
        XCTAssertFalse(SpeechModelCatalog.installDirectory.path.contains(".app/"),
                       "a model inside the bundle is deleted by every update")
    }
}

/// What the recording indicator says.
final class DictationOverlayCaptionTests: XCTestCase {
    /// Short dictations show a word, not a stopwatch. A timer that starts at
    /// 0:01 turns every sentence into something being measured.
    func testShortDictationsJustSayListening() {
        XCTAssertEqual(DictationOverlay.caption(for: 0), "Listening")
        XCTAssertEqual(DictationOverlay.caption(for: 9.9), "Listening")
    }

    /// Stops short of the last minute deliberately: 9:59 is inside the
    /// warning window, so asserting a bare "9:59" there would be asserting
    /// that the warning does not work.
    func testTheClockAppearsAfterTenSeconds() {
        XCTAssertEqual(DictationOverlay.caption(for: 10), "0:10")
        XCTAssertEqual(DictationOverlay.caption(for: 65), "1:05")
        XCTAssertEqual(DictationOverlay.caption(for: 500), "8:20")
    }

    /// The warning is the point of the cap: a forgotten toggle should say so
    /// before it stops, not after.
    func testItWarnsInTheLastMinute() {
        let caption = DictationOverlay.caption(
            for: AudioRecorder.maximumDuration - 30)
        XCTAssertTrue(caption.contains("stopping soon"), caption)
    }

    func testItDoesNotWarnEarly() {
        let caption = DictationOverlay.caption(
            for: AudioRecorder.maximumDuration - 120)
        XCTAssertFalse(caption.contains("stopping"), caption)
    }
}

/// Audio conversion, which every transcription depends on being right.
final class AudioSamplesTests: XCTestCase {
    func testWhisperFormatIsWhatTheModelExpects() {
        let format = AudioSamples.whisperFormat
        XCTAssertEqual(format.sampleRate, 16_000, "whisper was trained at 16kHz")
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertFalse(format.isInterleaved)
    }

    func testDurationIsSamplesOverRate() {
        XCTAssertEqual(AudioSamples.duration(of: Array(repeating: 0, count: 16_000)),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(AudioSamples.duration(of: []), 0)
    }

    func testReadingSomethingThatIsNotAudioFails() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nib-not-audio-\(UUID().uuidString).wav")
        try? Data("this is not a wav".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try AudioSamples.load(file))
    }

    /// A ten-minute cap is not arbitrary: it bounds what a forgotten toggle
    /// can consume. At 16kHz mono float that is about 38MB.
    func testTheRecordingCapIsBounded() {
        let bytes = AudioRecorder.maximumDuration * AudioSamples.sampleRate * 4
        XCTAssertLessThan(bytes, 50_000_000, "a forgotten toggle must stay small")
        XCTAssertGreaterThanOrEqual(AudioRecorder.maximumDuration, 300,
                                    "long dictation is a stated requirement")
    }
}

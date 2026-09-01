import CryptoKit
import XCTest
@testable import nib

/// Trimming, levelling, state and voice names.
///
/// The trim tests are the ones that matter: they run the real model, trim what
/// it returns, and expect the exact range the Python engine trimmed to. The
/// rest is pure and runs anywhere.
final class SpeechPipelineTests: XCTestCase {
    private struct Golden: Decodable {
        struct Trimmed: Decodable {
            let sample_count: Int
            let start: Int
            let end: Int
            let sha256_float32_le: String
            let first_8: [Float]
            let last_8: [Float]
            let top_db: Float
            let frame_length: Int
            let hop_length: Int
        }
        let token_ids: [Int]
        let voice: String
        let speed: Float
        let style_row: Int
        let intra_op_threads: Int32
        let sample_count: Int
        let has_duration_output: Bool
        let trimmed: Trimmed
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func rawSamples() throws -> [Float] {
        let runtime = Self.repository
            .appendingPathComponent("vendor/onnx/libonnxruntime.dylib")
        guard FileManager.default.fileExists(atPath: runtime.path) else {
            throw XCTSkip("no ONNX Runtime; run Scripts/fetch-onnx.sh")
        }
        guard let modelPath = ProcessInfo.processInfo.environment["NIB_KOKORO_MODEL"]
                ?? Self.installed("kokoro-v1.0.onnx"),
              let packPath = ProcessInfo.processInfo.environment["NIB_VOICE_PACK"]
                ?? Self.installed("voices-v1.0.bin") else {
            throw XCTSkip("no kokoro model; set NIB_KOKORO_MODEL and NIB_VOICE_PACK")
        }

        let reference = try golden()
        let engine = try KokoroEngine(model: URL(fileURLWithPath: modelPath),
                                      runtime: runtime,
                                      threads: reference.intra_op_threads)
        let style = try VoicePack(url: URL(fileURLWithPath: packPath))
            .style(for: reference.voice, tokenCount: reference.style_row + 1)
        return try engine.synthesise(tokens: reference.token_ids, style: style,
                                     speed: reference.speed)
    }

    private static func installed(_ name: String) -> String? {
        let url = VoiceCatalog.installDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    // MARK: - Trimming

    /// The model pads what it produces. The golden sentence is 79200 samples
    /// of which 15200 are silence -- six tenths of a second before the first
    /// word, every time.
    func testTrimFindsTheSameRangeAsTheEngine() throws {
        let samples = try rawSamples()
        let reference = try golden()
        let bounds = AudioTrim.bounds(of: samples)

        XCTAssertEqual(bounds.lowerBound, reference.trimmed.start)
        XCTAssertEqual(bounds.upperBound, reference.trimmed.end)
        XCTAssertEqual(bounds.count, reference.trimmed.sample_count)
    }

    func testTheTrimmedSamplesMatchTheEngine() throws {
        let samples = try rawSamples()
        let reference = try golden()
        let trimmed = AudioTrim.trimmed(samples)

        XCTAssertEqual(Self.digest(trimmed), reference.trimmed.sha256_float32_le)
        for (index, expected) in reference.trimmed.first_8.enumerated() {
            XCTAssertEqual(trimmed[index], expected, accuracy: 1e-9, "sample \(index)")
        }
    }

    /// Trimming has to actually remove something, or a test that compares
    /// "trimmed" with "raw" passes while doing nothing.
    func testTrimmingRemovesRealSilence() throws {
        let reference = try golden()
        XCTAssertLessThan(reference.trimmed.sample_count, reference.sample_count)
        XCTAssertGreaterThan(reference.sample_count - reference.trimmed.sample_count,
                             1000, "trimming barely did anything; check the fixture")
    }

    /// The constants librosa is called with. Changing one changes where every
    /// sentence starts, and the fixture was captured with these.
    func testTheTrimSettingsMatchTheFixture() throws {
        let reference = try golden()
        XCTAssertEqual(AudioTrim.topDB, reference.trimmed.top_db)
        XCTAssertEqual(AudioTrim.frameLength, reference.trimmed.frame_length)
        XCTAssertEqual(AudioTrim.hopLength, reference.trimmed.hop_length)
    }

    /// Pause insertion is skipped, and this records why: it needs per-phoneme
    /// timings, and this export has one output with no `duration` beside it.
    /// If a future model gains one, this fails and says to port it.
    func testTheModelHasNoTimingsSoPausesAreNotInserted() throws {
        XCTAssertFalse(try golden().has_duration_output,
                       "this export reports durations; kokoro's insert_pauses "
                       + "now applies and has not been ported")
    }

    // MARK: - Trimming, without the model

    /// Silence throughout is left alone rather than reduced to nothing.
    /// librosa's reference is the loudest frame, so a uniformly quiet signal
    /// has nothing below it.
    func testDigitalSilenceIsNotTrimmedToNothing() {
        let silence = [Float](repeating: 0, count: 24000)
        XCTAssertEqual(AudioTrim.bounds(of: silence), 0..<0)
    }

    func testShortInputIsHandled() {
        XCTAssertEqual(AudioTrim.trimmed([]), [])
        XCTAssertEqual(AudioTrim.bounds(of: [0.5, -0.5]).isEmpty, false)
    }

    /// A tone with silence around it keeps the tone.
    func testSilenceAroundSoundIsRemoved() {
        var samples = [Float](repeating: 0, count: 8192)
        for index in 4096..<6144 {
            samples[index] = sin(Float(index) * 0.1) * 0.8
        }
        let bounds = AudioTrim.bounds(of: samples)
        XCTAssertGreaterThan(bounds.lowerBound, 2048)
        XCTAssertLessThan(bounds.upperBound, 8192)
        XCTAssertGreaterThan(bounds.count, 1024)
    }

    // MARK: - Volume

    /// Clipped, not scaled. Past full scale it crackles rather than getting
    /// louder, and wrapping around would be worse than either.
    func testVolumeClipsRatherThanWrapping() {
        let loud: [Float] = [2.0, -2.0, 0.5]
        let result = SpeechSynthesizer.leveled(loud, volume: 1.0)
        XCTAssertEqual(result, [1.0, -1.0, 0.5])
    }

    func testVolumeScalesTheSamples() {
        XCTAssertEqual(SpeechSynthesizer.leveled([1.0, -1.0], volume: 0.45),
                       [0.45, -0.45])
    }

    /// The settings carried over from `voice status` on the setup nib replaces.
    /// The instruction was to move it without changing how it works, and these
    /// four numbers are most of what "how it works" means to the ear.
    func testTheDefaultsAreTheOnesCarriedOver() {
        XCTAssertEqual(SpeechSynthesizer.defaultVolume, 0.45)
        XCTAssertEqual(SpeechSynthesizer.defaultSpeed, 1.0)
        XCTAssertEqual(SpeechSynthesizer.defaultSentencePause, 0.25)
        XCTAssertEqual(SpeechSynthesizer.defaultClausePause, 0.1)
        XCTAssertEqual(VoiceCatalog.defaultVoice, "af_heart")
    }

    // MARK: - The state machine

    func testTheHotkeyStartsFromIdle() {
        XCTAssertEqual(SpeechState.idle.next(for: .toggled), .preparing)
    }

    func testTheHotkeyStopsWhateverStageItIsAt() {
        for state: SpeechState in [.preparing, .synthesising, .speaking] {
            XCTAssertEqual(state.next(for: .toggled), .idle, "\(state)")
        }
    }

    /// Hush only ever stops. It is a global key, and clearing a failure the
    /// user has not read yet would hide the reason nothing was spoken.
    func testHushDoesNothingWhenNothingIsSpeaking() {
        XCTAssertNil(SpeechState.idle.next(for: .hushed))
        XCTAssertNil(SpeechState.failed("no model").next(for: .hushed))
    }

    func testHushStopsAtEveryBusyStage() {
        for state: SpeechState in [.preparing, .synthesising, .speaking] {
            XCTAssertEqual(state.next(for: .hushed), .idle, "\(state)")
        }
    }

    func testTheHappyPathRunsToTheEnd() {
        var state = SpeechState.idle
        for event: SpeechEvent in [.toggled, .loaded, .synthesised, .finished] {
            state = try! XCTUnwrap(state.next(for: event))
        }
        XCTAssertEqual(state, .idle)
    }

    /// A second press while synthesising must cancel, not start a second one on
    /// top of the first -- which would speak the same sentence twice at once.
    func testASecondPressCancelsRatherThanStacking() {
        XCTAssertEqual(SpeechState.synthesising.next(for: .toggled), .idle)
    }

    func testAFailureCanBeRetried() {
        XCTAssertEqual(SpeechState.failed("no model").next(for: .toggled), .preparing)
    }

    func testFinishedOnlyAppliesWhileSpeaking() {
        XCTAssertNil(SpeechState.idle.next(for: .finished))
        XCTAssertNil(SpeechState.preparing.next(for: .finished))
    }

    // MARK: - Voice names

    /// 54 raw identifiers is a menu nobody reads to the end of.
    func testVoiceNamesAreReadable() {
        XCTAssertEqual(VoiceNames.title(for: "af_heart"), "Heart — American, female")
        XCTAssertEqual(VoiceNames.title(for: "bm_george"), "George — British, male")
        XCTAssertEqual(VoiceNames.title(for: "jf_alpha"), "Alpha — Japanese, female")
    }

    func testAnUnknownVoiceNameIsLeftAlone() {
        XCTAssertEqual(VoiceNames.title(for: "nonsense"), "nonsense")
    }

    /// Every voice in the real pack must produce a readable name, or the menu
    /// shows raw identifiers for some of them and not others.
    func testEveryVoiceInThePackHasAReadableName() throws {
        guard let path = ProcessInfo.processInfo.environment["NIB_VOICE_PACK"]
                ?? Self.installed("voices-v1.0.bin") else {
            throw XCTSkip("no voices-v1.0.bin")
        }
        for name in try VoicePack(url: URL(fileURLWithPath: path)).names {
            let title = VoiceNames.title(for: name)
            XCTAssertNotEqual(title, name, "\(name) has no readable name")
            XCTAssertTrue(title.contains("—"), "\(name) -> \(title)")
        }
    }

    private static func digest(_ values: [Float]) -> String {
        var bytes = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

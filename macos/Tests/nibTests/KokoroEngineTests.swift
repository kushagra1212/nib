import CryptoKit
import XCTest
@testable import nib

/// The inference itself, against what the Python engine's onnxruntime returned.
///
/// This is the last of the three unknowns the speech design named. The
/// tokeniser and the voice pack were closed first on purpose: both of this
/// call's inputs are already known to match the engine, so a difference in the
/// audio can only be the inference.
///
/// The fixture is deliberately not `kokoro-golden.json`. That one records
/// `kokoro.create(...)`, which is inference plus trimming plus pauses -- three
/// things, one hash, and no way to tell which disagreed. `audio-golden.json`
/// runs onnxruntime directly on the same 53 tokens and the same style row.
///
/// Skips without the model, which is a 326MB download.
final class KokoroEngineTests: XCTestCase {
    private struct Golden: Decodable {
        let onnxruntime_version: String
        let intra_op_threads: Int32
        let token_ids: [Int]
        let token_input_name: String
        let style_row: Int
        let style_sha256: String
        let sample_count: Int
        let sha256_float32_le: String
        let first_8: [Float]
        let last_8: [Float]
        let peak: Float
        let voice: String
        let speed: Float
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

    /// The model, wherever it is. nib installs it under Application Support;
    /// the machine this was written on also has the Python setup's copy.
    private static func modelPath() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NIB_KOKORO_MODEL"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(VoiceCatalog.installDirectory
            .appendingPathComponent("kokoro-v1.0.onnx"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func voicePackPath() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NIB_VOICE_PACK"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(VoiceCatalog.installDirectory
            .appendingPathComponent("voices-v1.0.bin"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func engine() throws -> KokoroEngine {
        let runtime = Self.repository
            .appendingPathComponent("vendor/onnx/libonnxruntime.dylib")
        guard FileManager.default.fileExists(atPath: runtime.path) else {
            throw XCTSkip("no ONNX Runtime; run Scripts/fetch-onnx.sh")
        }
        guard let model = Self.modelPath() else {
            throw XCTSkip("no kokoro model; set NIB_KOKORO_MODEL to one")
        }
        return try KokoroEngine(model: model, runtime: runtime,
                                threads: try golden().intra_op_threads)
    }

    // MARK: - Where the runtime lives

    func testNoCandidateIsSomebodysHomeDirectory() {
        let candidates = KokoroEngine.runtimeCandidates(
            bundleResources: URL(fileURLWithPath: "/Applications/nib.app/Contents/Resources"),
            executable: URL(fileURLWithPath: "/repo/.build/release/nib"))
        for url in candidates {
            XCTAssertFalse(url.path.hasPrefix("/Users/"), "\(url.path)")
        }
    }

    func testTheBundledRuntimeComesFirst() {
        let candidates = KokoroEngine.runtimeCandidates(
            bundleResources: URL(fileURLWithPath: "/Applications/nib.app/Contents/Resources"),
            executable: URL(fileURLWithPath: "/repo/.build/release/nib"))
        XCTAssertEqual(candidates.first?.path,
                       "/Applications/nib.app/Contents/Resources/onnx/libonnxruntime.dylib")
    }

    // MARK: - The comparison that matters

    /// Same tokens, same style, same samples. Bit for bit.
    func testTheSamplesMatchTheEngine() throws {
        let engine = try engine()
        let reference = try golden()
        let samples = try engine.synthesise(tokens: reference.token_ids,
                                            style: try style(reference),
                                            speed: reference.speed)

        XCTAssertEqual(samples.count, reference.sample_count)
        XCTAssertEqual(Self.digest(samples), reference.sha256_float32_le,
                       "the inference disagrees with onnxruntime in Python")
    }

    /// The same result through individual numbers, so a mismatch reads as
    /// "0.00013 became -0.4" rather than as two hashes that differ.
    func testTheFirstAndLastSamplesMatch() throws {
        let engine = try engine()
        let reference = try golden()
        let samples = try engine.synthesise(tokens: reference.token_ids,
                                            style: try style(reference),
                                            speed: reference.speed)

        for (index, expected) in reference.first_8.enumerated() {
            XCTAssertEqual(samples[index], expected, accuracy: 1e-9, "sample \(index)")
        }
        for (offset, expected) in reference.last_8.enumerated() {
            let index = samples.count - reference.last_8.count + offset
            XCTAssertEqual(samples[index], expected, accuracy: 1e-9, "sample \(index)")
        }
    }

    /// Silence would pass a length check and a peak check on its own. This is
    /// what distinguishes "it ran" from "it spoke".
    func testTheOutputIsNotSilence() throws {
        let engine = try engine()
        let reference = try golden()
        let samples = try engine.synthesise(tokens: reference.token_ids,
                                            style: try style(reference),
                                            speed: reference.speed)
        let peak = samples.map(abs).max() ?? 0
        XCTAssertEqual(peak, reference.peak, accuracy: 1e-6)
        XCTAssertGreaterThan(peak, 0.1, "the model returned near-silence")
    }

    // MARK: - What the model reports

    /// A different runtime can produce different samples for the same input, so
    /// the fixture says which one it was captured with.
    func testTheRuntimeIsTheOneTheFixtureUsed() throws {
        let engine = try engine()
        XCTAssertEqual(engine.runtimeVersion, try golden().onnxruntime_version)
    }

    /// The fixture has to describe what nib actually ships. Capturing at one
    /// thread count and running at another gives audio that sounds right and
    /// hashes wrong, which reads as a broken port rather than a stale fixture.
    func testTheFixtureWasCapturedAtTheShippedThreadCount() throws {
        XCTAssertEqual(try golden().intra_op_threads, KokoroEngine.threads)
    }

    /// Read from the model rather than assumed. This export says `tokens`;
    /// newer ones say `input_ids`, and guessing wrong fails at every synthesis.
    func testTheTokenInputNameIsReadFromTheModel() throws {
        let engine = try engine()
        XCTAssertEqual(engine.tokenInputName, try golden().token_input_name)
    }

    // MARK: - The inputs, end to end

    /// The style handed to the model comes from the voice pack reader, not from
    /// the fixture, so this is the two verified pieces meeting.
    func testTheVoicePackSuppliesTheStyleTheFixtureRecorded() throws {
        let reference = try golden()
        let style = try style(reference)
        XCTAssertEqual(Self.digest(style), reference.style_sha256)
        XCTAssertEqual(style.count, 256)
    }

    // MARK: - Edges

    func testNoTokensIsRefused() throws {
        let engine = try engine()
        XCTAssertThrowsError(try engine.synthesise(tokens: [], style: [0]))
    }

    /// A missing model names the file rather than failing inside the runtime.
    func testAMissingModelIsReportedByName() {
        let runtime = Self.repository
            .appendingPathComponent("vendor/onnx/libonnxruntime.dylib")
        XCTAssertThrowsError(
            try KokoroEngine(model: URL(fileURLWithPath: "/nonexistent/model.onnx"),
                             runtime: runtime)) { error in
            XCTAssertTrue("\(error)".contains("model.onnx"), "got: \(error)")
        }
    }

    func testAMissingRuntimeSaysWhichScriptToRun() {
        XCTAssertThrowsError(
            try KokoroEngine(model: URL(fileURLWithPath: "/nonexistent/model.onnx"),
                             runtime: URL(fileURLWithPath: "/nonexistent/lib.dylib")))
    }

    // MARK: - Helpers

    private func style(_ reference: Golden) throws -> [Float] {
        guard let path = Self.voicePackPath() else {
            throw XCTSkip("no voices-v1.0.bin; set NIB_VOICE_PACK to one")
        }
        return try VoicePack(url: path).style(for: reference.voice,
                                              tokenCount: reference.style_row + 1)
    }

    private static func digest(_ values: [Float]) -> String {
        var bytes = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

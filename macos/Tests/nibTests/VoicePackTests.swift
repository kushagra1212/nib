import CryptoKit
import XCTest
@testable import nib

/// Reading voices-v1.0.bin: the 28MB archive that decides how nib sounds.
///
/// Two kinds of test here, deliberately separated.
///
/// The first kind parses handwritten headers and runs anywhere, including CI
/// where the archive is absent. The second reads the real file and compares
/// against `Tests/Fixtures/voices-golden.json`, captured from the Python engine
/// by `Scripts/capture-voice-golden.py`; those skip when it is not installed.
///
/// The failure being guarded against is quiet. A style vector read from the
/// wrong row is not corrupt, it is a real voice with the wrong intonation --
/// which sounds like a mediocre model rather than a bug, and so never gets
/// reported as one.
final class VoicePackTests: XCTestCase {

    // MARK: - The numpy header, without the archive

    /// The exact header the pack carries, byte for byte.
    private let realHeader = "{'descr': '<f4', 'fortran_order': False, "
        + "'shape': (510, 1, 256), }"

    /// numpy pads the header with spaces so the numbers begin on a 64-byte
    /// boundary. For this header that is offset 128: 10 bytes of magic, version
    /// and length, then 117 spaces-and-text and the newline that ends it.
    private static let realDataOffset = 128

    private func npy(_ header: String, major: UInt8 = 1) -> Data {
        var data = Data([0x93]) + Data("NUMPY".utf8) + Data([major, 0])
        let width = Self.realDataOffset - 10 - 1
        let padded = header.padding(toLength: max(header.count, width),
                                    withPad: " ", startingAt: 0) + "\n"
        let length = UInt16(padded.utf8.count)
        data.append(UInt8(length & 0xFF))
        data.append(UInt8(length >> 8))
        data.append(Data(padded.utf8))
        return data
    }

    func testTheHeaderGivesTheShapeAndWhereTheNumbersStart() throws {
        let layout = try NumpyLayout.parse(npy(realHeader))
        XCTAssertEqual(layout.shape, [510, 1, 256])
        XCTAssertEqual(layout.rows, 510)
        XCTAssertEqual(layout.columns, 256)
        // 6 magic + 2 version + 2 length + the padded header itself.
        XCTAssertEqual(layout.dataOffset, Self.realDataOffset)
    }

    /// A row is every number under the first axis, not the last axis alone.
    /// Shape here is (510, 1, 256), so a row is 1 x 256.
    func testARowIsEverythingBelowTheFirstAxis() throws {
        XCTAssertEqual(try NumpyLayout.parse(npy(realHeader)).elementsPerRow, 256)
    }

    /// Big-endian, float64 and int16 would all be read as little-endian float32
    /// and produce numbers, not an error. Refused by name instead.
    func testOnlyLittleEndianFloat32IsAccepted() {
        for descr in ["'>f4'", "'<f8'", "'<i2'", "'|u1'"] {
            let header = "{'descr': \(descr), 'fortran_order': False, "
                + "'shape': (510, 1, 256), }"
            XCTAssertThrowsError(try NumpyLayout.parse(npy(header)),
                                 "\(descr) must be refused, not reinterpreted")
        }
    }

    /// Column-major would put the wrong numbers in every row while still
    /// filling the vector with plausible floats.
    func testFortranOrderIsRefused() {
        let header = "{'descr': '<f4', 'fortran_order': True, "
            + "'shape': (510, 1, 256), }"
        XCTAssertThrowsError(try NumpyLayout.parse(npy(header)))
    }

    func testANonNumpyFileIsRefused() {
        XCTAssertThrowsError(try NumpyLayout.parse(Data("PK\u{03}\u{04}nonsense".utf8)))
    }

    /// numpy writes version 2 when the header outgrows 65535 bytes, and the
    /// length field widens from 2 bytes to 4.
    func testVersionTwoHeadersAreRead() throws {
        var data = Data([0x93]) + Data("NUMPY".utf8) + Data([2, 0])
        let header = realHeader + " \n"
        var length = UInt32(header.utf8.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(Data(header.utf8))

        let layout = try NumpyLayout.parse(data)
        XCTAssertEqual(layout.shape, [510, 1, 256])
        XCTAssertEqual(layout.dataOffset, 12 + header.utf8.count)
    }

    // MARK: - The real archive

    private struct Golden: Decodable {
        struct Sample: Decodable {
            let voice: String
            let row: Int
            let count: Int
            let first_4: [Float]
            let last_4: [Float]
            let sha256_float32_le: String
        }
        let voice_count: Int
        let voices: [String]
        let rows: Int
        let style_dimensions: Int
        let all_entries_stored: Bool
        let samples: [Sample]
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/voices-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    /// Skips rather than fails where the pack is not installed, and says how to
    /// point at one -- a silently passing test here would be worse than none.
    private func pack() throws -> VoicePack {
        guard let url = VoicePackTests.installedPack() else {
            throw XCTSkip("no voices-v1.0.bin; set NIB_VOICE_PACK to one")
        }
        return try VoicePack(url: url)
    }

    private static func installedPack() -> URL? {
        if let path = ProcessInfo.processInfo.environment["NIB_VOICE_PACK"] {
            return URL(fileURLWithPath: path)
        }
        let installed = VoiceCatalog.installDirectory
            .appendingPathComponent("voices-v1.0.bin")
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    func testEveryVoiceInTheArchiveIsFound() throws {
        // Bound before asserting, here and below. An XCTSkip is thrown, so
        // `XCTAssertEqual(try pack()...)` catches the skip and reports it as a
        // failure -- which turns "no pack installed" into a red suite on any
        // machine that does not have the 28MB file.
        let pack = try pack()
        let reference = try golden()
        XCTAssertEqual(pack.names, reference.voices)
        XCTAssertEqual(pack.names.count, reference.voice_count)
    }

    /// The comparison that matters: the style the golden sentence uses, as the
    /// Python engine returned it.
    func testTheStyleMatchesTheEngine() throws {
        let pack = try pack()
        for sample in try golden().samples {
            let style = try pack.style(for: sample.voice, tokenCount: sample.row + 1)
            XCTAssertEqual(style.count, sample.count)
            XCTAssertEqual(VoicePackTests.digest(style), sample.sha256_float32_le,
                           "\(sample.voice) row \(sample.row) differs from the engine")
        }
    }

    /// Same rows again through the individual numbers, so a byte-order or
    /// stride mistake reads as "-0.222 became 1.7e-38" rather than as a hash
    /// that does not match.
    func testTheNumbersThemselvesMatch() throws {
        let pack = try pack()
        for sample in try golden().samples {
            let style = try pack.style(for: sample.voice, tokenCount: sample.row + 1)
            for (index, expected) in sample.first_4.enumerated() {
                XCTAssertEqual(style[index], expected, accuracy: 1e-9,
                               "\(sample.voice)[\(sample.row)][\(index)]")
            }
            for (offset, expected) in sample.last_4.enumerated() {
                let index = style.count - sample.last_4.count + offset
                XCTAssertEqual(style[index], expected, accuracy: 1e-9,
                               "\(sample.voice)[\(sample.row)][\(index)]")
            }
        }
    }

    /// `voice[min(len(tokens), len(voice)) - 1]`. One token reads row 0, and
    /// anything longer than the pack clamps to the last row rather than failing.
    func testTheRowIsTheTokenCountMinusOne() throws {
        let pack = try pack()
        let reference = try golden()
        let last = try pack.style(for: "af_heart", tokenCount: reference.rows)
        for beyond in [reference.rows + 1, 9_999] {
            XCTAssertEqual(try pack.style(for: "af_heart", tokenCount: beyond), last,
                           "\(beyond) tokens should clamp, not read past the end")
        }
    }

    /// Zero tokens would index row -1, which in Python wraps to the last row and
    /// in Swift traps. Neither is an answer, so it is refused.
    func testAnEmptySentenceIsRefused() throws {
        let pack = try pack()
        XCTAssertThrowsError(try pack.style(for: "af_heart", tokenCount: 0))
    }

    /// Names the voice, because the menu and the archive can disagree.
    func testAnUnknownVoiceSaysWhichOne() throws {
        let pack = try pack()
        XCTAssertThrowsError(try pack.style(for: "af_nonexistent", tokenCount: 10)) {
            XCTAssertTrue("\($0)".contains("af_nonexistent"), "got: \($0)")
        }
    }

    /// Two voices at the same row must differ, which fails if every entry
    /// resolves to the same offset in the archive.
    func testEachVoiceReadsItsOwnEntry() throws {
        let pack = try pack()
        let heart = try pack.style(for: "af_heart", tokenCount: 53)
        let adam = try pack.style(for: "am_adam", tokenCount: 53)
        XCTAssertNotEqual(heart, adam)
    }

    /// All 54, not just the sampled three: one entry with a different extra
    /// field in its local header would otherwise go unnoticed until someone
    /// picked that voice.
    func testAllFiftyFourVoicesAreReadable() throws {
        let pack = try pack()
        let dimensions = try golden().style_dimensions
        for name in pack.names {
            let style = try pack.style(for: name, tokenCount: 1)
            XCTAssertEqual(style.count, dimensions, "\(name)")
            XCTAssertFalse(style.allSatisfy { $0 == 0 }, "\(name) read as silence")
        }
    }

    /// Stored, not deflated. The whole reason a style costs one 1KB read rather
    /// than decompressing 28MB, and a future pack that changes it must fail
    /// loudly here rather than produce noise.
    func testTheArchiveIsStoredNotCompressed() throws {
        let pack = try pack()
        XCTAssertTrue(try golden().all_entries_stored)
        XCTAssertTrue(pack.isStored)
    }

    /// Hashed the way numpy writes them -- little-endian float32, in order --
    /// so this can be compared with what Python produced from `tobytes()`.
    private static func digest(_ values: [Float]) -> String {
        var bytes = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

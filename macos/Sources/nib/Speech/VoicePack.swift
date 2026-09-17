import Foundation

/// The 54 voices, and the one style vector a sentence needs.
///
/// `voices-v1.0.bin` is a 28MB zip of 54 numpy arrays, each 510 rows of 256
/// floats. Synthesis uses exactly one row: the model is handed 256 numbers that
/// describe how to sound, chosen by how many tokens the sentence has.
///
/// Which is why nothing here loads the file. Every entry is stored rather than
/// deflated, so a style is a seek and a 1KB read; holding 28MB resident to
/// return 1KB of it would also break the rule that nib keeps nothing in memory
/// between uses.
///
/// The row index is the part worth being careful about. It is the token count
/// minus one, and reading the neighbouring row is not an error -- it is the
/// right voice with slightly wrong intonation, which gets blamed on the model.
/// `VoicePackTests` compares three rows against what the Python engine returns.
struct VoicePack {
    /// One voice: where its numbers start in the file, and how they are shaped.
    private struct Entry {
        let dataOffset: Int
        let rows: Int
        let elementsPerRow: Int
    }

    private let url: URL
    private let entries: [String: Entry]

    /// Every voice in the pack, sorted, as the menu shows them.
    let names: [String]

    /// Whether the archive is stored throughout, which is what makes a style a
    /// single small read.
    let isStored: Bool

    enum Failure: Error, CustomStringConvertible {
        case noVoices(URL)
        case unknownVoice(String, available: Int)
        case emptySentence

        var description: String {
            switch self {
            case .noVoices(let url):
                return "no voices in \(url.lastPathComponent); expected an archive "
                    + "of .npy files"
            case .unknownVoice(let name, let available):
                return "no voice named \(name) in the pack, which has \(available)"
            case .emptySentence:
                return "no tokens to speak, so there is no style to choose"
            }
        }
    }

    private static let suffix = ".npy"

    init(url: URL) throws {
        self.url = url

        let members = try ZipDirectory.entries(of: url)
            .filter { $0.name.hasSuffix(Self.suffix) }
        guard !members.isEmpty else { throw Failure.noVoices(url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var entries: [String: Entry] = [:]
        var stored = true
        for member in members {
            guard member.isStored else {
                throw ZipDirectory.Failure.compressed(name: member.name,
                                                      method: member.compressionMethod)
            }
            // Every header is read now rather than when a voice is first picked.
            // A malformed entry should be a failure at load, where there is a
            // window to say so, not halfway through speaking a sentence.
            let start = try ZipDirectory.dataOffset(of: member, in: handle)
            let header = try ZipDirectory.read(handle, at: start,
                                               count: min(512, member.compressedSize),
                                               describing: "a numpy header")
            let layout = try NumpyLayout.parse(header)

            let name = String(member.name.dropLast(Self.suffix.count))
            entries[name] = Entry(dataOffset: start + layout.dataOffset,
                                  rows: layout.rows,
                                  elementsPerRow: layout.elementsPerRow)
            stored = stored && member.isStored
        }

        self.entries = entries
        self.names = entries.keys.sorted()
        self.isStored = stored
    }

    /// The 256 numbers describing how this voice says a sentence of this length.
    ///
    /// Matches kokoro_onnx's `voice[min(len(tokens), len(voice)) - 1]`: one row
    /// per token count, and anything longer than the pack uses the last row.
    /// Clamping rather than failing, because a 600-token sentence is a normal
    /// thing to say and the engine has always spoken it with row 509.
    func style(for name: String, tokenCount: Int) throws -> [Float] {
        guard tokenCount > 0 else { throw Failure.emptySentence }
        guard let entry = entries[name] else {
            throw Failure.unknownVoice(name, available: entries.count)
        }

        let row = min(tokenCount, entry.rows) - 1
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let offset = entry.dataOffset + row * entry.elementsPerRow * 4
        let data = try ZipDirectory.read(handle, at: offset,
                                         count: entry.elementsPerRow * 4,
                                         describing: "the style for \(name)")
        return Self.floats(data, count: entry.elementsPerRow)
    }

    /// Little-endian float32, assembled a byte at a time.
    ///
    /// The offsets in a zip are not aligned, so loading four bytes as a UInt32
    /// is undefined behaviour even though it works on this hardware.
    private static func floats(_ data: Data, count: Int) -> [Float] {
        let base = data.startIndex
        return (0..<count).map { index in
            let at = base + index * 4
            let bits = UInt32(data[at])
                | UInt32(data[at + 1]) << 8
                | UInt32(data[at + 2]) << 16
                | UInt32(data[at + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}

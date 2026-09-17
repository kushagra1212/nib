import Foundation

/// Where each member of a zip archive begins, without unpacking any of it.
///
/// Enough of the zip format to find one member's bytes and nothing more. The
/// voice pack is 28MB of 54 uncompressed arrays and a synthesis needs 1KB of
/// one of them, so the useful operation is "seek here" rather than "extract".
///
/// Decompression is deliberately absent. Every entry in the pack is stored, so
/// a deflated one means the format changed; refusing it by name beats reading
/// compressed bytes as floats, which yields noise rather than an error.
enum ZipDirectory {
    struct Entry {
        let name: String
        /// 0 is stored, 8 is deflate. Only 0 can be read here.
        let compressionMethod: Int
        let compressedSize: Int
        let uncompressedSize: Int
        /// Of the local header, which is not where the data starts -- the local
        /// header restates the name and extra field, at lengths that need not
        /// match the ones in the central directory.
        let localHeaderOffset: Int

        var isStored: Bool { compressionMethod == 0 }
    }

    enum Failure: Error, CustomStringConvertible {
        case notAZip
        case truncated(String)
        case zip64
        case compressed(name: String, method: Int)

        var description: String {
            switch self {
            case .notAZip:
                return "not a zip archive: no end-of-central-directory record"
            case .truncated(let what):
                return "the archive ends in the middle of \(what)"
            case .zip64:
                return "zip64 archives are not read here; the voice pack is 28MB "
                    + "and should be well inside the 4GB limit"
            case .compressed(let name, let method):
                return "\(name) is compressed (method \(method)) and this reads "
                    + "stored entries only"
            }
        }
    }

    private static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    private static let centralFileHeader: UInt32 = 0x0201_4B50
    private static let localFileHeader: UInt32 = 0x0403_4B50

    /// The largest an end record can be: 22 fixed bytes and a 65535-byte comment.
    private static let maxEndRecord = 22 + 0xFFFF

    static func entries(of url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = Int(try handle.seekToEnd())
        let tailLength = min(size, maxEndRecord)
        let tail = try read(handle, at: size - tailLength, count: tailLength,
                            describing: "the end of the archive")

        guard let end = lastIndex(of: endOfCentralDirectory, in: tail) else {
            throw Failure.notAZip
        }
        let count = int(tail, at: end + 10, bytes: 2)
        let directorySize = int(tail, at: end + 12, bytes: 4)
        let directoryOffset = int(tail, at: end + 16, bytes: 4)
        guard directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else {
            throw Failure.zip64
        }

        let directory = try read(handle, at: directoryOffset, count: directorySize,
                                 describing: "the central directory")
        return try parse(directory, expecting: count)
    }

    private static func parse(_ directory: Data, expecting count: Int) throws -> [Entry] {
        var entries: [Entry] = []
        var cursor = 0
        while entries.count < count {
            guard cursor + 46 <= directory.count else {
                throw Failure.truncated("a central directory entry")
            }
            guard int(directory, at: cursor, bytes: 4) == Int(centralFileHeader) else {
                throw Failure.truncated("the central directory")
            }

            let nameLength = int(directory, at: cursor + 28, bytes: 2)
            let extraLength = int(directory, at: cursor + 30, bytes: 2)
            let commentLength = int(directory, at: cursor + 32, bytes: 2)
            let nameStart = directory.startIndex + cursor + 46
            guard nameStart + nameLength <= directory.endIndex else {
                throw Failure.truncated("an entry name")
            }
            let name = String(decoding: directory[nameStart..<nameStart + nameLength],
                              as: UTF8.self)

            entries.append(Entry(
                name: name,
                compressionMethod: int(directory, at: cursor + 10, bytes: 2),
                compressedSize: int(directory, at: cursor + 20, bytes: 4),
                uncompressedSize: int(directory, at: cursor + 24, bytes: 4),
                localHeaderOffset: int(directory, at: cursor + 42, bytes: 4)))

            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Where an entry's bytes actually begin.
    ///
    /// The local header has to be read for this. Its name and extra field are
    /// separate from the central directory's, and archives written for aligned
    /// reads pad the local extra field to move the data -- so computing this
    /// from the central directory alone lands a few bytes off, which reads as
    /// numbers rather than as a failure.
    static func dataOffset(of entry: Entry, in handle: FileHandle) throws -> Int {
        let header = try read(handle, at: entry.localHeaderOffset, count: 30,
                              describing: "a local file header")
        guard int(header, at: 0, bytes: 4) == Int(localFileHeader) else {
            throw Failure.truncated("a local file header")
        }
        let nameLength = int(header, at: 26, bytes: 2)
        let extraLength = int(header, at: 28, bytes: 2)
        return entry.localHeaderOffset + 30 + nameLength + extraLength
    }

    static func read(_ handle: FileHandle, at offset: Int, count: Int,
                     describing what: String) throws -> Data {
        guard offset >= 0, count >= 0 else { throw Failure.truncated(what) }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Failure.truncated(what)
        }
        return data
    }

    /// The last match, not the first. A zip may legally contain a nested zip,
    /// and the record that describes this archive is the final one.
    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: 0, by: -1)
        where int(data, at: offset, bytes: 4) == Int(signature) {
            return offset
        }
        return nil
    }

    /// A little-endian integer, read a byte at a time.
    ///
    /// Byte by byte rather than by loading a UInt32, because the offsets in a
    /// zip are not aligned and an unaligned load is undefined behaviour.
    private static func int(_ data: Data, at offset: Int, bytes: Int) -> Int {
        let base = data.startIndex + offset
        guard base >= data.startIndex, base + bytes <= data.endIndex else { return -1 }
        var value = 0
        for step in 0..<bytes {
            value |= Int(data[base + step]) << (8 * step)
        }
        return value
    }
}

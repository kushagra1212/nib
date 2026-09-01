import Foundation

/// The shape of one `.npy` array, and where its numbers begin.
///
/// Enough of the numpy format to read a voice pack and nothing more. A `.npy`
/// file is a short ASCII header describing a Python dict, followed by the raw
/// numbers:
///
///     \x93NUMPY\x01\x00v\x00{'descr': '<f4', 'fortran_order': False,
///                            'shape': (510, 1, 256), }              <numbers>
///
/// The header is checked rather than assumed. Every field it carries can be
/// wrong in a way that still yields 256 plausible floats: big-endian numbers
/// read as little-endian are finite and wrong, float64 read as float32 is
/// finite and wrong, and column-major read as row-major is a real voice with
/// the wrong intonation. None of those produce an error on their own, so the
/// header has to produce one.
struct NumpyLayout: Equatable {
    /// As numpy writes it, outermost axis first: (510, 1, 256).
    let shape: [Int]
    /// Where the numbers start, counted from the beginning of the blob.
    let dataOffset: Int

    /// Rows, meaning entries along the outermost axis. One per token count.
    var rows: Int { shape.first ?? 0 }
    /// Numbers in one row -- everything below the first axis, multiplied out.
    /// Shape (510, 1, 256) has 256 per row, not 1.
    var elementsPerRow: Int { shape.dropFirst().reduce(1, *) }
    /// The last axis, which for a voice pack is the width of a style vector.
    var columns: Int { shape.last ?? 0 }
    /// Bytes in one row. float32 throughout, which `parse` has already checked.
    var bytesPerRow: Int { elementsPerRow * 4 }

    enum Failure: Error, CustomStringConvertible {
        case notNumpy
        case truncatedHeader
        case missingField(String)
        case unsupportedType(String)
        case columnMajor
        case badShape(String)

        var description: String {
            switch self {
            case .notNumpy:
                return "not a numpy array: the file does not start with \\x93NUMPY"
            case .truncatedHeader:
                return "the numpy header is cut short"
            case .missingField(let name):
                return "the numpy header has no '\(name)'"
            case .unsupportedType(let descr):
                return "numpy type \(descr) is not supported here; "
                    + "the voice pack should be '<f4', little-endian float32"
            case .columnMajor:
                return "the array is column-major, and this reads rows"
            case .badShape(let text):
                return "cannot read the numpy shape \(text)"
            }
        }
    }

    private static let magic = Data([0x93]) + Data("NUMPY".utf8)

    static func parse(_ blob: Data) throws -> NumpyLayout {
        let base = blob.startIndex
        guard blob.count > 10, blob[base..<base + 8].starts(with: magic) else {
            throw Failure.notNumpy
        }

        // Version 1 states the header length in 2 bytes; version 2 widened it
        // to 4 when headers grew past 65535, and version 3 only changed the
        // encoding to UTF-8. Both wider versions are read the same way here.
        let major = blob[base + 6]
        let lengthBytes = major >= 2 ? 4 : 2
        let headerStart = 8 + lengthBytes
        guard blob.count >= headerStart else { throw Failure.truncatedHeader }

        var length = 0
        for offset in 0..<lengthBytes {
            length |= Int(blob[base + 8 + offset]) << (8 * offset)
        }
        guard blob.count >= headerStart + length else { throw Failure.truncatedHeader }

        let headerData = blob[(base + headerStart)..<(base + headerStart + length)]
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw Failure.truncatedHeader
        }

        guard let descr = field("descr", in: header) else {
            throw Failure.missingField("descr")
        }
        // Only this one. Everything else would be read as float32 and produce
        // numbers rather than a complaint.
        guard descr == "'<f4'" else { throw Failure.unsupportedType(descr) }

        guard let order = field("fortran_order", in: header) else {
            throw Failure.missingField("fortran_order")
        }
        guard order == "False" else { throw Failure.columnMajor }

        guard let shapeText = field("shape", in: header) else {
            throw Failure.missingField("shape")
        }
        let shape = try dimensions(shapeText)

        return NumpyLayout(shape: shape, dataOffset: headerStart + length)
    }

    /// The value written against `'key':`, up to the comma that ends it.
    ///
    /// Bracket depth is tracked because a shape is `(510, 1, 256)` and its
    /// commas are not the one that ends the field.
    private static func field(_ key: String, in header: String) -> String? {
        guard let marker = header.range(of: "'\(key)':") else { return nil }
        var depth = 0
        var value = ""
        for character in header[marker.upperBound...] {
            if depth == 0, character == "," || character == "}" { break }
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
            value.append(character)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func dimensions(_ text: String) throws -> [Int] {
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
        // A one-dimensional shape is written "(510,)", so the empty piece after
        // the trailing comma is dropped rather than read as a zero.
        let parts = inner.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let shape = parts.compactMap { Int($0) }
        guard shape.count == parts.count, !shape.isEmpty,
              shape.allSatisfy({ $0 > 0 })
        else { throw Failure.badShape(text) }
        return shape
    }
}

import Foundation

/// Splits a byte stream into LSP messages.
///
/// LSP frames each JSON-RPC payload as `Content-Length: N\r\n\r\n<N bytes>`.
/// Reads off a pipe arrive in arbitrary chunks, so the framer buffers until a
/// full header and body are present and hands back only complete payloads.
struct MessageFramer {
    private var buffer = Data()

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Appends new bytes and returns every complete message body now available.
    mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var out: [Data] = []
        while let message = takeOne() {
            out.append(message)
        }
        return out
    }

    private mutating func takeOne() -> Data? {
        guard let headerEnd = buffer.range(of: Self.headerTerminator) else {
            return nil
        }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let length = Self.contentLength(in: header) else {
            // Unparseable header: drop it so one bad frame cannot wedge the stream.
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
            return nil
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart) >= length else {
            return nil // body still incomplete
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return body
    }

    private static func contentLength(in header: String) -> Int? {
        for line in header.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Wraps a payload in the LSP header framing.
    static func encode(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}

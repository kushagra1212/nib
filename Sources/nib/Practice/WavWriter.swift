import Foundation

/// Writes captured samples out as a WAV you can double-click.
///
/// The point of a practice take is hearing yourself, and nothing plays a
/// `[Float]`. Written as 16-bit PCM rather than 32-bit float because Preview,
/// QuickTime and Quick Look all open the former without comment and some of
/// them refuse the latter.
enum WavWriter {
    enum Failure: Error, CustomStringConvertible {
        case writeFailed(String)

        var description: String {
            switch self {
            case .writeFailed(let why): return "could not write the recording: \(why)"
            }
        }
    }

    static func write(_ samples: [Float],
                      sampleRate: Double = AudioSamples.sampleRate,
                      to url: URL) throws {
        var data = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * bitsPerSample / 8
        let payloadBytes = UInt32(samples.count * 2)

        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }

        append("RIFF")
        append(UInt32(36) + payloadBytes)
        append("WAVE")
        append("fmt ")
        append(UInt32(16))          // PCM header length
        append(UInt16(1))           // PCM, uncompressed
        append(channels)
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        append("data")
        append(payloadBytes)

        // Clamped before scaling. A float that drifts past 1.0 wraps to a loud
        // click at the other end of the range when it is truncated, and one
        // clipped sample is audible.
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: scaled.littleEndian) { data.append(contentsOf: $0) }
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}

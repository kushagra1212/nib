import AVFoundation

/// Audio in the one format whisper accepts: 16kHz, mono, float.
///
/// Everything that produces audio for transcription goes through here -- the
/// microphone while dictating, and a file during benchmarking -- so there is a
/// single place where the conversion is right or wrong.
enum AudioSamples {
    /// What whisper was trained on. Not a preference.
    static let sampleRate: Double = 16_000

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .unreadable(let path): return "could not read audio at \(path)"
            case .conversionFailed(let why): return "could not convert audio: \(why)"
            }
        }
    }

    /// The format a microphone tap and a decoded file are both converted into.
    static var whisperFormat: AVAudioFormat {
        // Non-interleaved single channel: one buffer of floats, which is what
        // whisper_full takes and avoids a second pass to deinterleave.
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: 1,
                      interleaved: false)!
    }

    /// Reads any format Core Audio can open and returns 16kHz mono samples.
    ///
    /// Used by the benchmark, which has to compare models on identical input.
    static func load(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw Failure.unreadable(url.path)
        }

        let source = file.processingFormat
        let target = whisperFormat
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw Failure.conversionFailed("no converter from \(source)")
        }

        guard let input = AVAudioPCMBuffer(pcmFormat: source,
                                           frameCapacity: AVAudioFrameCount(file.length))
        else { throw Failure.conversionFailed("could not allocate input buffer") }
        try file.read(into: input)

        // Ratio rather than a fixed size: 48kHz down to 16kHz is a third of the
        // frames, and sizing this from the source length overruns nothing but
        // wastes nothing either.
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: capacity)
        else { throw Failure.conversionFailed("could not allocate output buffer") }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            // Once. Returning the same buffer twice makes the converter repeat
            // the audio; returning nil first makes it produce silence.
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError {
            throw Failure.conversionFailed(conversionError.localizedDescription)
        }

        return samples(from: output)
    }

    /// Copies a buffer's first channel out as plain floats.
    static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel,
                                         count: Int(buffer.frameLength)))
    }

    /// How long a run of samples lasts, in seconds.
    static func duration(of samples: [Float]) -> Double {
        Double(samples.count) / sampleRate
    }
}

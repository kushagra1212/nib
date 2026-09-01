import Foundation

/// Removes the silence the model leaves at each end of an utterance.
///
/// Kokoro pads what it produces: the golden sentence is 79200 samples of which
/// 15200 are silence, about six tenths of a second. Left in, every sentence
/// starts late and the gap between two of them is twice what the punctuation
/// asked for.
///
/// This is librosa's `trim`, which kokoro vendors for this one function. The
/// definition of silence is relative rather than absolute -- a frame counts as
/// silent when it is 60 dB below the loudest frame in this utterance -- so a
/// quiet voice is not trimmed away and a loud one is not left with a gap.
///
/// Ported against `Tests/Fixtures/audio-golden.json`, which records the sample
/// range the Python engine trims to.
enum AudioTrim {
    /// How far below the loudest frame still counts as silence.
    static let topDB: Float = 60
    /// Samples in one analysis frame.
    static let frameLength = 2048
    /// Samples between frames.
    static let hopLength = 512

    /// The smallest amplitude the dB conversion will consider, squared.
    ///
    /// librosa's `amplitude_to_db` uses amin = 1e-5 and works in power, so the
    /// floor is 1e-10. Without it, digital silence is log(0) and every frame of
    /// a silent buffer reads as negative infinity rather than as quiet.
    private static let minimumPower: Float = 1e-10

    /// Where the sound is, as a range into the samples.
    ///
    /// Returned as a range rather than a copy so the caller can decide whether
    /// to allocate. An utterance that is silent throughout gives an empty range
    /// at zero, matching librosa.
    static func bounds(of samples: [Float],
                       topDB: Float = topDB,
                       frameLength: Int = frameLength,
                       hopLength: Int = hopLength) -> Range<Int> {
        let loudness = frameLoudness(samples, frameLength: frameLength,
                                     hopLength: hopLength)
        guard let loudest = loudness.max(), loudest > 0 else { return 0..<0 }

        // Frames are compared with the loudest, in decibels. Squared because
        // librosa converts amplitude to dB through power.
        let reference = max(minimumPower, loudest * loudest)
        let threshold = -topDB

        var first: Int?
        var last: Int?
        for (index, value) in loudness.enumerated() {
            let power = max(minimumPower, value * value)
            let decibels = 10 * log10(power) - 10 * log10(reference)
            guard decibels > threshold else { continue }
            if first == nil { first = index }
            last = index
        }

        guard let first, let last else { return 0..<0 }
        let start = first * hopLength
        // One frame past the last that had sound, so the final consonant is not
        // clipped, and never past the end of the buffer.
        let end = min(samples.count, (last + 1) * hopLength)
        return start..<max(start, end)
    }

    static func trimmed(_ samples: [Float]) -> [Float] {
        Array(samples[bounds(of: samples)])
    }

    /// Root mean square per frame, over the samples padded at both ends.
    ///
    /// The padding is librosa's `center=True`: half a frame of zeros on each
    /// side, so frame `i` is centred on sample `i * hop` rather than starting
    /// there. Without it every boundary lands half a frame late.
    private static func frameLoudness(_ samples: [Float], frameLength: Int,
                                      hopLength: Int) -> [Float] {
        let pad = frameLength / 2
        var padded = [Float](repeating: 0, count: samples.count + pad * 2)
        padded.replaceSubrange(pad..<(pad + samples.count), with: samples)

        guard padded.count >= frameLength else { return [] }
        let frames = (padded.count - frameLength) / hopLength + 1

        var loudness = [Float](repeating: 0, count: frames)
        padded.withUnsafeBufferPointer { buffer in
            for index in 0..<frames {
                let start = index * hopLength
                var total: Float = 0
                for offset in 0..<frameLength {
                    let sample = buffer[start + offset]
                    total += sample * sample
                }
                loudness[index] = (total / Float(frameLength)).squareRoot()
            }
        }
        return loudness
    }
}

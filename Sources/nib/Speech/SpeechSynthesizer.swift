import Foundation

/// Text in, samples out. The whole pipeline in one place.
///
/// Reproduces `kokoro_worker.py`, which is what the setup this replaces runs:
///
///   1. Phonemise, punctuation preserved.
///   2. Split into batches of at most 510 phonemes.
///   3. Per batch: tokenise, take the style row for that token count, run the
///      model, trim the silence it padded with, then add back the pause the
///      punctuation asked for.
///   4. Join, apply volume, clip.
///
/// Step 3's trim-then-pause ordering is not interchangeable. Trimming removes
/// the model's own gap after a full stop along with the silence, so without the
/// pause added back two sentences run together.
///
/// What this does not do is insert pauses inside a batch. kokoro can, but only
/// where the model reports per-phoneme timings, and this export has one output
/// -- `audio`, with no `duration` beside it -- so that path never runs. Checked
/// rather than assumed; the fixture records it.
struct SpeechSynthesizer {
    let engine: KokoroEngine
    let voices: VoicePack
    let phonemes: PhonemeSource

    /// Carried over from `voice status` on the setup this replaces, unchanged.
    /// The instruction was to move it without changing how it sounds, and these
    /// are most of what that means.
    static let defaultSpeed: Float = 1.0
    static let defaultVolume: Float = 0.45
    static let defaultSentencePause = 0.25
    static let defaultClausePause = 0.1

    var voice = VoiceCatalog.defaultVoice
    var speed = defaultSpeed
    var volume = defaultVolume
    var sentencePause = defaultSentencePause
    var clausePause = defaultClausePause

    enum Failure: Error, CustomStringConvertible {
        case nothingToSay(String)

        var description: String {
            switch self {
            case .nothingToSay(let text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "nothing selected to speak"
                    : "nothing speakable in \(text.prefix(40).debugDescription)"
            }
        }
    }

    /// Everything to be spoken, at 24000 Hz.
    ///
    /// `isCancelled` is checked between batches rather than during one. A batch
    /// is at most 510 phonemes, which is a few seconds; stopping inside the
    /// model would mean tearing down the session rather than dropping a result.
    func samples(for text: String,
                 isCancelled: () -> Bool = { false }) throws -> [Float] {
        let spoken = try Phonemizer.phonemes(of: text, using: phonemes)
        let batches = PhonemeChunker.split(spoken)
        guard !batches.isEmpty else { throw Failure.nothingToSay(text) }

        var audio: [Float] = []
        for (index, batch) in batches.enumerated() {
            if isCancelled() { break }

            let tokens = try KokoroTokenizer.tokenize(batch)
            guard !tokens.isEmpty else { continue }

            let style = try voices.style(for: voice, tokenCount: tokens.count)
            let raw = try engine.synthesise(tokens: tokens, style: style, speed: speed)
            audio += AudioTrim.trimmed(raw)

            // The last batch gets no pause; it is the end of the utterance and
            // trailing silence is just a delay before the next thing happens.
            guard index < batches.count - 1 else { continue }
            let pause = PhonemeChunker.pause(after: batch, sentence: sentencePause,
                                             clause: clausePause)
            if pause > 0 {
                audio += [Float](repeating: 0,
                                 count: Int(pause * Double(KokoroEngine.sampleRate)))
            }
        }

        guard !audio.isEmpty else { throw Failure.nothingToSay(text) }
        return Self.leveled(audio, volume: volume)
    }

    /// Volume, applied the way the existing setup applies it.
    ///
    /// Clipped rather than scaled to fit. Pushing past full scale crackles
    /// instead of getting louder, and the clip is what stops a loud sentence
    /// wrapping around into distortion.
    static func leveled(_ samples: [Float], volume: Float) -> [Float] {
        guard volume != 1.0 else { return samples.map { min(max($0, -1), 1) } }
        return samples.map { min(max($0 * volume, -1), 1) }
    }
}

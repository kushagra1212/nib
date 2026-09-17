import Foundation

/// Reports what the linked whisper build can do, and optionally transcribes a
/// file with it.
///
///     nib --whisper-probe
///     nib --whisper-probe model.bin audio.wav
///
/// The first form answers the question the whole design rests on: is this
/// running on the GPU. The second is the smallest end-to-end proof that the
/// framework, the model and the audio conversion all agree with each other,
/// and it needs no microphone and no permission to run.
func runWhisperProbe(model: String?, audio: String?) async -> Int32 {
    print("whisper build")
    for line in WhisperEngine.systemInfo.split(separator: "|") {
        let entry = line.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { continue }
        print("  \(entry)")
    }

    guard let model else {
        print("\npass a model and an audio file to transcribe:")
        print("  nib --whisper-probe ggml-base-q5_1.bin speech.wav")
        return 0
    }

    let modelURL = URL(fileURLWithPath: model)
    let engine = WhisperEngine(modelPath: modelURL)

    guard let audio else {
        print("\nno audio given; nothing to transcribe")
        return 0
    }

    let samples: [Float]
    do {
        samples = try AudioSamples.load(URL(fileURLWithPath: audio))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 1
    }

    print("\naudio: \(String(format: "%.1fs", AudioSamples.duration(of: samples)))"
        + ", \(samples.count) samples at 16kHz")
    print("model: \(modelURL.lastPathComponent)")
    print("words: \(SpeechVocabulary.terms().count) in the vocabulary")

    let clock = ContinuousClock()
    do {
        var transcript = ""
        let elapsed = try await clock.measure {
            // The same prompt the app sends. A probe that skips it measures
            // a path nothing takes.
            transcript = try await engine.transcribe(
                samples: samples, prompt: SpeechVocabulary.prompt())
        }
        await engine.release()

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let audioLength = AudioSamples.duration(of: samples)
        // Real-time factor: below 1.0 means it transcribes faster than the
        // audio was spoken, which is the number that decides whether a model
        // is usable for dictation.
        print(String(format: "time:  %.2fs  (%.2fx real time)",
                     seconds, audioLength / max(seconds, 0.001)))
        print("\n\(transcript)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 1
    }
}

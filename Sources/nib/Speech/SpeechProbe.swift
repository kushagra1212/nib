import Foundation

/// `nib --speak "some text"` — the whole speech path, from a terminal.
///
/// Exists because the feature is otherwise only reachable by pressing a key in
/// another application, which needs Accessibility, a selection, and a working
/// audio device. When speaking goes wrong, that is four things to eliminate
/// before reaching the one that broke.
///
/// This runs inside the built app when invoked through its binary, so it also
/// answers the question the tests cannot: whether the copies of espeak and ONNX
/// Runtime *inside the bundle* are found and load.
enum SpeechProbe {
    static func run(text: String, voice: String?, play: Bool) async -> Int32 {
        let started = Date()

        guard let model = VoiceCatalog.installedModel else {
            print("no model in \(VoiceCatalog.installDirectory.path)")
            print("open nib's Voices… window to download it")
            return 1
        }
        guard let pack = VoiceCatalog.installedVoicePack else {
            print("no voices-v1.0.bin in \(VoiceCatalog.installDirectory.path)")
            return 1
        }

        do {
            let espeak = try EspeakLibrary.shared()
            print("espeak      \(try EspeakLibrary.installedDirectory().path)")

            let loading = Date()
            let engine = try KokoroEngine(model: model)
            let voices = try VoicePack(url: pack)
            print("onnxruntime \(engine.runtimeVersion), input \(engine.tokenInputName)")
            print("model       \(model.lastPathComponent) "
                + "in \(elapsed(since: loading))")
            print("voices      \(voices.names.count)")

            var synthesizer = SpeechSynthesizer(engine: engine, voices: voices,
                                                phonemes: espeak)
            if let voice {
                guard voices.names.contains(voice) else {
                    // Bound first: a multi-line expression inside a string
                    // interpolation does not parse.
                    let examples = voices.names.prefix(4).joined(separator: ", ")
                    print("no voice called \(voice); try \(examples)")
                    return 1
                }
                synthesizer.voice = voice
            }
            print("voice       \(synthesizer.voice)")

            let phonemes = try Phonemizer.phonemes(of: text, using: espeak)
            print("phonemes    \(phonemes)")
            let batches = PhonemeChunker.split(phonemes)
            let firstBatch = try KokoroTokenizer.tokenize(batches.first ?? "")
            print("tokens      \(firstBatch.count) in the first of \(batches.count)")

            let rendering = Date()
            let samples = try synthesizer.samples(for: text)
            let seconds = Double(samples.count) / Double(KokoroEngine.sampleRate)
            let peak = samples.map(abs).max() ?? 0
            print("audio       \(samples.count) samples, "
                + String(format: "%.2fs", seconds)
                + ", peak " + String(format: "%.3f", peak))
            let took = Date().timeIntervalSince(rendering)
            print("synthesis   \(elapsed(since: rendering)) "
                + String(format: "(%.1fx real time)", seconds / took))

            // Near-silence is the failure this catches. Every stage can succeed
            // and still produce nothing audible, and a sample count alone would
            // not show it.
            guard peak > 0.01 else {
                print("that is silence -- something upstream produced no sound")
                return 1
            }

            if play {
                let player = try SpeechPlayer()
                var done = false
                try player.play(samples) { done = true }

                // The run loop, not a semaphore. Playback finishes on the main
                // queue, so blocking main to wait for it would stop the thing
                // being waited on.
                let deadline = Date().addingTimeInterval(seconds + 5)
                while !done, Date() < deadline {
                    RunLoop.current.run(mode: .default,
                                        before: Date().addingTimeInterval(0.05))
                }
                if !done { print("playback did not finish in time") }
            }

            print("total       \(elapsed(since: started))")
            return 0
        } catch {
            print("failed: \(error)")
            return 1
        }
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(date))
    }
}

import AppKit
import Foundation

/// Speaking the selection: the part with the moving pieces.
///
/// Loads the model on first use and keeps it. That is the one place this
/// departs from "nothing resident between uses", and it is a deliberate trade:
/// a session costs about a third of a second to open, which is most of the wait
/// before the first word. The model is dropped when speech is turned off or
/// nib quits, and nothing runs while it sits there -- no thread, no audio
/// device, no timer.
@MainActor
final class SpeechController {
    private(set) var state: SpeechState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((SpeechState) -> Void)?

    /// The voice, remembered across launches.
    var voice: String {
        get { UserDefaults.standard.string(forKey: Self.voiceKey)
                ?? VoiceCatalog.defaultVoice }
        set { UserDefaults.standard.set(newValue, forKey: Self.voiceKey) }
    }
    private static let voiceKey = "nib.speech.voice"

    private var engine: KokoroEngine?
    private var voices: VoicePack?
    private var player: SpeechPlayer?
    private var work: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    /// How long the model is kept after the last word is spoken.
    ///
    /// It used to be kept until nib quit, on the reasoning that reloading costs
    /// about half a second and that is most of the wait before the first word.
    /// That was measured for speed and not for what it cost: 62MB sitting there
    /// for the rest of the session, against a rule this project states plainly
    /// -- nothing resident between uses.
    ///
    /// Two minutes keeps it through a run of sentences, which is how people
    /// actually use it, and releases it when they move on.
    static let idleTimeout: TimeInterval = 120

    /// Reads what to speak. Injected so the controller can be tested without a
    /// frontmost application.
    var readSelection: () -> String? = {
        guard AXAccess.isTrusted, let grabbed = TextGrabber.grab() else { return nil }
        let selected = grabbed.selectedText
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selected
    }

    /// Falls back to the clipboard, as the design says. Someone who has copied
    /// a paragraph and pressed the key means that paragraph.
    var readClipboard: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }

    // MARK: - The hotkeys

    /// `⌃⌘N`. Starts if idle, stops if not.
    func toggle() {
        Log.write("speech: toggle pressed, state=\(state)")
        guard let next = state.next(for: .toggled) else {
            Log.write("speech: toggle ignored in \(state)")
            return
        }
        if next == .idle {
            cancel()
        } else {
            begin()
        }
    }

    /// `⌃⇧H`. Only ever stops, and does nothing when nothing is speaking.
    func hush() {
        guard state.next(for: .hushed) != nil else { return }
        cancel()
    }

    func cancel() {
        work?.cancel()
        work = nil
        player?.stop()
        state = .idle
        Log.write("speech: stopped")
        scheduleRelease()
    }

    /// Drops the model after `idleTimeout` with nothing spoken.
    private func scheduleRelease() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.state.isBusy else { return }
            guard self.engine != nil else { return }
            self.engine = nil
            self.voices = nil
            self.player = nil
            Log.write("speech: model released after \(Int(Self.idleTimeout))s idle")
        }
    }

    /// Drops the model now, without waiting for the idle timer.
    func release() {
        idleTask?.cancel()
        cancel()
        engine = nil
        voices = nil
        player = nil
    }

    // MARK: - Doing it

    private func begin() {
        let selected = readSelection()
        guard let text = selected ?? readClipboard() else {
            fail("Nothing selected, and nothing on the clipboard.")
            return
        }
        Log.write("speech: \(selected != nil ? "selection" : "clipboard"), "
            + "\(text.count) characters")
        guard VoiceCatalog.isInstalled else {
            fail("The voice is not downloaded yet. Open Voices… to get it.")
            return
        }

        idleTask?.cancel()
        state = .preparing
        let voice = self.voice
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let synthesizer = try await self.prepare(voice: voice)
                guard !Task.isCancelled else { return }
                self.state = .synthesising

                try await self.render(synthesizer, text: text)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.fail("\(error)")
            }
        }
    }

    /// Synthesises, playing each batch as it arrives.
    ///
    /// Waiting for the whole text first is what made this look broken: at about
    /// 1.8x real time, a 3540-character selection took 123 seconds to render
    /// and played nothing until it was done. Starting on the first batch brings
    /// the first word forward to that batch alone, and synthesis stays ahead of
    /// playback from then on.
    private func render(_ synthesizer: SpeechSynthesizer, text: String) async throws {
        let player = try self.player ?? SpeechPlayer()
        self.player = player

        var started = false
        var spoken = 0

        // The model runs off the main actor; each finished batch comes back to
        // it to be queued, because the audio node is not safe to touch from the
        // synthesis thread.
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try synthesizer.synthesise(text, isCancelled: { Task.isCancelled }) {
                batch, isLast in
                let samples = batch
                DispatchQueue.main.async {
                    guard let self, !Task.isCancelled else { return }
                    MainActor.assumeIsolated {
                        guard self.state == .synthesising || self.state == .speaking
                        else { return }
                        do {
                            if !started {
                                started = true
                                try player.begin { [weak self] in
                                    guard let self, self.state == .speaking else { return }
                                    self.state = .idle
                                    self.scheduleRelease()
                                }
                                self.state.next(for: .synthesised).map { self.state = $0 }
                            }
                            try player.enqueue(samples, isLast: isLast)
                            spoken += samples.count
                            if isLast {
                                let seconds = Double(spoken)
                                    / Double(KokoroEngine.sampleRate)
                                Log.write("speech: \(String(format: "%.1f", seconds))s spoken")
                            }
                        } catch {
                            self.fail("\(error)")
                        }
                    }
                }
            }
        }.value
    }

    /// Opens the model, or reuses the one already open.
    private func prepare(voice: String) async throws -> SpeechSynthesizer {
        if engine == nil || voices == nil {
            guard let model = VoiceCatalog.installedModel,
                  let pack = VoiceCatalog.installedVoicePack else {
                throw SpeechFailure.notInstalled
            }
            // Off the main actor: opening a 326MB model blocks for long enough
            // to freeze the menu, and the menu is what the user is looking at.
            let opened = try await Task.detached(priority: .userInitiated) {
                (try KokoroEngine(model: model), try VoicePack(url: pack))
            }.value
            engine = opened.0
            voices = opened.1
            Log.write("speech: loaded onnxruntime \(opened.0.runtimeVersion)")
        }
        guard let engine, let voices else { throw SpeechFailure.notInstalled }

        state.next(for: .loaded).map { state = $0 }
        var synthesizer = SpeechSynthesizer(engine: engine, voices: voices,
                                            phonemes: try EspeakLibrary.shared())
        synthesizer.voice = voices.names.contains(voice) ? voice
            : VoiceCatalog.defaultVoice
        return synthesizer
    }

    private func fail(_ why: String) {
        Log.write("speech failed: \(why)")
        state = .failed(why)
    }

    enum SpeechFailure: Error, CustomStringConvertible {
        case notInstalled
        var description: String {
            "The voice is not downloaded yet. Open Voices… to get it."
        }
    }
}

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
        guard let next = state.next(for: .toggled) else { return }
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
    }

    /// Drops the model. Called when speech is switched off, not between uses.
    func release() {
        cancel()
        engine = nil
        voices = nil
        player = nil
    }

    // MARK: - Doing it

    private func begin() {
        guard let text = readSelection() ?? readClipboard() else {
            fail("Nothing selected, and nothing on the clipboard.")
            return
        }
        guard VoiceCatalog.isInstalled else {
            fail("The voice is not downloaded yet. Open Voices… to get it.")
            return
        }

        state = .preparing
        let voice = self.voice
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let synthesizer = try await self.prepare(voice: voice)
                guard !Task.isCancelled else { return }
                self.state = .synthesising

                let samples = try await Self.render(synthesizer, text: text)
                guard !Task.isCancelled else { return }

                try self.speak(samples)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.fail("\(error)")
            }
        }
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

    private static func render(_ synthesizer: SpeechSynthesizer,
                               text: String) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            try synthesizer.samples(for: text) { Task.isCancelled }
        }.value
    }

    private func speak(_ samples: [Float]) throws {
        let player = try self.player ?? SpeechPlayer()
        self.player = player

        state.next(for: .synthesised).map { state = $0 }
        let seconds = Double(samples.count) / Double(KokoroEngine.sampleRate)
        Log.write("speech: \(String(format: "%.1f", seconds))s to speak")

        try player.play(samples) { [weak self] in
            guard let self, self.state == .speaking else { return }
            self.state = .idle
        }
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

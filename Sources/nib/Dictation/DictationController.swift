import AppKit

/// Runs a dictation from the hotkey to the text landing in the field.
///
/// The only place that sequences the microphone, the model and the insertion.
/// It owns no rules about what may follow what -- those are in
/// `DictationState`, which is tested on its own -- so this can stay a thin
/// layer that performs work and reports back.
@MainActor
final class DictationController {
    private(set) var state: DictationState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Called on every state change, for the overlay and the menu bar icon.
    var onStateChange: ((DictationState) -> Void)?
    /// Asked for the current audio level, 0...1, while recording.
    var level: Float { recorder.level }
    var elapsed: TimeInterval { recorder.elapsed }

    /// Called before transcription starts, so the rewrite model can be shut
    /// down. Both want the GPU, and a 16GB machine has already been measured
    /// failing to hold two models at once.
    var willTranscribe: (() -> Void)?
    /// Called when there is no speech model, so the caller can offer to fetch
    /// one instead of reporting a dead end.
    var onNeedsModel: (() -> Void)?

    private let recorder = AudioRecorder()
    private var engine: WhisperEngine?
    private var transcription: Task<Void, Never>?

    init() {
        recorder.onReachedLimit = { [weak self] in
            self?.handle(.reachedLimit)
        }
    }

    // MARK: - The hotkey

    /// One entry point for the hotkey, because the key means "start" or "stop"
    /// depending on where we are and the caller should not have to know which.
    func toggle() {
        guard SpeechModelCatalog.installed() != nil else {
            onNeedsModel?()
            return
        }
        handle(.toggled)
    }

    func cancel() {
        handle(.cancelled)
    }

    // MARK: - Sequencing

    private func handle(_ event: DictationEvent) {
        guard let next = state.next(for: event) else { return }
        let previous = state
        state = next
        perform(entering: next, from: previous)
    }

    private func perform(entering state: DictationState, from previous: DictationState) {
        switch state {
        case .requestingAccess:
            Task { [weak self] in
                let granted = await AudioRecorder.requestAccess()
                self?.handle(granted ? .accessGranted : .accessDenied)
            }

        case .recording:
            do {
                try recorder.start()
                Log.write("dictation: recording")
            } catch {
                handle(.failed("\(error)"))
            }

        case .transcribing:
            let samples = recorder.stop()
            Log.write("dictation: \(Int(AudioSamples.duration(of: samples)))s captured")
            transcribe(samples)

        case .inserting(let text):
            insert(text)

        case .idle:
            // Cancelled mid-recording, or finished. Either way nothing may be
            // left running: a cancel during transcription has to stop the
            // model, not merely stop listening to it.
            if previous == .recording { recorder.cancel() }
            transcription?.cancel()
            transcription = nil
            releaseModel()

        case .failed(let why):
            Log.write("dictation failed: \(why)")
            recorder.cancel()
            releaseModel()
        }
    }

    // MARK: - Work

    private func transcribe(_ samples: [Float]) {
        guard let model = SpeechModelCatalog.installed() else {
            handle(.failed("no speech model installed"))
            return
        }
        willTranscribe?()

        let engine = self.engine ?? WhisperEngine(modelPath: model)
        self.engine = engine

        transcription = Task { [weak self] in
            do {
                let text = try await engine.transcribe(samples: samples)
                guard !Task.isCancelled else { return }
                self?.handle(.transcribed(text))
            } catch {
                guard !Task.isCancelled else { return }
                self?.handle(.failed("\(error)"))
            }
        }
    }

    /// Types the transcript into whatever is focused.
    ///
    /// Typed rather than written through Accessibility, so the text enters the
    /// app's own undo stack and one Cmd-Z removes a dictation. An AX write
    /// lands without the app noticing and cannot be undone.
    private func insert(_ text: String) {
        guard AXAccess.isTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            handle(.failed("nib cannot type without Accessibility permission. "
                           + "The transcript is on your clipboard."))
            return
        }
        Keystroke.type(text)
        Log.write("dictation: inserted \(text.count) characters")
        handle(.inserted)
    }

    /// Frees the model's weights.
    ///
    /// Called at the end of every dictation rather than kept warm. Holding
    /// hundreds of megabytes for the next sentence would undo the reason this
    /// is a toggle rather than an always-listening design.
    private func releaseModel() {
        guard let engine else { return }
        self.engine = nil
        Task { await engine.release() }
    }

    // MARK: - First run

    /// Compiles whisper's Metal shaders so the first dictation does not.
    ///
    /// Measured at 31 seconds on a freshly built binary and 0.009s on every run
    /// after, because macOS caches the compiled library per binary. Left alone
    /// that half-minute lands on the first thing a new user tries.
    ///
    /// Runs detached and its result is ignored: this is a warm-up, and failing
    /// to warm up is not a failure worth reporting.
    static func warmUpMetal() {
        Task.detached(priority: .utility) {
            _ = WhisperEngine.systemInfo
        }
    }
}

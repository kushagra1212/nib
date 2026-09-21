import AppKit

/// Where practice takes land on disk.
///
/// Lives outside `PracticeController` because that class is `@MainActor` and
/// `save` runs off it. Under Swift 6 a `nonisolated static` member of an
/// actor-isolated type is still reached through that isolation, so the writer
/// could not see its own directory. A plain enum has no isolation to cross.
///
/// Documents, not Application Support. These are things you open, play and
/// delete yourself; burying them somewhere Finder hides by default would make
/// the feature useless for the one thing it is for.
enum PracticeStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("nib/practice", isDirectory: true)
    }
}

/// Records a spoken answer, transcribes it, and writes both to disk.
///
/// Dictation and practice share a microphone and a model and almost nothing
/// else. Dictation is a means: the words go into a field and the audio is
/// thrown away the instant it has served its purpose. A practice take is the
/// artefact -- you keep the audio because you need to hear it, and you keep the
/// transcript because you need to read what you actually said rather than what
/// you remember saying.
///
/// So it does not reuse `DictationController`. Sharing it would mean a mode
/// flag threaded through a state machine whose whole job is deciding what may
/// follow what, to make it sometimes not type.
@MainActor
final class PracticeController {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case finished(URL)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?
    /// Called before the model loads, so the rewrite engine can free the GPU.
    var willTranscribe: (() -> Void)?
    /// Called before the microphone opens, so nib stops reading aloud.
    var willRecord: (() -> Void)?
    var onNeedsModel: (() -> Void)?

    var level: Float { recorder.level }
    var elapsed: TimeInterval { recorder.elapsed }
    var isBusy: Bool { state == .recording || state == .transcribing }

    private let recorder = AudioRecorder()
    private var engine: WhisperEngine?
    private var work: Task<Void, Never>?

    /// Where takes land. See `PracticeStore`.
    nonisolated static var folder: URL { PracticeStore.folder }

    init() {
        recorder.onReachedLimit = { [weak self] in self?.stop() }
    }

    // MARK: - The hotkey

    func toggle() {
        switch state {
        case .recording: stop()
        case .transcribing: break   // Let it finish; a second press is impatience.
        default: start()
        }
    }

    private func start() {
        guard SpeechModelCatalog.installed() != nil else {
            onNeedsModel?()
            return
        }
        Task { [weak self] in
            guard await AudioRecorder.requestAccess() else {
                self?.state = .failed("nib is not allowed to use the microphone")
                return
            }
            self?.beginRecording()
        }
    }

    private func beginRecording() {
        willRecord?()
        do {
            try recorder.start()
            state = .recording
            Log.write("practice: recording")
        } catch {
            state = .failed("\(error)")
        }
    }

    private func stop() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        let duration = AudioSamples.duration(of: samples)
        Log.write("practice: \(Int(duration))s captured")
        guard duration >= 1 else {
            state = .failed("that take was under a second")
            return
        }
        state = .transcribing
        transcribe(samples, duration: duration)
    }

    func cancel() {
        recorder.cancel()
        work?.cancel()
        work = nil
        releaseModel()
        state = .idle
    }

    // MARK: - Work

    private func transcribe(_ samples: [Float], duration: TimeInterval) {
        guard let model = SpeechModelCatalog.installed() else {
            state = .failed("no speech model installed")
            return
        }
        willTranscribe?()

        let engine = self.engine ?? WhisperEngine(modelPath: model)
        self.engine = engine

        work = Task { [weak self] in
            do {
                let segments = try await engine.transcribeSegments(
                    samples: samples, prompt: SpeechVocabulary.prompt())
                guard !Task.isCancelled else { return }
                let url = try Self.save(samples: samples,
                                        segments: segments,
                                        duration: duration)
                self?.state = .finished(url)
                self?.releaseModel()
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed("\(error)")
                self?.releaseModel()
            }
        }
    }

    /// Writes the take and returns the transcript's URL.
    ///
    /// Audio and transcript share a stem so the pair stays obvious in Finder
    /// after a hundred takes, and the stem is a sortable timestamp so the list
    /// is in the order you recorded them without anyone naming anything.
    nonisolated static func save(samples: [Float],
                                 segments: [SpokenSegment],
                                 duration: TimeInterval,
                                 at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: PracticeStore.folder,
                                                withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = formatter.string(from: date)

        let audio = PracticeStore.folder.appendingPathComponent("\(stem).wav")
        try WavWriter.write(samples, to: audio)

        let report = DeliveryReport(segments: segments, duration: duration)
        let markdown = PracticeTranscript.markdown(segments: segments,
                                                   report: report,
                                                   audio: audio,
                                                   date: date)
        let transcript = PracticeStore.folder.appendingPathComponent("\(stem).md")
        try markdown.write(to: transcript, atomically: true, encoding: .utf8)

        Log.write("practice: wrote \(stem).wav and \(stem).md")
        return transcript
    }

    private func releaseModel() {
        guard let engine else { return }
        self.engine = nil
        Task { await engine.release() }
    }
}

import Foundation
import whisper

/// Speech to text, from whisper.cpp linked into the app.
///
/// Linked rather than spawned. whisper.cpp publishes no macOS command-line
/// build, only an XCFramework, and taking it at its word removes everything
/// the llama integration needs to keep working: a subprocess, a port, a health
/// check, an idle-shutdown timer, and a directory of dylibs that have to travel
/// beside the binary.
///
/// The model is held only while transcribing. It is hundreds of megabytes and
/// nothing else in nib needs it, so loading on demand and releasing after is
/// what keeps dictation free when nobody is dictating.
actor WhisperEngine {
    enum Failure: Error, CustomStringConvertible {
        case modelMissing(String)
        case modelUnreadable(String)
        case transcriptionFailed(Int32)
        case noAudio

        var description: String {
            switch self {
            case .modelMissing(let path):
                return "no speech model at \(path)"
            case .modelUnreadable(let name):
                return "\(name) could not be loaded -- it may be the wrong "
                    + "format, or too large for this machine's memory"
            case .transcriptionFailed(let code):
                return "whisper failed with code \(code)"
            case .noAudio:
                return "nothing was recorded"
            }
        }
    }

    private var context: OpaquePointer?
    private let modelPath: URL

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// What whisper reports about the hardware it will use.
    ///
    /// Metal rather than CPU is the whole basis of the CPU claim, and this is
    /// the only place that says which one is in play. Read by
    /// `nib --whisper-probe`.
    static var systemInfo: String {
        String(cString: whisper_print_system_info())
    }

    // MARK: - Loading

    /// Loads the model, or returns it if already loaded.
    private func ensureLoaded() throws -> OpaquePointer {
        if let context { return context }

        guard FileManager.default.isReadableFile(atPath: modelPath.path) else {
            throw Failure.modelMissing(modelPath.path)
        }

        var params = whisper_context_default_params()
        // The point of linking this build. Without the GPU the encoder runs on
        // the CPU cores the user is trying to keep.
        params.use_gpu = true
        params.flash_attn = true

        guard let loaded = whisper_init_from_file_with_params(
            modelPath.path, params) else {
            throw Failure.modelUnreadable(modelPath.lastPathComponent)
        }
        context = loaded
        return loaded
    }

    /// Frees the model. Called once a transcription is delivered, so an idle
    /// nib holds no weights.
    func release() {
        guard let context else { return }
        whisper_free(context)
        self.context = nil
    }

    // MARK: - Transcribing

    /// Turns 16kHz mono samples into text.
    ///
    /// - Parameter prompt: terms to bias decoding towards. This is how
    ///   "useMemo" and "AXUIElement" survive being dictated; a general
    ///   recogniser writes them as ordinary words.
    func transcribe(samples: [Float], prompt: String? = nil) throws -> String {
        guard !samples.isEmpty else { throw Failure.noAudio }
        let context = try ensureLoaded()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        // Half the cores, matching the rewrite engine: a transcription should
        // not compete with whatever the user is doing while it runs.
        params.n_threads = Int32(max(2, ProcessInfo.processInfo
            .activeProcessorCount / 2))

        // Held for the duration of the call. whisper keeps the pointer, and a
        // Swift String's storage is not guaranteed to outlive the expression
        // it appears in.
        let promptBuffer: UnsafeMutablePointer<CChar>?
        if let prompt, !prompt.isEmpty {
            promptBuffer = strdup(prompt)
            params.initial_prompt = UnsafePointer(promptBuffer)
        } else {
            promptBuffer = nil
        }
        defer { free(promptBuffer) }

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else { throw Failure.transcriptionFailed(status) }

        var text = ""
        for segment in 0..<whisper_full_n_segments(context) {
            text += String(cString: whisper_full_get_segment_text(context, segment))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

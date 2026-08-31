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

    /// Above this, a segment is treated as silence and dropped.
    ///
    /// Whisper's own default for the same judgement is 0.6. Kept there rather
    /// than tightened: raising it lets hallucinations through, and lowering it
    /// starts discarding quiet speech, which is the worse of the two failures
    /// for someone who just spoke a sentence.
    static let noSpeechLimit: Float = 0.6

    /// Overridable so a single factor can be measured at a time. Defaults are
    /// what ships; the environment variables exist for --whisper-probe.
    static var usesBeamSearch: Bool {
        ProcessInfo.processInfo.environment["NIB_WHISPER_GREEDY"] == nil
    }

    static var beamWidth: Int {
        Int(ProcessInfo.processInfo.environment["NIB_WHISPER_BEAM"] ?? "") ?? 5
    }

    /// English by default. A second language is a setting nib does not have
    /// yet; "auto" restores detection for anyone who needs it today.
    static var language: String {
        ProcessInfo.processInfo.environment["NIB_WHISPER_LANG"] ?? "en"
    }

    private var context: OpaquePointer?
    private let modelPath: URL

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Removes whisper's descriptions of sounds it heard but could not
    /// transcribe.
    ///
    /// Silence produces "[BLANK_AUDIO]", music produces "(upbeat music)", and
    /// a cough produces "*coughs*". These are annotations for a transcript,
    /// not words anyone said, and dictation types its result straight into
    /// somebody's document -- so a pause before speaking put "[BLANK_AUDIO]"
    /// into a message.
    ///
    /// Square brackets and asterisks go unconditionally: whisper never uses
    /// them for speech. Parentheses only when what they hold looks like a
    /// sound rather than an aside, because a dictated sentence can legitimately
    /// contain one.
    nonisolated static func clean(_ raw: String) -> String {
        var text = raw

        for pattern in [#"\[[^\]]*\]"#, #"\*[^*]*\*"#] {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: .regularExpression)
        }

        // "(laughs)", "(upbeat music)", "(wind blowing)" -- a short phrase of
        // plain words describing a sound. Anything with digits, punctuation or
        // more than three words is left alone as dictated speech.
        text = text.replacingOccurrences(
            of: #"\((?:[A-Za-z]+ ){0,2}[A-Za-z]+\)"#,
            with: " ", options: .regularExpression)

        text = text.replacingOccurrences(of: #"\s+"#, with: " ",
                                         options: .regularExpression)
        // Whitespace before punctuation, left behind when a marker sat mid
        // sentence: "Hello [BLANK_AUDIO], there" would otherwise end "Hello ,".
        text = text.replacingOccurrences(of: #" ([,.!?;:])"#, with: "$1",
                                         options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Asked before the model is loaded, so an accidental toggle costs
        // nothing at all rather than a model load and an invented sentence.
        guard !AudioSamples.isSilent(samples) else { return "" }
        let context = try ensureLoaded()

        // Beam search rather than greedy.
        //
        // Greedy takes the most likely next token and never reconsiders, which
        // is where an unfamiliar accent goes wrong: one early mistake commits
        // the rest of the sentence to it. Beam search keeps several candidate
        // transcriptions alive and picks the best whole sentence, so a vowel it
        // guessed badly can still be outvoted by the words after it.
        //
        // Slower, and worth it for a finished dictation nobody is watching
        // stream in.
        let strategy = Self.usesBeamSearch
            ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY
        var params = whisper_full_default_params(strategy)
        if Self.usesBeamSearch {
            params.beam_search.beam_size = Int32(Self.beamWidth)
        }

        // Told it is English rather than left to guess.
        //
        // Whisper detects the language from the first seconds of audio, and on
        // a short accented clip it guesses wrong often enough to matter -- an
        // English sentence decoded as Hindi comes back as confident nonsense.
        // Naming the language removes the guess.
        // Held for the duration of the call, not borrowed inside a closure.
        // withCString hands out a pointer that dies when the closure returns,
        // and whisper reads params.language later -- which is a dangling
        // pointer, and the kind that usually works until it does not.
        let languageBuffer = strdup(Self.language)
        params.language = UnsafePointer(languageBuffer)
        defer { free(languageBuffer) }
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        // Stop the model emitting sound descriptions. Left on, a pause
        // produces "[BLANK_AUDIO]" and a hum produces "(upbeat music)", and
        // both get typed into whatever field is focused as though they were
        // words. The output is filtered as well, because this flag reduces
        // them rather than removing them.
        params.suppress_nst = true
        // Half the cores, matching the rewrite engine: a transcription should
        // not compete with whatever the user is doing while it runs.
        params.n_threads = Int32(max(2, ProcessInfo.processInfo
            .activeProcessorCount / 2))

        // Held for the duration of the call. whisper keeps the pointer, and a
        // Swift String's storage is not guaranteed to outlive the expression
        // it appears in.
        let promptBuffer: UnsafeMutablePointer<CChar>?
        let prompt = prompt ?? ProcessInfo.processInfo.environment["NIB_WHISPER_PROMPT"]
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
            // Whisper invents words for silence. Four seconds of a silent WAV
            // transcribes as "you", and "Thank you." is the other common one --
            // artefacts of its training data, not sounds in the room. Stripping
            // the [BLANK_AUDIO] marker alone made this worse by hiding the
            // obvious case and leaving the plausible one.
            //
            // The model's own estimate that a segment contains no speech is
            // the only thing that separates a hallucinated "you" from a spoken
            // one.
            let silence = whisper_full_get_segment_no_speech_prob(context, segment)
            guard silence < Self.noSpeechLimit else { continue }
            text += String(cString: whisper_full_get_segment_text(context, segment))
        }
        return Self.clean(text)
    }
}

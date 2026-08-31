import Foundation

/// Speech models nib knows how to fetch.
///
/// Separate from the rewrite catalogue because they are different files for
/// different jobs -- `.bin` weights for whisper against `.gguf` for llama --
/// but the same `CatalogModel` shape, so the same installer, the same
/// truncation check and the same setup window serve both.
enum SpeechModelCatalog {
    private static func huggingFace(_ file: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!
    }

    /// Sizes are the real byte counts from the Hugging Face API.
    ///
    /// Multilingual builds throughout, not the `.en` variants: English-only
    /// models are smaller and better at English, and would fail the occasional
    /// Hindi sentence by transcribing it as nonsense English rather than by
    /// failing visibly.
    static let all: [CatalogModel] = [
        CatalogModel(
            filename: "ggml-base-q5_1.bin",
            title: "Whisper base",
            detail: "Smallest that works. Transcribes about 5x faster than you "
                + "speak, and mishears unusual words.",
            bytes: 59_700_000,
            url: huggingFace("ggml-base-q5_1.bin")),
        CatalogModel(
            filename: "ggml-small-q5_1.bin",
            title: "Whisper small",
            detail: "Noticeably better on technical terms and accents, for "
                + "three times the size.",
            bytes: 190_000_000,
            url: huggingFace("ggml-small-q5_1.bin")),
        CatalogModel(
            filename: "ggml-large-v3-turbo-q5_0.bin",
            title: "Whisper large v3 turbo",
            detail: "The most accurate of these, and still faster than real "
                + "time. Best for long dictation and mixed languages.",
            bytes: 574_000_000,
            url: huggingFace("ggml-large-v3-turbo-q5_0.bin")),
    ]

    /// Preselected in the setup window.
    ///
    /// `small` rather than the smallest or the best. Base mishears often enough
    /// to be annoying -- it wrote "nid" for "nib" on the first sentence tried --
    /// and turbo is a 574MB download to find out whether you like dictating at
    /// all. Revisit against `--dictate-bench` output, not against argument.
    static var recommended: CatalogModel { all[1] }

    /// Where speech models are installed.
    ///
    /// Beside the rewrite models but not among them: both directories are
    /// scanned by name, and a `.bin` appearing in the llama search path would
    /// be offered to a loader that cannot read it.
    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nib/speech")
    }

    /// The installed model, largest first, or nil if none.
    static func installed() -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: installDirectory.path)
        else { return nil }

        let models = names.filter { $0.hasSuffix(".bin") }
            .map { installDirectory.appendingPathComponent($0) }
        // Largest wins, which for whisper tracks accuracy: base, small, medium
        // and turbo are strictly ordered by size and by quality.
        return models.max { left, right in
            let l = (try? left.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let r = (try? right.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return l < r
        }
    }
}

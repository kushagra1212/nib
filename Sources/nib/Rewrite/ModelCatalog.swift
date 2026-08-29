import Foundation

/// A model nib knows how to fetch.
///
/// A short list rather than a browser of everything on Hugging Face. The models
/// here have been run against nib's own prompts; a picker over thousands of
/// files would mostly offer ways to end up with one that answers the wrong
/// question, which is the failure mode small models actually have.
struct CatalogModel: Equatable {
    /// Filename on disk, which is also what the ranking in rankModels reads.
    let filename: String
    let title: String
    /// What choosing this one gets you, in the terms someone deciding cares
    /// about: speed against quality, and how much disk it costs.
    let detail: String
    let bytes: Int64
    let url: URL

    var sizeLabel: String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000
            ? String(format: "%.1f GB", mb / 1000)
            : String(format: "%.0f MB", mb)
    }
}

enum ModelCatalog {
    private static func huggingFace(_ repo: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    /// Ordered smallest first, which is also roughly worst first. Sizes are the
    /// real byte counts from the Hugging Face API, not rounded guesses, so the
    /// figure shown before the download matches the one during it.
    ///
    /// Q8_0 for the 0.6B and not the 409MB Q4_0, which was tried and is not
    /// good enough. On the six-error sentence Q4_0 returned "Their is many
    /// errors in this sentence, and it are very long ... could of been" --
    /// it fixed the two misspellings and left every grammatical error behind,
    /// where Q8_0 of the same model fixes all six. Saving 360MB by shipping a
    /// default that cannot correct "Their is" is not a saving.
    static let all: [CatalogModel] = [
        CatalogModel(
            filename: "Qwen3-0.6B-Q8_0.gguf",
            title: "Qwen3 0.6B",
            detail: "Small and quick. Fixes everyday mistakes -- wrong verb "
                + "forms, tense, plurals -- in about half a second.",
            bytes: 804_753_632,
            url: huggingFace("ggml-org/Qwen3-0.6B-GGUF", "Qwen3-0.6B-Q8_0.gguf")),
    ]

    /// One entry, because one is what survived being measured.
    ///
    /// Qwen3 1.7B at Q4_K_M is 1.3GB against the 0.6B's 805MB and was worse in
    /// every mode tried. On four ordinary sentences it corrected two where the
    /// 0.6B corrected three, returning "we was going to the store" unchanged;
    /// asked to tighten a rambling sentence it removed the word "maybe" and
    /// left the rest, where the 0.6B rewrote it properly.
    ///
    /// Qwen3 1.7B at Q8_0 could not be tested: at 2.2GB it fails to run on a
    /// 16GB machine with a browser open, and llama.cpp reports
    /// kIOGPUCommandBufferCallbackErrorOutOfMemory. Offering a download that
    /// large without knowing it runs is not a recommendation.
    ///
    /// Anyone who wants something else can point the window at a file, or drop
    /// a .gguf into the models folder; nib is not limited to this list.

    /// Wraps a file the user picked so it can take the same path as a
    /// download. URLSession treats file:// like any other source, so choosing
    /// a local model reuses the checking and installing already written.
    static func local(_ url: URL) -> CatalogModel {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return CatalogModel(filename: url.lastPathComponent,
                            title: url.deletingPathExtension().lastPathComponent,
                            detail: "Already on this machine.",
                            bytes: Int64(size), url: url)
    }

    /// Preselected in the setup window.
    ///
    /// The smallest one, deliberately. Someone who has just installed a menu
    /// bar app should not be asked to spend two gigabytes to find out whether
    /// they like it, and 0.6B is measured as adequate rather than assumed to be.
    static var recommended: CatalogModel { all[0] }

    /// Where a downloaded model is installed.
    ///
    /// Application Support rather than beside the app: the app is replaced
    /// wholesale by every update and by Homebrew, and a model inside it would
    /// be a 800MB download silently thrown away each time.
    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nib/models")
    }
}

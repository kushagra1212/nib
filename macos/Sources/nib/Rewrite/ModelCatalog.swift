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
        CatalogModel(
            filename: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            title: "Qwen3 4B",
            detail: "Writes like a person. Rewrites awkward sentences into "
                + "natural English rather than just fixing the commas. "
                + "About a second and a half per rewrite.",
            bytes: 2_497_281_120,
            url: huggingFace("unsloth/Qwen3-4B-Instruct-2507-GGUF",
                             "Qwen3-4B-Instruct-2507-Q4_K_M.gguf")),
    ]

    /// Two entries, and the second is the one to use if the disk is there.
    ///
    /// Measured against each other on a sentence someone actually wrote:
    /// "Also I do not have option to see the score of the selected text how
    /// much is it grammatically correct because I am very naive at English so
    /// I can not judge myself."
    ///
    ///   0.6B, Fix      added one comma. Left "do not have option", left
    ///                  "how much is it grammatically correct", left
    ///                  "naive at English", left "can not".
    ///   0.6B, Native   added a second comma. Nothing else.
    ///   4B, Fix        "Also, I don't have the option to see the score of the
    ///                  selected text regarding how grammatically correct it
    ///                  is, because I am quite naive when it comes to English,
    ///                  so I can't judge myself."
    ///   4B, Native     "I also don't have the option to see how grammatically
    ///                  correct the selected text is -- I'm quite inexperienced
    ///                  with English, so I can't judge it on my own."
    ///
    /// On that evidence the 0.6B is a comma inserter and the 4B is the feature.
    /// It costs about 1.4s a rewrite against 0.3s, which is the right trade for
    /// something asked for by pressing a button.
    ///
    /// Instruct-2507 rather than plain Qwen3-4B: the base model is a hybrid
    /// reasoning model that thinks out loud before answering, and every token
    /// of that is latency for an answer nib throws away.
    ///
    /// Caveat measured rather than assumed: this ran on a 24GB machine. The
    /// note below about a 16GB machine failing on a 2.2GB model has not been
    /// retested against this one, so the 0.6B stays as the small option.
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
    /// The 4B, despite being 2.5GB. This used to be the 0.6B on the reasoning
    /// that a new user should not spend gigabytes to try a menu bar app -- but
    /// what they get for the smaller download is a model that inserts commas
    /// and leaves the grammar alone, which is not the app working cheaply, it
    /// is the app not working. The 0.6B is still there for a small disk.
    static var recommended: CatalogModel { all[1] }

    /// The small one, for anyone who wants it.
    static var compact: CatalogModel { all[0] }

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

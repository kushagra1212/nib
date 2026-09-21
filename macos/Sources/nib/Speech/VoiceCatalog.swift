import Foundation

/// The files nib needs to speak, and where they live.
///
/// Two of them, which is the difference from the other catalogues: a voice is
/// not chosen the way a whisper model is. The `.onnx` is the model and the
/// `.bin` is the pack of 54 voices, and neither is any use without the other,
/// so both are fetched together and a half-installed pair counts as missing.
enum VoiceCatalog {
    private static func release(_ file: String) -> URL {
        URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/"
            + "model-files-v1.0/\(file)")!
    }

    /// Sizes are the byte counts of the files this was built against, not
    /// rounded guesses, so the figure shown before a download matches the one
    /// during it and a truncated file is visible as a wrong size.
    static let models: [CatalogModel] = [
        CatalogModel(
            filename: "kokoro-v1.0.onnx",
            title: "Kokoro",
            detail: "The full model, and the one the existing setup runs. "
                + "Best quality.",
            bytes: 325_532_387,
            url: release("kokoro-v1.0.onnx")),
        CatalogModel(
            filename: "kokoro-v1.0.int8.onnx",
            title: "Kokoro, quantised",
            detail: "A quarter of the size for a small loss of quality. Untested "
                + "here -- the working setup uses the full model.",
            bytes: 92_361_271,
            url: release("kokoro-v1.0.int8.onnx")),
    ]

    /// Every voice, in one 28MB archive. Not a choice: the same file serves all
    /// 54, and picking a voice happens inside nib rather than at download time.
    static let voicePack = CatalogModel(
        filename: "voices-v1.0.bin",
        title: "Voices",
        detail: "54 voices. Needed whichever model is used.",
        bytes: 28_214_398,
        url: release("voices-v1.0.bin"))

    /// Matches the engine's own default, and the one the existing setup speaks
    /// with. Changing it would change how nib sounds for anyone who never
    /// opened the menu.
    static let defaultVoice = "af_heart"

    /// Beside the other models but in its own directory, because both of the
    /// others are scanned by extension and a `.bin` in the whisper directory
    /// would be offered to a loader that cannot read it.
    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nib/voice")
    }

    static var installedVoicePack: URL? {
        exists(voicePack.filename)
    }

    /// The installed model, preferring the full one over the quantised.
    static var installedModel: URL? {
        models.lazy.compactMap { exists($0.filename) }.first
    }

    /// Both files, or nothing. Speaking needs the pair.
    static var isInstalled: Bool {
        installedModel != nil && installedVoicePack != nil
    }

    /// What still has to be downloaded, largest first.
    ///
    /// The model goes first deliberately: it is 326MB against the pack's 28MB,
    /// so starting it while the window still has attention is better than
    /// finishing the small one and then appearing to stall.
    static var needed: [CatalogModel] {
        var wanted: [CatalogModel] = []
        if installedModel == nil { wanted.append(models[0]) }
        if installedVoicePack == nil { wanted.append(voicePack) }
        return wanted
    }

    private static func exists(_ filename: String) -> URL? {
        let url = installDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

import Foundation

/// espeak-ng, loaded at runtime and asked for phonemes.
///
/// Three C functions, reached through `dlopen` rather than linked. Linking
/// would make the whole app fail to build wherever `Scripts/fetch-espeak.sh`
/// has not been run, including CI; this way the library is a file that is
/// either there or not, and its absence is a message rather than a link error.
///
/// espeak keeps its state in process globals -- the voice, the dictionaries,
/// the position in the text it is reading. Two calls at once return each
/// other's phonemes, so every call here holds a lock. That is not a
/// conservative guess: it is what `phonemizer` does, for the same reason.
///
/// The library is initialised once. Initialising twice with a different data
/// path does not switch dictionaries, it just returns the sample rate again,
/// so the first caller decides and the rest share.
final class EspeakLibrary: PhonemeSource {
    /// Serialises everything, including loading. espeak has one set of globals
    /// however many of these exist.
    private static let lock = NSLock()
    private static var loaded: EspeakLibrary?

    private let handle: UnsafeMutableRawPointer
    private let textToPhonemes: TextToPhonemesFunction

    /// espeak's own sample rate, returned by initialisation. Not the rate the
    /// model speaks at -- Kokoro is 24000 -- but a sign the library came up.
    let sampleRate: Int32

    // MARK: - The C functions

    private typealias InitializeFunction =
        @convention(c) (Int32, Int32, UnsafePointer<CChar>?, Int32) -> Int32
    private typealias SetVoiceFunction =
        @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias TextToPhonemesFunction =
        @convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>?, Int32, Int32)
            -> UnsafePointer<CChar>?

    /// Synchronous output. espeak is only being asked for phonemes, but it
    /// still wants to know what it would have done with the audio.
    private static let audioOutputSynchronous: Int32 = 0x02

    /// UTF-8 in.
    private static let textModeUTF8: Int32 = 1

    /// IPA out, with `_` between the phonemes of a word.
    ///
    /// `ord("_") << 8 | 0x02`, exactly as phonemizer asks for it. The low bits
    /// choose IPA; the high byte is the separator character. Ask for a
    /// different separator and every phoneme boundary moves, which changes what
    /// the tokeniser is given.
    private static let phonemeModeIPA: Int32 = Int32(UInt8(ascii: "_")) << 8 | 0x02

    enum Failure: Error, CustomStringConvertible {
        case notInstalled([URL])
        case cannotLoad(String, String)
        case missingSymbol(String)
        case initialisationFailed(Int32, URL)
        case noSuchVoice(String)

        var description: String {
            switch self {
            case .notInstalled(let looked):
                return "espeak-ng is not installed. Run Scripts/fetch-espeak.sh. "
                    + "Looked in: " + looked.map(\.path).joined(separator: ", ")
            case .cannotLoad(let path, let reason):
                return "cannot load \(path): \(reason)"
            case .missingSymbol(let name):
                return "\(name) is not in this espeak-ng; it may be too old"
            case .initialisationFailed(let code, let data):
                return "espeak-ng would not start (\(code)) with data at "
                    + data.path + "; the data directory may be incomplete"
            case .noSuchVoice(let name):
                return "espeak-ng has no voice called \(name)"
            }
        }
    }

    // MARK: - Loading

    /// The one instance, loading it on first use.
    ///
    /// `directory` is for tests, which run from a bundle deep enough that
    /// walking up from the executable does not reach the checkout.
    static func shared(directory: URL? = nil,
                       voice: String = "en-us") throws -> EspeakLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }

        let directory = try directory ?? installedDirectory()
        let library = try EspeakLibrary(
            library: directory.appendingPathComponent("libespeak-ng.dylib"),
            data: directory.appendingPathComponent("espeak-ng-data"),
            voice: voice)
        loaded = library
        return library
    }

    /// Whether speech can work at all, for the setup window to ask.
    static var isInstalled: Bool { (try? installedDirectory()) != nil }

    static func contains(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("libespeak-ng.dylib").path)
    }

    static func installedDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["NIB_ESPEAK_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let candidates = directoryCandidates(
            bundleResources: Bundle.main.resourceURL,
            executable: URL(fileURLWithPath: CommandLine.arguments[0]))
        guard let found = candidates.first(where: contains) else {
            throw Failure.notInstalled(candidates)
        }
        return found
    }

    /// Where to look, in order. Pure so it can be tested without the files,
    /// the way `llamaServerCandidates` is -- that one once named a directory
    /// that existed on a single machine, and every install shipped broken.
    static func directoryCandidates(bundleResources: URL?,
                                    executable: URL) -> [URL] {
        var directories: [URL] = []
        if let bundleResources {
            directories.append(bundleResources.appendingPathComponent("espeak"))
        }
        // Walking up from the binary finds vendor/espeak in a checkout,
        // whether the build is debug, release, or somewhere else entirely.
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            directories.append(directory.appendingPathComponent("vendor/espeak"))
            directory = directory.deletingLastPathComponent()
        }
        return directories
    }

    init(library: URL, data: URL, voice: String) throws {
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            throw Failure.cannotLoad(library.path, reason)
        }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else {
                throw Failure.missingSymbol(name)
            }
            return unsafeBitCast(address, to: type)
        }

        let initialize = try symbol("espeak_Initialize", as: InitializeFunction.self)
        let setVoice = try symbol("espeak_SetVoiceByName", as: SetVoiceFunction.self)
        textToPhonemes = try symbol("espeak_TextToPhonemes",
                                    as: TextToPhonemesFunction.self)

        // Returns the sample rate, or a negative number. Zero is also a
        // failure -- it means the dictionaries were not found, which otherwise
        // shows up much later as English text phonemised as nothing.
        let rate = data.path.withCString {
            initialize(Self.audioOutputSynchronous, 0, $0, 0)
        }
        guard rate > 0 else {
            dlclose(handle)
            throw Failure.initialisationFailed(rate, data)
        }
        sampleRate = rate

        guard voice.withCString({ setVoice($0) }) == 0 else {
            dlclose(handle)
            throw Failure.noSuchVoice(voice)
        }
    }

    // MARK: - Asking

    /// espeak's phonemes for one chunk of text.
    ///
    /// Returned in pieces. espeak takes a pointer to the text and advances it
    /// as it reads, returning one clause at a time and setting the pointer to
    /// null when there is no more; the pieces are joined with a space, which is
    /// what phonemizer does with them.
    func phonemes(for text: String) throws -> String {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        return text.withCString { start -> String in
            var cursor = UnsafeRawPointer(start) as UnsafeRawPointer?
            var pieces: [String] = []
            while cursor != nil {
                let piece = withUnsafeMutablePointer(to: &cursor) {
                    textToPhonemes($0, Self.textModeUTF8, Self.phonemeModeIPA)
                }
                if let piece {
                    pieces.append(String(cString: piece))
                }
            }
            return pieces.joined(separator: " ")
        }
    }

    // Never closed. espeak's globals outlive any handle to it, and dlclose
    // followed by a later dlopen re-runs initialisation against state that was
    // never torn down.
}

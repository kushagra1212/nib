import CKokoro
import Foundation

/// The model, and one call into it.
///
/// Everything else in this directory exists to produce the two inputs: token
/// ids from `KokoroTokenizer`, and 256 floats from `VoicePack`. This hands them
/// to ONNX Runtime and gets samples back at 24000 Hz.
///
/// Both are verified against the Python engine before they reach here, which is
/// what makes a mismatch in the audio mean the inference rather than its
/// inputs.
final class KokoroEngine {
    /// What Kokoro speaks at. Not espeak's rate, and not the output device's.
    static let sampleRate = 24000

    private let session: OpaquePointer
    private let lock = NSLock()

    /// The runtime that was actually loaded, for reporting. The fixtures were
    /// captured against 1.29.0 and another build can produce different samples.
    let runtimeVersion: String

    /// Which name this export uses for its token input: newer models say
    /// `input_ids`, the one nib ships says `tokens`.
    let tokenInputName: String

    /// How many threads the inference may use.
    ///
    /// Two, measured rather than picked. On a 12-core machine, one thread runs
    /// at 1.9x real time, two at 3.5x, four at 4.9x and the default at 5.2x --
    /// so the second thread is worth having and the third is not, given nib
    /// sits in the menu bar and the tool it replaces was noticed for taking a
    /// quarter of the machine.
    ///
    /// It also decides the samples. Reductions run in a different order per
    /// thread count, so the same sentence at two threads and at four differ:
    /// identical to the ear, not to a hash. The audio fixture records this
    /// number for that reason, and changing it means recapturing.
    static let threads: Int32 = 2

    enum Failure: Error, CustomStringConvertible {
        case runtimeMissing([URL])
        case modelMissing(URL)
        case open(String)
        case run(String)
        case noTokens

        var description: String {
            switch self {
            case .runtimeMissing(let looked):
                return "ONNX Runtime is not installed. Run Scripts/fetch-onnx.sh. "
                    + "Looked in: " + looked.map(\.path).joined(separator: ", ")
            case .modelMissing(let url):
                return "no model at \(url.path); download it from nib's setup window"
            case .open(let message), .run(let message):
                return message
            case .noTokens:
                return "nothing to speak"
            }
        }
    }

    // MARK: - Where the runtime lives

    static func runtimeCandidates(bundleResources: URL?, executable: URL) -> [URL] {
        var directories: [URL] = []
        if let bundleResources {
            directories.append(bundleResources.appendingPathComponent("onnx"))
        }
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            directories.append(directory.appendingPathComponent("vendor/onnx"))
            directory = directory.deletingLastPathComponent()
        }
        return directories.map { $0.appendingPathComponent("libonnxruntime.dylib") }
    }

    static func installedRuntime() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["NIB_ONNX_RUNTIME"] {
            return URL(fileURLWithPath: override)
        }
        let candidates = runtimeCandidates(
            bundleResources: Bundle.main.resourceURL,
            executable: URL(fileURLWithPath: CommandLine.arguments[0]))
        guard let found = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { throw Failure.runtimeMissing(candidates) }
        return found
    }

    // MARK: - Opening

    convenience init(model: URL) throws {
        try self.init(model: model, runtime: Self.installedRuntime())
    }

    init(model: URL, runtime: URL, threads: Int32 = KokoroEngine.threads) throws {
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw Failure.modelMissing(model)
        }
        guard FileManager.default.fileExists(atPath: runtime.path) else {
            throw Failure.runtimeMissing([runtime])
        }

        var message = [CChar](repeating: 0, count: Int(KOKORO_ERROR_MAX))
        guard let opened = kokoro_open(runtime.path, model.path, threads, &message)
        else {
            throw Failure.open(String(cString: message))
        }
        // An opaque struct in the header, so Swift imports the pointer as
        // OpaquePointer and it needs no bridging.
        session = opened

        runtimeVersion = String(cString: kokoro_runtime_version(opened))
        tokenInputName = String(cString: kokoro_token_input_name(opened))
    }

    deinit {
        kokoro_close(session)
    }

    // MARK: - Speaking

    /// Samples for one batch of tokens, at 24000 Hz.
    ///
    /// The padding zeros the model expects are added inside the shim, so the
    /// tokens passed here are the tokeniser's own output and nothing else.
    ///
    /// Serialised. ONNX Runtime documents `Run` as safe to call concurrently,
    /// but nib has no reason to and an unverified claim about someone else's
    /// thread safety is not worth the crash it would cost to be wrong.
    func synthesise(tokens: [Int], style: [Float], speed: Float = 1.0) throws -> [Float] {
        guard !tokens.isEmpty else { throw Failure.noTokens }

        lock.lock()
        defer { lock.unlock() }

        let identifiers = tokens.map(Int64.init)
        var message = [CChar](repeating: 0, count: Int(KOKORO_ERROR_MAX))
        var samples: UnsafeMutablePointer<Float>?
        var count = 0

        let status = identifiers.withUnsafeBufferPointer { tokenBuffer in
            style.withUnsafeBufferPointer { styleBuffer in
                kokoro_run(session,
                           tokenBuffer.baseAddress, tokenBuffer.count,
                           styleBuffer.baseAddress, styleBuffer.count,
                           speed, &samples, &count, &message)
            }
        }

        guard status == 0, let samples else {
            throw Failure.run(String(cString: message))
        }
        defer { kokoro_free_samples(samples) }
        return Array(UnsafeBufferPointer(start: samples, count: count))
    }
}

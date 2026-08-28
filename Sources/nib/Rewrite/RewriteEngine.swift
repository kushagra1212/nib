import Foundation

/// What to ask the model for.
enum RewriteMode: String, CaseIterable {
    case fixGrammar = "Fix grammar"
    case clearer = "Make clearer"
    case shorter = "Make shorter"

    /// Instruction given to the model.
    ///
    /// Small models drift into commentary ("Sure! Here is the corrected...")
    /// unless told plainly to emit the text alone, so every prompt says so.
    var instruction: String {
        switch self {
        case .fixGrammar:
            return "Correct the grammar, spelling, and punctuation of the text below. "
                + "Keep the meaning and wording as close to the original as possible."
        case .clearer:
            return "Rewrite the text below to be clearer and easier to read. "
                + "Keep the same meaning and roughly the same length."
        case .shorter:
            return "Rewrite the text below to be shorter, keeping every important point."
        }
    }
}

enum RewriteError: Error, CustomStringConvertible {
    case modelMissing(String)
    case serverFailed(String)
    case badResponse

    var description: String {
        switch self {
        case .modelMissing(let path): return "no model at \(path)"
        case .serverFailed(let why): return "llama-server: \(why)"
        case .badResponse: return "could not parse the model's response"
        }
    }
}

/// Runs a local GGUF model for rewriting, via llama-server.
///
/// A subprocess rather than linked libllama: it isolates crashes, and killing
/// the process is the simplest way to actually return the model's memory to the
/// system when it goes idle. Loading a model costs a few hundred MB, which is
/// most of nib's footprint, so it is not kept resident.
actor RewriteEngine {
    struct Config {
        var serverBinary: URL
        var modelPath: URL
        var port: UInt16 = 8

        /// Kill the server after this long with no requests.
        var idleTimeout: TimeInterval = 300
        var contextSize = 2048
        var maxTokens = 512
        /// Low but not zero: deterministic enough to trust, not so rigid that
        /// it repeats the input verbatim when it has nothing to change.
        var temperature = 0.3
    }

    private let config: Config
    private var process: Process?
    private var port: UInt16?
    private var idleTask: Task<Void, Never>?

    init(config: Config) {
        self.config = config
    }

    var isLoaded: Bool { process?.isRunning ?? false }

    // MARK: - Rewriting

    func rewrite(_ text: String, mode: RewriteMode) async throws -> String {
        let port = try await ensureRunning()
        scheduleIdleShutdown()

        let prompt = """
        \(mode.instruction)
        Reply with only the rewritten text. Do not explain, comment, or add quotes.

        Text:
        \(text)
        """

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "user", "content": prompt]],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false,
        ])

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw RewriteError.badResponse }

        return Self.clean(content)
    }

    /// Strips the scaffolding small models add despite being told not to.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reasoning models emit a <think> block before the answer.
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fenced code blocks, which some models wrap prose in.
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let body = lines.dropFirst().prefix { !$0.hasPrefix("```") }
            text = body.joined(separator: "\n")
        }

        // A preamble like "Here is the corrected text:" on its own first line.
        let preambles = ["here is", "here's", "sure", "certainly", "corrected text",
                         "rewritten text", "revised text"]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            let first = lines[0].lowercased().trimmingCharacters(in: .whitespaces)
            if first.hasSuffix(":"), preambles.contains(where: { first.hasPrefix($0) }) {
                text = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Matched wrapping quotes the model added around the whole answer.
        for pair in [("\"", "\""), ("“", "”"), ("'", "'")] {
            if text.hasPrefix(pair.0), text.hasSuffix(pair.1), text.count > 2 {
                text = String(text.dropFirst().dropLast())
                break
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Server lifecycle

    private func ensureRunning() async throws -> UInt16 {
        if let process, process.isRunning, let port { return port }

        guard FileManager.default.isReadableFile(atPath: config.modelPath.path) else {
            throw RewriteError.modelMissing(config.modelPath.path)
        }
        guard FileManager.default.isExecutableFile(atPath: config.serverBinary.path) else {
            throw RewriteError.serverFailed("binary not found at \(config.serverBinary.path)")
        }

        let chosen = try Self.freePort()
        let proc = Process()
        proc.executableURL = config.serverBinary
        proc.arguments = [
            "--model", config.modelPath.path,
            "--port", String(chosen),
            "--host", "127.0.0.1",
            "--ctx-size", String(config.contextSize),
            "--log-disable",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw RewriteError.serverFailed(error.localizedDescription)
        }
        process = proc
        port = chosen

        try await waitUntilHealthy(port: chosen, process: proc)
        return chosen
    }

    private func waitUntilHealthy(port: UInt16, process: Process) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = Date().addingTimeInterval(60)

        while Date() < deadline {
            guard process.isRunning else {
                throw RewriteError.serverFailed("exited during startup")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        shutdown()
        throw RewriteError.serverFailed("did not become healthy within 60s")
    }

    /// Asks the kernel for an unused port by binding one and releasing it.
    private static func freePort() throws -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw RewriteError.serverFailed("socket() failed") }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // let the kernel pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw RewriteError.serverFailed("bind() failed") }

        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        guard named == 0 else { throw RewriteError.serverFailed("getsockname() failed") }
        return UInt16(bigEndian: out.sin_port)
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let timeout = config.idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.shutdown()
        }
    }

    func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        process?.terminate()
        process = nil
        port = nil
    }
}

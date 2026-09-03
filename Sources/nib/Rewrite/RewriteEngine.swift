import Foundation

/// What to ask the model for.
enum RewriteMode: String, CaseIterable {
    case fixGrammar = "Fix grammar"
    case clearer = "Make clearer"
    case shorter = "Make shorter"
    case native = "Native English"

    /// Instruction given to the model.
    ///
    /// Small models drift into commentary ("Sure! Here is the corrected...")
    /// unless told plainly to emit the text alone, so every prompt says so.
    var instruction: String {
        switch self {
        case .fixGrammar:
            // Measured on Qwen3 0.6B against "there is a bug in product
            // details, it is not exactly a bug but ideally when I click on 2
            // options, ... does not get close":
            //
            //   instruction alone            echoed the input, unchanged
            //   + example                    fixed the capital, nothing else
            //   + example + "always output   fixed the capital, split the
            //     a corrected version"       comma splice, "close" -> "closed"
            //                                -- and rewrote text that was
            //                                already correct: "The quick brown
            //                                fox jumps over the lazy dog"
            //                                became "There is a quick brown
            //                                fox that jumps over the lazy dog"
            //
            // Damaging correct sentences is the worse failure, so the coercion
            // is not here. What that leaves is a model that fixes spelling and
            // little else: it does not correct "it are not" or "I clicks" even
            // when told plainly. 0.6B is under the bar for grammar. A 1.7B
            // model is what this prompt is waiting for, and rankModels already
            // prefers one when installed.
            return "Correct the grammar, spelling, and punctuation of the user's text. "
                + "Keep the meaning and wording as close to the original as possible. "
                + "Split run-on sentences and comma splices."
        case .clearer:
            return "Rewrite the user's text to be clearer and easier to read. "
                + "Keep the same meaning and roughly the same length."
        case .shorter:
            return "Rewrite the user's text to be shorter, keeping every important point."
        case .native:
            // The only mode allowed to reorder. Everything else is written to
            // stay close to what was typed, because its output is applied as
            // inline corrections; this one is asked for explicitly, shown in
            // full, and applied only when accepted.
            //
            // "As a native speaker would write it" rather than "so it reads
            // well". The second gets a tidier version of the same sentence;
            // the first is what someone learning the language is asking for --
            // the phrasing a native would have reached for instead.
            return "Rewrite the user's text the way a native British English "
                + "speaker would naturally write it. Fix the grammar, replace "
                + "unidiomatic phrasing with what a native speaker would say, "
                + "and reorder or split sentences where that is more natural. "
                + "Keep every fact and every point the text makes. "
                + "Do not add information that is not there."
        }
    }

    /// Constant per mode, so the server can reuse the cached prefix rather
    /// than reprocessing the instruction on every request.
    /// British English throughout: spelling and idiom both.
    ///
    /// Stated rather than left to the model. Asked without it, a model trained
    /// mostly on American text writes "color" and "gotten" into a document
    /// whose every other word is British, which is a worse result than either
    /// convention applied consistently.
    static let dialect = " Use British English spelling and idiom."

    /// How far a rewrite may travel from what was written.
    ///
    /// Constant. This was a three-stop dial on the selection bar, removed
    /// because it asked a question most people cannot answer about a sentence
    /// they already know is wrong.
    static let latitude = " Rewrite as much as needed for it to read well."

    func systemPrompt() -> String {
        instruction
            + Self.latitude
            + Self.dialect
            + " Reply with only the rewritten text."
            + " Do not explain, comment, add quotes, or think out loud."
            + " Leave code, identifiers, acronyms and proper nouns exactly as written."
    }

    /// A worked example, as a real exchange rather than text in the system
    /// message.
    ///
    /// Written into the instruction, the example was not understood as an
    /// example. Given a long input, Qwen3 0.6B returned "We were going to the
    /// store and bought milk. It doesn't work." -- the example's own output,
    /// in place of the user's sentence. Asked to tidy a paragraph about
    /// Chromium, it answered with a paragraph about milk.
    ///
    /// As a user turn and an assistant turn it is unambiguous: the model sees
    /// one exchange that is over, then a new question. The demonstration
    /// survives and the leak does not.
    var example: (input: String, output: String)? {
        // None, for any mode.
        //
        // Moving it into proper turns did not help: given the same long
        // paragraph the model still answered "We were going to the store and
        // bought milk. It doesn't work." A 0.6B model handed a long input and
        // a short worked example returns the example, whichever way it is
        // framed, and one wrong sentence delivered in place of someone's
        // paragraph costs more than the capital letter the example bought.
        //
        // The hook stays because a larger model does use examples properly,
        // and this is where its example goes.
        nil
    }
}

/// The tail of llama-server's stderr.
///
/// Written from the pipe's reader thread and read by the actor, so it holds a
/// lock rather than relying on either one's isolation. Bounded: a server left
/// running for an afternoon would otherwise accumulate its whole log in memory
/// for the sake of the last few lines, which are the only ones ever read.
final class ServerErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        if text.count > 8_000 { text = String(text.suffix(4_000)) }
    }

    var recent: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        text = ""
    }
}

enum RewriteError: Error, CustomStringConvertible {
    case modelMissing(String)
    case serverFailed(String)
    case badResponse
    /// The server answered, and said no.
    case rejected(status: Int, detail: String)
    /// Metal could not find room for the model.
    case outOfMemory

    var description: String {
        switch self {
        case .modelMissing(let path): return "no model at \(path)"
        case .serverFailed(let why): return "llama-server: \(why)"
        case .badResponse: return "could not parse the model's response"
        case let .rejected(status, detail):
            return detail.isEmpty
                ? "llama-server answered \(status)"
                : "llama-server answered \(status): \(detail)"
        case .outOfMemory:
            return "not enough memory to run this model -- try a smaller one, "
                + "or close some apps"
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
        /// Greedy. Correcting a sentence has a right answer, so sampling adds
        /// latency and variance in exchange for nothing. It also makes the
        /// cache useful: the same input now yields the same output.
        var temperature = 0.0
        /// Half the performance cores, so a rewrite does not compete with
        /// whatever the user is actually doing.
        var threads = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    private let config: Config
    private var process: Process?
    private var port: UInt16?
    private let errorLog = ServerErrorLog()
    private var idleTask: Task<Void, Never>?

    init(config: Config) {
        self.config = config
    }

    var isLoaded: Bool { process?.isRunning ?? false }

    // MARK: - Rewriting

    func rewrite(
        _ text: String, mode: RewriteMode,
    ) async throws -> String {
        let port = try await ensureRunning()
        scheduleIdleShutdown()

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // The instruction is a system message so it stays byte-identical
        // between calls, which is what lets the server reuse the cached
        // prefix and only process the sentence itself.
        var messages: [[String: String]] = [
            ["role": "system", "content": mode.systemPrompt()],
        ]
        if let example = mode.example {
            messages.append(["role": "user", "content": example.input])
            messages.append(["role": "assistant", "content": example.output])
        }
        messages.append(["role": "user", "content": text])

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": messages,
            "temperature": config.temperature,
            "top_k": 1,
            "max_tokens": Self.tokenBudget(for: text, limit: config.maxTokens),
            "stream": false,
            // Belt and braces alongside the server flag: some templates only
            // honour thinking control passed per request.
            "chat_template_kwargs": ["enable_thinking": false],
        ])

        // Cleared immediately before the request, so anything the server logs
        // belongs to this one rather than to something that failed earlier.
        errorLog.clear()
        let (data, response) = try await URLSession.shared.data(for: request)

        // A refusal is not a parse problem, and reporting it as one costs an
        // afternoon: "could not parse the model's response" says nothing about
        // what to do next, and sends you looking for a parsing bug that is not
        // there.
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw Self.failure(status: http.statusCode, body: data,
                               log: errorLog.recent)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw RewriteError.badResponse }

        return Self.clean(content)
    }

    /// Turns an error response into something worth reading.
    ///
    /// Both halves are needed. The body carries llama.cpp's own message, which
    /// for a model too large is the unhelpful "Compute error."; the log
    /// carries the Metal out-of-memory line that says what actually happened.
    /// Naming that one matters because the fix is a smaller model, not a retry.
    static func failure(status: Int, body: Data, log: String = "") -> RewriteError {
        var detail = String(decoding: body, as: UTF8.self)
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            detail = message
        }

        let haystack = (detail + " " + log).lowercased()
        for marker in ["out of memory", "outofmemory", "insufficient memory"] {
            if haystack.contains(marker) { return .outOfMemory }
        }
        return .rejected(status: status,
                         detail: String(detail.prefix(200))
                             .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Caps generation to a little more than the input.
    ///
    /// A correction is about as long as what it corrects, so a flat 512-token
    /// ceiling only ever mattered when the model had started rambling -- and
    /// then it made us wait for the rambling. Roughly four characters per
    /// token, with headroom for a longer rewrite.
    static func tokenBudget(for text: String, limit: Int) -> Int {
        let estimated = text.count / 4
        return min(limit, max(64, Int(Double(estimated) * 1.8) + 32))
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

            // --log-disable is deliberately not passed. It silences the Metal
            // out-of-memory report along with everything else, which is the
            // one message worth having: with it on, a model too large for the
            // machine fails as "Compute error." and nothing else.
            //
            // The output is not printed anywhere. It goes to the bounded
            // buffer above, which is read only to look for that failure and is
            // never shown to the user, so nothing llama.cpp logs is displayed.

            // Offload everything to the GPU. 'auto' is already the default in
            // recent builds, but being explicit means an older llama.cpp does
            // not quietly run this on the CPU.
            "--n-gpu-layers", "99",
            "--flash-attn", "on",

            // Qwen3 is a reasoning model: left alone it emits a <think> block
            // before the answer, and the budget is unrestricted by default.
            // The block was being generated in full and then thrown away by
            // clean(), so every rewrite paid for hundreds of tokens nobody
            // ever saw. This is the single largest cost in the whole path.
            "--reasoning", "off",
            "--reasoning-budget", "0",

            // Reuse the cached prefix across calls. The instruction is a
            // constant system message, so only the user's sentence needs
            // processing on each request.
            "--cache-reuse", "128",

            // One slot: the app never issues concurrent rewrites, and each
            // extra slot reserves its own KV cache.
            "--parallel", "1",

            // Leave cores for the user. The default takes every performance
            // core, which is exactly the wrong trade for something running
            // behind whatever they are actually doing.
            "--threads", String(config.threads),
        ]
        proc.standardOutput = FileHandle.nullDevice

        // stderr is kept rather than discarded. When a model is too big for
        // the GPU, llama.cpp answers the HTTP request with the two words
        // "Compute error." and writes the actual reason -- an out-of-memory
        // from Metal -- only here. Throwing this away makes the most common
        // reason a model will not run impossible to report.
        let errors = Pipe()
        proc.standardError = errors
        let log = errorLog
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            log.append(String(decoding: chunk, as: UTF8.self))
        }

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
        if let errors = process?.standardError as? Pipe {
            errors.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminate()
        process = nil
        port = nil
        errorLog.clear()
    }
}

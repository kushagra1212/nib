import Foundation

enum LSPError: Error, CustomStringConvertible {
    case notRunning
    case launchFailed(String)
    case server(code: Int, message: String)
    case timedOut(method: String)

    var description: String {
        switch self {
        case .notRunning: return "language server is not running"
        case .launchFailed(let why): return "could not launch language server: \(why)"
        case .server(let code, let message): return "server error \(code): \(message)"
        case .timedOut(let method): return "timed out waiting for \(method)"
        }
    }
}

/// JSON-RPC transport for a language server spoken over stdio.
///
/// Deliberately untyped: LSP payloads are heterogeneous and modelling every
/// message as Codable costs far more than it returns here. Callers pluck the
/// fields they need out of the dictionaries.
final class LSPClient {
    /// Answers a server-to-client request. Return the `result` value.
    var onRequest: ((_ method: String, _ params: Any?) -> Any?)?
    /// Receives a server-to-client notification.
    var onNotification: ((_ method: String, _ params: Any?) -> Void)?
    /// Called if the server process exits on its own.
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var framer = MessageFramer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "nib.lsp.write")

    var isRunning: Bool { process?.isRunning ?? false }

    func start(executable: URL, arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(
                Data("[harper-ls] \(String(decoding: data, as: UTF8.self))".utf8)
            )
        }
        proc.terminationHandler = { [weak self] p in
            self?.failAllPending(with: LSPError.notRunning)
            self?.onExit?(p.terminationStatus)
        }

        do {
            try proc.run()
        } catch {
            throw LSPError.launchFailed(error.localizedDescription)
        }
        process = proc
        stdin = inPipe.fileHandleForWriting
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        failAllPending(with: LSPError.notRunning)
        process = nil
        stdin = nil
    }

    // MARK: - Sending

    func notify(_ method: String, _ params: Any) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Sends a request and suspends until the matching response arrives.
    func request(_ method: String, _ params: Any, timeout: TimeInterval = 10) async throws -> Any? {
        guard isRunning else { throw LSPError.notRunning }

        let id: Int = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resume(id: id, with: .failure(LSPError.timedOut(method: method)))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    private func write(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        let framed = MessageFramer.encode(body)
        writeQueue.async { [weak self] in
            guard let handle = self?.stdin else { return }
            // The server can die between the guard and the write; a broken pipe
            // raises SIGPIPE-as-exception, which would take the whole app down.
            do {
                try handle.write(contentsOf: framed)
            } catch {
                self?.failAllPending(with: LSPError.notRunning)
            }
        }
    }

    // MARK: - Receiving

    private func ingest(_ data: Data) {
        let messages = lock.withLock { framer.push(data) }
        for body in messages {
            guard let obj = try? JSONSerialization.jsonObject(with: body),
                  let message = obj as? [String: Any] else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: [String: Any]) {
        let method = message["method"] as? String
        let id = message["id"] as? Int

        switch (method, id) {
        case let (method?, id?): // server -> client request
            let result = onRequest?(method, message["params"]) ?? NSNull()
            write(["jsonrpc": "2.0", "id": id, "result": result])

        case let (method?, nil): // server -> client notification
            onNotification?(method, message["params"])

        case let (nil, id?): // response to one of our requests
            if let error = message["error"] as? [String: Any] {
                resume(id: id, with: .failure(LSPError.server(
                    code: error["code"] as? Int ?? -1,
                    message: error["message"] as? String ?? "unknown"
                )))
            } else {
                resume(id: id, with: .success(message["result"]))
            }

        case (nil, nil):
            break
        }
    }

    private func resume(id: Int, with result: Result<Any?, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        guard let continuation else { return } // already resumed
        continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        let waiting = lock.withLock {
            let all = pending
            pending.removeAll()
            return all
        }
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }
}

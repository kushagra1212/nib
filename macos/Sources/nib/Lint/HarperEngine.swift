import Foundation

/// Drives harper-ls and turns its diagnostics into `Suggestion`s.
///
/// The handshake here is not guesswork: harper-ls pulls its settings via
/// `workspace/configuration` and refuses to lint at all if the reply lacks a
/// top-level "harper-ls" key, logging `Settings must contain a "harper-ls" key`
/// to stderr and then silently doing nothing. It also drops `didOpen` if that
/// arrives before it has answered `initialize`, so the handshake is sequenced.
/// See Scripts/probe_harper.py for the bare-bones reproduction.
final class HarperEngine {
    struct Settings {
        var dialect = "American"
        var diagnosticSeverity = "hint"
        var isolateEnglish = false
        var maxFileLength = 120_000

        var payload: [String: Any] {
            [
                "linters": [:],
                "codeActions": ["forceStable": false],
                "markdown": ["IgnoreLinkTitle": false],
                "dialect": dialect,
                "diagnosticSeverity": diagnosticSeverity,
                "isolateEnglish": isolateEnglish,
                "maxFileLength": maxFileLength,
            ]
        }
    }

    /// harper-ls keys documents by URI. We only ever lint one scratch buffer.
    private static let documentURI = "file:///private/tmp/nib-buffer.md"

    private let client = LSPClient()
    private let executable: URL
    private var settings: Settings
    private var version = 0
    private var started = false

    private let lock = NSLock()
    private var diagnosticsWaiter: CheckedContinuation<[[String: Any]], Error>?
    /// Bumped per lint so a late timeout cannot cancel a newer request's waiter.
    private var waiterGeneration = 0
    /// Raw diagnostics from the last lint, keyed by suggestion, so replacement
    /// text can be fetched on demand instead of for every diagnostic upfront.
    private var diagnosticIndex: [UUID: (diagnostic: [String: Any], range: [String: Any])] = [:]

    init(executable: URL, settings: Settings = Settings()) {
        self.executable = executable
        self.settings = settings
    }

    /// Set NIB_DEBUG=1 to trace the LSP conversation.
    static func debugLog(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["NIB_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[nib] \(message())\n".utf8))
    }

    var isRunning: Bool { client.isRunning }

    // MARK: - Lifecycle

    func start() async throws {
        guard !started else { return }

        client.onRequest = { [weak self] method, _ in
            guard let self else { return NSNull() }
            switch method {
            case "workspace/configuration":
                // One settings object per requested item; harper only ever asks
                // for one, but answering per-item keeps us spec-correct.
                return [["harper-ls": self.settings.payload]]
            case "client/registerCapability":
                return NSNull()
            default:
                return NSNull()
            }
        }
        client.onNotification = { [weak self] method, params in
            guard method == "textDocument/publishDiagnostics",
                  let params = params as? [String: Any],
                  params["uri"] as? String == Self.documentURI,
                  let diagnostics = params["diagnostics"] as? [[String: Any]]
            else { return }
            Self.debugLog("publishDiagnostics count=\(diagnostics.count) "
                          + "version=\(params["version"] as? Int ?? -1)")
            self?.deliverDiagnostics(diagnostics)
        }
        client.onExit = { [weak self] _ in
            self?.started = false
            self?.failWaiter(LSPError.notRunning)
        }

        try client.start(executable: executable, arguments: ["--stdio"])

        _ = try await client.request("initialize", [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": "file:///private/tmp",
            "workspaceFolders": [["uri": "file:///private/tmp", "name": "tmp"]],
            "capabilities": [
                "textDocument": [
                    "publishDiagnostics": [:],
                    "codeAction": [:],
                    "synchronization": ["dynamicRegistration": false],
                ],
                "workspace": ["configuration": true],
            ],
        ], timeout: 15)

        client.notify("initialized", [:])

        // harper answers didOpen with its own publishDiagnostics. For an empty
        // document that is an empty array, and it lands asynchronously — late
        // enough to be mistaken for the answer to the first real lint, which
        // then reports a document full of errors as clean. Drain it here.
        started = true
        _ = try? await awaitDiagnostics(timeout: 5) {
            client.notify("textDocument/didOpen", [
                "textDocument": [
                    "uri": Self.documentURI,
                    "languageId": "markdown",
                    "version": 0,
                    "text": "",
                ],
            ])
        }
    }

    func stop() {
        client.stop()
        started = false
    }

    // MARK: - Linting

    /// Lints `text` and returns suggestions, without replacement text.
    ///
    /// Replacements deliberately are not fetched here. Harper reports them only
    /// through `textDocument/codeAction`, one request per diagnostic, and a
    /// 2000-word document produces ~430 diagnostics. Fanning those out over a
    /// single stdio pipe took 5.7s. The user only ever acts on a handful, so
    /// call `replacements(for:)` when a suggestion is actually shown.
    func lint(_ text: String, timeout: TimeInterval = 10) async throws -> [Suggestion] {
        if !started { try await start() }

        version += 1
        let diagnostics = try await awaitDiagnostics(timeout: timeout) {
            client.notify("textDocument/didChange", [
                "textDocument": ["uri": Self.documentURI, "version": version],
                "contentChanges": [["text": text]],
            ])
        }

        let mapper = PositionMapper(text: text)
        var suggestions: [Suggestion] = []
        var index: [UUID: (diagnostic: [String: Any], range: [String: Any])] = [:]

        for diagnostic in diagnostics {
            guard let lspRange = diagnostic["range"] as? [String: Any],
                  let range = mapper.range(from: lspRange),
                  let message = diagnostic["message"] as? String
            else { continue }
            let suggestion = Suggestion(range: range, message: message, replacements: [])
            suggestions.append(suggestion)
            index[suggestion.id] = (diagnostic, lspRange)
        }

        lock.withLock { diagnosticIndex = index }
        // Harper matches against a word list, so it "corrects" acronyms, type
        // names and product names into nonsense. Filtered before anything is
        // shown; see SuggestionFilter.
        return SuggestionFilter.apply(suggestions, in: text)
    }

    /// Fetches replacement text for one suggestion from the last lint.
    ///
    /// Returns an empty array for advisory lints that carry no edit, and for
    /// suggestions from a superseded lint.
    func replacements(for suggestion: Suggestion) async -> [String] {
        guard let entry = lock.withLock({ diagnosticIndex[suggestion.id] }) else { return [] }

        let response = try? await client.request("textDocument/codeAction", [
            "textDocument": ["uri": Self.documentURI],
            "range": entry.range,
            "context": ["diagnostics": [entry.diagnostic]],
        ], timeout: 5)

        guard let actions = response as? [[String: Any]] else { return [] }
        return actions.compactMap { action -> String? in
            // Skip "Add to dictionary" / "Ignore" actions: they carry no edit.
            guard let edit = action["edit"] as? [String: Any],
                  let changes = edit["changes"] as? [String: [[String: Any]]],
                  let edits = changes[Self.documentURI], edits.count == 1
            else { return nil }
            return edits[0]["newText"] as? String
        }
    }

    /// Fills in replacements for a slice of suggestions, for a panel or card
    /// that is about to display them.
    ///
    /// `text` is needed to re-run the filter: the plausibility half compares a
    /// replacement against the word it would replace, and replacements are not
    /// known when `lint` first filters. Skipping this pass let "bugs" to
    /// "thing" through, since only the shape checks had run.
    func withReplacements(_ suggestions: [Suggestion], in text: String) async -> [Suggestion] {
        var out: [Suggestion] = []
        for suggestion in suggestions {
            let fixes = await replacements(for: suggestion)
            out.append(Suggestion(id: suggestion.id, range: suggestion.range,
                                  message: suggestion.message, replacements: fixes))
        }
        return SuggestionFilter.apply(out, in: text)
    }

    // MARK: - Waiter plumbing

    /// Arms a one-shot waiter for the next publishDiagnostics, then runs `send`.
    ///
    /// The waiter is installed before `send` so a fast reply cannot arrive
    /// before anything is listening for it.
    private func awaitDiagnostics(
        timeout: TimeInterval, send: () -> Void
    ) async throws -> [[String: Any]] {
        let generation: Int = lock.withLock {
            waiterGeneration += 1
            return waiterGeneration
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // A previous request that never got an answer must not strand its caller.
            let stale = diagnosticsWaiter
            diagnosticsWaiter = continuation
            lock.unlock()
            stale?.resume(throwing: LSPError.timedOut(method: "publishDiagnostics"))

            send()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Only fail the waiter this timeout was armed for.
                self?.failWaiter(LSPError.timedOut(method: "publishDiagnostics"),
                                 generation: generation)
            }
        }
    }

    private func deliverDiagnostics(_ diagnostics: [[String: Any]]) {
        lock.lock()
        let waiter = diagnosticsWaiter
        diagnosticsWaiter = nil
        lock.unlock()
        waiter?.resume(returning: diagnostics)
    }

    private func failWaiter(_ error: Error, generation: Int? = nil) {
        lock.lock()
        // A timeout carries the generation it was armed for; if the current
        // waiter is newer, this timeout belongs to a lint that already finished.
        if let generation, generation != waiterGeneration {
            lock.unlock()
            return
        }
        let waiter = diagnosticsWaiter
        diagnosticsWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }
}

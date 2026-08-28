import AppKit
import Foundation

/// Locates the bundled harper-ls.
///
/// Inside a built .app it sits in Contents/Resources; during development it
/// lives in vendor/ at the repo root, which is where fetch-harper.sh puts it.
func locateHarper() -> URL? {
    let fm = FileManager.default

    if let resource = Bundle.main.url(forResource: "harper-ls", withExtension: nil),
       fm.isExecutableFile(atPath: resource.path) {
        return resource
    }

    // Walk up from the executable looking for vendor/harper-ls.
    var dir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("vendor/harper-ls")
        if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

func runLintCLI(_ text: String) async -> Int32 {
    guard let harper = locateHarper() else {
        FileHandle.standardError.write(Data(
            "harper-ls not found. Run Scripts/fetch-harper.sh\n".utf8))
        return 1
    }

    let engine = HarperEngine(executable: harper)
    defer { engine.stop() }

    do {
        let clock = ContinuousClock()
        var suggestions: [Suggestion] = []
        let elapsed = try await clock.measure {
            suggestions = try await engine.lint(text)
        }

        if suggestions.isEmpty {
            print("clean (\(elapsed))")
            return 0
        }
        print("\(suggestions.count) suggestion(s) in \(elapsed):")
        // Replacements are fetched only for what gets shown.
        let shown = await engine.withReplacements(Array(suggestions.prefix(20)))
        for s in shown {
            let excerpt = s.excerpt(in: text) ?? "?"
            let fixes = s.replacements.isEmpty
                ? "(no automatic fix)"
                : s.replacements.prefix(3).joined(separator: " | ")
            print("  \(excerpt.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.message)")
            print("      -> \(fixes)")
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("lint failed: \(error)\n".utf8))
        return 1
    }
}

/// Measures cold start separately from warm lint latency.
///
/// Cold includes spawning harper-ls and the LSP handshake; warm is what the
/// user actually feels once the app is resident, so they are reported apart.
func runBench(words: Int, iterations: Int) async -> Int32 {
    guard let harper = locateHarper() else {
        FileHandle.standardError.write(Data("harper-ls not found\n".utf8))
        return 1
    }
    let sample = "The quick brown fox jumps over the lazy dog. Their is a erors here. "
    var text = ""
    while text.split(separator: " ").count < words { text += sample }

    let engine = HarperEngine(executable: harper)
    defer { engine.stop() }
    let clock = ContinuousClock()

    do {
        var first: [Suggestion] = []
        let cold = try await clock.measure { first = try await engine.lint(text) }
        print("words: \(text.split(separator: " ").count), suggestions: \(first.count)")
        print("cold (spawn + handshake + lint): \(cold)")

        var timings: [Duration] = []
        for _ in 0..<iterations {
            timings.append(try await clock.measure { _ = try await engine.lint(text) })
        }
        let sorted = timings.sorted()
        let total = timings.reduce(Duration.zero, +)
        print("warm x\(iterations): min \(sorted.first!), median \(sorted[sorted.count / 2]), max \(sorted.last!), mean \(total / iterations)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("bench failed: \(error)\n".utf8))
        return 1
    }
}

/// Counts down, then reports what AX exposes for whatever field is focused.
func runAXProbe(delay: Int) -> Int32 {
    if !AXAccess.isTrusted {
        print("Accessibility permission not granted.")
        AXAccess.requestTrust()
        print("Approve nib in System Settings > Privacy & Security > Accessibility,")
        print("then run this again. Opening that pane now.")
        AXAccess.openSettings()
        return 1
    }

    print("Click into a text field in the app you want to test.")
    for remaining in stride(from: delay, to: 0, by: -1) {
        print("  probing in \(remaining)...")
        Thread.sleep(forTimeInterval: 1)
    }

    guard let report = AXProbe.probeFocused() else {
        print(AXProbe.diagnoseNoFocus())
        return 1
    }
    AXProbe.printReport(report)
    return 0
}

/// Directories that may hold GGUF models, most specific first.
///
/// The current directory is deliberately not among them: an app launched from
/// Finder has a working directory of "/", so anything relative silently fails.
func modelSearchPaths() -> [URL] {
    var paths: [URL] = []
    if let resources = Bundle.main.resourceURL {
        paths.append(resources.appendingPathComponent("models"))
    }
    paths.append(
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nib/models")
    )
    // Development checkout: walk up from the executable to the repo root.
    var dir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<6 {
        paths.append(dir.appendingPathComponent("models"))
        dir = dir.deletingLastPathComponent()
    }
    return paths
}

/// Locates llama-server, checking the bundle before known build locations.
func locateLlamaServer() -> URL? {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL {
        candidates.append(resources.appendingPathComponent("llama-server"))
    }
    candidates.append(URL(fileURLWithPath:
        "/Users/apple/code/per/llama.cpp/build/bin/llama-server"))
    candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"))
    candidates.append(URL(fileURLWithPath: "/usr/local/bin/llama-server"))

    return candidates.first { fm.isExecutableFile(atPath: $0.path) }
}

/// Ranks installed models best-first.
///
/// Measured on "Their is many erors in this sentance, and it are very long and
/// wordy in a way that could of been much more shorter":
///
///   Qwen3 0.6B    fixed every error in all three modes.
///   Gemma 3 270M  fixed only the misspellings in grammar mode, and for
///                 "clearer" and "shorter" it described the sentence
///                 ("The sentence is too long and wordy.") instead of
///                 rewriting it.
///
/// 0.6B is the floor for this task. Anything smaller answers the wrong
/// question, so a 270M model is only used when nothing better is installed.
func rankModels(_ names: [String]) -> [String] {
    func score(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("qwen3-1.7b") { return 0 }
        if lower.contains("qwen3-0.6b") { return 1 }
        if lower.contains("llama-3.2-3b") { return 1 }
        if lower.contains("270m") { return 9 } // verified inadequate
        return 5
    }
    return names.sorted { (score($0), $0) < (score($1), $1) }
}

/// Builds a rewrite config, or nil if either the server or a model is missing.
func rewriteConfig(modelName: String?) -> RewriteEngine.Config? {
    guard let server = locateLlamaServer() else { return nil }
    let fm = FileManager.default

    // An explicit absolute path wins over any search.
    if let modelName, modelName.contains("/") {
        return RewriteEngine.Config(serverBinary: server,
                                    modelPath: URL(fileURLWithPath: modelName))
    }

    for dir in modelSearchPaths() {
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
        let models = rankModels(entries.filter { $0.hasSuffix(".gguf") })
        guard !models.isEmpty else { continue }

        if let modelName {
            guard models.contains(modelName) else { continue }
            return RewriteEngine.Config(serverBinary: server,
                                        modelPath: dir.appendingPathComponent(modelName))
        }
        return RewriteEngine.Config(serverBinary: server,
                                    modelPath: dir.appendingPathComponent(models[0]))
    }
    return nil
}

func runRewriteCLI(text: String, modelName: String?) async -> Int32 {
    guard let config = rewriteConfig(modelName: modelName) else {
        FileHandle.standardError.write(Data("no .gguf model in ./models\n".utf8))
        return 1
    }
    print("model: \(config.modelPath.lastPathComponent)")

    let engine = RewriteEngine(config: config)
    defer { Task { await engine.shutdown() } }
    let clock = ContinuousClock()

    for mode in RewriteMode.allCases {
        do {
            var out = ""
            let elapsed = try await clock.measure {
                out = try await engine.rewrite(text, mode: mode)
            }
            print("\n[\(mode.rawValue)] \(elapsed)")
            print("  \(out)")
        } catch {
            print("\n[\(mode.rawValue)] failed: \(error)")
            return 1
        }
    }
    return 0
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--rewrite" {
    let text = args.count > 1 ? args[1] : "Their is many erors in this sentance, and it are very long and wordy in a way that could of been much more shorter."
    let model = args.count > 2 ? args[2] : nil
    exit(await runRewriteCLI(text: text, modelName: model))
}

if args.first == "--ax-probe" {
    let delay = args.count > 1 ? Int(args[1]) ?? 5 : 5
    exit(runAXProbe(delay: delay))
}

if args.first == "--bench" {
    let words = args.count > 1 ? Int(args[1]) ?? 2000 : 2000
    exit(await runBench(words: words, iterations: 10))
}

if args.first == "--lint" {
    let text = args.count > 1
        ? args[1]
        : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    exit(await runLintCLI(text))
}

if args.first == "--help" || args.first == "-h" {
    print("""
    nib — offline writing assistant

    usage:
      nib                        run the menu bar app
      nib --lint "text"          check text and print suggestions
      nib --bench [words]        measure lint latency
      nib --ax-probe [seconds]   report what the focused text field exposes
    """)
    exit(0)
}

// No arguments: run as the menu bar app.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

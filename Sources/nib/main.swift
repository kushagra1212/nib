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

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())

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

FileHandle.standardError.write(Data("""
nib — offline writing assistant

usage:
  nib --lint "text to check"
  echo "text" | nib --lint

The menu bar app is not wired up yet.

""".utf8))
exit(2)

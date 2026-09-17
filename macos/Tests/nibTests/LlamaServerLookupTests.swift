import XCTest
@testable import nib

/// Where nib looks for llama-server.
///
/// This used to name a directory on the author's machine, which meant every
/// Fix, Clearer, Shorter and Freely button was dead for everyone who installed
/// the DMG -- the app looked for a llama.cpp build at a path that only existed
/// here, found nothing, and disabled the feature without saying why.
final class LlamaServerLookupTests: XCTestCase {
    private let bundle = URL(fileURLWithPath: "/Applications/nib.app/Contents/Resources")
    private let executable = URL(fileURLWithPath: "/repo/.build/release/nib")

    private func candidates(bundled: Bool = true) -> [URL] {
        llamaServerCandidates(bundleResources: bundled ? bundle : nil,
                              executable: executable)
    }

    // MARK: - The bug this replaced

    func testNoCandidateIsSomebodysHomeDirectory() {
        for url in candidates() {
            XCTAssertFalse(url.path.hasPrefix("/Users/"),
                           "\(url.path) only exists on one machine")
        }
    }

    // MARK: - Order

    func testTheBundledCopyComesFirst() {
        XCTAssertEqual(candidates().first?.path,
                       "/Applications/nib.app/Contents/Resources/llama/llama-server")
    }

    /// Not Resources/llama-server. The binary needs its libraries beside it,
    /// so it lives in a directory of its own.
    func testTheBundledCopyIsInItsOwnDirectory() {
        let first = try! XCTUnwrap(candidates().first)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "llama")
    }

    func testHomebrewIsLastAndInTheUsualOrder() {
        let paths = candidates().map(\.path)
        XCTAssertEqual(paths.suffix(2), [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
        ])
    }

    /// Homebrew ships a different build than the one nib was tested against,
    /// so nothing bundled or vendored may ever lose to it.
    func testEverythingLocalOutranksHomebrew() {
        let paths = candidates().map(\.path)
        let firstHomebrew = try! XCTUnwrap(paths.firstIndex { $0.hasPrefix("/opt/") })
        XCTAssertEqual(firstHomebrew, paths.count - 2)
    }

    // MARK: - The development checkout

    func testWalksUpFromTheExecutableToTheRepoRoot() {
        let paths = candidates().map(\.path)
        XCTAssertTrue(paths.contains("/repo/vendor/llama/llama-server"),
                      "a checkout that ran Scripts/fetch-llama.sh must be found")
    }

    /// Six directories starting at the one holding the executable, so the
    /// last one reached is five levels above it.
    func testWalksUpSixLevels() {
        let deep = URL(fileURLWithPath: "/a/b/c/d/e/f/g/nib")
        let paths = llamaServerCandidates(bundleResources: nil, executable: deep)
            .map(\.path)
        XCTAssertEqual(paths.first, "/a/b/c/d/e/f/g/vendor/llama/llama-server")
        XCTAssertTrue(paths.contains("/a/b/vendor/llama/llama-server"))
        XCTAssertFalse(paths.contains("/a/vendor/llama/llama-server"))
        XCTAssertEqual(paths.filter { $0.contains("/vendor/llama/") }.count, 6)
    }

    /// The layout that actually matters: .build/release/nib in a checkout has
    /// to reach the repo root, which is three of the six.
    func testADevelopmentCheckoutIsWithinReach() {
        let paths = llamaServerCandidates(
            bundleResources: nil,
            executable: URL(fileURLWithPath: "/repo/.build/release/nib")).map(\.path)
        XCTAssertEqual(paths.prefix(3), [
            "/repo/.build/release/vendor/llama/llama-server",
            "/repo/.build/vendor/llama/llama-server",
            "/repo/vendor/llama/llama-server",
        ])
    }

    /// Running from / must not loop or produce nonsense: deletingLastPathComponent
    /// on the root path returns the root path again.
    func testAnExecutableAtTheRootDoesNotMisbehave() {
        let paths = llamaServerCandidates(
            bundleResources: nil,
            executable: URL(fileURLWithPath: "/nib")).map(\.path)
        XCTAssertFalse(paths.isEmpty)
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix("llama-server") })
    }

    // MARK: - Shape

    func testWithoutABundleTheRestStillResolve() {
        let paths = candidates(bundled: false).map(\.path)
        XCTAssertFalse(paths.contains { $0.contains("nib.app") })
        XCTAssertTrue(paths.contains("/repo/vendor/llama/llama-server"))
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/llama-server"))
    }

    func testTheBundleOnlyAddsOneCandidate() {
        XCTAssertEqual(candidates().count, candidates(bundled: false).count + 1)
    }

    func testEveryCandidateNamesTheBinary() {
        XCTAssertTrue(candidates().allSatisfy { $0.lastPathComponent == "llama-server" })
    }

    // MARK: - What fetch-llama.sh actually produced

    /// Checks the vendored directory when there is one. Skipped rather than
    /// failed on a checkout that has not fetched yet, but a checkout that has
    /// fetched an incomplete set should not get to the point of shipping it.
    func testTheVendoredDirectoryIsComplete() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // nibTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let dir = root.appendingPathComponent("vendor/llama")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: dir.appendingPathComponent("llama-server").path)
        else { throw XCTSkip("vendor/llama is absent -- run Scripts/fetch-llama.sh") }

        let names = try Set(fm.contentsOfDirectory(atPath: dir.path))
        // Not the full closure by name: that changes with the pinned build.
        // These are the ones llama-server cannot start without.
        for required in ["libggml-base.0.dylib", "libggml-cpu.0.dylib",
                         "libggml-metal.0.dylib", "libllama.0.dylib",
                         "libllama-server-impl.dylib"] {
            XCTAssertTrue(names.contains(required), "vendor/llama is missing \(required)")
        }
        XCTAssertTrue(names.contains("LICENSE"), "llama.cpp is MIT; ship its licence")

        // Every @rpath reference has to resolve inside this directory, because
        // at runtime there is nowhere else for it to look.
        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        otool.arguments = ["-L", dir.appendingPathComponent("llama-server").path]
        let pipe = Pipe()
        otool.standardOutput = pipe
        try otool.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        otool.waitUntilExit()

        for line in output.split(separator: "\n").dropFirst() {
            let dep = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            guard dep.hasPrefix("@rpath/") else { continue }
            let name = String(dep.dropFirst("@rpath/".count))
            XCTAssertTrue(names.contains(name),
                          "llama-server loads \(name), which was not vendored")
        }
    }
}

import XCTest
@testable import nib

/// The list of models the setup window offers.
final class ModelCatalogTests: XCTestCase {
    // MARK: - A file the user picked

    func testALocalFileBecomesAnInstallableModel() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("My-Model.gguf")
        try Data(repeating: 0x41, count: 2048).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let model = ModelCatalog.local(file)
        XCTAssertEqual(model.filename, "My-Model.gguf")
        XCTAssertEqual(model.title, "My-Model", "the extension is not a name")
        XCTAssertEqual(model.bytes, 2048, "size is read from disk, not guessed")
        XCTAssertTrue(model.url.isFileURL)
    }

    /// A size read as zero would make the truncation check reject the file it
    /// was just given.
    func testAMissingLocalFileReportsZeroRatherThanCrashing() {
        let model = ModelCatalog.local(
            URL(fileURLWithPath: "/nonexistent/nothing.gguf"))
        XCTAssertEqual(model.bytes, 0)
    }

    func testEveryEntryIsAGGUFOverHTTPS() {
        for model in ModelCatalog.all {
            XCTAssertTrue(model.filename.hasSuffix(".gguf"), model.filename)
            XCTAssertEqual(model.url.scheme, "https", model.filename)
            XCTAssertTrue(model.url.absoluteString.hasSuffix(model.filename),
                          "\(model.filename) must be what the URL downloads")
        }
    }

    func testFilenamesAreUnique() {
        let names = ModelCatalog.all.map(\.filename)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// The preselected one has to be the cheapest thing that works, or the
    /// window is asking for a commitment before it has earned one.
    func testTheRecommendationIsTheSmallest() {
        let smallest = ModelCatalog.all.min { $0.bytes < $1.bytes }
        XCTAssertEqual(ModelCatalog.recommended, smallest)
    }

    func testListedSmallestFirst() {
        let sizes = ModelCatalog.all.map(\.bytes)
        XCTAssertEqual(sizes, sizes.sorted())
    }

    /// Every offered model must survive the ranking that picks between
    /// installed ones. Shipping a download that rankModels treats as junk
    /// would mean installing it and having nib prefer something else.
    func testNothingOfferedIsRankedAsInadequate() {
        let names = ModelCatalog.all.map(\.filename)
        let ranked = rankModels(names + ["gemma-3-270m-it-Q8_0.gguf"])
        XCTAssertEqual(ranked.last, "gemma-3-270m-it-Q8_0.gguf",
                       "the known-bad model must rank below everything offered")
    }

    // MARK: - Sizes as shown

    func testMegabytesBelowAGigabyte() {
        let model = CatalogModel(filename: "a.gguf", title: "a", detail: "",
                                 bytes: 804_753_632,
                                 url: URL(string: "https://example.com/a.gguf")!)
        XCTAssertEqual(model.sizeLabel, "805 MB")
    }

    func testGigabytesAbove() {
        let model = CatalogModel(filename: "b.gguf", title: "b", detail: "",
                                 bytes: 2_165_039_200,
                                 url: URL(string: "https://example.com/b.gguf")!)
        XCTAssertEqual(model.sizeLabel, "2.2 GB")
    }

    /// Decimal, matching what the Finder reports for the same file. Showing
    /// 767MB for a file macOS calls 805MB reads as the wrong download.
    func testSizesAreDecimalNotBinary() {
        XCTAssertEqual(ModelCatalog.all[0].sizeLabel, "805 MB")
    }

    func testInstallDirectoryIsOutsideTheApp() {
        let path = ModelCatalog.installDirectory.path
        XCTAssertTrue(path.contains("Application Support/nib/models"), path)
        XCTAssertFalse(path.contains(".app/"),
                       "a model inside the bundle is deleted by every update")
    }
}

/// Downloading, checking and installing.
final class ModelInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nib-installer-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A local file stands in for the download. URLSession treats file:// the
    /// same way, which exercises the real delegate path without a network.
    private func localModel(bytes: Int, declared: Int64) throws -> CatalogModel {
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nib-source-\(UUID().uuidString).gguf")
        try Data(repeating: 0x41, count: bytes).write(to: source)
        return CatalogModel(filename: "Test-Model.gguf", title: "Test",
                            detail: "", bytes: declared, url: source)
    }

    private func run(_ installer: ModelInstaller, _ model: CatalogModel,
                     timeout: TimeInterval = 20) -> ModelInstaller.Stage {
        let done = expectation(description: "installer settles")
        var last: ModelInstaller.Stage = .idle
        installer.onChange = { stage in
            last = stage
            switch stage {
            case .done, .failed, .cancelled: done.fulfill()
            default: break
            }
        }
        installer.start(model)
        wait(for: [done], timeout: timeout)
        return last
    }

    func testInstallsIntoTheGivenDirectory() throws {
        let model = try localModel(bytes: 4096, declared: 4096)
        let installer = ModelInstaller(destinationDirectory: directory,
                                       verifies: false)
        let stage = run(installer, model)

        guard case let .done(path) = stage else {
            return XCTFail("expected .done, got \(stage)")
        }
        XCTAssertEqual(path, directory.appendingPathComponent("Test-Model.gguf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    /// The failure that most resembles success: a connection that drops
    /// partway leaves a real file of the right name and the wrong length.
    func testRefusesATruncatedDownload() throws {
        let model = try localModel(bytes: 100, declared: 800_000_000)
        let installer = ModelInstaller(destinationDirectory: directory,
                                       verifies: false)
        let stage = run(installer, model)

        guard case let .failed(message) = stage else {
            return XCTFail("expected .failed, got \(stage)")
        }
        XCTAssertTrue(message.contains("stopped early"), message)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Test-Model.gguf").path),
            "nothing may be left where the model search will find it")
    }

    /// A catalogue size that has drifted slightly must not block an install
    /// that is otherwise complete.
    func testToleratesASizeThatDriftedSlightly() throws {
        let model = try localModel(bytes: 1_000_000, declared: 1_100_000)
        let installer = ModelInstaller(destinationDirectory: directory,
                                       verifies: false)
        guard case .done = run(installer, model) else {
            return XCTFail("a 9% difference is drift, not truncation")
        }
    }

    func testReplacesAnExistingModelOfTheSameName() throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Test-Model.gguf")
        try Data(repeating: 0x00, count: 10).write(to: destination)

        let model = try localModel(bytes: 4096, declared: 4096)
        _ = run(ModelInstaller(destinationDirectory: directory, verifies: false),
                model)

        let installed = try Data(contentsOf: destination)
        XCTAssertEqual(installed.count, 4096, "the old file must be replaced")
    }

    /// Nothing half-written may survive under a name the model search reads.
    func testLeavesNoStagingFileBehind() throws {
        let model = try localModel(bytes: 4096, declared: 4096)
        _ = run(ModelInstaller(destinationDirectory: directory, verifies: false),
                model)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["Test-Model.gguf"], "found leftovers: \(left)")
    }

    func testAMissingSourceFails() throws {
        let model = CatalogModel(
            filename: "Test-Model.gguf", title: "Test", detail: "", bytes: 4096,
            url: URL(fileURLWithPath: "/nonexistent/nothing-here.gguf"))
        guard case .failed = run(ModelInstaller(destinationDirectory: directory,
                                                verifies: false), model) else {
            return XCTFail("a download that cannot start is a failure")
        }
    }

    // MARK: - Before starting

    func testRefusesAModelTooBigForTheDisk() {
        let huge = CatalogModel(
            filename: "huge.gguf", title: "Huge", detail: "",
            bytes: 900_000_000_000,
            url: URL(string: "https://example.com/huge.gguf")!)
        let problem = ModelInstaller.spaceProblem(for: huge)
        XCTAssertNotNil(problem, "900GB cannot fit on this machine")
        XCTAssertTrue(problem?.contains("disk space") == true, problem ?? "")
    }

    func testAllowsAModelThatFits() {
        XCTAssertNil(ModelInstaller.spaceProblem(for: ModelCatalog.recommended),
                     "the recommended model must be installable here")
    }

    // MARK: - State

    func testIdleUntilStarted() {
        let installer = ModelInstaller(destinationDirectory: directory)
        XCTAssertEqual(installer.stage, .idle)
        XCTAssertFalse(installer.isBusy)
    }

    func testCancelBeforeStartingChangesNothing() {
        let installer = ModelInstaller(destinationDirectory: directory)
        installer.cancel()
        XCTAssertEqual(installer.stage, .idle,
                       "cancelling nothing must not read as a cancelled install")
    }

    func testResetAfterAFailureReturnsToIdle() throws {
        let model = try localModel(bytes: 100, declared: 800_000_000)
        let installer = ModelInstaller(destinationDirectory: directory,
                                       verifies: false)
        _ = run(installer, model)
        installer.reset()
        XCTAssertEqual(installer.stage, .idle, "the list has to come back")
    }
}

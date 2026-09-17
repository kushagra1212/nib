import Foundation

/// Downloads a model and proves it works before calling itself done.
///
/// The proof matters. A file of the right size in the right folder is not the
/// same as a working rewrite: the download can be a Hugging Face error page, a
/// captive-portal login, or a GGUF this build of llama.cpp cannot read. All
/// three leave something on disk and all three end with the buttons still doing
/// nothing, which is the failure this whole window exists to remove.
final class ModelInstaller: NSObject {
    enum Stage: Equatable {
        case idle
        case downloading(fraction: Double, received: Int64, total: Int64)
        /// Loading the model and asking it to correct one sentence.
        case verifying
        case done(URL)
        case failed(String)
        case cancelled
    }

    /// Called on the main thread for every change.
    var onChange: ((Stage) -> Void)?

    private(set) var stage: Stage = .idle {
        didSet {
            guard stage != oldValue else { return }
            let stage = stage
            DispatchQueue.main.async { [weak self] in self?.onChange?(stage) }
        }
    }

    /// Where the finished file goes. Injected so a test can install into a
    /// temporary directory instead of the one the running app reads.
    private let destinationDirectory: URL
    /// Whether to load the model and try a rewrite before declaring success.
    /// Off in tests, which have no reason to spend a model load proving that
    /// a file of random bytes is not a GGUF.
    private let verifies: Bool

    init(destinationDirectory: URL = ModelCatalog.installDirectory,
         verifies: Bool = true) {
        self.destinationDirectory = destinationDirectory
        self.verifies = verifies
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var model: CatalogModel?
    /// Set once, so a cancellation cannot be reported as a failure and a
    /// failure cannot be overwritten by the cancellation that follows it.
    private var finished = false

    // MARK: - Starting

    func start(_ model: CatalogModel) {
        guard case .idle = stage else { return }
        self.model = model
        finished = false

        if let problem = ModelInstaller.spaceProblem(for: model) {
            stage = .failed(problem)
            return
        }

        // A background session would survive quitting, but it also survives
        // the user changing their mind, and resuming an 800MB download nobody
        // asked for on next launch is worse than starting it again.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: config, delegate: self,
                                 delegateQueue: nil)
        self.session = session
        stage = .downloading(fraction: 0, received: 0, total: model.bytes)
        task = session.downloadTask(with: model.url)
        task?.resume()
    }

    func cancel() {
        // Only a running install can be cancelled. Closing the window before
        // choosing anything used to leave the installer reporting .cancelled,
        // which the next open rendered as a cancellation of nothing.
        guard isBusy, !finished else { return }
        finished = true
        task?.cancel()
        session?.invalidateAndCancel()
        stage = .cancelled
    }

    /// Back to idle so the window can offer the list again after a failure.
    func reset() {
        guard !isBusy else { return }
        finished = false
        stage = .idle
    }

    var isBusy: Bool {
        switch stage {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: - Checks

    /// Refuses a download that cannot fit, with room to spare.
    ///
    /// The file lands in a temporary directory first and is then moved, so at
    /// the moment of the move both copies can exist. Asking for twice the size
    /// plus a margin is the honest requirement.
    static func spaceProblem(for model: CatalogModel) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }   // Unknown capacity is not evidence of a problem.

        let needed = model.bytes * 2 + 500_000_000
        guard free < needed else { return nil }
        let gb = { (bytes: Int64) in
            String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        return "Not enough disk space. \(model.title) needs about "
            + "\(gb(needed)) free while installing, and there is \(gb(free))."
    }

    // MARK: - Finishing

    private func install(from temporary: URL) {
        guard let model else { return }
        let fm = FileManager.default
        let destination = destinationDirectory
            .appendingPathComponent(model.filename)

        do {
            try fm.createDirectory(at: destinationDirectory,
                                   withIntermediateDirectories: true)

            // A truncated download is the common failure and the one that
            // looks most like success, so check before anything is moved into
            // place. Tolerant of small differences: the catalogue's size can
            // age, and being wrong about the last megabyte should not block an
            // install that is otherwise fine.
            let size = (try fm.attributesOfItem(atPath: temporary.path)[.size]
                as? NSNumber)?.int64Value ?? 0
            guard size > model.bytes / 2 else {
                fail("The download stopped early -- \(size / 1_000_000)MB of "
                     + "\(model.bytes / 1_000_000)MB. Check the connection and "
                     + "try again.")
                return
            }

            // Into place in one step. A half-written file under the real name
            // would be found by the model search on the next launch and loaded
            // as though it were whole.
            let staged = destinationDirectory
                .appendingPathComponent(".\(model.filename).incoming")
            try? fm.removeItem(at: staged)
            try fm.moveItem(at: temporary, to: staged)
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } catch {
            fail("Could not save the model: \(error.localizedDescription)")
            return
        }

        guard verifies else {
            succeed(destination)
            return
        }
        stage = .verifying
        verify(at: destination)
    }

    /// Runs one real rewrite through the model that was just installed.
    private func verify(at path: URL) {
        guard let server = locateLlamaServer() else {
            // Downloaded fine, but there is nothing to run it with. Leave the
            // file: it is valid, and the missing piece is the app bundle.
            fail("The model downloaded, but llama-server is missing from the "
                 + "app. Reinstall nib.")
            return
        }

        Task { [weak self] in
            let engine = RewriteEngine(
                config: .init(serverBinary: server, modelPath: path))
            defer { Task { await engine.shutdown() } }

            do {
                let answer = try await engine.rewrite("she dont like it",
                                                      mode: .fixGrammar)
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    self?.fail("The model loaded but returned nothing. It may "
                               + "not be a model this build can use.")
                    return
                }
                self?.succeed(path)
            } catch {
                self?.fail("The model downloaded but would not load: "
                           + "\(error.localizedDescription)")
            }
        }
    }

    private func succeed(_ path: URL) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        stage = .done(path)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        stage = .failed(message)
    }
}

extension ModelInstaller: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // The server's figure when it gives one, the catalogue's when it does
        // not: a chunked response reports -1 here and would show as a bar that
        // never moves.
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (model?.bytes ?? 0)
        let fraction = total > 0
            ? min(1, Double(totalBytesWritten) / Double(total)) : 0
        stage = .downloading(fraction: fraction,
                             received: totalBytesWritten, total: total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // An HTTP error still arrives here, with the error page as the body.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            fail("The download server answered \(response.statusCode). "
                 + "The model may have moved.")
            return
        }
        // This file is deleted the moment this method returns, so it has to be
        // moved now, on this thread, rather than handed to anything async.
        let held = location.deletingLastPathComponent()
            .appendingPathComponent("nib-model-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: held)
        } catch {
            fail("Could not read the download: \(error.localizedDescription)")
            return
        }
        install(from: held)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail(error.localizedDescription)
    }
}

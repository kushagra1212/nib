import Foundation

/// Appends state transitions to ~/Library/Logs/nib.log.
///
/// Screenshots cannot tell "the badge is broken" apart from "the badge is
/// correctly hidden because focus moved" -- right-clicking a word opens a menu,
/// which takes focus, which clears everything. Both look like an empty screen.
/// Reproducing once against a log settles it.
///
/// No field text is written, only lengths and counts. This file records what
/// someone typed into a password manager or a private channel otherwise.
enum Log {
    /// Off unless NIB_LOG is set, so a shipped app writes nothing by default.
    static let isEnabled = ProcessInfo.processInfo.environment["NIB_LOG"] != nil

    static let url: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/nib.log")

    private static let queue = DispatchQueue(label: "nib.log")
    private static let started = Date()

    static func write(_ message: String) {
        guard isEnabled else { return }
        let stamp = String(format: "%8.3f", Date().timeIntervalSince(started))
        let line = "\(stamp)  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Keep the file from growing without bound across long sessions.
                if (try? handle.seekToEnd()) ?? 0 > 4_000_000 {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Empties the log so a fresh reproduction is not read against old lines.
    static func reset() {
        guard isEnabled else { return }
        queue.async { try? Data().write(to: url) }
    }
}

import Foundation

/// The last hundred things you dictated, so a lost one can be got back.
///
/// Dictation types into whatever has focus, and that is the whole design --
/// but it means a transcript that lands in the wrong window, or in a field that
/// was cleared a moment later, is simply gone. There is nothing to scroll back
/// to and no way to ask what was said.
///
/// Kept rather than copied to the clipboard automatically. Overwriting the
/// clipboard on every dictation would lose whatever was on it, which is the
/// same failure in the other direction; this keeps them and copies one when
/// asked.
///
/// Written to disk, which is a privacy decision worth naming. `Log` refuses to
/// record field text because it would capture whatever someone typed into a
/// password manager. This is different in kind -- it is what you deliberately
/// spoke to nib -- but it is still your words on disk, in plain JSON, readable
/// by anything running as you. It can be cleared from the menu, and it never
/// leaves the machine.
struct DictationHistory {
    struct Entry: Codable, Equatable {
        let text: String
        let date: Date

        /// One line for a menu, with the ends kept.
        ///
        /// The middle is what goes, not the tail: the end of a sentence is
        /// usually how you tell two dictations apart, and a list of entries
        /// all truncated at the same prefix is unreadable.
        func label(width: Int = 60) -> String {
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard flat.count > width else { return flat }
            let head = flat.prefix(width - 22)
            let tail = flat.suffix(18)
            return "\(head)… \(tail)"
        }
    }

    /// How many are kept. A hundred, as asked for.
    static let limit = 100

    private(set) var entries: [Entry] = []

    /// Newest first, which is the order a menu wants and the order someone
    /// looking for "the one I just lost" is thinking in.
    mutating func add(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The same sentence dictated twice in a row is one entry. Repeating a
        // failed dictation is the commonest reason to say the same thing
        // again, and two identical rows help nobody find anything.
        if entries.first?.text == trimmed {
            entries[0] = Entry(text: trimmed, date: date)
            return
        }
        entries.insert(Entry(text: trimmed, date: date), at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    mutating func clear() { entries = [] }

    // MARK: - On disk

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nib/dictation.json")
    }

    static func load(from url: URL = fileURL) -> DictationHistory {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return DictationHistory() }

        var history = DictationHistory()
        // Trimmed on read as well as on write: a file from a build with a
        // larger limit should not grow this one's menu without bound.
        history.entries = Array(entries.prefix(limit))
        return history
    }

    /// Saved with the file readable only by its owner.
    ///
    /// It is a record of things said at a desk, and the default for a new file
    /// in Application Support is world-readable.
    func save(to url: URL = fileURL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}

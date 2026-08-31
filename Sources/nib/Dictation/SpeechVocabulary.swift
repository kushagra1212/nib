import Foundation

/// Words nib tells whisper to expect.
///
/// The largest single improvement to dictation accuracy, and it costs nothing.
/// Measured on Indian-accented speech, small model:
///
///     "The useMemo hook is causing a re-render"
///       without  ->  "The Usamimohuk is causing a re-render"
///       with     ->  "The useMemo hook is causing a re-render"
///
///     "The Hasura metadata needs to be refreshed"
///       without  ->  "The Azure metadata needs to be refreshed"
///       with     ->  "The Hasura metadata needs to be refreshed"
///
/// Ordinary sentences were already transcribed correctly by both models. What
/// failed was vocabulary: names the model has never seen, which it replaces
/// with whatever real word sounds closest. No amount of accent training fixes
/// that, because "Hasura" is not a word in any accent.
///
/// Whisper takes an initial prompt and biases decoding towards its contents.
/// It is a nudge rather than a dictionary -- a term in the list is more likely,
/// not guaranteed -- and a long list dilutes it, so this stays short.
enum SpeechVocabulary {
    /// Where the editable list lives, one term per line.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nib/vocabulary.txt")
    }

    /// What ships, for someone who never opens the file.
    ///
    /// Deliberately generic. A list tuned to one person's projects would be
    /// worse than nothing for everyone else, and the whole point is that it is
    /// editable.
    static let defaults = [
        "GitHub", "TypeScript", "JavaScript", "Swift", "Xcode", "macOS",
        "npm", "API", "JSON", "SQL", "GraphQL", "CSS", "HTML",
        "React", "Node", "Docker", "Kubernetes", "Postgres", "Redis",
        // Camel-case names are the worst case for a speech model: it has no
        // reason to join two ordinary words into one, so "useMemo" arrives as
        // "Usamimohuk" until it is told the word exists.
        "useMemo", "useState", "useEffect", "useCallback",
        "backend", "frontend", "staging", "refactor", "async", "await",
        "repo", "commit", "merge", "rebase", "pull request", "changelog",
    ]

    /// The terms in use: the file if there is one, the defaults if not.
    static func terms() -> [String] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return defaults }

        let lines = contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // "#" starts a comment, so the file can explain itself.
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? defaults : lines
    }

    /// The prompt handed to whisper.
    ///
    /// Written as a sentence rather than a bare list. The prompt is treated as
    /// preceding transcript, so prose primes it better than comma-separated
    /// tokens -- and a trailing full stop stops the first spoken word being
    /// glued onto the last term.
    static func prompt(_ terms: [String] = terms()) -> String? {
        let usable = capped(terms)
        guard !usable.isEmpty else { return nil }
        return "Terms used: " + usable.joined(separator: ", ") + "."
    }

    /// Whisper's prompt window is 224 tokens and everything past it is
    /// discarded, taking the bias with it. Roughly a word and a half per term,
    /// so this stays well inside it -- and a shorter list biases harder anyway.
    static let limit = 64

    static func capped(_ terms: [String]) -> [String] {
        Array(terms.prefix(limit))
    }

    /// Creates the file with the defaults in it, for editing.
    @discardableResult
    static func createFileIfNeeded() -> URL {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }

        let header = """
        # Words nib should expect when you dictate.
        #
        # One per line. Names, jargon and project words belong here: whisper
        # replaces anything it has never seen with the nearest real word, so
        # "Hasura" becomes "Azure" until it is listed below.
        #
        # Keep it short. This is a nudge, not a dictionary, and a long list
        # dilutes it. Lines starting with # are ignored.

        """
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (header + defaults.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

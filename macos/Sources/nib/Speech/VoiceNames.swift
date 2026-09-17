import Foundation

/// Turns `af_heart` into `Heart — American, female`.
///
/// The pack names voices by a two-letter prefix and a given name. The prefix is
/// the useful part and the least readable: `bm_george` is a British man, and
/// nothing in the string says so.
///
/// A menu of 54 raw identifiers is a menu nobody reads to the end of.
enum VoiceNames {
    /// The prefixes kokoro uses. First letter is the accent, second the voice.
    private static let accents: [Character: String] = [
        "a": "American", "b": "British", "e": "Spanish", "f": "French",
        "h": "Hindi", "i": "Italian", "j": "Japanese", "p": "Portuguese",
        "z": "Chinese",
    ]

    static func title(for identifier: String) -> String {
        let parts = identifier.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2 else {
            return identifier
        }

        let prefix = Array(parts[0])
        let given = parts[1].capitalized
        guard let accent = accents[prefix[0]] else { return given }

        let gender = prefix[1] == "f" ? "female" : "male"
        return "\(given) — \(accent), \(gender)"
    }

    /// Which group a voice belongs to, for splitting the menu up.
    static func accent(of identifier: String) -> String {
        guard let first = identifier.first, let accent = accents[first] else {
            return "Other"
        }
        return accent
    }
}

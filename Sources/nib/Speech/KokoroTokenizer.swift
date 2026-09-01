import Foundation

/// Turns phonemes into the numbers Kokoro is fed.
///
/// The step between espeak and the model. espeak produces a string of sound
/// symbols -- "ðə kwˈɪk bɹˈaʊn" -- and the model takes a list of integers, one
/// per symbol, looked up in the table it was trained with.
///
/// This is the part of the port most likely to be quietly wrong. A mistyped id
/// does not crash: the model speaks whatever sound that number means, fluently,
/// and the result is English that is subtly not what was written. So the table
/// is generated from the engine's own config rather than copied, and this rule
/// is checked against a transcript captured from the Python engine.
enum KokoroTokenizer {
    enum Failure: Error, CustomStringConvertible {
        case tooLong(Int)

        var description: String {
            switch self {
            case .tooLong(let count):
                return "\(count) phonemes is more than the model's limit of "
                    + "\(KokoroVocab.maxPhonemes)"
            }
        }
    }

    /// Maps each symbol through the table, dropping any it does not know.
    ///
    /// Dropping rather than substituting or failing, which is what the Python
    /// does: `[i for i in map(self.vocab.get, phonemes) if i is not None]`.
    /// An unknown symbol contributes nothing rather than a wrong sound.
    ///
    /// Per Character, not per byte or per scalar. Several phonemes here are
    /// multi-byte -- ð, ɹ, ˈ -- and splitting them any other way produces ids
    /// for pieces of a symbol rather than the symbol.
    static func tokenize(_ phonemes: String) throws -> [Int] {
        // Counted in Characters, matching Python's len() over a str, which
        // counts scalars. These agree for this vocabulary: it holds no
        // combining marks or emoji, where the two would diverge.
        guard phonemes.count <= KokoroVocab.maxPhonemes else {
            throw Failure.tooLong(phonemes.count)
        }
        return phonemes.compactMap { KokoroVocab.table[String($0)] }
    }

    /// The symbols the table does not know, for diagnosing a bad transcript.
    static func unknown(in phonemes: String) -> [String] {
        var seen = Set<String>()
        return phonemes.compactMap { character in
            let symbol = String(character)
            guard KokoroVocab.table[symbol] == nil, seen.insert(symbol).inserted
            else { return nil }
            return symbol
        }
    }
}

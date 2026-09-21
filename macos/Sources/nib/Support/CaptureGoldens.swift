import Foundation

/// Records what the Swift implementation does, so the C++ port can be held to
/// it exactly.
///
/// Run before a module moves; the output is committed and then treated as
/// read-only. It is a recording, not a specification -- where the two disagree
/// the recording wins, because the recording is what nib ships today.
///
/// The inputs are chosen to cover what the hand-written tests do not. 47 of the
/// test files assert against someone's idea of correct; these assert against
/// the observed answer, which is the only thing a port can safely preserve.
enum CaptureGoldens {
    /// Text whose handling is easy to change by accident.
    ///
    /// Surrogate pairs, combining marks and Indic viramas are here because the
    /// tokenizer inspects one UTF-16 unit at a time, which treats them
    /// differently from how a reader would. Abbreviations, decimals and dotted
    /// identifiers are here because sentence splitting on "." alone breaks all
    /// three, and the text nib checks is often technical.
    static let inputs: [String] = [
        "",
        "    \n  ",
        "The quick brown fox jumps over the dog.",
        "The quick brown fox jumps over it. Another long sentence follows here.",
        "The quick brown fox jumps here.    Second long sentence goes here.",
        "Thanks!",
        "Yes. No. Maybe.",
        "One two three.",
        "We tested e.g. the login flow and it worked well.",
        "The build takes 3.5 minutes on this machine now.",
        "We should check NSString.length before we index into it.",
        "this is a sentence without a full stop",
        "😀 The quick brown fox jumps over it.",
        "The first sentence lives here.\nThe second one lives here.",
        "don't split contractions or hyphen-joined words or snake_case names",
        "देवनागरी में लिखा गया एक वाक्य यहाँ है।",
        "café naïve résumé coöperate",
        "Dr. Smith arrived at 3.5 p.m. and left again.",
        "a\u{0301}ccent combining marks stay attached",
        "emoji 👨‍👩‍👧‍👦 family sequence splits on surrogates",
    ]

    private struct TokenRecord: Encodable {
        let text: String
        let location: Int
        let length: Int
    }

    private struct TokenCase: Encodable {
        let input: String
        let tokens: [TokenRecord]
    }

    private struct SentenceRecord: Encodable {
        let text: String
        let location: Int
        let length: Int
    }

    private struct SentenceCase: Encodable {
        let input: String
        let minimumWords: Int
        let sentences: [SentenceRecord]
    }

    /// Cases plus the locale they were produced under.
    ///
    /// Not decoration. `enumerateSubstrings(.localized)` asks ICU to segment
    /// using the user's locale, so the same input splits differently for
    /// different people. A recording that does not say which locale produced it
    /// cannot be reproduced -- the port would be checked against an answer
    /// whose question is missing.
    private struct GoldenFile<Case: Encodable>: Encodable {
        let locale: String
        let cases: [Case]
    }

    static func run() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let tokenCases = inputs.map { input in
            TokenCase(input: input, tokens: WordDiff.tokenize(input).map {
                TokenRecord(text: $0.text,
                            location: $0.range.location,
                            length: $0.range.length)
            })
        }

        // Both thresholds, because the default is a parameter and a port that
        // hardcodes five would pass every test that uses the default.
        var sentenceCases: [SentenceCase] = []
        for input in inputs {
            for minimum in [3, 5] {
                let found = SentenceSplitter.sentences(in: input, minimumWords: minimum)
                sentenceCases.append(SentenceCase(
                    input: input,
                    minimumWords: minimum,
                    sentences: found.map {
                        SentenceRecord(text: $0.text,
                                       location: $0.range.location,
                                       length: $0.range.length)
                    }))
            }
        }

        // Written relative to the working directory, so this runs from the
        // repository root and nowhere else.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = root.appendingPathComponent("goldens")

        let locale = Locale.current.identifier

        do {
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            try encoder.encode(GoldenFile(locale: locale, cases: tokenCases))
                .write(to: folder.appendingPathComponent("word-tokenize.json"))
            try encoder.encode(GoldenFile(locale: locale, cases: sentenceCases))
                .write(to: folder.appendingPathComponent("sentence-split.json"))
        } catch {
            FileHandle.standardError.write(Data(
                "could not write goldens: \(error)\n".utf8))
            exit(1)
        }

        // The locale is recorded because sentence splitting asks for it.
        // enumerateSubstrings(.localized) reads the user's locale, so a capture
        // made under one and a port built against another disagree for reasons
        // that have nothing to do with the port.
        FileHandle.standardError.write(Data("""
            captured \(tokenCases.count) tokenize cases, \
            \(sentenceCases.count) sentence cases
            locale: \(Locale.current.identifier)

            """.utf8))
    }
}

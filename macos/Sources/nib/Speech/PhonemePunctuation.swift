import Foundation

/// Hides punctuation from espeak, and puts it back afterwards.
///
/// espeak drops punctuation silently. Kokoro's vocabulary does not: ".", ",",
/// "!" and "?" are tokens in their own right, and the full stop at the end of
/// a sentence is what makes it sound finished rather than cut off. So the marks
/// are taken out before espeak sees the text and restored into the phonemes it
/// returns.
///
/// It cannot be done the other way round -- phonemise once, then patch the
/// marks in -- because removing them changes what espeak says. Handed
/// "Parentheses (like this)" espeak returns `ð_ɪ_s`; handed "like this" alone
/// it returns `ð_ˈɪ_s`, with a stress. Splitting first is what produces the
/// second, which is what the model was trained on.
///
/// Ported from `phonemizer/punctuation.py`, quirks included, and checked
/// against it over `Tests/Fixtures/phonemes-golden.json`.
enum PhonemePunctuation {
    /// phonemizer's default marks, verbatim.
    static let defaultMarks: Set<Character> = Set(";:,.!?¡¿—…\"«»“”(){}[]")

    /// Marks that double as a decimal separator. Between two digits these are
    /// part of a number rather than punctuation, and splitting there makes
    /// espeak read two numbers instead of one.
    private static let decimalSeparators: Set<Character> = [",", "."]

    /// Where a run of marks sits, which decides how it is put back.
    enum Position: String {
        /// At the start of the line, so it goes in front of the first chunk.
        case begin = "B"
        /// At the end, so it closes the line.
        case end = "E"
        /// Between two chunks, which it joins.
        case inside = "I"
        /// The line is nothing but marks, so there are no phonemes to attach to.
        case alone = "A"
    }

    struct Mark: Equatable {
        /// Which line of the text it came from. Text is phonemised a line at a
        /// time, so a mark on line 2 must not be placed at the end of line 1.
        let line: Int
        /// The run as it appeared, including any spaces around it.
        let text: String
        let position: Position
    }

    /// Splits text into the parts espeak should see, and the marks to restore.
    ///
    ///     "hello, my world!" -> ["hello", "my world"], [",", "!"]
    ///
    /// Newlines are a boundary before punctuation is even considered, matching
    /// phonemizer's `str2list`. They survive into the output, which is what
    /// keeps two lines from being spoken as one sentence.
    static func preserve(_ text: String,
                         marks markSet: Set<Character> = defaultMarks)
        -> (chunks: [String], marks: [Mark]) {
        var chunks: [String] = []
        var marks: [Mark] = []
        for (number, line) in lines(of: text).enumerated() {
            let (lineChunks, lineMarks) = preserve(line: line, number: number,
                                                   marks: markSet)
            chunks += lineChunks
            marks += lineMarks
        }
        // Empty chunks are dropped, so a line starting with a mark -- or an
        // empty line -- does not hand espeak an empty string.
        return (chunks.filter { !$0.isEmpty }, marks)
    }

    /// The lines that will be phonemised, in the order they are numbered.
    ///
    /// Newlines off both ends, split on newline, then blank lines dropped --
    /// `phonemize.py` does the last of these before the backend ever runs, and
    /// the lines that survive are renumbered from zero. Keeping a blank line
    /// would shift every mark after it onto the wrong line.
    ///
    /// A whitespace-only input therefore has no lines at all, and produces no
    /// speech rather than a space.
    static func lines(of text: String) -> [String] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func preserve(line: String, number: Int,
                                 marks markSet: Set<Character>)
        -> (chunks: [String], marks: [Mark]) {
        let characters = Array(line)
        let runs = markRuns(in: characters, marks: markSet)
        guard !runs.isEmpty else { return ([line], []) }

        let texts = runs.map { String(characters[$0]) }

        // Nothing but marks. There is no text to attach them to, so they are
        // carried whole and returned as-is; "..." should still say "...".
        if texts.count == 1, texts[0] == line {
            return ([], [Mark(line: number, text: line, position: .alone)])
        }

        var marks: [Mark] = []
        for (index, text) in texts.enumerated() {
            var position = Position.inside
            if index == 0, line.hasPrefix(text) {
                position = .begin
            } else if index == texts.count - 1, line.hasSuffix(text) {
                position = .end
            }
            marks.append(Mark(line: number, text: text, position: position))
        }

        // Cut where the marks actually are.
        //
        // phonemizer cuts by searching the line for each mark's text, which
        // finds the first character that looks like it rather than the run it
        // measured. That was ported faithfully and is wrong in a way people
        // hear: "The file is 5.8 GB." has one mark, the closing full stop, but
        // the search lands on the dot inside 5.8 and cuts the number in half.
        // espeak is then handed "The file is 5" and "8 GB." and says "five"
        // then "eight" -- the decimal is gone and a sentence break is in its
        // place. Measured:
        //
        //   "5.8 GB"              fˈaɪv pɔɪnt ˈeɪt      five point eight
        //   "The file is 5.8 GB." fˈaɪv. ˈeɪt           five. eight
        //
        // The positions are already known from markRuns, so this uses them.
        // It is a deliberate divergence from the reference implementation, and
        // the corpus records which entries it changes.
        var chunks: [String] = []
        var cursor = 0
        for run in runs {
            chunks.append(String(characters[cursor..<run.lowerBound]))
            cursor = run.upperBound
        }
        chunks.append(String(characters[cursor...]))
        return (chunks, marks)
    }

    /// Puts the marks back into phonemised chunks.
    ///
    ///     ["hello", "my world"], [",", "!"] -> ["hello, my world!"]
    ///
    /// `separator` is the string between words, a single space here. `strip`
    /// says whether the line may end with one; kokoro leaves it on and trims
    /// later, so this is called with false.
    static func restore(_ phonemized: [String], marks allMarks: [Mark],
                        separator: String, strip: Bool) -> [String] {
        var text = phonemized
        var marks = allMarks
        var restored: [String] = []

        // Which line is being rebuilt. A mark is only placed while its own line
        // is the one in hand; once that line is finished the next mark waits,
        // which is what stops a full stop from line 2 landing on line 1.
        var line = 0

        while !text.isEmpty || !marks.isEmpty {
            if marks.isEmpty {
                for line in text {
                    let needsSeparator = !strip && !separator.isEmpty
                        && !line.hasSuffix(separator)
                    restored.append(needsSeparator ? line + separator : line)
                }
                text = []
                continue
            }

            if text.isEmpty {
                // Nothing was phonemised: the line was marks alone.
                restored.append(marks.map(\.text).joined()
                    .replacingOccurrences(of: " ", with: separator))
                marks = []
                continue
            }

            guard marks[0].line == line else {
                restored.append(text.removeFirst())
                line += 1
                continue
            }

            let current = marks.removeFirst()
            let mark = current.text.replacingOccurrences(of: " ", with: separator)

            // The chunk carries a trailing word separator from phonemisation.
            // It comes off before the mark goes on, or every mark would be
            // preceded by a space: "hello ." rather than "hello.".
            if !separator.isEmpty, text[0].hasSuffix(separator) {
                text[0].removeLast(separator.count)
            }

            let trailing = (strip || mark.hasSuffix(separator)) ? "" : separator
            switch current.position {
            case .begin:
                text[0] = mark + text[0]
            case .end:
                restored.append(text[0] + mark + trailing)
                text.removeFirst()
                line += 1
            case .alone:
                restored.append(mark + trailing)
                line += 1
            case .inside:
                if text.count == 1 {
                    // The text after this mark was never phonemised, which
                    // happens when a line ends on a mark that is not the last.
                    text[0] += mark
                } else {
                    let first = text.removeFirst()
                    text[0] = first + mark + text[0]
                }
            }
        }

        return restored
    }

    // MARK: - Finding the marks

    /// Maximal runs of marks and whitespace that contain at least one mark.
    ///
    /// This is phonemizer's `(\s*(?:marks)+\s*)+` written out. A run absorbs
    /// the whitespace on both sides, so "a, b" yields ", " rather than ",",
    /// and that space is what reappears between the phonemised chunks.
    private static func markRuns(in characters: [Character],
                                 marks: Set<Character>) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var index = 0

        while index < characters.count {
            guard isMark(characters, index, marks) || characters[index].isWhitespace
            else { index += 1; continue }

            var end = index
            var holdsMark = false
            while end < characters.count,
                  isMark(characters, end, marks) || characters[end].isWhitespace {
                if isMark(characters, end, marks) { holdsMark = true }
                end += 1
            }
            // Whitespace on its own is not punctuation, so a run without a mark
            // is left where it is rather than splitting the line there.
            if holdsMark { runs.append(index..<end) }
            index = end
        }
        return runs
    }

    private static func isMark(_ characters: [Character], _ index: Int,
                               _ marks: Set<Character>) -> Bool {
        let character = characters[index]
        guard marks.contains(character) else { return false }
        guard decimalSeparators.contains(character) else { return true }

        // Between two digits it is part of a number. "19,99" must reach espeak
        // whole; split, it is read as two numbers rather than one.
        let before = index > 0 && isDigit(characters[index - 1])
        let after = index + 1 < characters.count && isDigit(characters[index + 1])
        return !(before && after)
    }

    /// ASCII only, matching the `[0-9]` phonemizer uses. `Character.isNumber`
    /// would also accept ٣ and ३, which espeak does not read as digits here.
    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}

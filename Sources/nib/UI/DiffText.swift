import AppKit

/// Renders what a rewrite actually changed, word by word.
///
/// The bar shows the proposed text on its own, which answers "what would I be
/// left with" but not "what is it doing to my sentence". Those are different
/// questions, and on a long selection the second one is impossible to answer
/// by reading two paragraphs side by side and spotting the differences.
///
/// Removed words are struck through, added words are underlined. Colour marks
/// them too, but colour alone would leave the change invisible to a reader who
/// cannot separate red from green.
enum DiffText {
    static func attributed(
        from original: String, to rewritten: String,
        fontSize: CGFloat = 13
    ) -> NSAttributedString {
        let before = WordDiff.tokenize(original).map(\.text)
        let after = WordDiff.tokenize(rewritten).map(\.text)
        // Case-sensitive, unlike the matching elsewhere. "chatgpt" to
        // "ChatGPT" is a correction nib now offers, and folding case here
        // would render that as no change at all -- a diff claiming nothing
        // happened while the button underneath it changes the text.
        let kept = WordDiff.longestCommonSubsequence(before, after)

        let out = NSMutableAttributedString()
        var i = 0, j = 0, k = 0

        func append(_ word: String, _ style: Style) {
            if out.length > 0 { out.append(NSAttributedString(string: " ")) }
            out.append(NSAttributedString(string: word, attributes: style.attributes(fontSize)))
        }

        while i < before.count || j < after.count {
            let common = k < kept.count ? kept[k] : nil

            // Anything before the next surviving word was taken out.
            if i < before.count, before[i] != common {
                append(before[i], .removed)
                i += 1
                continue
            }
            // Anything before it on the other side was put in.
            if j < after.count, after[j] != common {
                append(after[j], .added)
                j += 1
                continue
            }
            guard i < before.count, j < after.count else { break }
            append(after[j], .kept)
            i += 1
            j += 1
            k += 1
        }
        return out
    }

    private enum Style {
        case kept, removed, added

        func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            switch self {
            case .kept:
                return [.foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: size)]
            case .removed:
                return [.foregroundColor: Theme.Colour.removed,
                        .font: NSFont.systemFont(ofSize: size),
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: Theme.Colour.removed]
            case .added:
                return [.foregroundColor: Theme.Colour.added,
                        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: Theme.Colour.added.withAlphaComponent(0.6)]
            }
        }
    }
}

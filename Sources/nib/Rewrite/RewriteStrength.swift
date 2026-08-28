import Foundation

/// How far a rewrite is allowed to travel from what was written.
///
/// Three stops rather than a continuous slider. The dial lives on a bar that
/// floats over someone's text and has to stay small, where a continuous
/// control is unreadable and unlandable; and each stop moves a threshold that
/// can be stated and tested, which "0.63 of the way along" cannot.
///
/// The setting is remembered, because it is a statement about how you write
/// rather than about the sentence in front of you.
enum RewriteStrength: String, CaseIterable {
    /// Spelling, agreement, punctuation. Leaves the wording alone.
    case light
    /// The default: tidies phrasing, keeps the shape of the sentence.
    case balanced
    /// May reorder clauses and merge or split sentences.
    case bold

    static let defaultsKey = "nib.rewriteStrength"

    static var current: RewriteStrength {
        get {
            // The command line tools do not share the app's defaults domain,
            // so comparing two settings from a terminal silently compared the
            // same one twice. NIB_STRENGTH makes the dial testable.
            if let override = ProcessInfo.processInfo.environment["NIB_STRENGTH"],
               let parsed = RewriteStrength(rawValue: override) {
                return parsed
            }
            return UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(RewriteStrength.init) ?? .balanced
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .bold: return "Bold"
        }
    }

    /// Added to the mode's instruction.
    ///
    /// The mode says what to do; this says how far. Kept to one sentence so
    /// the system prompt stays short enough for a small model to hold onto.
    var clause: String {
        switch self {
        case .light:
            return " Change as little as possible: fix only what is wrong."
        case .balanced:
            return " Improve the phrasing where it helps, but keep the "
                + "sentence structure recognisable."
        case .bold:
            return " Rewrite as much as needed for it to read well."
        }
    }

    /// How many consecutive words a rewrite may drop before it is refused.
    ///
    /// The guard cannot tell "reordered" from "deleted the end of the
    /// sentence", so this is the dial's real teeth: at Light almost nothing
    /// may go missing, at Bold the check is off and the reader is trusted to
    /// look at what they are accepting.
    var maxDroppedRun: Int? {
        switch self {
        case .light: return 2
        case .balanced: return 3
        case .bold: return nil
        }
    }
}

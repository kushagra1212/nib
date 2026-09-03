import Foundation

/// What came back from asking for a rewrite.
///
/// Three answers, not one string, because two of them used to be
/// indistinguishable and the bar drew the wrong conclusion from it.
///
/// `ModelChecker` refuses a rewrite that truncates the ending, answers a
/// question instead of rewriting it, or silently drops a clause. It refused by
/// returning the original text -- which the selection bar could not tell apart
/// from "the model had nothing to change", so it reported "looks good" in
/// green over a sentence that had just had a rewrite rejected for changing the
/// meaning.
///
/// Green on unchecked writing is the failure this codebase has now made twice.
enum RewriteOutcome: Equatable {
    /// The model produced something different, and it survived the checks.
    case rewritten(String)
    /// The model returned what it was given. The writing needs nothing, at
    /// least in this mode.
    case unchanged
    /// A check rejected the result, with a reason worth showing.
    case refused(String)

    /// The text to use, or nil when there is nothing to apply.
    var text: String? {
        if case .rewritten(let text) = self { return text }
        return nil
    }
}

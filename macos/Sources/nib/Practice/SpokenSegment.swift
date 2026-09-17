import Foundation

/// One stretch of speech whisper decoded, with where it sat in the recording.
///
/// Deliberately not a `DictationHistory.Entry`: that keeps what you meant to
/// type, this keeps when you said it. The timings are the whole point -- what
/// separates a fluent answer from a hesitant one is almost never the words.
struct SpokenSegment: Equatable {
    let text: String
    /// Seconds from the start of the recording.
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

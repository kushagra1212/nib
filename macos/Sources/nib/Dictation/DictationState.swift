import Foundation

/// Where a dictation is up to.
///
/// Split from the controller so the sequencing can be tested without a
/// microphone, a model, or permission to use either. Every rule about what may
/// follow what lives here; the controller performs the work and asks this what
/// is allowed.
enum DictationState: Equatable {
    case idle
    /// Waiting on the microphone permission prompt.
    case requestingAccess
    case recording
    case transcribing
    /// Holding finished text while it is written into the focused field.
    case inserting(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed: return false
        case .requestingAccess, .recording, .transcribing, .inserting: return true
        }
    }

    /// Whether the microphone is live. The indicator is driven from this and
    /// nothing else, so it cannot disagree with reality.
    var isListening: Bool { self == .recording }
}

/// What can happen to a dictation.
enum DictationEvent: Equatable {
    /// The hotkey, which means "start" or "stop" depending on where we are.
    case toggled
    case accessGranted
    case accessDenied
    case reachedLimit
    case transcribed(String)
    case inserted
    case failed(String)
    case cancelled
}

extension DictationState {
    /// The next state, or nil if the event does not apply here.
    ///
    /// Returning nil rather than staying put matters: a hotkey pressed while
    /// transcribing must not start a second recording, and the caller needs to
    /// know the difference between "handled" and "ignored" to avoid acting on
    /// a transition that never happened.
    func next(for event: DictationEvent) -> DictationState? {
        switch (self, event) {
        // Starting.
        case (.idle, .toggled):        return .requestingAccess
        case (.failed, .toggled):      return .requestingAccess
        case (.requestingAccess, .accessGranted): return .recording
        case (.requestingAccess, .accessDenied):
            return .failed("nib is not allowed to use the microphone")

        // Stopping. Both the hotkey and the length cap end a recording the
        // same way -- by transcribing what was said, never by discarding it.
        case (.recording, .toggled):      return .transcribing
        case (.recording, .reachedLimit): return .transcribing

        // Finishing.
        case (.transcribing, .transcribed(let text)):
            // Whisper returns an empty string for silence. Inserting that
            // would put an empty edit into the user's field and, worse, make
            // an accidental toggle look like a failure.
            return text.isEmpty ? .idle : .inserting(text)
        case (.inserting, .inserted): return .idle

        // Giving up. Allowed from anywhere that is doing something.
        case (_, .cancelled) where isBusy:  return .idle
        case (_, .failed(let why)) where isBusy: return .failed(why)

        default: return nil
        }
    }
}

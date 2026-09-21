import Foundation

/// Where speaking a selection is up to.
///
/// Split from the controller for the same reason `DictationState` is: the
/// sequencing can then be tested without a model, an audio device, or 326MB on
/// disk. Every rule about what may follow what lives here.
enum SpeechState: Equatable {
    case idle
    /// Loading the model. The first press of a session pays about a third of a
    /// second for this; later ones do not.
    case preparing
    /// Turning text into samples. The long part, and the one worth showing.
    case synthesising
    case speaking
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed: return false
        case .preparing, .synthesising, .speaking: return true
        }
    }

    /// What the menu bar says.
    var label: String {
        switch self {
        case .idle: return "Speak Selection"
        case .preparing: return "Loading the voice…"
        case .synthesising: return "Preparing speech…"
        case .speaking: return "Stop Speaking"
        case .failed: return "Speak Selection"
        }
    }
}

/// What can happen to it.
enum SpeechEvent: Equatable {
    /// `⌃⌘N`, which starts or stops depending on where we are.
    case toggled
    /// `⌃⇧H`, which only ever stops.
    case hushed
    case loaded
    case synthesised
    case finished
    case failed(String)
}

extension SpeechState {
    /// The next state, or nil where the event does not apply here.
    ///
    /// Returning nil rather than staying put is deliberate: the caller uses it
    /// to decide whether to do any work, so a second `⌃⌘N` while synthesising
    /// cancels rather than starting a second synthesis on top of the first.
    func next(for event: SpeechEvent) -> SpeechState? {
        switch (self, event) {
        // Starting.
        case (.idle, .toggled), (.failed, .toggled):
            return .preparing
        case (.preparing, .loaded):
            return .synthesising
        case (.synthesising, .synthesised):
            return .speaking

        // Stopping. A toggle while busy means stop, at any stage.
        case (.preparing, .toggled), (.synthesising, .toggled), (.speaking, .toggled):
            return .idle
        case (.preparing, .hushed), (.synthesising, .hushed), (.speaking, .hushed):
            return .idle

        // Hush when nothing is speaking does nothing at all. It is a global
        // key, and returning .idle here would clear a failure the user has not
        // read yet.
        case (.idle, .hushed), (.failed, .hushed):
            return nil

        case (.speaking, .finished):
            return .idle

        case (_, .failed(let why)):
            return .failed(why)

        default:
            return nil
        }
    }
}

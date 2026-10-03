#pragma once
#include <optional>
#include <string>

// The sequencing rules for read-aloud and dictation, apart from the work, so
// they are tested without a model, a microphone or an audio device. Each
// next() returns nullopt where an event does not apply -- the caller uses that
// to decide whether to act, so a second press while busy cancels rather than
// starting a second run on top of the first.

namespace nib::speech {

// --- SpeechState ----------------------------------------------------------------

struct SpeechState {
    enum class Kind { idle, preparing, synthesising, speaking, failed };
    Kind kind = Kind::idle;
    std::u16string why;  // failed

    bool busy() const { return kind == Kind::preparing || kind == Kind::synthesising || kind == Kind::speaking; }
    std::u16string label() const;

    enum class Event { toggled, hushed, loaded, synthesised, finished, failed };
    std::optional<SpeechState> next(Event event, const std::u16string& why = {}) const;

    friend bool operator==(const SpeechState& a, const SpeechState& b) { return a.kind == b.kind && a.why == b.why; }
};

// --- DictationState ------------------------------------------------------------

struct DictationState {
    enum class Kind { idle, requesting_access, recording, transcribing, inserting, failed };
    Kind kind = Kind::idle;
    std::u16string text;  // inserting: the transcript; failed: the reason

    bool busy() const { return kind != Kind::idle && kind != Kind::failed; }
    // The indicator is driven from this and nothing else, so it cannot
    // disagree with reality.
    bool listening() const { return kind == Kind::recording; }

    enum class Event { toggled, access_granted, access_denied, reached_limit, transcribed, inserted, failed,
                       cancelled };
    std::optional<DictationState> next(Event event, const std::u16string& payload = {}) const;

    friend bool operator==(const DictationState& a, const DictationState& b) {
        return a.kind == b.kind && a.text == b.text;
    }
};

}  // namespace nib::speech

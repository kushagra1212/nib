#include "speech/speech_state.hpp"

namespace nib::speech {

std::u16string SpeechState::label() const {
    switch (kind) {
    case Kind::idle:         return u"Speak Selection";
    case Kind::preparing:    return u"Loading the voice…";
    case Kind::synthesising: return u"Preparing speech…";
    case Kind::speaking:     return u"Stop Speaking";
    case Kind::failed:       return u"Speak Selection";
    }
    return {};
}

std::optional<SpeechState> SpeechState::next(Event event, const std::u16string& reason) const {
    using K = Kind;
    using E = Event;
    switch (event) {
    case E::toggled:
        if (kind == K::idle || kind == K::failed) return SpeechState{K::preparing, {}};
        return SpeechState{K::idle, {}};  // stop, at any busy stage
    case E::hushed:
        // Hush with nothing speaking does nothing: it is a global key, and
        // returning idle would clear a failure the user has not read yet.
        if (busy()) return SpeechState{K::idle, {}};
        return std::nullopt;
    case E::loaded:
        if (kind == K::preparing) return SpeechState{K::synthesising, {}};
        return std::nullopt;
    case E::synthesised:
        if (kind == K::synthesising) return SpeechState{K::speaking, {}};
        return std::nullopt;
    case E::finished:
        if (kind == K::speaking) return SpeechState{K::idle, {}};
        return std::nullopt;
    case E::failed:
        return SpeechState{K::failed, reason};
    }
    return std::nullopt;
}

std::optional<DictationState> DictationState::next(Event event, const std::u16string& payload) const {
    using K = Kind;
    using E = Event;
    switch (event) {
    case E::toggled:
        if (kind == K::idle || kind == K::failed) return DictationState{K::requesting_access, {}};
        // Both the hotkey and the length cap end a recording by transcribing
        // what was said, never by discarding it.
        if (kind == K::recording) return DictationState{K::transcribing, {}};
        return std::nullopt;
    case E::access_granted:
        if (kind == K::requesting_access) return DictationState{K::recording, {}};
        return std::nullopt;
    case E::access_denied:
        if (kind == K::requesting_access) {
            return DictationState{K::failed, u"nib is not allowed to use the microphone"};
        }
        return std::nullopt;
    case E::reached_limit:
        if (kind == K::recording) return DictationState{K::transcribing, {}};
        return std::nullopt;
    case E::transcribed:
        // Silence transcribes to nothing; inserting that would make an
        // accidental toggle look like a failure.
        if (kind == K::transcribing) {
            return payload.empty() ? DictationState{K::idle, {}} : DictationState{K::inserting, payload};
        }
        return std::nullopt;
    case E::inserted:
        if (kind == K::inserting) return DictationState{K::idle, {}};
        return std::nullopt;
    case E::cancelled:
        if (busy()) return DictationState{K::idle, {}};
        return std::nullopt;
    case E::failed:
        if (busy()) return DictationState{K::failed, payload};
        return std::nullopt;
    }
    return std::nullopt;
}

}  // namespace nib::speech

#pragma once
#include <windows.h>

#include <atomic>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include "speech/audio_io.hpp"
#include "speech/dictation_text.hpp"
#include "speech/engines.hpp"
#include "speech/speech_state.hpp"

// The three features that use audio, each a thin layer that performs work and
// reports back; the rules about what may follow what are in the core's state
// machines. Everything public is called on the UI thread, and every callback
// arrives on it.

namespace nib::app {

// Port of SpeechController: reading the selection aloud.
//
// The model is held for two minutes after the last word and then released --
// fast for a run of sentences, nothing resident once you move on.
class SpeechController {
public:
    SpeechController();
    ~SpeechController();

    std::function<void(const speech::SpeechState&)> on_change;
    // What to speak: the selection, or the clipboard when nothing is selected.
    // Called on a worker thread.
    std::function<std::optional<std::u16string>()> read_text;
    // Dictation wins: the microphone would record nib's own voice.
    std::function<bool()> is_dictating;

    void toggle();
    void hush();
    void cancel();
    void release();  // drop the model now

    const speech::SpeechState& state() const { return state_; }
    std::string voice() const;
    void set_voice(const std::string& voice);

    static constexpr unsigned idle_release_ms = 120'000;

private:
    void set(speech::SpeechState s);
    void fail(const std::u16string& why);
    void begin();
    void schedule_release();

    speech::SpeechState state_;
    std::shared_ptr<std::atomic<bool>> cancelled_;
    std::shared_ptr<speech::Kokoro> engine_;
    std::shared_ptr<speech::VoicePack> voices_;
    std::shared_ptr<audio::Player> player_;
    UINT_PTR release_timer_ = 0;
    uint64_t generation_ = 0;
};

// Port of DictationController: from the hotkey to the words landing in the
// focused field.
class DictationController {
public:
    DictationController();
    ~DictationController();

    std::function<void(const speech::DictationState&)> on_change;
    std::function<void()> will_record;      // stop reading aloud first
    std::function<void()> will_transcribe;  // free the rewrite model's memory
    std::function<void()> needs_model;
    std::function<void(const std::u16string&)> on_transcript;  // before typing

    void toggle();
    void cancel();

    const speech::DictationState& state() const { return state_; }
    float level() const { return recorder_.level(); }
    double elapsed() const { return recorder_.elapsed(); }

private:
    void handle(speech::DictationState::Event e, const std::u16string& payload = {});
    void enter(const speech::DictationState& next, const speech::DictationState& previous);

    speech::DictationState state_;
    audio::Recorder recorder_;
    std::shared_ptr<speech::Whisper> engine_;
    uint64_t generation_ = 0;
};

// Port of PracticeController: record an answer, transcribe it, and write the
// audio and a Markdown report to Documents\nib\practice.
class PracticeController {
public:
    enum class State { idle, recording, transcribing, finished, failed };

    PracticeController();
    ~PracticeController();

    std::function<void(State, const std::wstring& detail)> on_change;  // detail: file or reason
    std::function<void()> will_record;
    std::function<void()> will_transcribe;
    std::function<void()> needs_model;

    void toggle();
    void cancel();
    State state() const { return state_; }
    bool busy() const { return state_ == State::recording || state_ == State::transcribing; }
    float level() const { return recorder_.level(); }
    double elapsed() const { return recorder_.elapsed(); }

    static std::filesystem::path folder();

private:
    void set(State s, const std::wstring& detail = {});
    void start();
    void stop();

    State state_ = State::idle;
    audio::Recorder recorder_;
    uint64_t generation_ = 0;
};

}  // namespace nib::app

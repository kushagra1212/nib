#include "speech/controllers.hpp"

#include <shlobj.h>

#include <ctime>
#include <fstream>
#include "app/dispatch.hpp"
#include "app/settings.hpp"
#include "speech/audio.hpp"
#include "speech/practice.hpp"
#include "speech/speech_catalog.hpp"
#include "support/log.hpp"
#include "text/keystroke.hpp"
#include "text/unicode.hpp"

namespace nib::app {

using speech::DictationState;
using speech::SpeechState;
namespace fs = std::filesystem;

// --- SpeechController ------------------------------------------------------------

SpeechController::SpeechController() = default;

SpeechController::~SpeechController() {
    if (cancelled_) *cancelled_ = true;
    if (player_) player_->stop();
}

std::string SpeechController::voice() const { return settings().voice; }

void SpeechController::set_voice(const std::string& voice) {
    settings().voice = voice;
    settings().save();
    log::write("speech: voice set to " + voice);
}

void SpeechController::set(SpeechState s) {
    if (s == state_) return;
    state_ = std::move(s);
    if (on_change) on_change(state_);
}

void SpeechController::fail(const std::u16string& why) {
    log::write("speech failed: " + utf16_to_utf8(why));
    set({SpeechState::Kind::failed, why});
}

void SpeechController::toggle() {
    const auto next = state_.next(SpeechState::Event::toggled);
    if (!next) return;
    if (next->kind == SpeechState::Kind::idle) {
        cancel();
    } else {
        begin();
    }
}

void SpeechController::hush() {
    if (state_.next(SpeechState::Event::hushed)) cancel();
}

void SpeechController::cancel() {
    ++generation_;
    if (cancelled_) *cancelled_ = true;
    if (player_) player_->stop();
    set({});
    log::write("speech: stopped");
    schedule_release();
}

void SpeechController::release() {
    cancel();
    app::cancel(release_timer_);
    release_timer_ = 0;
    engine_.reset();
    voices_.reset();
    player_.reset();
}

void SpeechController::schedule_release() {
    app::cancel(release_timer_);
    release_timer_ = after(idle_release_ms, [this] {
        release_timer_ = 0;
        if (state_.busy() || !engine_) return;
        engine_.reset();
        voices_.reset();
        log::write("speech: model released after 120s idle");
    });
}

void SpeechController::begin() {
    if (is_dictating && is_dictating()) {
        log::write("speech: not starting, dictation has the microphone");
        fail(u"nib is listening. Stop dictation first.");
        return;
    }
    if (!speech::voice_catalog::installed()) {
        fail(u"The voice is not downloaded yet. Open nib > Voices to get it.");
        return;
    }
    app::cancel(release_timer_);
    release_timer_ = 0;
    set({SpeechState::Kind::preparing});

    const uint64_t generation = ++generation_;
    auto cancelled = std::make_shared<std::atomic<bool>>(false);
    cancelled_ = cancelled;
    auto engine = engine_;
    auto voices = voices_;
    auto reader = read_text;
    const std::string voice = settings().voice;

    in_background([this, generation, cancelled, engine, voices, reader, voice]() mutable {
        std::optional<std::u16string> text;
        try {
            text = reader ? reader() : std::nullopt;
        } catch (...) {
        }
        if (!text || trimmed(*text).empty()) {
            on_ui([this, generation] {
                if (generation == generation_) fail(u"Nothing selected, and nothing on the clipboard.");
            });
            return;
        }
        log::write("speech: " + std::to_string(text->size()) + " characters");
        try {
            // Off the UI thread: opening a 326MB model blocks long enough to
            // freeze the menu.
            if (!engine || !voices) {
                const auto runtime = speech::Kokoro::runtime();
                if (!runtime) throw speech::SpeechError("ONNX Runtime is missing; reinstall nib");
                engine = std::make_shared<speech::Kokoro>(*speech::voice_catalog::installed_model(), *runtime);
                voices = std::make_shared<speech::VoicePack>(*speech::voice_catalog::installed_voice_pack());
                log::write("speech: loaded onnxruntime " + engine->runtime_version());
            }
            on_ui([this, generation, engine, voices] {
                if (generation != generation_) return;
                engine_ = engine;
                voices_ = voices;
                if (auto n = state_.next(SpeechState::Event::loaded)) set(*n);
            });

            auto& espeak = speech::Espeak::shared();
            speech::Synthesizer synth{*engine, *voices,
                                      [&espeak](const std::u32string& c) { return espeak.phonemes(c); }};
            const auto& names = voices->names();
            synth.voice = std::find(names.begin(), names.end(), voice) != names.end()
                              ? voice
                              : speech::voice_catalog::default_voice;

            auto player = std::make_shared<audio::Player>();
            bool started = false;
            size_t spoken = 0;
            synth.synthesise(
                *text, [&] { return cancelled->load(); },
                [&](std::vector<float> batch, bool last) {
                    if (cancelled->load()) return;
                    if (!started) {
                        started = true;
                        player->begin([this, generation] {
                            on_ui([this, generation] {
                                if (generation != generation_) return;
                                if (auto n = state_.next(SpeechState::Event::finished)) {
                                    set(*n);
                                    schedule_release();
                                }
                            });
                        });
                        on_ui([this, generation, player] {
                            if (generation != generation_) {
                                player->stop();
                                return;
                            }
                            player_ = player;
                            if (auto n = state_.next(SpeechState::Event::synthesised)) set(*n);
                        });
                    }
                    spoken += batch.size();
                    player->enqueue(batch, last);
                    if (last) {
                        char line[64];
                        std::snprintf(line, sizeof line, "speech: %.1fs spoken",
                                      static_cast<double>(spoken) / speech::Kokoro::sample_rate);
                        log::write(line);
                    }
                });
            if (cancelled->load()) player->stop();
        } catch (const std::exception& e) {
            const std::u16string why = utf8_to_utf16(e.what());
            on_ui([this, generation, why] {
                if (generation == generation_) fail(why);
            });
        }
    });
}

// --- DictationController ------------------------------------------------------------

DictationController::DictationController() {
    recorder_.on_reached_limit = [this] {
        on_ui([this] { handle(DictationState::Event::reached_limit); });
    };
}

DictationController::~DictationController() { recorder_.cancel(); }

void DictationController::toggle() {
    if (!speech::whisper_catalog::installed()) {
        if (needs_model) needs_model();
        return;
    }
    handle(DictationState::Event::toggled);
}

void DictationController::cancel() { handle(DictationState::Event::cancelled); }

void DictationController::handle(DictationState::Event e, const std::u16string& payload) {
    const auto next = state_.next(e, payload);
    if (!next) return;
    const auto previous = state_;
    state_ = *next;
    if (on_change) on_change(state_);
    enter(state_, previous);
}

void DictationController::enter(const DictationState& s, const DictationState& previous) {
    using K = DictationState::Kind;
    switch (s.kind) {
    case K::requesting_access:
        // Windows has no prompt to wait on: the privacy setting is read, and
        // a refusal surfaces when the device will not open.
        handle(audio::microphone_allowed() ? DictationState::Event::access_granted
                                           : DictationState::Event::access_denied);
        break;
    case K::recording:
        if (will_record) will_record();
        try {
            recorder_.start();
            log::write("dictation: recording");
        } catch (const audio::AudioError& err) {
            handle(DictationState::Event::failed,
                   err.kind == audio::AudioError::Kind::access_denied
                       ? u"nib is not allowed to use the microphone. Turn on microphone access for desktop apps "
                         u"in Windows Settings."
                       : utf8_to_utf16(err.what()));
        }
        break;
    case K::transcribing: {
        auto samples = recorder_.stop();
        log::write("dictation: " + std::to_string(static_cast<int>(speech::audio::duration(samples))) + "s captured");
        const auto model = speech::whisper_catalog::installed();
        if (!model) {
            handle(DictationState::Event::failed, u"no speech model installed");
            return;
        }
        if (will_transcribe) will_transcribe();
        if (!engine_) engine_ = std::make_shared<speech::Whisper>(*model);
        auto engine = engine_;
        const uint64_t generation = ++generation_;
        in_background([this, engine, generation, samples = std::move(samples)] {
            std::u16string text, failure;
            try {
                // Read per dictation, so an edit applies to the next sentence.
                text = engine->transcribe(samples, speech::vocabulary::prompt(speech::vocabulary::terms()));
            } catch (const std::exception& e) {
                failure = utf8_to_utf16(e.what());
            }
            // Released after every dictation: holding hundreds of megabytes
            // for the next one would undo the reason this is a toggle.
            engine->release();
            on_ui([this, generation, text, failure] {
                if (generation != generation_) return;
                if (!failure.empty()) handle(DictationState::Event::failed, failure);
                else handle(DictationState::Event::transcribed, text);
            });
        });
        break;
    }
    case K::inserting:
        // Kept before typing: if the insert goes wrong, that is exactly when
        // the transcript is worth having.
        if (on_transcript) on_transcript(s.text);
        text::type(s.text);
        log::write("dictation: inserted " + std::to_string(s.text.size()) + " characters");
        handle(DictationState::Event::inserted);
        break;
    case K::idle:
        if (previous.kind == K::recording) recorder_.cancel();
        ++generation_;
        break;
    case K::failed:
        log::write("dictation failed: " + utf16_to_utf8(s.text));
        recorder_.cancel();
        ++generation_;
        break;
    }
}

// --- PracticeController --------------------------------------------------------------

PracticeController::PracticeController() {
    recorder_.on_reached_limit = [this] { on_ui([this] { stop(); }); };
}

PracticeController::~PracticeController() { recorder_.cancel(); }

fs::path PracticeController::folder() {
    // Documents, not app data: these are things you open, play and delete.
    PWSTR documents = nullptr;
    fs::path out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &documents))) {
        out = fs::path(documents) / L"nib" / L"practice";
    }
    CoTaskMemFree(documents);
    return out;
}

void PracticeController::set(State s, const std::wstring& detail) {
    state_ = s;
    if (on_change) on_change(s, detail);
}

void PracticeController::toggle() {
    switch (state_) {
    case State::recording: stop(); break;
    case State::transcribing: break;  // let it finish
    default: start(); break;
    }
}

void PracticeController::start() {
    if (!speech::whisper_catalog::installed()) {
        if (needs_model) needs_model();
        return;
    }
    if (!audio::microphone_allowed()) {
        set(State::failed, L"nib is not allowed to use the microphone");
        return;
    }
    if (will_record) will_record();
    try {
        recorder_.start();
        set(State::recording);
        log::write("practice: recording");
    } catch (const std::exception& e) {
        set(State::failed, widen(e.what()));
    }
}

void PracticeController::stop() {
    if (state_ != State::recording) return;
    auto samples = recorder_.stop();
    const double duration = speech::audio::duration(samples);
    log::write("practice: " + std::to_string(static_cast<int>(duration)) + "s captured");
    if (duration < 1) {
        set(State::failed, L"that take was under a second");
        return;
    }
    const auto model = speech::whisper_catalog::installed();
    if (!model) {
        set(State::failed, L"no speech model installed");
        return;
    }
    set(State::transcribing);
    if (will_transcribe) will_transcribe();
    const uint64_t generation = ++generation_;
    const fs::path where = folder();
    in_background([this, generation, where, model = *model, samples = std::move(samples), duration] {
        std::wstring result;
        bool ok = false;
        try {
            speech::Whisper engine(model);
            const auto segments = engine.transcribe_segments(samples, speech::vocabulary::prompt(speech::vocabulary::terms()));
            engine.release();

            std::error_code ec;
            fs::create_directories(where, ec);
            // A shared, sortable stem keeps the pair together after a hundred
            // takes, in the order they were recorded.
            const std::time_t now = std::time(nullptr);
            std::tm local{};
            localtime_s(&local, &now);
            wchar_t stem[32];
            wcsftime(stem, 32, L"%Y-%m-%d-%H%M%S", &local);
            const auto wav = where / (std::wstring(stem) + L".wav");
            const auto md = where / (std::wstring(stem) + L".md");
            speech::audio::write_wav(wav, samples);
            const speech::DeliveryReport report(segments, duration);
            const auto body = speech::practice::markdown(segments, report, wav.filename().u16string(),
                                                         static_cast<int64_t>(now));
            std::ofstream(md, std::ios::binary) << utf16_to_utf8(body);
            log::write("practice: wrote a take and its report");
            result = md.wstring();
            ok = true;
        } catch (const std::exception& e) {
            result = widen(e.what());
        }
        on_ui([this, generation, ok, result] {
            if (generation != generation_) return;
            set(ok ? State::finished : State::failed, result);
        });
    });
}

void PracticeController::cancel() {
    recorder_.cancel();
    ++generation_;
    set(State::idle);
}

}  // namespace nib::app

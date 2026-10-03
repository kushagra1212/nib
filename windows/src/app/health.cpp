#include "app/health.hpp"

#include "app/dispatch.hpp"
#include "rewrite/model_catalog.hpp"
#include "speech/engines.hpp"
#include "speech/speech_catalog.hpp"

namespace nib::app {

const wchar_t* title(Feature f) {
    switch (f) {
    case Feature::text_access:   return L"Reading text";
    case Feature::grammar:       return L"Grammar checking";
    case Feature::rewrite:       return L"AI rewrite";
    case Feature::dictation:     return L"Dictation";
    case Feature::speech:        return L"Speak selection";
    case Feature::hotkeys:       return L"Keyboard shortcuts";
    case Feature::live_checking: return L"Underline as I type";
    }
    return L"";
}

// What stops working when this does: "harper-ls is not running" means
// nothing to someone who wanted to know why their typos stopped being marked.
const wchar_t* purpose(Feature f) {
    switch (f) {
    case Feature::text_access:   return L"Reading and editing text in other apps";
    case Feature::grammar:       return L"Finding spelling and grammar mistakes";
    case Feature::rewrite:       return L"Fix, Clearer, Shorter and Native";
    case Feature::dictation:     return L"Typing by speaking";
    case Feature::speech:        return L"Reading selected text aloud";
    case Feature::hotkeys:       return L"Triggering nib without the tray menu";
    case Feature::live_checking: return L"Underlining mistakes while you type";
    }
    return L"";
}

HealthRow health_row(Feature f, const HealthContext& c) {
    // A recorded failure outranks an inferred one.
    const auto failure_it = c.last_failures.find(f);
    const std::wstring failure = failure_it == c.last_failures.end() ? L"" : failure_it->second;

    switch (f) {
    case Feature::text_access:
        // Windows asks no permission for UI Automation. The one wall is
        // integrity: an app running as administrator is out of reach.
        return {f, HealthState::working, L"Available",
                L"", L"Apps running as administrator cannot be read or typed into unless nib is too.", false};

    case Feature::grammar:
        if (!c.grammar_found) {
            return {f, HealthState::broken, L"harper-ls missing",
                    L"The grammar engine is not where nib expects it.", L"Reinstall nib.", false};
        }
        if (!failure.empty()) {
            return {f, HealthState::broken, L"Stopped", failure,
                    L"Restart grammar checking. If it stops again, reinstall nib.", true};
        }
        if (!c.grammar_running) {
            return {f, HealthState::degraded, L"Starts on first use", L"", L"", true};
        }
        return {f, HealthState::working, L"Running", L"", L"", true};

    case Feature::rewrite: {
        const auto model = find_model();
        if (!model) {
            return {f, HealthState::broken, L"No model installed",
                    L"Fix, Clearer, Shorter and Native all need a local model, and there is none in "
                        + model_catalog::install_directory().wstring() + L".",
                    L"Open Models and download " + wide(model_catalog::recommended().title) + L".", false};
        }
        if (!locate_llama_server()) {
            return {f, HealthState::broken, L"llama-server missing",
                    L"The model is installed but the engine that runs it is not.", L"Reinstall nib.", false};
        }
        const std::wstring name = model->filename().wstring();
        if (!failure.empty()) {
            return {f, HealthState::degraded, name + L", last attempt failed", failure,
                    L"Restart the rewrite engine. If it fails for memory, close some apps or switch to the "
                    L"smaller model.",
                    true};
        }
        // Sleeping is correct, not a fault: the server exits after two idle
        // minutes to hand back its memory.
        return {f, HealthState::working, name + (c.rewriter_loaded ? L", loaded" : L", sleeping"), L"", L"",
                c.rewriter_loaded};
    }

    case Feature::dictation: {
        const auto model = speech::whisper_catalog::installed();
        if (!model) {
            return {f, HealthState::broken, L"No model installed",
                    L"Dictation needs a whisper model, and there is none in "
                        + speech::whisper_catalog::install_directory().wstring() + L".",
                    L"Open Models and download " + wide(speech::whisper_catalog::recommended().title) + L".", false};
        }
        if (!speech::Whisper::library()) {
            return {f, HealthState::broken, L"whisper missing", L"The speech engine is not installed.",
                    L"Reinstall nib.", false};
        }
        if (!c.microphone_allowed) {
            return {f, HealthState::broken, L"Microphone blocked",
                    L"Windows is not letting desktop apps use the microphone.",
                    L"Settings > Privacy & security > Microphone: turn on \"Let desktop apps access your "
                    L"microphone\".",
                    false};
        }
        if (!failure.empty()) {
            return {f, HealthState::broken, model->filename().wstring(), failure,
                    L"Check the microphone in Windows Settings > Sound.", false};
        }
        return {f, HealthState::working, model->filename().wstring(), L"", L"", false};
    }

    case Feature::speech: {
        const bool model = speech::voice_catalog::installed_model().has_value();
        const bool pack = speech::voice_catalog::installed_voice_pack().has_value();
        if (!model || !pack) {
            std::wstring missing = !model && !pack ? L"the Kokoro model and the voice pack"
                                   : !model        ? L"the Kokoro model"
                                                   : L"the voice pack";
            return {f, HealthState::broken, L"Missing " + missing,
                    L"Speaking needs both the model and the 54-voice pack.",
                    L"Open Voices and download what is missing.", false};
        }
        if (!speech::Espeak::installed_directory() || !speech::Kokoro::runtime()) {
            return {f, HealthState::broken, L"Speech engine missing",
                    L"espeak-ng or ONNX Runtime is missing from nib's folder.", L"Reinstall nib.", false};
        }
        if (!failure.empty()) {
            return {f, HealthState::degraded, L"Last attempt failed", failure,
                    L"Try again. If it keeps failing, check the output device in Sound settings.", false};
        }
        return {f, HealthState::working, L"Ready", L"", L"", false};
    }

    case Feature::hotkeys: {
        std::wstring lost, held;
        int registered = 0;
        for (const auto& [name, combo] : c.hotkeys) {
            if (combo.empty()) lost += (lost.empty() ? L"" : L", ") + name;
            else {
                ++registered;
                held += (held.empty() ? L"" : L"  ") + combo;
            }
        }
        if (!lost.empty()) {
            return {f, HealthState::degraded,
                    std::to_wstring(registered) + L" of " + std::to_wstring(c.hotkeys.size()) + L" registered",
                    L"Another app already holds the shortcut for " + lost
                        + L". Windows gives a combination to one app only, and tells the other nothing.",
                    L"Quit whatever else uses it, then restart the shortcuts here. Everything is still in the "
                    L"tray menu.",
                    true};
        }
        return {f, HealthState::working, held, L"", L"", true};
    }

    case Feature::live_checking:
        if (!c.live_enabled) {
            // Off is a choice, not a fault.
            return {f, HealthState::degraded, L"Switched off", L"", L"Turn on Underline As I Type in the tray menu.",
                    false};
        }
        if (!failure.empty()) {
            return {f, HealthState::degraded, L"On, last pass failed", failure,
                    L"Restart underlining. Some apps expose no text positions, and then the badge and Ctrl+Alt+Space "
                    L"still work.",
                    true};
        }
        return {f, HealthState::working, L"On", L"", L"", true};
    }
    return {f, HealthState::broken, L"", L"", L"", false};
}

std::vector<HealthRow> health_report(const HealthContext& context) {
    std::vector<HealthRow> rows;
    for (auto f : all_features) rows.push_back(health_row(f, context));
    return rows;
}

}  // namespace nib::app

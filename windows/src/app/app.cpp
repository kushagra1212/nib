#include "app/app.hpp"

#include <shellapi.h>
#include <wtsapi32.h>

#include "app/diagnostics.hpp"
#include "app/settings.hpp"
#include "app/startup.hpp"
#include "platform/paths.hpp"
#include "present/presentation.hpp"
#include "speech/audio.hpp"
#include "speech/audio_io.hpp"
#include "speech/speech_catalog.hpp"
#include "support/log.hpp"
#include "text/clipboard.hpp"
#include "text/keystroke.hpp"
#include "text/unicode.hpp"
#include "ui/dialogs.hpp"

namespace nib::app {
namespace fs = std::filesystem;

namespace {

std::wstring short_path(const fs::path& p) { return p.filename().wstring(); }

}  // namespace

App::App() = default;

App::~App() {
    if (live_) live_->stop();
    if (harper_) harper_->stop();
    if (rewriter_) rewriter_->shutdown();
    if (hwnd_) WTSUnRegisterSessionNotification(hwnd_);
}

// --- Lifecycle ----------------------------------------------------------------------

int App::run(bool background) {
    init_dispatch();
    log::set_file_enabled(log::file_enabled() || settings().file_log);
    log::reset();
    log::write("launched, " + narrow(windows_version()));

    WNDCLASSW wc{};
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = window_class;
    RegisterClassW(&wc);
    // A hidden top-level window rather than message-only: it has to receive
    // the TaskbarCreated broadcast and power notifications.
    hwnd_ = CreateWindowExW(WS_EX_TOOLWINDOW, window_class, L"nib", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
                            wc.hInstance, this);
    WTSRegisterSessionNotification(hwnd_, NOTIFY_FOR_THIS_SESSION);

    icon_ = static_cast<HICON>(LoadImageW(wc.hInstance, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                          GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
    tray_ = std::make_unique<Tray>(hwnd_, icon_, L"nib");
    hotkeys_ = std::make_unique<Hotkeys>(hwnd_);

    panel_ = std::make_unique<ui::SuggestionPanel>();
    control_ = std::make_unique<ui::ControlPanel>(panel_host());
    speech_ = std::make_unique<SpeechController>();
    dictation_ = std::make_unique<DictationController>();
    practice_ = std::make_unique<PracticeController>();
    overlay_ = std::make_unique<DictationOverlay>();
    history_ = speech::DictationHistory::load();
    speech::whisper_catalog::prefer(settings().speech_model);
    uia_queue_ = std::make_shared<SerialQueue>("uia");

    start_engines();
    register_hotkeys();

    // Speech: reads the selection, or the clipboard when nothing is selected.
    speech_->read_text = [this] { return read_selection_for_speech(); };
    speech_->is_dictating = [this] { return dictation_->state().busy() || practice_->busy(); };
    speech_->on_change = [this](const speech::SpeechState& s) {
        if (s.kind == speech::SpeechState::Kind::failed) {
            failures_[Feature::speech] = wide(s.why);
            tray_->balloon(L"Speak Selection", wide(s.why));
        } else if (s.kind == speech::SpeechState::Kind::speaking) {
            failures_.erase(Feature::speech);
        }
    };

    // Dictation and practice share the courtesies: stop reading aloud before
    // the microphone opens -- or nib records its own voice and types it back --
    // and free the rewrite model's memory before whisper loads.
    auto quiet = [this] {
        if (speech_->state().busy()) {
            log::write("speech: stopped, the microphone is opening");
            speech_->hush();
        }
    };
    auto free_model = [this] {
        if (rewriter_) {
            auto r = rewriter_;
            in_background([r] { r->shutdown(); });
        }
    };
    dictation_->will_record = quiet;
    dictation_->will_transcribe = free_model;
    dictation_->needs_model = [this] { offer_speech_model(); };
    dictation_->on_transcript = [this](const std::u16string& t) { record_transcript(t); };
    dictation_->on_change = [this](const speech::DictationState& s) {
        using K = speech::DictationState::Kind;
        switch (s.kind) {
        case K::recording: overlay_->listening(); break;
        case K::transcribing: overlay_->working(L"Transcribing…"); break;
        case K::requesting_access: overlay_->working(L"Opening the microphone…"); break;
        case K::failed:
            overlay_->dismiss();
            report_dictation(s.text);
            break;
        default: overlay_->dismiss(); break;
        }
    };
    overlay_->sample = [this] {
        if (practice_->state() == PracticeController::State::recording) {
            return std::pair<float, double>{practice_->level(), practice_->elapsed()};
        }
        return std::pair<float, double>{dictation_->level(), dictation_->elapsed()};
    };
    overlay_->on_stop = [this] {
        if (practice_->state() == PracticeController::State::recording) practice_->toggle();
        else dictation_->cancel();
    };
    practice_->will_record = quiet;
    practice_->will_transcribe = free_model;
    practice_->needs_model = [this] { offer_speech_model(); };
    practice_->on_change = [this](PracticeController::State s, const std::wstring& detail) {
        switch (s) {
        case PracticeController::State::recording: overlay_->listening(L"Practice take"); break;
        case PracticeController::State::transcribing: overlay_->working(L"Scoring the take…"); break;
        case PracticeController::State::finished:
            overlay_->dismiss();
            // Revealed rather than opened: a take is usually one of several
            // being compared, and the folder is more use than the file.
            ui::reveal(detail);
            break;
        case PracticeController::State::failed:
            overlay_->dismiss();
            log::write("practice failed: " + narrow(detail));
            tray_->balloon(L"Practice take", detail);
            break;
        default: overlay_->dismiss(); break;
        }
    };

    if (settings().live_checking) start_live();

    // Offered once, and only when there is no rewrite model: someone who has
    // one, or closed this on a previous launch, never sees it.
    if (!find_model() && !settings().setup_offered) {
        settings().setup_offered = true;
        settings().save();
        open_panel(ui::ControlPanel::Section::models);
    } else if (!background) {
        open_panel();
    }
    tray_->set_tooltip(L"nib — " + status_line());

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

void App::start_engines() {
    lint_queue_ = std::make_shared<SerialQueue>("harper");
    model_queue_ = std::make_shared<SerialQueue>("model");
    if (auto harper = locate_harper()) {
        harper_ = std::make_shared<HarperEngine>(harper->u16string());
        // Warmed now so the first keystroke is not a cold start.
        auto h = harper_;
        lint_queue_->post([this, h] {
            try {
                h->start();
            } catch (const std::exception& e) {
                const auto why = widen(e.what());
                on_ui([this, why] { failures_[Feature::grammar] = why; });
            }
        });
    } else {
        log::write("harper-ls not found");
    }
    // The model loads on first rewrite, not here: it is gigabytes, and most
    // sessions never ask for one.
    const auto& chosen = settings().rewrite_model;
    adopt_model(find_model(chosen.empty() ? std::string() : chosen));
}

void App::adopt_model(const std::optional<fs::path>& model) {
    if (rewriter_) {
        auto old = rewriter_;
        in_background([old] { old->shutdown(); });
    }
    rewriter_.reset();
    model_.reset();
    model_path_ = model;
    const auto server = locate_llama_server();
    if (model && server) {
        RewriteEngine::Config config;
        config.server_binary = *server;
        config.model_path = *model;
        rewriter_ = std::make_shared<RewriteEngine>(config);
        model_ = std::make_shared<ModelChecker>(*rewriter_);
        log::write("rewrite model: " + model->filename().string());
    }
    // The live checker captured the old checker when it was built; it is
    // rebuilt, or the rewrite bar stays absent until the next launch.
    if (live_ && live_->running()) {
        stop_live();
        start_live();
    }
}

void App::start_live() {
    if (!harper_) return;
    if (!live_) {
        live_ = std::make_unique<LiveChecker>(harper_, lint_queue_, model_, model_queue_);
        // A big model is for work you asked for, not every typing pause.
        if (model_path_) {
            live_->runs_model_pass = ModelChecker::is_light_enough_for_live_use(*model_path_);
            if (!live_->runs_model_pass) {
                log::write("live: model pass off -- " + model_path_->filename().string()
                           + " is too large to run on every pause; harper still marks");
            }
        }
        live_->hotkey_label = hotkeys_->registered(Hotkeys::Action::panel) ? hotkeys_->label(Hotkeys::Action::panel)
                                                                           : L"tray menu";
        live_->on_open_panel = [this] { check_selection(); };
    }
    live_->start();
    failures_.erase(Feature::live_checking);
}

void App::stop_live() {
    if (live_) live_->stop();
    live_.reset();
}

void App::register_hotkeys() {
    hotkeys_->add(Hotkeys::Action::panel, [this] { check_selection(); });
    hotkeys_->add(Hotkeys::Action::dictate, [this] { dictation_->toggle(); });
    hotkeys_->add(Hotkeys::Action::practice, [this] { practice_->toggle(); });
    hotkeys_->add(Hotkeys::Action::speak, [this] { speech_->toggle(); });
    hotkeys_->add(Hotkeys::Action::hush, [this] { speech_->hush(); });
    claim_hotkeys_later();
}

void App::claim_hotkeys_later() {
    // Whatever held a combination at startup -- often an older nib still
    // running -- may quit at any time. Until every key is ours, ask again
    // every ten seconds; once they are, stop asking.
    if (hotkeys_->all_registered()) return;
    after(10000, [this] {
        if (hotkeys_->claim_missing() && live_ && hotkeys_->registered(Hotkeys::Action::panel)) {
            live_->hotkey_label = hotkeys_->label(Hotkeys::Action::panel);
        }
        claim_hotkeys_later();
    });
}

LRESULT CALLBACK App::proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_NCCREATE) {
        auto* created = reinterpret_cast<App*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(created));
        // Stored now, not when CreateWindowEx returns: the messages sent
        // during creation are handled with it, and a null one fails creation.
        created->hwnd_ = hwnd;
    }
    auto* self = reinterpret_cast<App*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    return self ? self->handle(msg, wp, lp) : DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT App::handle(UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == Tray::taskbar_created() && tray_) {
        tray_->readd();
        return 0;
    }
    switch (msg) {
    case WM_HOTKEY:
        hotkeys_->fired(wp);
        return 0;
    case Tray::callback_message:
        switch (LOWORD(lp)) {
        case WM_LBUTTONUP:
        case WM_CONTEXTMENU:
        case WM_RBUTTONUP:
            show_menu();
            break;
        case WM_LBUTTONDBLCLK:
            open_panel();
            break;
        }
        return 0;
    case open_message:
        open_panel();
        return 0;
    case WM_POWERBROADCAST:
        // Registrations do not reliably survive sleep; a lid closed overnight
        // left every hotkey dead on macOS until nib restarted.
        if (wp == PBT_APMRESUMEAUTOMATIC) hotkeys_->reregister();
        return TRUE;
    case WM_WTSSESSION_CHANGE:
        if (wp == WTS_SESSION_UNLOCK) hotkeys_->reregister();
        return 0;
    case WM_ENDSESSION:
        if (wp) {
            if (harper_) harper_->stop();
            if (rewriter_) rewriter_->shutdown();
        }
        return 0;
    }
    return DefWindowProcW(hwnd_, msg, wp, lp);
}

// --- Tray menu --------------------------------------------------------------------

std::wstring App::status_line() {
    if (!harper_) return L"Not working — grammar engine missing";
    if (!live_ || !live_->running()) return L"Underlines off — turn on below";
    if (!rewriter_) return L"Working — no AI model";
    // "Installed" is about a file; "ready" is about a server that answered.
    return rewriter_->loaded() ? L"Working — AI ready" : L"Working — AI loads on first use";
}

std::vector<MenuItem> App::menu() {
    std::vector<MenuItem> items;
    MenuItem status;
    status.text = status_line();
    status.enabled = false;
    items.push_back(status);
    items.push_back(MenuItem::sep());

    auto label = [this](const wchar_t* text, Hotkeys::Action a) {
        const auto combo = hotkeys_->label(a);
        return std::wstring(text) + (combo.empty() ? L"" : L"\t" + combo);
    };
    items.push_back({label(L"Check Selection", Hotkeys::Action::panel), [this] { check_selection(); }});
    MenuItem live{L"Underline As I Type", [this] {
                      const bool on = live_ && live_->running();
                      settings().live_checking = !on;
                      settings().save();
                      if (on) stop_live();
                      else start_live();
                  }};
    live.checked = live_ && live_->running();
    items.push_back(live);
    items.push_back(MenuItem::sep());

    using DK = speech::DictationState::Kind;
    const auto d = dictation_->state().kind;
    items.push_back({d == DK::recording      ? label(L"Stop Dictating", Hotkeys::Action::dictate)
                     : d == DK::transcribing ? std::wstring(L"Transcribing…")
                                             : label(L"Dictate", Hotkeys::Action::dictate),
                     [this] { dictation_->toggle(); }});

    // Dictation types into whatever has focus, so one that lands in the wrong
    // window is otherwise gone. These are kept instead.
    MenuItem recent;
    recent.text = history_.entries().empty() ? L"Recent Dictation — none yet" : L"Recent Dictation";
    recent.enabled = !history_.entries().empty();
    for (size_t i = 0; i < history_.entries().size() && i < 15; ++i) {
        const auto text = history_.entries()[i].text;
        recent.submenu.push_back({wide(history_.entries()[i].label()), [text] { text::clipboard::set(text); }});
    }
    if (!recent.submenu.empty()) {
        recent.submenu.push_back(MenuItem::sep());
        recent.submenu.push_back({L"Clear History", [this] {
                                      history_.clear();
                                      history_.save();
                                  }});
    }
    items.push_back(recent);

    const auto p = practice_->state();
    items.push_back({p == PracticeController::State::recording      ? label(L"Stop Practice Take", Hotkeys::Action::practice)
                     : p == PracticeController::State::transcribing ? std::wstring(L"Scoring the take…")
                                                                    : label(L"Practice Take", Hotkeys::Action::practice),
                     [this] { practice_->toggle(); }});
    items.push_back({L"Practice Takes…", [] {
                         std::error_code ec;
                         fs::create_directories(PracticeController::folder(), ec);
                         ui::open(PracticeController::folder().wstring());
                     }});

    const auto& sp = speech_->state();
    std::wstring speak = sp.kind == speech::SpeechState::Kind::speaking ? label(L"Stop Speaking", Hotkeys::Action::hush)
                         : sp.busy()                                     ? wide(sp.label())
                         : speech::voice_catalog::installed()            ? label(L"Speak Selection", Hotkeys::Action::speak)
                                                                         : std::wstring(L"Speak Selection — download the voice first");
    items.push_back({speak, [this] { speech_->toggle(); }});
    items.push_back(MenuItem::sep());

    items.push_back({rewriter_ ? L"AI Rewrite: " + short_path(*model_path_) : std::wstring(L"Set Up AI Rewrite…"),
                     [this] { open_panel(ui::ControlPanel::Section::models); }});
    // The engines are separate processes; this is the one place the total is
    // visible, and the way to hand it back.
    const auto fp = footprint();
    MenuItem memory{L"Memory: " + fp.summary(), [this] { free_memory(); }};
    memory.enabled = fp.engines > 0 || speech_->state().kind == speech::SpeechState::Kind::idle;
    items.push_back(memory);
    MenuItem login{L"Start at Sign-in", [] { startup::set(startup::state() != startup::State::on); }};
    login.checked = startup::state() == startup::State::on;
    if (startup::state() == startup::State::disabled_by_user) login.text = L"Start at Sign-in — turned off in Task Manager";
    items.push_back(login);
    MenuItem open{L"Open nib…", [this] { open_panel(); }};
    open.bold = true;
    items.push_back(open);
    items.push_back(MenuItem::sep());
    items.push_back({L"Quit nib", [] { PostQuitMessage(0); }});
    return items;
}

void App::show_menu() {
    auto items = menu();
    tray_->popup(items);
    tray_->set_tooltip(L"nib — " + status_line());
}

// --- The hotkey panel ------------------------------------------------------------------

void App::check_selection() {
    log::write(std::string("panel: requested") + (panel_busy_ ? ", already busy" : ""));
    if (panel_busy_) return;
    if (!harper_) {
        ui::tell(nullptr, L"Grammar checking is not available", L"harper-ls is missing from nib's folder. Reinstall nib.",
                 true);
        return;
    }
    panel_busy_ = true;
    POINT cursor;
    GetCursorPos(&cursor);
    uia_queue_->post([this, cursor] {
        text::GrabFailure why = text::GrabFailure::none;
        auto grabbed = text::grab(text::Uia::for_this_thread(), &why);
        log::write(grabbed ? "panel: grabbed " + std::to_string(grabbed->text.size()) + " characters"
                               + (grabbed->source == text::TextTarget::Source::automation ? " through UI Automation"
                                                                                           : " through the clipboard")
                           : "panel: nothing grabbed, reason " + std::to_string(static_cast<int>(why)));
        on_ui([this, grabbed, why, cursor] {
            panel_busy_ = false;
            if (!grabbed || grabbed->text.empty()) {
                switch (why) {
                case text::GrabFailure::sensitive: return;  // a password field: say nothing, read nothing
                case text::GrabFailure::elevated:
                    ui::tell(nullptr, L"nib cannot reach that app",
                             L"It is running as administrator, and Windows keeps other apps out of it.", true);
                    return;
                default:
                    ui::tell(nullptr, L"Nothing to check", L"Select some text first, then press "
                                                               + hotkeys_->label(Hotkeys::Action::panel) + L".");
                    return;
                }
            }
            target_ = grabbed;
            const auto text = grabbed->text;

            ui::SuggestionPanel::Callbacks callbacks;
            callbacks.apply = [this](const std::u16string& edited) { write_back(edited); };
            callbacks.closed = [] {};
            callbacks.fill_fixes = [this](std::vector<Suggestion> list, std::u16string t,
                                          std::function<void(std::vector<Suggestion>)> done) {
                auto h = harper_;
                lint_queue_->post([h, list, t, done] {
                    auto filled = h->with_replacements(list, t);
                    on_ui([done, filled] { done(filled); });
                });
            };
            callbacks.rewrite = [this](std::u16string input, RewriteMode mode,
                                       std::function<void(ui::SuggestionPanel::RewriteResult)> done) {
                if (!rewriter_) {
                    // Pressing the button is the clearest statement anyone can
                    // make that they want this; offer to set it up.
                    open_panel(ui::ControlPanel::Section::models);
                    done({std::nullopt, u"needs a model"});
                    return;
                }
                auto r = rewriter_;
                model_queue_->post([this, r, input, mode, done] {
                    ui::SuggestionPanel::RewriteResult result;
                    try {
                        result.text = r->rewrite(input, mode);
                    } catch (const RewriteException& e) {
                        result.error = present::failure_message(e.error);
                        const auto why = wide(e.error.description());
                        on_ui([this, why] { failures_[Feature::rewrite] = why; });
                    }
                    on_ui([done, result] { done(result); });
                });
            };
            panel_->present(text, cursor, std::move(callbacks));

            auto h = harper_;
            lint_queue_->post([this, h, text] {
                std::vector<Suggestion> found;
                std::wstring error;
                try {
                    found = h->lint(text);
                } catch (const std::exception& e) {
                    error = L"check failed: " + widen(e.what());
                }
                on_ui([this, found, error] {
                    if (!error.empty()) panel_->show_error(error);
                    else panel_->show_found(found);
                });
            });
        });
    });
}

void App::write_back(const std::u16string& edited) {
    if (!target_) return;
    auto target = *target_;
    target_.reset();
    uia_queue_->post([this, target, edited] {
        const auto outcome = text::replace(text::Uia::for_this_thread(), target, edited);
        if (outcome == text::WriteOutcome::copied_to_clipboard) {
            on_ui([] {
                ui::tell(nullptr, L"Could not write to that app", L"The result is on your clipboard.", true);
            });
        }
    });
}

// --- Speech and dictation ---------------------------------------------------------------

std::optional<std::u16string> App::read_selection_for_speech() {
    // On the speech worker: grab through UI Automation on this thread.
    text::GrabFailure why = text::GrabFailure::none;
    if (auto grabbed = text::grab(text::Uia::for_this_thread(), &why)) {
        if (grabbed->had_selection && !trimmed(grabbed->text).empty()) {
            log::write("speech: reading the selection");
            return grabbed->text;
        }
    }
    // A password field is not read aloud, and its absence is not a reason to
    // reach for the clipboard instead.
    if (why == text::GrabFailure::sensitive) return std::nullopt;
    // Someone who has copied a paragraph and pressed the key means that one.
    if (auto clip = text::clipboard::get(); clip && !trimmed(*clip).empty()) {
        log::write("speech: nothing selected, reading the clipboard");
        return clip;
    }
    return std::nullopt;
}

void App::offer_speech_model() {
    open_panel(ui::ControlPanel::Section::models);
    tray_->balloon(L"Dictation needs a speech model",
                   L"Download one from Models. It runs on this machine; nothing you say is uploaded.");
}

void App::report_dictation(const std::u16string& why) {
    // Written down as well as shown: a dialog is not a record.
    failures_[Feature::dictation] = wide(why);
    const bool microphone = contains(lowercased(why), u"microphone");
    if (microphone) {
        if (ui::ask(nullptr, L"nib", L"Dictation stopped", wide(why), {L"Open Microphone Settings", L"OK"}, true) == 0) {
            audio::open_microphone_settings();
        }
    } else {
        ui::tell(nullptr, L"Dictation stopped", wide(why), true);
    }
}

void App::record_transcript(const std::u16string& text) {
    history_.add(text);
    history_.save();
    failures_.erase(Feature::dictation);
    if (control_) control_->refresh();
}

// --- Control panel -------------------------------------------------------------------

void App::open_panel(ui::ControlPanel::Section section) { control_->open(section); }

HealthContext App::health() {
    HealthContext c;
    c.grammar_found = locate_harper().has_value();
    c.grammar_running = harper_ && harper_->running();
    c.rewriter_loaded = rewriter_ && rewriter_->loaded();
    c.live_enabled = live_ && live_->running();
    c.microphone_allowed = audio::microphone_allowed();
    for (auto a : {Hotkeys::Action::panel, Hotkeys::Action::dictate, Hotkeys::Action::practice, Hotkeys::Action::speak,
                   Hotkeys::Action::hush}) {
        c.hotkeys.emplace_back(Hotkeys::name(a), hotkeys_->label(a));
    }
    c.last_failures = failures_;
    return c;
}

void App::test(Feature f, std::function<void(std::wstring)> done) {
    auto finish = [done](std::wstring s) { on_ui([done, s] { done(s); }); };
    switch (f) {
    case Feature::grammar: {
        if (!harper_) return done(L"harper-ls is missing.");
        auto h = harper_;
        lint_queue_->post([h, finish] {
            try {
                const auto start = std::chrono::steady_clock::now();
                const auto found = h->lint(u"Their is many erors here.");
                const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
                finish(found.empty() ? L"harper answered but found nothing in a sentence with four mistakes."
                                     : L"Working: found " + std::to_wstring(found.size()) + L" mistakes in "
                                           + std::to_wstring(ms) + L" ms.");
            } catch (const std::exception& e) {
                finish(L"Failed: " + widen(e.what()));
            }
        });
        return;
    }
    case Feature::rewrite: {
        if (!rewriter_) return done(L"No model installed.");
        auto r = rewriter_;
        model_queue_->post([this, r, finish] {
            try {
                const auto start = std::chrono::steady_clock::now();
                const auto out = r->rewrite(u"she dont like it", RewriteMode::fix_grammar);
                const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
                on_ui([this] { failures_.erase(Feature::rewrite); });
                finish(L"Working: \"she dont like it\" → \"" + wide(out) + L"\" in " + std::to_wstring(ms) + L" ms.");
            } catch (const RewriteException& e) {
                const auto why = wide(e.error.description());
                on_ui([this, why] { failures_[Feature::rewrite] = why; });
                finish(L"Failed: " + why);
            }
        });
        return;
    }
    case Feature::dictation: {
        // The real path end to end, without needing anyone to speak: Kokoro
        // says a sentence when it can, and whisper must hear it.
        const auto model = speech::whisper_catalog::installed();
        if (!model) return done(L"No speech model installed.");
        in_background([model, finish] {
            try {
                std::vector<float> samples;
                if (speech::voice_catalog::installed() && speech::Kokoro::runtime()) {
                    speech::Kokoro k(*speech::voice_catalog::installed_model(), *speech::Kokoro::runtime());
                    speech::VoicePack pack(*speech::voice_catalog::installed_voice_pack());
                    auto& espeak = speech::Espeak::shared();
                    speech::Synthesizer s{k, pack, [&](const std::u32string& c) { return espeak.phonemes(c); }};
                    s.volume = 1.0f;
                    s.synthesise(u"Testing dictation, one two three.", [] { return false; },
                                 [&](std::vector<float> b, bool) { samples.insert(samples.end(), b.begin(), b.end()); });
                    samples = speech::audio::resample(samples, speech::Kokoro::sample_rate, 16'000);
                } else {
                    finish(L"Model and engine present. Speak to test it: press the dictation shortcut.");
                    return;
                }
                speech::Whisper w(*model);
                const auto start = std::chrono::steady_clock::now();
                const auto heard = w.transcribe(samples, std::nullopt);
                const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
                finish(L"Working: heard \"" + wide(heard) + L"\" in " + std::to_wstring(ms) + L" ms. Microphone: "
                       + (audio::microphone_allowed() ? L"allowed." : L"BLOCKED in Windows Settings."));
            } catch (const std::exception& e) {
                finish(L"Failed: " + widen(e.what()));
            }
        });
        return;
    }
    case Feature::speech:
        speech_->read_text = [] { return std::optional<std::u16string>(u"This is nib, reading aloud."); };
        speech_->toggle();
        after(200, [this] { speech_->read_text = [this] { return read_selection_for_speech(); }; });
        done(L"Speaking a test sentence. If nothing is heard, check the output device in Sound settings.");
        return;
    case Feature::hotkeys:
        hotkeys_->reregister();
        done(L"Re-registered: " + health_row(Feature::hotkeys, health()).detail);
        return;
    case Feature::live_checking:
        done(live_ ? live_->report() : L"Underlining is off.");
        return;
    case Feature::text_access:
        done(L"");
        return;
    }
}

std::wstring App::restart(Feature f) {
    switch (f) {
    case Feature::grammar: {
        failures_.erase(Feature::grammar);
        if (!harper_) return L"harper-ls is missing -- reinstall nib.";
        auto h = harper_;
        lint_queue_->post([h] {
            h->stop();
            try {
                h->start();
            } catch (...) {
            }
        });
        return L"Grammar checking restarted.";
    }
    case Feature::rewrite:
        // Shutting down is the whole restart: the next rewrite starts a fresh
        // server, and not starting one now hands the memory back meanwhile.
        if (rewriter_) {
            auto r = rewriter_;
            in_background([r] { r->shutdown(); });
        }
        failures_.erase(Feature::rewrite);
        return L"Rewrite engine stopped. The next rewrite starts a fresh one.";
    case Feature::hotkeys:
        hotkeys_->reregister();
        return health_row(Feature::hotkeys, health()).detail;
    case Feature::live_checking:
        stop_live();
        start_live();
        return L"Underlining restarted.";
    default:
        return L"";
    }
}

void App::restart_app() {
    // A new instance first, so a failed launch leaves this one running.
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    STARTUPINFOW si{sizeof si};
    PROCESS_INFORMATION pi{};
    std::wstring cmd = L"\"" + std::wstring(exe) + L"\" --after-restart";
    if (CreateProcessW(exe, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        PostQuitMessage(0);
    } else {
        log::write("restart failed: " + std::to_string(GetLastError()));
    }
}

void App::free_memory() {
    speech_->release();
    if (rewriter_) {
        auto r = rewriter_;
        in_background([r] { r->shutdown(); });
    }
    log::write("memory: released on request");
}

void App::install(const std::string& kind, const CatalogModel& model) {
    auto& slot = installers_[kind];
    if (slot && slot->busy()) return;
    const fs::path dest = kind == "rewrite"     ? model_catalog::install_directory()
                          : kind == "dictation" ? speech::whisper_catalog::install_directory()
                                                : speech::voice_catalog::install_directory();
    // Only a rewrite model can be proven by running it; a speech model or
    // voice is checked by size, and proven by its own Test.
    slot = std::make_unique<ModelInstaller>(dest, kind == "rewrite");
    slot->on_change = [this, kind](const ModelInstaller::Stage& s) {
        on_ui([this, kind, s] {
            ui::ControlPanel::Install p;
            using K = ModelInstaller::Stage::Kind;
            switch (s.kind) {
            case K::downloading: {
                p.stage = L"downloading";
                wchar_t buf[64];
                swprintf(buf, 64, L"%.0f of %.0f MB", s.received / 1e6, s.total / 1e6);
                p.message = buf;
                p.fraction = s.fraction;
                p.busy = true;
                break;
            }
            case K::verifying:
                p.stage = L"checking it runs";
                p.message = L"loading the model and correcting one sentence";
                p.busy = true;
                break;
            case K::done:
                p.stage = L"installed";
                p.message = s.installed.filename().wstring();
                if (kind == "rewrite") {
                    settings().rewrite_model = s.installed.filename().string();
                    settings().save();
                    adopt_model(s.installed);
                }
                break;
            case K::failed:
                p.stage = L"failed";
                p.message = wide(s.message);
                break;
            case K::cancelled:
                p.stage = L"cancelled";
                break;
            case K::idle:
                break;
            }
            control_->install_progress(kind, p);
            if (s.kind == K::done) {
                // Voices need the pair: fetch the other half straight after.
                if (kind == "voice") {
                    const auto needed = speech::voice_catalog::needed();
                    if (!needed.empty()) install("voice", needed.front());
                }
                control_->refresh();
            }
        });
    };
    slot->start(model);
}

ui::ControlPanel::Host App::panel_host() {
    ui::ControlPanel::Host h;
    h.health = [this] { return health(); };
    h.test = [this](Feature f, std::function<void(std::wstring)> done) { test(f, std::move(done)); };
    h.restart = [this](Feature f) { return restart(f); };
    h.restart_app = [this] { restart_app(); };
    h.open_setup = [this](Feature f) {
        open_panel(f == Feature::speech ? ui::ControlPanel::Section::voices : ui::ControlPanel::Section::models);
    };
    h.install = [this](const std::string& kind, const CatalogModel& m) { install(kind, m); };
    h.cancel_install = [this](const std::string& kind) {
        if (auto it = installers_.find(kind); it != installers_.end() && it->second) it->second->cancel();
    };
    h.remove = [this](const std::string& kind, const fs::path& p) {
        if (kind == "rewrite" && model_path_ && *model_path_ == p) adopt_model(std::nullopt);
        if (kind == "voice") speech_->release();
        std::error_code ec;
        fs::remove(p, ec);
        if (kind == "rewrite") adopt_model(find_model(settings().rewrite_model));
    };
    h.use = [this](const std::string& kind, const fs::path& p) {
        if (kind == "rewrite") {
            settings().rewrite_model = p.filename().string();
            settings().save();
            adopt_model(p);
        } else if (kind == "dictation") {
            settings().speech_model = p.filename().string();
            settings().save();
            speech::whisper_catalog::prefer(settings().speech_model);
        }
    };
    h.active = [this](const std::string& kind) -> std::optional<fs::path> {
        if (kind == "rewrite") return model_path_;
        if (kind == "dictation") return speech::whisper_catalog::installed();
        return std::nullopt;
    };
    h.voices = [] {
        std::vector<std::string> out;
        if (auto pack = speech::voice_catalog::installed_voice_pack()) {
            try {
                out = speech::VoicePack(*pack).names();
            } catch (...) {
            }
        }
        return out;
    };
    h.voice = [this] { return speech_->voice(); };
    h.set_voice = [this](const std::string& v) { speech_->set_voice(v); };
    h.preview_voice = [this](const std::string&) {
        if (speech_->state().busy()) speech_->cancel();
        speech_->read_text = [] { return std::optional<std::u16string>(u"Hello. This is how I sound when I read your writing aloud."); };
        speech_->toggle();
        after(200, [this] { speech_->read_text = [this] { return read_selection_for_speech(); }; });
    };
    h.history = [this] {
        std::vector<std::pair<std::u16string, int64_t>> out;
        for (const auto& e : history_.entries()) out.emplace_back(e.text, e.unix_seconds);
        return out;
    };
    h.copy = [](const std::u16string& t) { text::clipboard::set(t); };
    h.clear_history = [this] {
        history_.clear();
        history_.save();
    };
    h.live_report = [this] { return live_ ? live_->report() : std::wstring(L"Underlining is off."); };
    h.probe_field = [this](std::function<void(std::wstring)> done) {
        // Five seconds to click into the field under investigation.
        after(5000, [this, done] {
            uia_queue_->post([done] {
                const auto report = probe_field(text::Uia::for_this_thread());
                on_ui([done, report] { done(report); });
            });
        });
    };
    h.diagnostic_report = [this] { return diagnostic_report(health()); };
    h.footprint = [] { return L"Memory: " + footprint().summary(); };
    h.free_memory = [this] { free_memory(); };
    h.live_enabled = [this] { return live_ && live_->running(); };
    h.set_live = [this](bool on) {
        settings().live_checking = on;
        settings().save();
        if (on) start_live();
        else stop_live();
    };
    h.login_enabled = [] { return startup::state() == startup::State::on; };
    h.set_login = [](bool on) { startup::set(on); };
    return h;
}

}  // namespace nib::app

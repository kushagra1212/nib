#include "ui/control_panel.hpp"

#include <windowsx.h>

#include <algorithm>
#include <ctime>
#include <fstream>
#include "app/dispatch.hpp"
#include "platform/paths.hpp"
#include "speech/dictation_text.hpp"
#include "speech/speech_catalog.hpp"
#include "support/log.hpp"
#include "text/unicode.hpp"
#include "ui/dialogs.hpp"

namespace nib::ui {
namespace {

constexpr float sidebar_width = 200;
constexpr float content_left = sidebar_width + 24;
constexpr float top = 24;

const wchar_t* section_title(ControlPanel::Section s) {
    switch (s) {
    case ControlPanel::Section::status:      return L"Status";
    case ControlPanel::Section::models:      return L"Models";
    case ControlPanel::Section::voices:      return L"Voices";
    case ControlPanel::Section::words:       return L"Dictation Words";
    case ControlPanel::Section::diagnostics: return L"Diagnostics";
    }
    return L"";
}

Colour state_colour(app::HealthState s) {
    switch (s) {
    case app::HealthState::working:  return colour::accept;
    case app::HealthState::degraded: return colour::warning;
    case app::HealthState::broken:   return colour::correction;
    }
    return colour::ink_muted;
}

std::wstring when(int64_t unix_seconds) {
    const std::time_t t = static_cast<std::time_t>(unix_seconds);
    std::tm local{};
    localtime_s(&local, &t);
    wchar_t buf[32];
    wcsftime(buf, 32, L"%d %b %H:%M", &local);
    return buf;
}

std::wstring read_file(const std::filesystem::path& p) {
    std::ifstream in(p, std::ios::binary);
    const std::string s((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return app::widen(s);
}

}  // namespace

ControlPanel::ControlPanel(Host host) : Surface(Kind::window), host_(std::move(host)) {
    create(L"nib");
    edit_font_ = CreateFontW(-static_cast<int>(13 * scale_), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH, L"Cascadia Mono");
    edit_brush_ = CreateSolidBrush(colour::field.colorref());
    words_edit_ = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL,
                                  0, 0, 10, 10, hwnd(), nullptr, GetModuleHandleW(nullptr), nullptr);
    log_edit_ = CreateWindowExW(0, L"EDIT", L"",
                                WS_CHILD | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY | WS_VSCROLL, 0, 0, 10, 10,
                                hwnd(), nullptr, GetModuleHandleW(nullptr), nullptr);
    for (HWND e : {words_edit_, log_edit_}) SendMessageW(e, WM_SETFONT, reinterpret_cast<WPARAM>(edit_font_), TRUE);
    SendMessageW(log_edit_, EM_SETLIMITTEXT, 0, 0);

    const Section all[] = {Section::status, Section::models, Section::voices, Section::words, Section::diagnostics};
    float y = top + 60;
    for (auto s : all) {
        Button b;
        b.label = section_title(s);
        b.emphasis = Button::Emphasis::plain;
        b.rect = {12, y, sidebar_width - 12, y + 32};
        b.on_click = [this, s] { select(s); };
        sidebar_.add(std::move(b));
        y += 36;
    }
    // The licences of everything nib ships, beside nib.exe in an install.
    Button licences;
    licences.label = L"Licences";
    licences.emphasis = Button::Emphasis::plain;
    licences.rect = {12, y + 12, sidebar_width - 12, y + 44};
    licences.on_click = [] {
        const auto installed = platform::paths::executable_dir() / L"THIRD-PARTY-LICENSES.txt";
        std::error_code ec;
        ui::open(std::filesystem::exists(installed, ec)
                     ? installed.wstring()
                     : L"https://github.com/kushagra1212/nib/blob/main/THIRD-PARTY-LICENSES.txt");
    };
    sidebar_.add(std::move(licences));
}

ControlPanel::~ControlPanel() {
    if (log_timer_) KillTimer(hwnd(), 7);
    if (edit_font_) DeleteObject(edit_font_);
    if (edit_brush_) DeleteObject(edit_brush_);
}

void ControlPanel::open(Section section) {
    if (!visible()) {
        // Centred on the screen with the pointer, at a size that shows Status
        // without scrolling.
        POINT p;
        GetCursorPos(&p);
        HMONITOR monitor = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        MONITORINFO info{sizeof info};
        GetMonitorInfoW(monitor, &info);
        const float s = scale_for_point(p);
        const float w = 900, h = 640;
        const int x = (info.rcWork.left + info.rcWork.right) / 2 - static_cast<int>(w * s / 2);
        const int y = (info.rcWork.top + info.rcWork.bottom) / 2 - static_cast<int>(h * s / 2);
        place(x, y, w, h);
    }
    show(true);
    ShowWindow(hwnd(), SW_RESTORE);
    SetForegroundWindow(hwnd());
    select(section);
}

void ControlPanel::refresh() {
    if (visible()) rebuild();
}

void ControlPanel::install_progress(const std::string& kind, const Install& progress) {
    installs_[kind] = progress;
    if (visible() && section_ == Section::models) rebuild();
}

void ControlPanel::select(Section s) {
    // Unsaved words are saved on the way out rather than lost.
    if (section_ == Section::words && s != Section::words) {
        const int n = GetWindowTextLengthW(words_edit_);
        std::wstring text(static_cast<size_t>(n) + 1, L'\0');
        GetWindowTextW(words_edit_, text.data(), n + 1);
        text.resize(static_cast<size_t>(n));
        if (!text.empty()) {
            std::ofstream(speech::vocabulary::file(), std::ios::binary) << app::narrow(text);
        }
    }
    const bool entering = section_ != s;
    section_ = s;
    scroll_ = 0;
    if (entering && s == Section::words) {
        const auto file = speech::vocabulary::create_file_if_needed();
        auto text = read_file(file);
        // EDIT wants CRLF.
        std::wstring crlf;
        for (wchar_t c : text) {
            if (c == L'\n') crlf += L"\r\n";
            else if (c != L'\r') crlf.push_back(c);
        }
        SetWindowTextW(words_edit_, crlf.c_str());
    }
    for (size_t i = 0; i < 5; ++i) {
        auto& b = sidebar_.items()[i];
        b.emphasis = static_cast<int>(i) == static_cast<int>(s) ? Button::Emphasis::secondary : Button::Emphasis::plain;
    }
    if (s == Section::diagnostics) {
        if (!log_timer_) log_timer_ = SetTimer(hwnd(), 7, 1000, nullptr);
    } else if (log_timer_) {
        KillTimer(hwnd(), 7);
        log_timer_ = 0;
    }
    rebuild();
}

void ControlPanel::rebuild() {
    content_.clear();
    labels_.clear();
    dots_.clear();
    bars_.clear();
    panels_.clear();
    words_rect_ = log_rect_ = {};

    float y = top;
    labels_.push_back({section_title(section_), Font::heading, colour::ink, content_left, y, 500});
    y += 34;
    switch (section_) {
    case Section::status:      y = build_status(y); break;
    case Section::models:      y = build_models(y); break;
    case Section::voices:      y = build_voices(y); break;
    case Section::words:       y = build_words(y); break;
    case Section::diagnostics: y = build_diagnostics(y); break;
    }
    content_height_ = y + top;
    scroll_ = std::clamp(scroll_, 0.f, std::max(0.f, content_height_ - height_));
    layout_children();
    invalidate();
}

void ControlPanel::layout_children() {
    auto place_edit = [&](HWND edit, const D2D1_RECT_F& r) {
        const bool show = r.right > r.left;
        ShowWindow(edit, show ? SW_SHOWNA : SW_HIDE);
        if (!show) return;
        MoveWindow(edit, static_cast<int>((r.left + 6) * scale_), static_cast<int>((r.top + 6 - scroll_) * scale_),
                   static_cast<int>((r.right - r.left - 12) * scale_), static_cast<int>((r.bottom - r.top - 12) * scale_),
                   TRUE);
    };
    place_edit(words_edit_, words_rect_);
    place_edit(log_edit_, log_rect_);
}

// --- Status ---------------------------------------------------------------------------

float ControlPanel::build_status(float y) {
    const float w = width_ - content_left - 24;
    labels_.push_back({L"Checked passively: nothing is started to find out. Test runs the feature for real.",
                       Font::caption, colour::ink_muted, content_left, y, w});
    y += 26;

    // Switches that used to live only in the menu.
    std::vector<Button*> row;
    Button live;
    const bool on = host_.live_enabled && host_.live_enabled();
    live.label = on ? L"Underline as I type: on" : L"Underline as I type: off";
    live.mark = on ? colour::accept : colour::ink_muted;
    live.on_click = [this, on] {
        if (host_.set_live) host_.set_live(!on);
        rebuild();
    };
    Button login;
    const bool starts = host_.login_enabled && host_.login_enabled();
    login.label = starts ? L"Start at sign-in: on" : L"Start at sign-in: off";
    login.mark = starts ? colour::accept : colour::ink_muted;
    login.on_click = [this, starts] {
        if (host_.set_login) host_.set_login(!starts);
        rebuild();
    };
    Button memory;
    memory.label = L"Free memory";
    memory.emphasis = Button::Emphasis::plain;
    memory.on_click = [this] {
        if (host_.free_memory) host_.free_memory();
        app::after(500, [this] { rebuild(); });
    };
    row.push_back(&content_.add(std::move(live)));
    row.push_back(&content_.add(std::move(login)));
    row.push_back(&content_.add(std::move(memory)));
    const float right = Buttons::row(row, content_left, y, 8);
    if (host_.footprint) labels_.push_back({host_.footprint(), Font::caption, colour::ink_muted, right + 12, y + 4, w});
    y += metric::control + 16;

    const auto context = host_.health ? host_.health() : app::HealthContext{};
    for (const auto& r : app::health_report(context)) {
        const float card_top = y;
        float cy = y + 12;
        dots_.push_back({content_left + 18, cy + 9, state_colour(r.state)});
        labels_.push_back({app::title(r.feature), Font::row_title, colour::ink, content_left + 32, cy, 240});
        labels_.push_back({r.detail, Font::caption, colour::ink_muted, content_left + 280, cy + 2, w - 300, 1});
        cy += 22;
        labels_.push_back({app::purpose(r.feature), Font::caption, colour::ink_muted, content_left + 32, cy, w - 50});
        cy += 18;
        if (!r.reason.empty()) {
            const auto t = layout(r.reason, Font::caption, w - 50);
            labels_.push_back({r.reason, Font::caption, colour::ink, content_left + 32, cy, w - 50});
            cy += t.height + 4;
        }
        if (!r.fix.empty()) {
            const std::wstring fix = L"What to do: " + r.fix;
            const auto t = layout(fix, Font::caption, w - 50);
            labels_.push_back({fix, Font::caption, colour::accept, content_left + 32, cy, w - 50});
            cy += t.height + 4;
        }
        if (const auto it = test_results_.find(r.feature); it != test_results_.end()) {
            const auto t = layout(it->second, Font::caption, w - 50);
            labels_.push_back({it->second, Font::caption, colour::slate, content_left + 32, cy, w - 50});
            cy += t.height + 4;
        }
        std::vector<Button*> actions;
        const auto feature = r.feature;
        if (feature != app::Feature::text_access) {
            Button test;
            test.label = L"Test";
            test.on_click = [this, feature] {
                test_results_[feature] = L"Testing…";
                rebuild();
                if (host_.test) {
                    host_.test(feature, [this, feature](std::wstring result) {
                        test_results_[feature] = std::move(result);
                        rebuild();
                    });
                }
            };
            actions.push_back(&content_.add(std::move(test)));
        }
        if (r.restartable && host_.restart) {
            Button restart;
            restart.label = L"Restart";
            restart.on_click = [this, feature] {
                test_results_[feature] = host_.restart(feature);
                rebuild();
            };
            actions.push_back(&content_.add(std::move(restart)));
        }
        if (r.state == app::HealthState::broken
            && (feature == app::Feature::rewrite || feature == app::Feature::dictation || feature == app::Feature::speech)) {
            Button setup;
            setup.label = L"Open setup";
            setup.emphasis = Button::Emphasis::primary;
            setup.tint = colour::accept;
            setup.on_click = [this, feature] {
                if (host_.open_setup) host_.open_setup(feature);
            };
            actions.push_back(&content_.add(std::move(setup)));
        }
        if (!actions.empty()) {
            cy += 4;
            Buttons::row(actions, content_left + 32, cy, 6);
            cy += metric::control;
        }
        y = cy + 12;
        panels_.push_back({{content_left, card_top, content_left + w, y}});
        y += 8;
    }
    Button restart_app;
    restart_app.label = L"Restart nib";
    restart_app.emphasis = Button::Emphasis::plain;
    restart_app.on_click = [this] {
        if (host_.restart_app) host_.restart_app();
    };
    auto& b = content_.add(std::move(restart_app));
    b.rect = {content_left, y, content_left + b.natural_width(), y + metric::control};
    return y + metric::control;
}

// --- Models ---------------------------------------------------------------------------

void ControlPanel::model_rows(const std::string& kind, const std::vector<CatalogModel>& list, float& y) {
    const float w = width_ - content_left - 24;
    const auto active = host_.active ? host_.active(kind) : std::nullopt;
    const auto install = installs_.find(kind);
    const bool busy = install != installs_.end() && install->second.busy;

    for (const auto& m : list) {
        const float card_top = y;
        float cy = y + 12;
        std::error_code ec;
        std::filesystem::path dir = kind == "rewrite"     ? model_catalog::install_directory()
                                    : kind == "dictation" ? speech::whisper_catalog::install_directory()
                                                          : speech::voice_catalog::install_directory();
        const auto path = dir / std::filesystem::u8path(m.filename);
        const bool installed = std::filesystem::is_regular_file(path, ec);
        const bool in_use = installed && active && std::filesystem::equivalent(*active, path, ec);

        dots_.push_back({content_left + 18, cy + 9, installed ? colour::accept : colour::ink_muted});
        labels_.push_back({app::wide(m.title), Font::row_title, colour::ink, content_left + 32, cy, 260});
        labels_.push_back({app::wide(m.size_label()) + (in_use ? L" · in use" : installed ? L" · installed" : L""),
                           Font::caption, in_use ? colour::accept : colour::ink_muted, content_left + 300, cy + 2, 300});
        cy += 22;
        const auto detail = layout(app::wide(m.detail), Font::caption, w - 50);
        labels_.push_back({app::wide(m.detail), Font::caption, colour::ink_muted, content_left + 32, cy, w - 50});
        cy += detail.height + 8;

        std::vector<Button*> actions;
        if (!installed) {
            Button get;
            get.label = L"Download";
            get.emphasis = Button::Emphasis::primary;
            get.tint = colour::accept;
            get.enabled = !busy;
            get.on_click = [this, kind, m] {
                if (host_.install) host_.install(kind, m);
            };
            actions.push_back(&content_.add(std::move(get)));
        } else {
            if (!in_use && kind != "voice") {
                Button use;
                use.label = L"Use";
                use.on_click = [this, kind, path] {
                    if (host_.use) host_.use(kind, path);
                    rebuild();
                };
                actions.push_back(&content_.add(std::move(use)));
            }
            Button remove;
            remove.label = L"Remove";
            remove.emphasis = Button::Emphasis::plain;
            remove.on_click = [this, kind, path, m] {
                if (ask(hwnd(), L"nib", L"Remove " + app::wide(m.title) + L"?",
                        L"The file is deleted. It can be downloaded again from here.", {L"Remove", L"Keep"}, true)
                    == 0) {
                    if (host_.remove) host_.remove(kind, path);
                    rebuild();
                }
            };
            actions.push_back(&content_.add(std::move(remove)));
        }
        Buttons::row(actions, content_left + 32, cy, 6);
        cy += metric::control;
        y = cy + 12;
        panels_.push_back({{content_left, card_top, content_left + w, y}});
        y += 8;
    }

    if (install != installs_.end() && !install->second.stage.empty()) {
        const auto& p = install->second;
        labels_.push_back({p.stage + (p.message.empty() ? L"" : L": " + p.message), Font::caption,
                           p.stage == L"failed" ? colour::correction : colour::ink, content_left, y, w});
        y += 20;
        if (p.busy) {
            bars_.push_back({{content_left, y, content_left + w - 90, y + 6}, p.fraction});
            Button cancel;
            cancel.label = L"Cancel";
            cancel.emphasis = Button::Emphasis::plain;
            cancel.on_click = [this, kind] {
                if (host_.cancel_install) host_.cancel_install(kind);
            };
            auto& b = content_.add(std::move(cancel));
            b.rect = {content_left + w - 80, y - 9, content_left + w, y - 9 + metric::control};
            y += 22;
        }
    }
}

float ControlPanel::build_models(float y) {
    const float w = width_ - content_left - 24;
    const std::wstring intro = L"Everything runs on this machine. Models are downloaded once, into "
                               + platform::paths::data_dir().wstring() + L", and nothing is ever uploaded.";
    labels_.push_back({intro, Font::caption, colour::ink_muted, content_left, y, w});
    y += layout(intro, Font::caption, w).height + 16;

    labels_.push_back({L"Rewrite", Font::row_title, colour::ink, content_left, y, w});
    y += 26;
    std::vector<CatalogModel> rewrite = model_catalog::all();
    // Anything else dropped into the folder is listed too: nib is not limited
    // to its own catalogue.
    std::error_code ec;
    for (const auto& e : std::filesystem::directory_iterator(model_catalog::install_directory(), ec)) {
        const auto name = e.path().filename().string();
        if (e.path().extension() != ".gguf" || name.empty() || name[0] == '.') continue;
        const bool known = std::any_of(rewrite.begin(), rewrite.end(), [&](const CatalogModel& m) { return m.filename == name; });
        if (!known) rewrite.push_back(model_catalog::local(e.path()));
    }
    model_rows("rewrite", rewrite, y);
    Button choose;
    choose.label = L"Choose File…";
    choose.emphasis = Button::Emphasis::plain;
    choose.on_click = [this] {
        const auto file = choose_file(hwnd(), L"Choose a GGUF model", L"GGUF models", L"gguf");
        if (!file.empty() && host_.install) host_.install("rewrite", model_catalog::local(file));
    };
    auto& c = content_.add(std::move(choose));
    c.rect = {content_left, y, content_left + c.natural_width(), y + metric::control};
    y += metric::control + 24;

    // The row this section exists for: a missing whisper model is silent --
    // the key fires and nothing happens -- and looks like a dead microphone.
    labels_.push_back({L"Dictation", Font::row_title, colour::ink, content_left, y, w});
    y += 26;
    model_rows("dictation", speech::whisper_catalog::all(), y);
    y += 16;

    labels_.push_back({L"Voice", Font::row_title, colour::ink, content_left, y, w});
    y += 26;
    auto voice = speech::voice_catalog::models();
    voice.push_back(speech::voice_catalog::voice_pack());
    model_rows("voice", voice, y);
    return y;
}

// --- Voices ---------------------------------------------------------------------------

float ControlPanel::build_voices(float y) {
    const float w = width_ - content_left - 24;
    if (!speech::voice_catalog::installed()) {
        labels_.push_back({L"The voice is not downloaded yet: the Kokoro model (326 MB) and the voice pack (28 MB).",
                           Font::body, colour::ink, content_left, y, w});
        y += 30;
        Button go;
        go.label = L"Open Models";
        go.emphasis = Button::Emphasis::primary;
        go.tint = colour::accept;
        go.on_click = [this] { select(Section::models); };
        auto& b = content_.add(std::move(go));
        b.rect = {content_left, y, content_left + b.natural_width(), y + metric::control};
        return y + metric::control;
    }
    const auto current = host_.voice ? host_.voice() : std::string();
    const std::wstring intro = L"Select text anywhere and press Ctrl+Alt+N to hear it; Ctrl+Alt+H stops. With nothing "
                               L"selected, the clipboard is read.";
    labels_.push_back({intro, Font::caption, colour::ink_muted, content_left, y, w});
    y += layout(intro, Font::caption, w).height + 12;
    Button preview;
    preview.label = L"Preview voice";
    preview.mark = colour::rewrite;
    preview.on_click = [this, current] {
        if (host_.preview_voice) host_.preview_voice(current);
    };
    auto& p = content_.add(std::move(preview));
    p.rect = {content_left, y, content_left + p.natural_width(), y + metric::control};
    labels_.push_back({L"Current: " + app::wide(speech::voice_catalog::title(current)), Font::caption, colour::ink,
                       p.rect.right + 12, y + 4, w});
    y += metric::control + 16;

    const auto voices = host_.voices ? host_.voices() : std::vector<std::string>{};
    std::u16string last;
    float x = content_left;
    for (const auto& v : voices) {
        const auto accent = speech::voice_catalog::accent(v);
        if (accent != last) {
            if (!last.empty()) y += metric::control + 12;
            labels_.push_back({app::wide(accent), Font::title, colour::ink_muted, content_left, y, w});
            y += 22;
            x = content_left;
            last = accent;
        }
        Button b;
        auto title = speech::voice_catalog::title(v);
        const auto dash = title.find(u" —");
        b.label = app::wide(dash == std::u16string::npos ? title : title.substr(0, dash)) + (v[1] == 'f' ? L" ♀" : L" ♂");
        b.emphasis = v == current ? Button::Emphasis::primary : Button::Emphasis::secondary;
        b.tint = colour::taupe;
        b.on_click = [this, v] {
            if (host_.set_voice) host_.set_voice(v);
            rebuild();
        };
        const float bw = std::max(b.natural_width(), 96.f);
        if (x + bw > content_left + w) {
            x = content_left;
            y += metric::control + 6;
        }
        b.rect = {x, y, x + bw, y + metric::control};
        content_.add(std::move(b));
        x += bw + 6;
    }
    return y + metric::control;
}

// --- Dictation words ------------------------------------------------------------------

float ControlPanel::build_words(float y) {
    const float w = width_ - content_left - 24;
    const std::wstring intro =
        L"Whisper replaces any name it has never seen with the nearest real word -- \"Hasura\" arrives as "
        L"\"Azure\" until it is listed here. One per line. Keep it short: a nudge, not a dictionary.";
    labels_.push_back({intro, Font::caption, colour::ink_muted, content_left, y, w});
    y += layout(intro, Font::caption, w).height + 12;
    words_rect_ = {content_left, y, content_left + w, y + 220};
    panels_.push_back({words_rect_});
    y += 228;
    Button save;
    save.label = L"Save";
    save.emphasis = Button::Emphasis::primary;
    save.tint = colour::accept;
    save.on_click = [this] {
        const int n = GetWindowTextLengthW(words_edit_);
        std::wstring text(static_cast<size_t>(n) + 1, L'\0');
        GetWindowTextW(words_edit_, text.data(), n + 1);
        text.resize(static_cast<size_t>(n));
        std::wstring lf;
        for (wchar_t c : text) {
            if (c != L'\r') lf.push_back(c);
        }
        std::ofstream(speech::vocabulary::file(), std::ios::binary) << app::narrow(lf);
        probe_output_ = L"Saved. Applies to the next thing you dictate.";
        rebuild();
    };
    Button reset;
    reset.label = L"Defaults";
    reset.emphasis = Button::Emphasis::plain;
    reset.on_click = [this] {
        std::u16string body = speech::vocabulary::file_header();
        for (const auto& t : speech::vocabulary::defaults()) body += t + u"\n";
        std::wstring crlf;
        for (char16_t c : body) {
            if (c == u'\n') crlf += L"\r\n";
            else crlf.push_back(static_cast<wchar_t>(c));
        }
        SetWindowTextW(words_edit_, crlf.c_str());
    };
    std::vector<Button*> row{&content_.add(std::move(save)), &content_.add(std::move(reset))};
    const float right = Buttons::row(row, content_left, y, 6);
    if (!probe_output_.empty()) labels_.push_back({probe_output_, Font::caption, colour::accept, right + 12, y + 4, w});
    y += metric::control + 24;

    // Recent dictation: a transcript that landed in the wrong window is not lost.
    labels_.push_back({L"Recent dictation", Font::row_title, colour::ink, content_left, y, w});
    y += 26;
    const auto history = host_.history ? host_.history() : std::vector<std::pair<std::u16string, int64_t>>{};
    if (history.empty()) {
        labels_.push_back({L"Nothing yet. The last hundred dictations are kept here, on this machine only.",
                           Font::caption, colour::ink_muted, content_left, y, w});
        y += 20;
    }
    for (size_t i = 0; i < history.size() && i < 15; ++i) {
        const auto& [text, at] = history[i];
        const speech::DictationHistory::Entry entry{text, at};
        labels_.push_back({when(at), Font::caption, colour::ink_muted, content_left, y + 4, 90, 1});
        labels_.push_back({app::wide(entry.label(80)), Font::caption, colour::ink, content_left + 96, y + 4, w - 180, 1});
        Button copy;
        copy.label = L"Copy";
        copy.emphasis = Button::Emphasis::plain;
        copy.on_click = [this, text] {
            if (host_.copy) host_.copy(text);
        };
        auto& b = content_.add(std::move(copy));
        b.rect = {content_left + w - 70, y, content_left + w, y + metric::control};
        y += metric::control + 4;
    }
    if (!history.empty()) {
        Button clear;
        clear.label = L"Clear history";
        clear.emphasis = Button::Emphasis::plain;
        clear.on_click = [this] {
            if (host_.clear_history) host_.clear_history();
            rebuild();
        };
        auto& b = content_.add(std::move(clear));
        b.rect = {content_left, y + 6, content_left + b.natural_width(), y + 6 + metric::control};
        y += metric::control + 6;
    }
    return y;
}

// --- Diagnostics ------------------------------------------------------------------------

float ControlPanel::build_diagnostics(float y) {
    const float w = width_ - content_left - 24;
    labels_.push_back({L"Each probe does the real work for one part and reports what it saw.", Font::caption,
                       colour::ink_muted, content_left, y, w});
    y += 26;

    std::vector<Button*> row;
    auto probe = [&](const wchar_t* label, std::function<void()> run) {
        Button b;
        b.label = label;
        b.on_click = std::move(run);
        row.push_back(&content_.add(std::move(b)));
    };
    auto feature_test = [this](app::Feature f) {
        return [this, f] {
            probe_output_ = std::wstring(app::title(f)) + L": testing…";
            rebuild();
            if (host_.test) {
                host_.test(f, [this, f](std::wstring result) {
                    probe_output_ = std::wstring(app::title(f)) + L": " + result;
                    rebuild();
                });
            }
        };
    };
    probe(L"Grammar", feature_test(app::Feature::grammar));
    probe(L"Rewrite", feature_test(app::Feature::rewrite));
    probe(L"Dictation", feature_test(app::Feature::dictation));
    probe(L"Speech", feature_test(app::Feature::speech));
    probe(L"Focused field", [this] {
        probe_output_ = L"Click into the field to check. Reading it in 5 seconds…";
        rebuild();
        if (host_.probe_field) {
            host_.probe_field([this](std::wstring report) {
                probe_output_ = std::move(report);
                rebuild();
            });
        }
    });
    probe(L"Live checking", [this] {
        probe_output_ = host_.live_report ? host_.live_report() : L"";
        rebuild();
    });
    Buttons::row(row, content_left, y, 6);
    y += metric::control + 12;

    if (!probe_output_.empty()) {
        const auto t = layout(probe_output_, Font::mono, w - 24);
        panels_.push_back({{content_left, y, content_left + w, y + t.height + 20}});
        labels_.push_back({probe_output_, Font::mono, colour::ink, content_left + 12, y + 10, w - 24});
        y += t.height + 28;
    }

    std::vector<Button*> logs;
    Button file;
    const bool on = log::file_enabled();
    file.label = on ? L"Log to file: on" : L"Log to file: off";
    file.mark = on ? colour::accept : colour::ink_muted;
    file.on_click = [this, on] {
        log::set_file_enabled(!on);
        rebuild();
    };
    Button copy;
    copy.label = L"Copy report";
    copy.emphasis = Button::Emphasis::primary;
    copy.tint = colour::clarity;
    copy.on_click = [this] {
        if (host_.diagnostic_report && host_.copy) {
            host_.copy(app::u16(host_.diagnostic_report()));
            probe_output_ = L"Report copied. It holds versions, states, models and recent log lines -- never your "
                            L"text.";
            rebuild();
        }
    };
    Button folder;
    folder.label = L"Open data folder";
    folder.emphasis = Button::Emphasis::plain;
    folder.on_click = [] { ui::open(platform::paths::data_dir().wstring()); };
    logs.push_back(&content_.add(std::move(file)));
    logs.push_back(&content_.add(std::move(copy)));
    logs.push_back(&content_.add(std::move(folder)));
    Buttons::row(logs, content_left, y, 6);
    y += metric::control + 10;

    labels_.push_back({L"Recent log -- lengths and counts only, never field text.", Font::caption, colour::ink_muted,
                       content_left, y, w});
    y += 20;
    log_rect_ = {content_left, y, content_left + w, y + 230};
    panels_.push_back({log_rect_});
    std::wstring text;
    for (const auto& line : log::recent()) text += app::widen(line) + L"\r\n";
    SetWindowTextW(log_edit_, text.c_str());
    SendMessageW(log_edit_, EM_LINESCROLL, 0, 100000);
    return y + 238;
}

// --- Painting and input ---------------------------------------------------------------------

void ControlPanel::paint(ID2D1RenderTarget* rt) {
    // The sidebar on the aurora; the content on the plain ground.
    aurora(rt, {0, 0, sidebar_width, height_}, 0);
    layout(L"nib", Font::heading).draw(rt, 24, top, colour::ink);
    layout(L"offline writing assistant", Font::caption).draw(rt, 24, top + 26, colour::ink_muted);
    sidebar_.draw(rt);
    layout(L"Version " NIB_VERSION_W, Font::caption).draw(rt, 24, height_ - 30, colour::ink_muted);

    rt->PushAxisAlignedClip({sidebar_width, 0, width_, height_}, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    D2D1_MATRIX_3X2_F base;
    rt->GetTransform(&base);
    rt->SetTransform(D2D1::Matrix3x2F::Translation(0, -scroll_) * base);
    for (const auto& p : panels_) {
        fill_round(rt, p.rect, metric::radius_window, colour::control_fill(0.04f));
        stroke_round(rt, p.rect, metric::radius_window, colour::rule);
    }
    for (const auto& d : dots_) fill_round(rt, {d.x - 5, d.y - 5, d.x + 5, d.y + 5}, 5, d.colour);
    for (const auto& l : labels_) layout(l.text, l.font, l.width, l.max_lines).draw(rt, l.x, l.y, l.colour);
    for (const auto& b : bars_) {
        fill_round(rt, b.rect, 3, colour::control_fill(0.12f));
        D2D1_RECT_F done = b.rect;
        done.right = b.rect.left + static_cast<float>((b.rect.right - b.rect.left) * std::clamp(b.fraction, 0.0, 1.0));
        fill_round(rt, done, 3, colour::accept);
    }
    content_.draw(rt);
    rt->SetTransform(base);
    rt->PopAxisAlignedClip();
}

void ControlPanel::on_mouse_move(float x, float y) {
    bool changed = sidebar_.hover(x, y);
    changed |= content_.hover(x, x > sidebar_width ? y + scroll_ : -1000);
    if (changed) invalidate();
}

void ControlPanel::on_mouse_down(float x, float y) {
    bool changed = sidebar_.down(x, y);
    changed |= content_.down(x, x > sidebar_width ? y + scroll_ : -1000);
    if (changed) invalidate();
}

void ControlPanel::on_mouse_up(float x, float y) {
    // Either list may be rebuilt by its handler; each fires at most one.
    if (sidebar_.up(x, y)) {
        invalidate();
        return;
    }
    if (content_.up(x, x > sidebar_width ? y + scroll_ : -1000)) invalidate();
}

void ControlPanel::on_mouse_leave() {
    bool changed = sidebar_.leave();
    changed |= content_.leave();
    if (changed) invalidate();
}

void ControlPanel::on_wheel(float delta) {
    const float limit = std::max(0.f, content_height_ - height_);
    scroll_ = std::clamp(scroll_ - delta * 60, 0.f, limit);
    layout_children();
    invalidate();
}

void ControlPanel::on_resized() {
    if (visible()) rebuild();
}

LRESULT ControlPanel::on_message(UINT msg, WPARAM wp, LPARAM lp, bool& handled) {
    handled = false;
    if (msg == WM_CTLCOLOREDIT || msg == WM_CTLCOLORSTATIC) {
        HDC dc = reinterpret_cast<HDC>(wp);
        SetTextColor(dc, colour::ink.colorref());
        SetBkColor(dc, colour::field.colorref());
        handled = true;
        return reinterpret_cast<LRESULT>(edit_brush_);
    }
    if (msg == WM_TIMER && wp == 7) {
        if (section_ == Section::diagnostics && visible()) {
            std::wstring text;
            for (const auto& line : log::recent()) text += app::widen(line) + L"\r\n";
            const int n = GetWindowTextLengthW(log_edit_);
            if (static_cast<size_t>(n) != text.size()) {
                SetWindowTextW(log_edit_, text.c_str());
                SendMessageW(log_edit_, EM_LINESCROLL, 0, 100000);
            }
        }
        handled = true;
        return 0;
    }
    (void)lp;
    return 0;
}

}  // namespace nib::ui

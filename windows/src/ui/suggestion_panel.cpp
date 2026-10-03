#include "ui/suggestion_panel.hpp"

#include <commctrl.h>
#include <richedit.h>

#include <algorithm>
#include "app/dispatch.hpp"
#include "lint/edit_planner.hpp"

namespace nib::ui {
namespace {

constexpr float panel_width = 470;
constexpr float max_text_height = 128;
constexpr float min_text_height = 24;
constexpr float row_height = 26;
constexpr size_t max_visible_rows = 4;
constexpr float field_inset = 6;

Colour mode_tint(RewriteMode mode) {
    switch (mode) {
    case RewriteMode::fix_grammar: return colour::fix;
    case RewriteMode::clearer:     return colour::rewrite;
    case RewriteMode::shorter:     return colour::condense;
    case RewriteMode::native:      return colour::clarity;
    }
    return colour::ink;
}

COLORREF blend(Colour over, float alpha, Colour under) {
    const float r = over.r * alpha + under.r * (1 - alpha);
    const float g = over.g * alpha + under.g * (1 - alpha);
    const float b = over.b * alpha + under.b * (1 - alpha);
    return RGB(static_cast<int>(r * 255), static_cast<int>(g * 255), static_cast<int>(b * 255));
}

}  // namespace

SuggestionPanel::SuggestionPanel() : Surface(Kind::window) {
    LoadLibraryW(L"Msftedit.dll");
    create(L"nib", WS_POPUP);
    field_brush_ = CreateSolidBrush(colour::field.colorref());

    edit_ = CreateWindowExW(0, MSFTEDIT_CLASS, L"",
                            WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL | ES_NOHIDESEL,
                            0, 0, 100, 24, hwnd(), nullptr, GetModuleHandleW(nullptr), nullptr);
    SendMessageW(edit_, EM_SETBKGNDCOLOR, 0, colour::field.colorref());
    SendMessageW(edit_, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE | ENM_CHANGE);
    // Rich, not plain: plain-text mode holds one format for the whole text,
    // and the marks need a format per range. Ctrl+V pastes plain text (the
    // subclass below).
    SendMessageW(edit_, EM_SETTEXTMODE, TM_RICHTEXT | TM_MULTILEVELUNDO, 0);
    SendMessageW(edit_, EM_SETTYPOGRAPHYOPTIONS, TO_ADVANCEDTYPOGRAPHY, TO_ADVANCEDTYPOGRAPHY);
    SetWindowSubclass(edit_, edit_proc, 1, reinterpret_cast<DWORD_PTR>(this));
}

SuggestionPanel::~SuggestionPanel() {
    if (font_) DeleteObject(font_);
    if (field_brush_) DeleteObject(field_brush_);
}

void SuggestionPanel::present(const std::u16string& text, POINT anchor, Callbacks callbacks) {
    callbacks_ = std::move(callbacks);
    before_rewrite_.reset();
    suggestions_.clear();
    rewriting_ = false;

    scale_ = scale_for_point(anchor);
    if (font_) DeleteObject(font_);
    font_ = CreateFontW(-static_cast<int>(14 * scale_), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                        DEFAULT_PITCH, L"Georgia");
    SendMessageW(edit_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    set_text(text);
    set_status(L"checking", colour::ink_muted, true);

    // Near the pointer, kept on screen.
    HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    relayout();
    const int w = static_cast<int>(width_ * scale_), h = static_cast<int>(height_ * scale_);
    int x = anchor.x - static_cast<int>(20 * scale_);
    int y = anchor.y + static_cast<int>(20 * scale_);
    const RECT& work = info.rcWork;
    x = std::clamp(x, static_cast<int>(work.left + 8), static_cast<int>(work.right - w - 8));
    if (y + h > work.bottom - 8) y = anchor.y - h - static_cast<int>(20 * scale_);
    y = std::clamp(y, static_cast<int>(work.top + 8), static_cast<int>(work.bottom - h - 8));
    place(x, y, width_, height_);
    show(true);
    SetFocus(edit_);
    // Caret at the end, nothing selected: a selection would hide the marks.
    SendMessageW(edit_, EM_SETSEL, -1, -1);
}

std::u16string SuggestionPanel::current_text() const {
    const int n = GetWindowTextLengthW(edit_);
    std::wstring w(static_cast<size_t>(n) + 1, L'\0');
    GetWindowTextW(edit_, w.data(), n + 1);
    w.resize(static_cast<size_t>(n));
    // RichEdit stores line breaks as \r; nib's text uses \n.
    for (auto& c : w) {
        if (c == L'\r') c = L'\n';
    }
    return app::u16(w);
}

void SuggestionPanel::set_text(const std::u16string& text) {
    std::wstring w = app::wide(text);
    SendMessageW(edit_, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE);
    SetWindowTextW(edit_, w.c_str());

    CHARFORMAT2W cf{};
    cf.cbSize = sizeof cf;
    cf.dwMask = CFM_COLOR | CFM_BACKCOLOR | CFM_UNDERLINETYPE | CFM_UNDERLINE;
    cf.crTextColor = colour::ink.colorref();
    cf.crBackColor = colour::field.colorref();
    cf.dwEffects = 0;
    SendMessageW(edit_, EM_SETCHARFORMAT, SCF_ALL, reinterpret_cast<LPARAM>(&cf));
    SendMessageW(edit_, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE | ENM_CHANGE);
    SendMessageW(edit_, EM_REQUESTRESIZE, 0, 0);
}

void SuggestionPanel::decorate() {
    SendMessageW(edit_, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE);
    CHARRANGE saved{};
    SendMessageW(edit_, EM_EXGETSEL, 0, reinterpret_cast<LPARAM>(&saved));

    CHARFORMAT2W plain{};
    plain.cbSize = sizeof plain;
    plain.dwMask = CFM_BACKCOLOR | CFM_UNDERLINETYPE | CFM_UNDERLINE | CFM_COLOR;
    plain.crBackColor = colour::field.colorref();
    plain.crTextColor = colour::ink.colorref();
    SendMessageW(edit_, EM_SETCHARFORMAT, SCF_ALL, reinterpret_cast<LPARAM>(&plain));

    const auto text = current_text();
    for (const auto& s : suggestions_) {
        if (range_end(s.range) > static_cast<int32_t>(text.size())) continue;
        CHARRANGE r{s.range.location, range_end(s.range)};
        SendMessageW(edit_, EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&r));
        CHARFORMAT2W cf{};
        cf.cbSize = sizeof cf;
        cf.dwMask = CFM_BACKCOLOR | CFM_UNDERLINETYPE | CFM_UNDERLINE | CFM_COLOR;
        cf.dwEffects = CFE_UNDERLINE;
        const bool correction = s.kind == SuggestionKind::correction;
        // The flagged words take the mark's colour, and a wave under them in
        // the same colour: RichEdit draws an underline in the text colour.
        const Colour tint = correction ? colour::correction : colour::clarity;
        cf.bUnderlineType = CFU_UNDERLINEWAVE;
        cf.crTextColor = tint.colorref();
        cf.crBackColor = blend(tint, 0.16f, colour::field);
        SendMessageW(edit_, EM_SETCHARFORMAT, SCF_SELECTION, reinterpret_cast<LPARAM>(&cf));
    }
    SendMessageW(edit_, EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&saved));
    SendMessageW(edit_, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE | ENM_CHANGE);
}

void SuggestionPanel::set_status(std::wstring text, Colour tint, bool busy) {
    status_ = std::move(text);
    status_tint_ = tint;
    busy_ = busy;
    invalidate();
}

void SuggestionPanel::show_found(std::vector<Suggestion> found) {
    suggestions_ = std::move(found);
    decorate();
    if (suggestions_.empty()) {
        set_status(L"looks clean", colour::accept);
    } else {
        set_status(std::to_wstring(suggestions_.size()) + (suggestions_.size() == 1 ? L" issue" : L" issues"),
                   colour::correction);
    }
    relayout();

    if (!callbacks_.fill_fixes || suggestions_.empty()) return;
    std::vector<Suggestion> visible(suggestions_.begin(),
                                    suggestions_.begin() + std::min(max_visible_rows, suggestions_.size()));
    const auto text = current_text();
    callbacks_.fill_fixes(visible, text, [this, text](std::vector<Suggestion> filled) {
        // The text may have been edited while replacements were fetched.
        if (current_text() != text || suggestions_.size() < filled.size()) return;
        for (const auto& f : filled) {
            for (auto& s : suggestions_) {
                if (s.id == f.id) s.replacements = f.replacements;
            }
        }
        relayout();
    });
}

void SuggestionPanel::show_error(const std::wstring& message) {
    set_status(message, colour::warning);
}

void SuggestionPanel::dismiss() {
    if (!visible()) return;
    hide();
    if (callbacks_.closed) callbacks_.closed();
}

void SuggestionPanel::relayout() {
    width_ = panel_width;
    layout_controls();
    // Keep the top-left where it is; only the height follows the content.
    if (visible()) {
        const RECT r = screen_rect();
        place(r.left, r.top, width_, height_);
    }
    invalidate();
}

void SuggestionPanel::layout_controls() {
    const float content_w = panel_width - metric::edge * 2;
    float y = metric::edge + 20 + metric::row;

    // The editor: its own height, clamped tightly -- letting it take the slack
    // left a block of empty space under one line of text.
    const float th = std::clamp(text_height_, min_text_height, max_text_height);
    MoveWindow(edit_, static_cast<int>((metric::edge + field_inset) * scale_),
               static_cast<int>((y + field_inset) * scale_),
               static_cast<int>((content_w - field_inset * 2) * scale_), static_cast<int>(th * scale_), TRUE);
    ShowScrollBar(edit_, SB_VERT, text_height_ > max_text_height);
    y += th + field_inset * 2 + metric::row;

    buttons_.clear();
    mode_buttons_.clear();
    rows_top_ = y;

    // Fix rows.
    const auto text = current_text();
    const size_t shown = std::min(max_visible_rows, suggestions_.size());
    for (size_t i = 0; i < shown; ++i) {
        const auto& s = suggestions_[i];
        const auto word = layout(app::wide(s.excerpt(text).value_or(u"")), Font::control, 140);
        float x = metric::edge + std::min(word.width, 140.f) + 10 + 14;
        for (size_t k = 0; k < s.replacements.size() && k < 2; ++k) {
            Button b;
            b.label = app::wide(s.replacements[k]);
            b.emphasis = Button::Emphasis::secondary;
            const float w = std::min(b.natural_width(), 150.f);
            b.rect = {x, y + 1, x + w, y + 1 + metric::control};
            const auto replacement = s.replacements[k];
            b.on_click = [this, i, replacement] { apply_fix(i, replacement); };
            buttons_.add(std::move(b));
            x += w + metric::tight;
        }
        y += row_height;
    }
    if (suggestions_.size() > max_visible_rows) y += 18;
    if (shown) y += metric::tight;

    // Actions.
    std::vector<Button*> left;
    for (auto mode : all_rewrite_modes) {
        Button b;
        b.label = rewrite_mode::short_title(mode) ? app::wide(rewrite_mode::short_title(mode)) : L"";
        b.mark = mode_tint(mode);
        b.enabled = !rewriting_;
        b.on_click = [this, mode] { run_rewrite(mode); };
        mode_buttons_.push_back(buttons_.items().size());
        buttons_.add(std::move(b));
    }
    if (before_rewrite_) {
        Button undo;
        undo.label = L"Undo";
        undo.emphasis = Button::Emphasis::plain;
        undo.on_click = [this] { undo_rewrite(); };
        buttons_.add(std::move(undo));
    }
    Button esc;
    esc.label = L"Esc";
    esc.emphasis = Button::Emphasis::plain;
    esc.on_click = [this] { dismiss(); };
    buttons_.add(std::move(esc));
    Button replace;
    replace.label = L"Replace";
    replace.emphasis = Button::Emphasis::primary;
    replace.tint = colour::clarity;
    replace.on_click = [this] { accept(); };
    buttons_.add(std::move(replace));

    // The modes on the left; Undo, Esc and Replace from the right edge in.
    auto& items = buttons_.items();
    for (size_t i : mode_buttons_) left.push_back(&items[i]);
    Buttons::row(left, metric::edge, y);
    float right = panel_width - metric::edge;
    for (size_t i = items.size(); i-- > mode_buttons_.back() + 1;) {
        const float w = items[i].natural_width();
        items[i].rect = {right - w, y, right, y + metric::control};
        right -= w + metric::tight;
    }
    y += metric::control + metric::edge;
    height_ = y;
}

void SuggestionPanel::paint(ID2D1RenderTarget* rt) {
    const D2D1_RECT_F all{0, 0, width_, height_};
    aurora(rt, all, metric::radius_window);

    layout(L"nib", Font::title).draw(rt, metric::edge, metric::edge + 2, colour::ink_muted);
    if (busy_) {
        layout(L"…", Font::title).draw(rt, metric::edge + 26, metric::edge + 2, colour::ink_muted);
    }
    if (!status_.empty()) draw_pill(rt, width_ - metric::edge, metric::edge, status_, status_tint_);

    // The field behind the editor.
    const float top = metric::edge + 20 + metric::row;
    const float th = std::clamp(text_height_, min_text_height, max_text_height);
    fill_round(rt, {metric::edge, top, width_ - metric::edge, top + th + field_inset * 2},
               metric::radius_control, colour::field);
    stroke_round(rt, {metric::edge, top, width_ - metric::edge, top + th + field_inset * 2},
                 metric::radius_control, colour::rule);

    // Rows.
    const auto text = current_text();
    float y = rows_top_;
    const size_t shown = std::min(max_visible_rows, suggestions_.size());
    if (shown) line(rt, {metric::edge, y - metric::row / 2}, {width_ - metric::edge, y - metric::row / 2}, colour::rule);
    for (size_t i = 0; i < shown; ++i) {
        const auto& s = suggestions_[i];
        const Colour tint = s.kind == SuggestionKind::correction ? colour::correction : colour::clarity;
        const auto word = layout(app::wide(s.excerpt(text).value_or(u"")), Font::control, 140, 1);
        word.draw(rt, metric::edge, y + (row_height - word.height) / 2, tint);
        const float after = metric::edge + std::min(word.width, 140.f) + 6;
        if (s.replacements.empty()) {
            const auto note = layout(app::wide(s.message), Font::caption, width_ - after - metric::edge, 1);
            note.draw(rt, after + 4, y + (row_height - note.height) / 2, colour::ink_muted);
        } else {
            const auto arrow = layout(L"→", Font::caption);
            arrow.draw(rt, after, y + (row_height - arrow.height) / 2, colour::ink_muted);
        }
        y += row_height;
    }
    if (suggestions_.size() > max_visible_rows) {
        layout(L"+" + std::to_wstring(suggestions_.size() - max_visible_rows) + L" more", Font::caption)
            .draw(rt, metric::edge, y, colour::ink_muted);
    }
    buttons_.draw(rt);
}

void SuggestionPanel::apply_fix(size_t index, const std::u16string& replacement) {
    if (index >= suggestions_.size()) return;
    const auto text = current_text();
    const auto s = suggestions_[index];
    const TextEdit edit{s.range, replacement, s.excerpt(text).value_or(u"")};
    const auto updated = edit_planner::apply(edit, text);
    if (!updated) return;

    // Through the edit control's own replace, so its undo history keeps it.
    SendMessageW(edit_, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE);
    CHARRANGE r{s.range.location, range_end(s.range)};
    SendMessageW(edit_, EM_EXSETSEL, 0, reinterpret_cast<LPARAM>(&r));
    const std::wstring w = app::wide(replacement);
    SendMessageW(edit_, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(w.c_str()));
    SendMessageW(edit_, EM_SETEVENTMASK, 0, ENM_REQUESTRESIZE | ENM_CHANGE);

    suggestions_ = edit_planner::prune_out_of_bounds(edit_planner::reanchor(suggestions_, edit), *updated);
    decorate();
    if (suggestions_.empty()) set_status(L"all fixed", colour::accept);
    else set_status(std::to_wstring(suggestions_.size()) + L" left", colour::correction);
    relayout();
}

void SuggestionPanel::run_rewrite(RewriteMode mode) {
    if (!callbacks_.rewrite || rewriting_) return;
    const auto input = current_text();
    bool blank = true;
    for (char16_t c : input) {
        if (c != u' ' && c != u'\n' && c != u'\t') blank = false;
    }
    if (blank) return;

    rewriting_ = true;
    std::wstring label = app::wide(rewrite_mode::short_title(mode));
    for (auto& c : label) c = static_cast<wchar_t>(towlower(c));
    set_status(label + L"…", colour::ink_muted, true);
    relayout();

    callbacks_.rewrite(input, mode, [this, input](RewriteResult result) {
        rewriting_ = false;
        if (!result.text || result.text->empty()) {
            set_status(result.error.empty() ? L"no suggestion" : app::wide(result.error), colour::warning);
            relayout();
            return;
        }
        if (*result.text == input) {
            set_status(L"nothing to change", colour::ink_muted);
            relayout();
            return;
        }
        before_rewrite_ = input;
        suggestions_.clear();
        set_text(*result.text);
        set_status(L"rewritten", colour::accept);
        relayout();
    });
}

void SuggestionPanel::undo_rewrite() {
    if (!before_rewrite_) return;
    set_text(*before_rewrite_);
    before_rewrite_.reset();
    suggestions_.clear();
    set_status(L"reverted", colour::ink_muted);
    relayout();
}

void SuggestionPanel::accept() {
    const auto text = current_text();
    auto apply = callbacks_.apply;
    hide();
    if (apply) apply(text);
    if (callbacks_.closed) callbacks_.closed();
}

void SuggestionPanel::on_mouse_move(float x, float y) {
    if (buttons_.hover(x, y)) invalidate();
}

void SuggestionPanel::on_mouse_down(float x, float y) {
    if (buttons_.down(x, y)) {
        invalidate();
        return;
    }
    // Dragging by the background moves the panel.
    ReleaseCapture();
    SendMessageW(hwnd(), WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

void SuggestionPanel::on_mouse_up(float x, float y) {
    if (buttons_.up(x, y)) invalidate();
}

void SuggestionPanel::on_mouse_leave() {
    if (buttons_.leave()) invalidate();
}

bool SuggestionPanel::on_key(WPARAM key) {
    if (key == VK_ESCAPE) {
        dismiss();
        return true;
    }
    if (key == VK_RETURN) {
        accept();
        return true;
    }
    return false;
}

LRESULT SuggestionPanel::on_message(UINT msg, WPARAM wp, LPARAM lp, bool& handled) {
    handled = false;
    if (msg == WM_NOTIFY) {
        const auto* hdr = reinterpret_cast<NMHDR*>(lp);
        if (hdr->hwndFrom == edit_ && hdr->code == EN_REQUESTRESIZE) {
            const auto* req = reinterpret_cast<REQRESIZE*>(lp);
            const float h = (req->rc.bottom - req->rc.top) / scale_;
            if (std::abs(h - text_height_) > 0.5f) {
                text_height_ = h;
                relayout();
            }
            handled = true;
            return 0;
        }
    }
    if (msg == WM_COMMAND && reinterpret_cast<HWND>(lp) == edit_ && HIWORD(wp) == EN_CHANGE) {
        // Typed into by hand: the marks no longer describe the text.
        if (!suggestions_.empty()) {
            suggestions_.clear();
            decorate();
            set_status(L"edited", colour::ink_muted);
            relayout();
        }
        handled = true;
        return 0;
    }
    if (msg == WM_ACTIVATE && LOWORD(wp) != WA_INACTIVE) {
        SetFocus(edit_);
    }
    return 0;
}

LRESULT CALLBACK SuggestionPanel::edit_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR,
                                            DWORD_PTR data) {
    auto* self = reinterpret_cast<SuggestionPanel*>(data);
    if (msg == WM_KEYDOWN) {
        const bool shift = GetKeyState(VK_SHIFT) & 0x8000;
        const bool ctrl = GetKeyState(VK_CONTROL) & 0x8000;
        // Return applies, as on macOS; Shift+Return is a new line.
        if (wp == VK_RETURN && !shift) {
            self->accept();
            return 0;
        }
        if (wp == VK_ESCAPE) {
            self->dismiss();
            return 0;
        }
        // Paste as plain text: someone else's fonts and colours have no place
        // in the panel, and would hide the marks.
        if (ctrl && wp == 'V') {
            SendMessageW(hwnd, EM_PASTESPECIAL, CF_UNICODETEXT, 0);
            return 0;
        }
        if (ctrl && wp == 'Z' && self->before_rewrite_) {
            self->undo_rewrite();
            return 0;
        }
    }
    if (msg == WM_CHAR && (wp == L'\r' || wp == 27) && !(GetKeyState(VK_SHIFT) & 0x8000)) return 0;
    return DefSubclassProc(hwnd, msg, wp, lp);
}

}  // namespace nib::ui

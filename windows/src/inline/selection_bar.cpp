#include "inline/selection_bar.hpp"

#include <windowsx.h>

#include <algorithm>
#include "app/dispatch.hpp"
#include "present/presentation.hpp"
#include "support/log.hpp"
#include "text/unicode.hpp"

namespace nib::app {
namespace {

constexpr float max_width = 600, min_width = 210;
constexpr float pad_x = 12, pad_y = 8;
constexpr float tag_gap = 6;

ui::Colour mode_tint(RewriteMode mode) {
    switch (mode) {
    case RewriteMode::fix_grammar: return ui::colour::fix;
    case RewriteMode::clearer:     return ui::colour::rewrite;
    case RewriteMode::shorter:     return ui::colour::condense;
    case RewriteMode::native:      return ui::colour::clarity;
    }
    return ui::colour::ink;
}

ui::Colour standing_tint(WritingScore::Standing s) {
    switch (s) {
    case WritingScore::Standing::clean: return ui::colour::accept;
    case WritingScore::Standing::few:   return ui::colour::ink_muted;
    case WritingScore::Standing::many:  return ui::colour::correction;
    }
    return ui::colour::ink_muted;
}

}  // namespace

SelectionBar::SelectionBar() : Surface(Kind::popup) { create(L"nib rewrite"); }

void SelectionBar::present(const RECT& anchor, const std::u16string& original, Rewrite rewrite, Score score,
                           std::function<void(const std::u16string&)> accept) {
    const bool reappearing = visible();
    anchor_ = anchor;
    original_ = original;
    rewrite_ = std::move(rewrite);
    score_ = std::move(score);
    accept_ = std::move(accept);
    proposal_.reset();
    diff_ = false;
    expanded_ = false;
    score_text_.clear();
    status_.clear();
    if (!reappearing) moved_ = false;
    ++generation_;

    layout_controls();
    reposition();
    show();

    // The count first and separately: harper answers in ~30ms against the
    // model's second or more, so the fast answer is not hidden behind the slow.
    if (score_) {
        const auto generation = generation_;
        score_([this, generation](std::optional<WritingScore> s) {
            if (generation != generation_ || !s || s->words <= 0) return;
            score_text_ = app::wide(s->summary());
            score_tint_ = standing_tint(s->standing());
            layout_controls();
            reposition();
        });
    }
    // Offer something without being asked: a bar of buttons is a menu, and
    // having the suggestion already there is the point.
    run_auto();
}

void SelectionBar::dismiss() {
    ++generation_;
    moved_ = false;
    busy_ = false;
    hide();
}

void SelectionBar::set_status(const std::wstring& text, ui::Colour tint, bool busy) {
    status_ = text;
    status_tint_ = tint;
    busy_ = busy;
    layout_controls();
    reposition();
}

void SelectionBar::run_auto() {
    if (!rewrite_) return;
    const auto generation = generation_;
    set_status(L"reading", ui::colour::ink_muted, true);

    // Least invasive first: an unasked-for rewrite should fix the mistake and
    // leave the voice alone. A failure is kept apart from a clean sentence --
    // "looks good" in green over writing nobody checked is the bug this
    // codebase has made twice -- and a refusal apart from both.
    struct Progress {
        size_t next = 0;
        std::optional<RewriteError> failure;
        std::optional<std::u16string> refusal;
    };
    auto progress = std::make_shared<Progress>();
    auto step = std::make_shared<std::function<void()>>();
    *step = [this, generation, progress, step] {
        if (generation != generation_) return;
        if (progress->next >= present::auto_order.size()) {
            if (progress->failure) {
                log::write("selection rewrite failed: " + utf16_to_utf8(progress->failure->description()));
                set_status(app::wide(present::failure_message(*progress->failure)), ui::colour::warning);
            } else if (progress->refusal) {
                set_status(app::wide(*progress->refusal), ui::colour::correction);
            } else {
                set_status(L"looks good", ui::colour::accept);
            }
            return;
        }
        const auto mode = present::auto_order[progress->next++];
        rewrite_(mode, [this, generation, progress, step, mode](Answer answer) {
            if (generation != generation_) return;
            if (answer.error) {
                progress->failure = answer.error;
            } else if (answer.outcome) {
                if (answer.outcome->kind == RewriteOutcome::Kind::rewritten && !answer.outcome->text.empty()) {
                    show_proposal(answer.outcome->text, mode);
                    return;
                }
                if (answer.outcome->kind == RewriteOutcome::Kind::refused && !progress->refusal) {
                    progress->refusal = answer.outcome->text;
                }
            }
            (*step)();
        });
    };
    (*step)();
}

void SelectionBar::run(RewriteMode mode) {
    if (!rewrite_) return;
    const auto generation = ++generation_;
    proposal_.reset();
    std::wstring label = app::wide(rewrite_mode::short_title(mode));
    for (auto& c : label) c = static_cast<wchar_t>(towlower(c));
    set_status(label, ui::colour::ink_muted, true);
    rewrite_(mode, [this, generation, mode](Answer answer) {
        if (generation != generation_) return;
        if (answer.error) {
            log::write("selection rewrite failed: " + utf16_to_utf8(answer.error->description()));
            set_status(app::wide(present::failure_message(*answer.error)), ui::colour::warning);
            return;
        }
        if (!answer.outcome) return;
        switch (answer.outcome->kind) {
        case RewriteOutcome::Kind::rewritten:
            if (!answer.outcome->text.empty()) {
                show_proposal(answer.outcome->text, mode);
                return;
            }
            [[fallthrough]];
        case RewriteOutcome::Kind::unchanged:
            set_status(L"nothing to change", ui::colour::ink_muted);
            return;
        case RewriteOutcome::Kind::refused:
            // Asked for explicitly, so the reason is owed.
            set_status(app::wide(answer.outcome->text), ui::colour::correction);
            return;
        }
    });
}

void SelectionBar::show_proposal(const std::u16string& text, RewriteMode mode) {
    proposal_ = text;
    proposal_mode_ = mode;
    diff_ = false;
    expanded_ = false;
    status_.clear();
    busy_ = false;
    layout_controls();
    reposition();
}

void SelectionBar::accept() {
    if (!proposal_) return;
    const auto text = *proposal_;
    auto accept = accept_;
    dismiss();
    if (accept) accept(text);
}

void SelectionBar::layout_controls() {
    using namespace ui;
    buttons_.clear();
    float y = pad_y;
    float width = min_width;
    proposal_layout_.Reset();

    if (proposal_) {
        // The tag names the mode: the bar usually answers with Fix, and
        // untagged that was judged as Native.
        const std::wstring tag = app::wide(rewrite_mode::badge(proposal_mode_)) + L"  ";
        std::vector<present::Run> runs = diff_ ? present::diff(original_, *proposal_)
                                               : std::vector<present::Run>{{*proposal_, present::Style::plain}};
        std::wstring text = tag;
        for (const auto& r : runs) text += app::wide(r.text);
        const float wrap = 440 - pad_x * 2 - 40;
        dwrite()->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format(Font::body), wrap, 2000,
                                   &proposal_layout_);
        if (proposal_layout_) {
            proposal_layout_->SetFontFamilyName(L"Segoe UI", {0, static_cast<UINT32>(tag.size())});
            proposal_layout_->SetFontSize(10, {0, static_cast<UINT32>(tag.size())});
            proposal_layout_->SetFontWeight(DWRITE_FONT_WEIGHT_BOLD, {0, static_cast<UINT32>(tag.size())});
            UINT32 at = static_cast<UINT32>(tag.size());
            for (const auto& r : runs) {
                const DWRITE_TEXT_RANGE range{at, static_cast<UINT32>(r.text.size())};
                if (r.style == present::Style::removed) proposal_layout_->SetStrikethrough(TRUE, range);
                if (r.style == present::Style::added) {
                    proposal_layout_->SetUnderline(TRUE, range);
                    proposal_layout_->SetFontWeight(DWRITE_FONT_WEIGHT_SEMI_BOLD, range);
                }
                at += range.length;
            }
            DWRITE_TEXT_METRICS m{};
            proposal_layout_->GetMetrics(&m);
            DWRITE_LINE_METRICS lines[64];
            UINT32 count = 0;
            proposal_layout_->GetLineMetrics(lines, 64, &count);
            float h = m.height;
            const bool fits = count <= 4;
            if (!fits && !expanded_) {
                h = 0;
                for (UINT32 i = 0; i < 4; ++i) h += lines[i].height;
            }
            proposal_layout_->SetMaxHeight(h);
            proposal_rect_ = {pad_x, y, pad_x + std::max(m.widthIncludingTrailingWhitespace + 20 + 24, 180.f), y + h + 14};
            expander_rect_ = fits ? D2D1_RECT_F{} : D2D1_RECT_F{proposal_rect_.right - 30, proposal_rect_.top + (h + 14) / 2 - 12,
                                                                proposal_rect_.right - 6, proposal_rect_.top + (h + 14) / 2 + 12};
            width = std::max(width, proposal_rect_.right + pad_x);
            y = proposal_rect_.bottom + metric::row;
        }
    }

    // The action row: a mark of whose bar this is, then the four modes.
    float x = pad_x + 13 + metric::row;
    std::vector<Button*> row;
    for (auto mode : all_rewrite_modes) {
        Button b;
        b.label = app::wide(rewrite_mode::short_title(mode));
        b.mark = mode_tint(mode);
        b.enabled = !busy_;
        b.on_click = [this, mode] { run(mode); };
        buttons_.add(std::move(b));
    }
    if (proposal_) {
        Button d;
        d.label = diff_ ? L"Result" : L"Diff";
        d.mark = colour::accept;
        d.tooltip = diff_ ? L"Show the finished text" : L"Show what this changes";
        d.on_click = [this] {
            diff_ = !diff_;
            layout_controls();
            reposition();
        };
        buttons_.add(std::move(d));
    }
    for (auto& b : buttons_.items()) row.push_back(&b);
    x = Buttons::row(row, x, y, metric::tight) + metric::row;
    if (!score_text_.empty()) x += layout(score_text_, Font::caption).width + metric::row;
    if (!status_.empty()) x += layout(status_ + (busy_ ? L"…" : L""), Font::caption, 200).width + metric::row;
    width = std::clamp(std::max(width, x + pad_x), min_width, max_width);
    height_ = y + metric::control + pad_y;
    width_ = width;
}

void SelectionBar::reposition() {
    POINT centre{(anchor_.left + anchor_.right) / 2, anchor_.top};
    const float scale = ui::scale_for_point(centre);
    const int w = static_cast<int>(width_ * scale), h = static_cast<int>(height_ * scale);
    if (moved_ && visible()) {
        const RECT r = screen_rect();
        place(r.left, r.top, width_, height_);
        invalidate();
        return;
    }
    HMONITOR monitor = MonitorFromPoint(centre, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    const RECT& work = info.rcWork;
    const int gap = static_cast<int>(8 * scale), edge = static_cast<int>(6 * scale);
    // Above by default -- the eye is already at the end of what was selected
    // -- and below when there is no room for the height it is about to be.
    const int room_above = anchor_.top - work.top;
    const int room_below = work.bottom - anchor_.bottom;
    const bool above = room_above >= h + gap + edge || room_above >= room_below;
    int x = centre.x - w / 2;
    int y = above ? anchor_.top - h - gap : anchor_.bottom + gap;
    x = std::clamp(x, static_cast<int>(work.left + edge), static_cast<int>(work.right - w - edge));
    y = std::clamp(y, static_cast<int>(work.top + edge), static_cast<int>(work.bottom - h - edge));
    place(x, y, width_, height_);
    invalidate();
}

void SelectionBar::paint(ID2D1RenderTarget* rt) {
    using namespace ui;
    aurora(rt, {0, 0, width_, height_}, metric::radius_window);

    if (proposal_ && proposal_layout_) {
        fill_round(rt, proposal_rect_, metric::radius_control,
                   proposal_hovered_ ? colour::accept.with_alpha(0.16f) : colour::control_fill(0.10f));
        if (proposal_hovered_) stroke_round(rt, proposal_rect_, metric::radius_control, colour::accept.with_alpha(0.55f));
        ui::ComPtr<ID2D1SolidColorBrush> ink, tag, removed, added;
        rt->CreateSolidColorBrush(colour::ink.d2d(), &ink);
        rt->CreateSolidColorBrush(colour::rewrite.d2d(), &tag);
        rt->CreateSolidColorBrush(colour::removed.d2d(), &removed);
        rt->CreateSolidColorBrush(colour::added.d2d(), &added);
        const std::wstring tag_text = app::wide(rewrite_mode::badge(proposal_mode_)) + L"  ";
        proposal_layout_->SetDrawingEffect(tag.Get(), {0, static_cast<UINT32>(tag_text.size())});
        if (diff_) {
            UINT32 at = static_cast<UINT32>(tag_text.size());
            for (const auto& r : present::diff(original_, *proposal_)) {
                const DWRITE_TEXT_RANGE range{at, static_cast<UINT32>(r.text.size())};
                if (r.style == present::Style::removed) proposal_layout_->SetDrawingEffect(removed.Get(), range);
                if (r.style == present::Style::added) proposal_layout_->SetDrawingEffect(added.Get(), range);
                at += range.length;
            }
        }
        rt->DrawTextLayout({proposal_rect_.left + 10, proposal_rect_.top + 7}, proposal_layout_.Get(), ink.Get(),
                           D2D1_DRAW_TEXT_OPTIONS_CLIP);
        // A tick, not a return arrow: clicking is how this is accepted.
        const auto tick = layout(L"✓", Font::control);
        tick.draw(rt, proposal_rect_.right - 18, (proposal_rect_.top + proposal_rect_.bottom - tick.height) / 2,
                  proposal_hovered_ ? colour::accept : colour::ink_muted);
        if (expander_rect_.right > 0) {
            const auto chevron = layout(expanded_ ? L"˄" : L"˅", Font::control);
            chevron.draw(rt, expander_rect_.left + 4, (expander_rect_.top + expander_rect_.bottom - chevron.height) / 2,
                         colour::ink_muted);
        }
    }

    const float row_y = height_ - pad_y - metric::control;
    const float cy = row_y + metric::control / 2;
    fill_round(rt, {pad_x, cy - 6.5f, pad_x + 13, cy + 6.5f}, 6.5f, colour::rewrite.with_alpha(0.85f));
    buttons_.draw(rt);
    float x = buttons_.items().empty() ? pad_x + 21 : buttons_.items().back().rect.right + metric::row;
    if (!score_text_.empty()) {
        const auto s = layout(score_text_, Font::caption);
        s.draw(rt, x, cy - s.height / 2, score_tint_);
        x += s.width + metric::row;
    }
    if (!status_.empty()) {
        const auto s = layout(status_ + (busy_ ? L"…" : L""), Font::caption, width_ - x - pad_x, 1);
        s.draw(rt, x, cy - s.height / 2, status_tint_);
    }
}

void SelectionBar::on_mouse_move(float x, float y) {
    if (dragging_) {
        POINT p;
        GetCursorPos(&p);
        const int dx = p.x - drag_from_.x, dy = p.y - drag_from_.y;
        if (std::abs(dx) + std::abs(dy) > 2) moved_ = true;
        SetWindowPos(hwnd(), nullptr, drag_window_.left + dx, drag_window_.top + dy, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        return;
    }
    bool changed = buttons_.hover(x, y);
    const bool over = proposal_ && ui::inside(proposal_rect_, x, y) && !ui::inside(expander_rect_, x, y);
    if (over != proposal_hovered_) {
        proposal_hovered_ = over;
        changed = true;
        SetCursor(LoadCursorW(nullptr, over ? IDC_HAND : IDC_ARROW));
    }
    if (changed) invalidate();
}

void SelectionBar::on_mouse_down(float x, float y) {
    if (buttons_.down(x, y)) {
        invalidate();
        return;
    }
    if (proposal_ && ui::inside(proposal_rect_, x, y)) return;
    // Drag it anywhere by its background: above the selection is right until
    // it covers the line being rewritten, and then only the reader knows.
    dragging_ = true;
    GetCursorPos(&drag_from_);
    drag_window_ = screen_rect();
    SetCapture(hwnd());
}

void SelectionBar::on_mouse_up(float x, float y) {
    if (dragging_) {
        dragging_ = false;
        ReleaseCapture();
        if (moved_) log::write("selection bar moved by hand");
        return;
    }
    if (buttons_.up(x, y)) {
        invalidate();
        return;
    }
    if (proposal_ && expander_rect_.right > 0 && ui::inside(expander_rect_, x, y)) {
        expanded_ = !expanded_;
        layout_controls();
        reposition();
        return;
    }
    if (proposal_ && ui::inside(proposal_rect_, x, y)) accept();
}

void SelectionBar::on_mouse_leave() {
    bool changed = buttons_.leave();
    if (proposal_hovered_) {
        proposal_hovered_ = false;
        changed = true;
    }
    if (changed) invalidate();
}

}  // namespace nib::app

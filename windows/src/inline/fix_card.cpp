#include "inline/fix_card.hpp"

#include <algorithm>
#include "app/dispatch.hpp"

namespace nib::app {
namespace {

constexpr float card_width = 360;
constexpr float padding = 14;

// The diff as one DirectWrite layout, styled per run: the old words struck in
// clay, the new in bold verdigris, the context in ink.
ui::ComPtr<IDWriteTextLayout> styled_layout(const std::vector<present::Run>& runs, float width, bool clarity) {
    std::wstring text;
    for (const auto& r : runs) text += wide(r.text);
    ui::ComPtr<IDWriteTextLayout> layout;
    ui::dwrite()->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), ui::format(ui::Font::diff), width,
                                   1000, &layout);
    if (!layout) return layout;
    UINT32 at = 0;
    for (const auto& r : runs) {
        const DWRITE_TEXT_RANGE range{at, static_cast<UINT32>(r.text.size())};
        if (r.style == present::Style::removed) {
            layout->SetStrikethrough(TRUE, range);
        } else if (r.style == present::Style::added && !clarity) {
            layout->SetFontWeight(DWRITE_FONT_WEIGHT_SEMI_BOLD, range);
        }
        at += range.length;
    }
    return layout;
}

ui::Colour run_colour(present::Style s) {
    switch (s) {
    case present::Style::removed: return ui::colour::removed;
    case present::Style::added:   return ui::colour::added;
    default:                      return ui::colour::ink;
    }
}

}  // namespace

FixCard::FixCard() : Surface(Kind::popup) { create(L"nib fix"); }

void FixCard::build(const std::u16string& context, size_t index, size_t total) {
    using namespace ui;
    const auto& s = suggestion_;
    explanation_ = wide(s.message);
    const bool clarity = s.kind == SuggestionKind::clarity;
    const float content = card_width - padding * 2;

    if (s.replacements.empty()) {
        // No fix is a valid state -- harper flags plenty it cannot repair. The
        // card says so, rather than a missing button reading as broken.
        runs_ = {{u"No suggested fix — flagged only.", present::Style::plain}};
    } else if (clarity) {
        // A sentence rewrite would repeat most of itself as a word diff; the
        // rewritten sentence alone says it.
        runs_ = {{s.replacements.front(), present::Style::plain}};
    } else {
        runs_ = present::fix_card(s, s.replacements.front(), context);
    }
    diff_layout_ = styled_layout(runs_, content, clarity);
    if (diff_layout_) {
        if (!s.replacements.empty()) {
            UINT32 at = 0;
            for (const auto& r : runs_) at += static_cast<UINT32>(r.text.size());
        }
        diff_layout_->SetMaxHeight(4 * 20.f);
        DWRITE_TEXT_METRICS m{};
        diff_layout_->GetMetrics(&m);
        diff_height_ = std::min(m.height, 4 * 20.f);
    }

    const auto expl = layout(explanation_, Font::caption, content, 2);
    float y = padding + (s.source == SuggestionSource::model ? 16.f : 0.f) + expl.height + 10 + diff_height_ + 12;

    buttons_.clear();
    std::vector<Button*> row;
    if (!s.replacements.empty()) {
        Button accept;
        accept.label = L"Accept";
        accept.emphasis = Button::Emphasis::primary;
        accept.tint = clarity ? colour::clarity : colour::accept;
        accept.on_click = [this] {
            if (on_accept) on_accept(suggestion_, suggestion_.replacements.front());
        };
        buttons_.add(std::move(accept));
    }
    Button dismiss;
    dismiss.label = L"Dismiss";
    dismiss.emphasis = Button::Emphasis::plain;
    dismiss.on_click = [this] {
        if (on_dismiss) on_dismiss(suggestion_);
    };
    buttons_.add(std::move(dismiss));
    for (auto& b : buttons_.items()) row.push_back(&b);
    Buttons::row(row, padding, y, 6);

    counter_ = total > 1 ? std::to_wstring(index + 1) + L" of " + std::to_wstring(total) : L"";
    if (total > 1) {
        Button next;
        next.label = L"›";
        next.emphasis = Button::Emphasis::plain;
        next.on_click = [this] {
            if (on_step) on_step(1);
        };
        Button prev;
        prev.label = L"‹";
        prev.emphasis = Button::Emphasis::plain;
        prev.on_click = [this] {
            if (on_step) on_step(-1);
        };
        const float w = metric::target;
        auto& n = buttons_.add(std::move(next));
        n.rect = {card_width - padding - w, y, card_width - padding, y + metric::control};
        auto& p = buttons_.add(std::move(prev));
        p.rect = {card_width - padding - w * 2 - 4, y, card_width - padding - w - 4, y + metric::control};
    }
    height_ = y + metric::control + padding;
    width_ = card_width;
}

void FixCard::present(const Suggestion& s, const std::u16string& context, size_t index, size_t total, POINT below) {
    if (shown_id_ != s.id) {
        suggestion_ = s;
        shown_id_ = s.id;
        build(context, index, total);
    }
    // Below the word; above it when there is no room.
    HMONITOR monitor = MonitorFromPoint(below, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    const float scale = ui::scale_for_point(below);
    const int w = static_cast<int>(width_ * scale), h = static_cast<int>(height_ * scale);
    int x = below.x - static_cast<int>(8 * scale);
    int y = below.y + static_cast<int>(8 * scale);
    x = std::clamp(x, static_cast<int>(info.rcWork.left + 6), static_cast<int>(info.rcWork.right - w - 6));
    if (y + h > info.rcWork.bottom - 6) y = below.y - h - static_cast<int>(28 * scale);
    place(x, y, width_, height_);
    show();
}

bool FixCard::mouse_inside() const {
    if (!visible()) return false;
    POINT p;
    GetCursorPos(&p);
    RECT r = screen_rect();
    InflateRect(&r, 6, 6);
    return PtInRect(&r, p) != FALSE;
}

void FixCard::paint(ID2D1RenderTarget* rt) {
    using namespace ui;
    aurora(rt, {0, 0, width_, height_}, 10);
    float y = padding;
    if (suggestion_.source == SuggestionSource::model) {
        // Says where the advice came from: a model wrote this, and it does not
        // deserve the confidence of a dictionary match.
        layout(L"AI", Font::tag).draw(rt, padding, y, colour::rewrite);
        y += 16;
    }
    const auto expl = layout(explanation_, Font::caption, width_ - padding * 2, 2);
    expl.draw(rt, padding, y, colour::ink_muted);
    y += expl.height + 10;

    if (diff_layout_) {
        // Colour per run, drawn with one brush per style.
        ui::ComPtr<ID2D1SolidColorBrush> ink;
        rt->CreateSolidColorBrush(colour::ink.d2d(), &ink);
        UINT32 at = 0;
        for (const auto& r : runs_) {
            ui::ComPtr<ID2D1SolidColorBrush> b;
            rt->CreateSolidColorBrush(run_colour(r.style).d2d(), &b);
            diff_layout_->SetDrawingEffect(b.Get(), {at, static_cast<UINT32>(r.text.size())});
            at += static_cast<UINT32>(r.text.size());
        }
        rt->DrawTextLayout({padding, y}, diff_layout_.Get(), ink.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
    }
    buttons_.draw(rt);
    if (!counter_.empty()) {
        const auto c = layout(counter_, Font::caption);
        const auto& prev = buttons_.items().back();
        c.draw(rt, prev.rect.left - 6 - c.width, prev.rect.top + (metric::control - c.height) / 2, colour::ink_muted);
    }
}

void FixCard::on_mouse_move(float x, float y) {
    if (buttons_.hover(x, y)) invalidate();
}
void FixCard::on_mouse_down(float x, float y) {
    if (buttons_.down(x, y)) invalidate();
}
void FixCard::on_mouse_up(float x, float y) {
    if (buttons_.up(x, y)) invalidate();
}
void FixCard::on_mouse_leave() {
    if (buttons_.leave()) invalidate();
}

}  // namespace nib::app

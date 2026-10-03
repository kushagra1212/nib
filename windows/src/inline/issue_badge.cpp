#include "inline/issue_badge.hpp"

#include <algorithm>
#include "ui/widgets.hpp"

namespace nib::app {

IssueBadge::IssueBadge() : Surface(Kind::popup) { create(L"nib badge"); }

void IssueBadge::present(size_t count, const std::wstring& hint, const RECT& field) {
    if (!count || field.right <= field.left) {
        hide();
        return;
    }
    label_ = std::to_wstring(count) + (count == 1 ? L" issue" : L" issues") + L" · " + hint;
    const auto text = ui::layout(label_, ui::Font::control);
    const float w = 10 + 10 + 5 + text.width + 11, h = 26;

    // Above the leading edge of the field: the trailing edge is where apps
    // keep their send buttons, and a badge there reads as part of the app.
    POINT origin{field.left, field.top};
    const float scale = ui::scale_for_point(origin);
    HMONITOR monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    int x = field.left + static_cast<int>(4 * scale);
    int y = field.top - static_cast<int>((h + 4) * scale);
    if (y < info.rcWork.top + 4) y = field.bottom + static_cast<int>(4 * scale);
    x = std::clamp(x, static_cast<int>(info.rcWork.left + 4), static_cast<int>(info.rcWork.right - w * scale - 4));
    place(x, y, w, h);
    show();
}

void IssueBadge::set_hovered(bool hovered) {
    if (hovered == hovered_) return;
    hovered_ = hovered;
    invalidate();
}

void IssueBadge::paint(ID2D1RenderTarget* rt) {
    using namespace ui;
    fill_round(rt, {0, 0, width_, height_}, 11, colour::base.with_alpha(0.94f));
    if (hovered_) fill_round(rt, {0, 0, width_, height_}, 11, colour::control_fill(0.10f));
    stroke_round(rt, {0, 0, width_, height_}, 11, colour::control_fill(0.18f));
    // A pencil mark in correction red, then the count.
    fill_round(rt, {10, height_ / 2 - 4, 18, height_ / 2 + 4}, 4, colour::correction);
    const auto text = layout(label_, Font::control);
    text.draw(rt, 25, (height_ - text.height) / 2, colour::ink);
}

void IssueBadge::on_mouse_up(float, float) {
    hide();
    if (on_open) on_open();
}

}  // namespace nib::app

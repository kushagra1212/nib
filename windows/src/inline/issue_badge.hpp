#pragma once
#include <functional>
#include <string>
#include "ui/surface.hpp"

namespace nib::app {

// Port of IssueBadge: for fields that report no text positions -- many
// Chromium and Electron apps -- there is nowhere to draw an underline, so a
// count sits just above the field instead. Clicking it opens the panel;
// hovering it shows the same fix cards.
class IssueBadge : public ui::Surface {
public:
    IssueBadge();

    std::function<void()> on_open;

    void present(size_t count, const std::wstring& hint, const RECT& field);
    void set_hovered(bool hovered);
    void dismiss() { hide(); }

protected:
    void paint(ID2D1RenderTarget* rt) override;
    void on_mouse_up(float x, float y) override;

private:
    std::wstring label_;
    bool hovered_ = false;
};

}  // namespace nib::app

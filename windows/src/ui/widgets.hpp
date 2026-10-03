#pragma once
#include <functional>
#include <string>
#include <vector>
#include "ui/gfx.hpp"

namespace nib::ui {

// One control height, one radius, one hairline, one face -- so a button in the
// rewrite bar and a button in the control panel are the same object.
struct Button {
    enum class Emphasis { primary, secondary, plain };

    std::wstring label;
    Emphasis emphasis = Emphasis::secondary;
    Colour tint = colour::accept;        // primary fill
    Colour mark = {0, 0, 0, 0};          // a small coloured square before the label
    D2D1_RECT_F rect{};
    bool enabled = true;
    bool hovered = false;
    bool pressed = false;
    std::wstring tooltip;
    std::function<void()> on_click;

    float natural_width() const;
};

// A set of buttons on one surface, with hover and press tracking.
class Buttons {
public:
    Button& add(Button b);
    void clear() { items_.clear(); }
    std::vector<Button>& items() { return items_; }

    void draw(ID2D1RenderTarget* rt) const;
    // Each returns whether anything changed and the surface should redraw.
    bool hover(float x, float y);
    bool leave();
    bool down(float x, float y);
    // Fires the button released over, if it is the one pressed.
    bool up(float x, float y);
    bool contains(float x, float y) const;

    // Lays the given buttons out left to right from (x, y); returns the right edge.
    static float row(std::vector<Button*> buttons, float x, float y, float gap = metric::tight);

private:
    std::vector<Button> items_;
};

void draw_button(ID2D1RenderTarget* rt, const Button& b);

// A short pill of text with a tinted dot, for state: "3 issues", "looks clean".
void draw_pill(ID2D1RenderTarget* rt, float right, float y, const std::wstring& text, Colour tint);

inline bool inside(const D2D1_RECT_F& r, float x, float y) {
    return x >= r.left && x < r.right && y >= r.top && y < r.bottom;
}

}  // namespace nib::ui

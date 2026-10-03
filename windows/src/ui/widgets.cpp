#include "ui/widgets.hpp"

namespace nib::ui {

float Button::natural_width() const {
    const auto text = layout(label, Font::control);
    float w = text.width + metric::control_padding * 2;
    if (mark.a > 0) w += 8 + 5;
    return std::max(w, metric::target);
}

Button& Buttons::add(Button b) {
    items_.push_back(std::move(b));
    return items_.back();
}

void draw_button(ID2D1RenderTarget* rt, const Button& b) {
    const D2D1_RECT_F& r = b.rect;
    const float alpha = b.enabled ? 1.f : 0.45f;
    Colour text = colour::ink;

    switch (b.emphasis) {
    case Button::Emphasis::primary:
        fill_round(rt, r, metric::radius_control,
                   b.tint.with_alpha((b.pressed ? 0.70f : b.hovered ? 0.95f : 0.85f) * alpha));
        text = colour::base;
        break;
    case Button::Emphasis::secondary:
        fill_round(rt, r, metric::radius_control,
                   colour::control_fill((b.pressed ? 0.20f : b.hovered ? 0.16f : 0.10f) * alpha));
        stroke_round(rt, r, metric::radius_control,
                     b.hovered ? colour::taupe.with_alpha(0.6f) : colour::rule);
        break;
    case Button::Emphasis::plain:
        if (b.hovered || b.pressed) {
            fill_round(rt, r, metric::radius_control, colour::control_fill(b.pressed ? 0.14f : 0.08f));
        }
        text = colour::ink_muted;
        break;
    }

    const auto label = layout(b.label, Font::control);
    float content = label.width;
    if (b.mark.a > 0) content += 8 + 5;
    float x = (r.left + r.right - content) / 2;
    const float cy = (r.top + r.bottom) / 2;
    if (b.mark.a > 0) {
        fill_round(rt, {x, cy - 4, x + 8, cy + 4}, 1.5f, b.mark.with_alpha(alpha));
        x += 13;
    }
    label.draw(rt, x, cy - label.height / 2, text.with_alpha(alpha));
}

void Buttons::draw(ID2D1RenderTarget* rt) const {
    for (const auto& b : items_) draw_button(rt, b);
}

bool Buttons::hover(float x, float y) {
    bool changed = false;
    for (auto& b : items_) {
        const bool h = b.enabled && inside(b.rect, x, y);
        if (h != b.hovered) {
            b.hovered = h;
            changed = true;
        }
    }
    return changed;
}

bool Buttons::leave() {
    bool changed = false;
    for (auto& b : items_) {
        if (b.hovered || b.pressed) changed = true;
        b.hovered = b.pressed = false;
    }
    return changed;
}

bool Buttons::down(float x, float y) {
    bool changed = false;
    for (auto& b : items_) {
        const bool p = b.enabled && inside(b.rect, x, y);
        if (p != b.pressed) {
            b.pressed = p;
            changed = true;
        }
    }
    return changed;
}

bool Buttons::up(float x, float y) {
    std::function<void()> fire;
    bool changed = false;
    for (auto& b : items_) {
        if (b.pressed) {
            changed = true;
            if (b.enabled && inside(b.rect, x, y)) fire = b.on_click;
        }
        b.pressed = false;
    }
    // Last: the handler may clear and rebuild this very list.
    if (fire) fire();
    return changed;
}

bool Buttons::contains(float x, float y) const {
    for (const auto& b : items_) {
        if (inside(b.rect, x, y)) return true;
    }
    return false;
}

float Buttons::row(std::vector<Button*> buttons, float x, float y, float gap) {
    for (auto* b : buttons) {
        const float w = b->natural_width();
        b->rect = {x, y, x + w, y + metric::control};
        x += w + gap;
    }
    return x - gap;
}

void draw_pill(ID2D1RenderTarget* rt, float right, float y, const std::wstring& text, Colour tint) {
    const auto label = layout(text, Font::caption);
    const float w = label.width + 12 + 10;
    const D2D1_RECT_F r{right - w, y, right, y + 20};
    fill_round(rt, r, 10, tint.with_alpha(0.14f));
    fill_round(rt, {r.left + 8, y + 7, r.left + 14, y + 13}, 3, tint);
    label.draw(rt, r.left + 18, y + (20 - label.height) / 2, colour::ink);
}

}  // namespace nib::ui

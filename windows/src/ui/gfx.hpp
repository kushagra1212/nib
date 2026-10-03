#pragma once
#include <windows.h>
#include <d2d1_1.h>
#include <dwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>
#include <string_view>

// Direct2D and DirectWrite, reduced to what nib draws: rounded panels on an
// aurora, text in two weights, pill buttons, squiggles.
//
// The palette is the macOS Theme's, value for value -- pigments rather than
// system colours, because every surface nib draws sits on top of someone
// else's sentence and must not pull the eye off it.

namespace nib::ui {

using Microsoft::WRL::ComPtr;

ID2D1Factory1* d2d();
IDWriteFactory* dwrite();

struct Colour {
    float r, g, b, a;
    static constexpr Colour hex(uint32_t v, float alpha = 1.f) {
        return {((v >> 16) & 0xFF) / 255.f, ((v >> 8) & 0xFF) / 255.f, (v & 0xFF) / 255.f, alpha};
    }
    constexpr Colour with_alpha(float alpha) const { return {r, g, b, alpha}; }
    D2D1_COLOR_F d2d() const { return {r, g, b, a}; }
    COLORREF colorref() const {
        return RGB(static_cast<int>(r * 255), static_cast<int>(g * 255), static_cast<int>(b * 255));
    }
};

namespace colour {
// Pompeian red, verdigris, Wedgwood blue, brass.
inline constexpr Colour clay = Colour::hex(0xFFA0A0);
inline constexpr Colour sage = Colour::hex(0x4FE3C1);
inline constexpr Colour slate = Colour::hex(0x6FB4FF);
inline constexpr Colour taupe = Colour::hex(0xC4A6FF);

inline constexpr Colour correction = clay;
inline constexpr Colour clarity = slate;
inline constexpr Colour accept = sage;
inline constexpr Colour removed = clay;
inline constexpr Colour added = sage;
inline constexpr Colour listening = clay;
inline constexpr Colour fix = sage;
inline constexpr Colour rewrite = slate;
inline constexpr Colour condense = taupe;
inline constexpr Colour warning = Colour::hex(0xFFC56B);

inline constexpr Colour ink = Colour::hex(0xF2F5F7);
inline constexpr Colour ink_muted = Colour::hex(0xC6D2DB);
inline constexpr Colour rule = Colour::hex(0xFFFFFF, 0.14f);
inline constexpr Colour base = {0.055f, 0.06f, 0.08f, 1.f};
inline constexpr Colour field = Colour::hex(0x15171C);

inline constexpr Colour control_fill(float opacity) { return {1, 1, 1, opacity}; }
}  // namespace colour

namespace metric {
inline constexpr float control = 24;
inline constexpr float control_padding = 12;
inline constexpr float target = 24;
inline constexpr float radius_window = 6;
inline constexpr float radius_control = 3;
inline constexpr float edge = 12;
inline constexpr float row = 8;
inline constexpr float tight = 4;
}  // namespace metric

enum class Font { body, diff, diff_bold, control, caption, title, heading, row_title, tag, mono };

IDWriteTextFormat* format(Font font);

// A laid-out block of text, measured once and drawn as often as needed.
struct TextBlock {
    ComPtr<IDWriteTextLayout> layout;
    float width = 0, height = 0;
    int lines = 0;

    void draw(ID2D1RenderTarget* rt, float x, float y, Colour colour) const;
};

TextBlock layout(std::wstring_view text, Font font, float max_width = 10'000.f,
                 int max_lines = 0, bool centred = false);

// Shared drawing.
void fill_round(ID2D1RenderTarget* rt, D2D1_RECT_F r, float radius, Colour c);
void stroke_round(ID2D1RenderTarget* rt, D2D1_RECT_F r, float radius, Colour c, float width = 1.f);
void line(ID2D1RenderTarget* rt, D2D1_POINT_2F a, D2D1_POINT_2F b, Colour c, float width = 1.f);

// The panel ground: dark base, three soft lights, a hairline rim.
void aurora(ID2D1RenderTarget* rt, D2D1_RECT_F r, float radius);

// A wavy underline under a span, the shape spell checkers have taught everyone.
void squiggle(ID2D1RenderTarget* rt, float x0, float x1, float baseline, Colour c, float scale);

// Pixels per DIP for a window, so 1 DIP is one point at 96 DPI.
float scale_for(HWND hwnd);
float scale_for_point(POINT p);

}  // namespace nib::ui

#pragma once
#include <windows.h>

#include <functional>
#include <string>
#include "ui/gfx.hpp"

namespace nib::ui {

// A window nib draws itself, in DIPs.
//
// Two kinds, because nib has two kinds of window:
//
//   Popup    floats over someone else's app: the hover card, the rewrite bar,
//            the badge, the underlines. Per-pixel alpha through
//            UpdateLayeredWindow, never activated, never in the taskbar --
//            taking focus from the field being typed in is the one thing these
//            must not do. Optionally click-through, for the underline layer.
//
//   Window   an ordinary top-level window, for the control panel and the
//            suggestion panel, which take keyboard input and may hold native
//            child controls (an edit box cannot be drawn into a layered
//            window).
class Surface {
public:
    enum class Kind { popup, click_through, window };

    explicit Surface(Kind kind);
    virtual ~Surface();
    Surface(const Surface&) = delete;
    Surface& operator=(const Surface&) = delete;

    HWND hwnd() const { return hwnd_; }
    bool visible() const { return hwnd_ && IsWindowVisible(hwnd_); }
    float scale() const { return scale_; }

    // Position and size in physical pixels, size in DIPs.
    void place(int x, int y, float width_dip, float height_dip);
    void show(bool activate = false);
    void hide();
    void invalidate();
    RECT screen_rect() const;
    float width() const { return width_; }
    float height() const { return height_; }

protected:
    void create(const wchar_t* title, DWORD extra_style = 0, HWND owner = nullptr);

    virtual void paint(ID2D1RenderTarget* rt) = 0;
    virtual void on_mouse_move(float, float) {}
    virtual void on_mouse_down(float, float) {}
    virtual void on_mouse_up(float, float) {}
    virtual void on_mouse_leave() {}
    virtual void on_wheel(float) {}
    virtual bool on_key(WPARAM) { return false; }
    virtual void on_resized() {}
    virtual void on_closed() {}
    virtual LRESULT on_message(UINT, WPARAM, LPARAM, bool& handled) {
        handled = false;
        return 0;
    }

    float width_ = 0, height_ = 0;
    float scale_ = 1;

private:
    static LRESULT CALLBACK proc(HWND, UINT, WPARAM, LPARAM);
    LRESULT handle(UINT, WPARAM, LPARAM);
    void render_layered();
    void render_window();

    Kind kind_;
    bool framed_ = false;
    HWND hwnd_ = nullptr;
    bool tracking_ = false;
    ComPtr<ID2D1HwndRenderTarget> window_target_;
    ComPtr<ID2D1DCRenderTarget> dc_target_;
};

// Fades in or out by stepping the layered alpha over a few frames. Instant
// when the system asks for less motion -- these appear beside the sentence
// being read, which is exactly the movement that setting exists to stop.
bool reduce_motion();

}  // namespace nib::ui

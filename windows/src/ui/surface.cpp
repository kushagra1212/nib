#include "ui/surface.hpp"

#include <dwmapi.h>
#include <windowsx.h>

namespace nib::ui {
namespace {

const wchar_t* class_name(Surface::Kind kind) {
    switch (kind) {
    case Surface::Kind::popup:         return L"nib.popup";
    case Surface::Kind::click_through: return L"nib.overlay";
    case Surface::Kind::window:        return L"nib.window";
    }
    return L"nib.popup";
}

}  // namespace

bool reduce_motion() {
    BOOL animations = TRUE;
    SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
    return !animations;
}

Surface::Surface(Kind kind) : kind_(kind) {}

Surface::~Surface() {
    if (hwnd_) {
        SetWindowLongPtrW(hwnd_, GWLP_USERDATA, 0);
        DestroyWindow(hwnd_);
    }
}

void Surface::create(const wchar_t* title, DWORD extra_style, HWND owner) {
    const wchar_t* name = class_name(kind_);
    WNDCLASSEXW wc{sizeof wc};
    if (!GetClassInfoExW(GetModuleHandleW(nullptr), name, &wc)) {
        wc = {sizeof wc};
        wc.style = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc = proc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(1));
        wc.lpszClassName = name;
        RegisterClassExW(&wc);
    }

    DWORD ex = 0, style = 0;
    switch (kind_) {
    case Kind::popup:
        ex = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
        style = WS_POPUP;
        break;
    case Kind::click_through:
        ex = WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
        style = WS_POPUP;
        break;
    case Kind::window:
        // A borderless top-level window when asked for WS_POPUP -- the
        // suggestion panel, which takes the keyboard but is not a document.
        framed_ = !(extra_style & WS_POPUP);
        style = WS_CLIPCHILDREN | (framed_ ? WS_OVERLAPPEDWINDOW : 0);
        if (!framed_) ex = WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
        break;
    }
    hwnd_ = CreateWindowExW(ex, name, title, style | extra_style, CW_USEDEFAULT, CW_USEDEFAULT, 100,
                            100, owner, nullptr, GetModuleHandleW(nullptr), this);
    scale_ = scale_for(hwnd_);

    if (kind_ == Kind::window) {
        // Dark title bar and rounded corners, matching the panels.
        BOOL dark = TRUE;
        DwmSetWindowAttribute(hwnd_, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof dark);
        const COLORREF caption = colour::base.colorref();
        DwmSetWindowAttribute(hwnd_, 35 /* DWMWA_CAPTION_COLOR */, &caption, sizeof caption);
        const int round = 2;  // DWMWCP_ROUND, Windows 11; ignored on 10
        DwmSetWindowAttribute(hwnd_, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &round, sizeof round);
    }
}

void Surface::place(int x, int y, float width_dip, float height_dip) {
    if (!hwnd_) return;
    POINT p{x, y};
    scale_ = kind_ == Kind::window ? scale_for(hwnd_) : scale_for_point(p);
    width_ = width_dip;
    height_ = height_dip;
    const int w = static_cast<int>(width_dip * scale_ + 0.5f);
    const int h = static_cast<int>(height_dip * scale_ + 0.5f);
    if (kind_ == Kind::window) {
        RECT r{0, 0, w, h};
        AdjustWindowRectExForDpi(&r, static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_STYLE)), FALSE,
                                 static_cast<DWORD>(GetWindowLongPtrW(hwnd_, GWL_EXSTYLE)),
                                 GetDpiForWindow(hwnd_));
        SetWindowPos(hwnd_, nullptr, x, y, r.right - r.left, r.bottom - r.top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
    } else {
        SetWindowPos(hwnd_, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
        render_layered();
    }
}

void Surface::show(bool activate) {
    if (!hwnd_) return;
    if (kind_ == Kind::window) {
        ShowWindow(hwnd_, activate ? SW_SHOW : SW_SHOWNA);
        if (activate) SetForegroundWindow(hwnd_);
        invalidate();
        return;
    }
    render_layered();
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void Surface::hide() {
    if (hwnd_ && IsWindowVisible(hwnd_)) ShowWindow(hwnd_, SW_HIDE);
}

void Surface::invalidate() {
    if (!hwnd_) return;
    if (kind_ == Kind::window) {
        InvalidateRect(hwnd_, nullptr, FALSE);
    } else {
        render_layered();
    }
}

RECT Surface::screen_rect() const {
    RECT r{};
    if (hwnd_) GetWindowRect(hwnd_, &r);
    return r;
}

void Surface::render_layered() {
    const int w = static_cast<int>(width_ * scale_ + 0.5f);
    const int h = static_cast<int>(height_ * scale_ + 0.5f);
    if (w <= 0 || h <= 0) return;

    HDC screen = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof bmi.bmiHeader;
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    void* bits = nullptr;
    HBITMAP dib = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ old = SelectObject(mem, dib);

    if (!dc_target_) {
        const auto props = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
        d2d()->CreateDCRenderTarget(&props, &dc_target_);
    }
    RECT bounds{0, 0, w, h};
    if (dc_target_ && SUCCEEDED(dc_target_->BindDC(mem, &bounds))) {
        dc_target_->BeginDraw();
        dc_target_->SetTransform(D2D1::Matrix3x2F::Scale(scale_, scale_));
        dc_target_->Clear({0, 0, 0, 0});
        dc_target_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        paint(dc_target_.Get());
        if (dc_target_->EndDraw() == D2DERR_RECREATE_TARGET) dc_target_.Reset();
    }

    RECT wr{};
    GetWindowRect(hwnd_, &wr);
    POINT dst{wr.left, wr.top};
    SIZE size{w, h};
    POINT src{0, 0};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd_, screen, &dst, &size, mem, &src, 0, &blend, ULW_ALPHA);

    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
}

void Surface::render_window() {
    RECT rc{};
    GetClientRect(hwnd_, &rc);
    const D2D1_SIZE_U size{static_cast<UINT32>(rc.right), static_cast<UINT32>(rc.bottom)};
    if (!window_target_) {
        d2d()->CreateHwndRenderTarget(D2D1::RenderTargetProperties(),
                                      D2D1::HwndRenderTargetProperties(hwnd_, size),
                                      &window_target_);
    } else {
        window_target_->Resize(size);
    }
    if (!window_target_) return;
    window_target_->SetDpi(96, 96);
    window_target_->BeginDraw();
    window_target_->SetTransform(D2D1::Matrix3x2F::Scale(scale_, scale_));
    window_target_->Clear(colour::base.d2d());
    paint(window_target_.Get());
    if (window_target_->EndDraw() == D2DERR_RECREATE_TARGET) window_target_.Reset();
}

LRESULT CALLBACK Surface::proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_NCCREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    }
    auto* self = reinterpret_cast<Surface*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!self) return DefWindowProcW(hwnd, msg, wp, lp);
    if (!self->hwnd_) self->hwnd_ = hwnd;
    return self->handle(msg, wp, lp);
}

LRESULT Surface::handle(UINT msg, WPARAM wp, LPARAM lp) {
    bool handled = false;
    const LRESULT custom = on_message(msg, wp, lp, handled);
    if (handled) return custom;

    auto dip = [&](LPARAM l) {
        return std::pair<float, float>{GET_X_LPARAM(l) / scale_, GET_Y_LPARAM(l) / scale_};
    };
    switch (msg) {
    case WM_MOUSEACTIVATE:
        if (kind_ != Kind::window) return MA_NOACTIVATE;
        break;
    case WM_PAINT:
        if (kind_ == Kind::window) {
            PAINTSTRUCT ps;
            BeginPaint(hwnd_, &ps);
            render_window();
            EndPaint(hwnd_, &ps);
            return 0;
        }
        break;
    case WM_ERASEBKGND:
        return 1;
    case WM_SIZE:
        if (kind_ == Kind::window) {
            RECT rc{};
            GetClientRect(hwnd_, &rc);
            width_ = rc.right / scale_;
            height_ = rc.bottom / scale_;
            on_resized();
            invalidate();
        }
        return 0;
    case WM_DPICHANGED:
        if (kind_ == Kind::window) {
            scale_ = HIWORD(wp) / 96.f;
            const auto* r = reinterpret_cast<RECT*>(lp);
            SetWindowPos(hwnd_, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
            return 0;
        }
        break;
    case WM_MOUSEMOVE: {
        if (!tracking_) {
            TRACKMOUSEEVENT t{sizeof t, TME_LEAVE, hwnd_, 0};
            TrackMouseEvent(&t);
            tracking_ = true;
        }
        const auto [x, y] = dip(lp);
        on_mouse_move(x, y);
        return 0;
    }
    case WM_MOUSELEAVE:
        tracking_ = false;
        on_mouse_leave();
        return 0;
    case WM_LBUTTONDOWN: {
        const auto [x, y] = dip(lp);
        if (kind_ == Kind::window) SetCapture(hwnd_);
        on_mouse_down(x, y);
        return 0;
    }
    case WM_LBUTTONUP: {
        if (GetCapture() == hwnd_) ReleaseCapture();
        const auto [x, y] = dip(lp);
        on_mouse_up(x, y);
        return 0;
    }
    case WM_MOUSEWHEEL:
        on_wheel(GET_WHEEL_DELTA_WPARAM(wp) / static_cast<float>(WHEEL_DELTA));
        return 0;
    case WM_KEYDOWN:
        if (on_key(wp)) return 0;
        break;
    case WM_CLOSE:
        if (kind_ == Kind::window && framed_) {
            // Closing hides: the panel keeps its state and reopens instantly.
            hide();
            on_closed();
            return 0;
        }
        break;
    case WM_GETMINMAXINFO:
        if (kind_ == Kind::window && framed_) {
            auto* info = reinterpret_cast<MINMAXINFO*>(lp);
            info->ptMinTrackSize = {static_cast<LONG>(640 * scale_), static_cast<LONG>(440 * scale_)};
            return 0;
        }
        break;
    }
    return DefWindowProcW(hwnd_, msg, wp, lp);
}

}  // namespace nib::ui

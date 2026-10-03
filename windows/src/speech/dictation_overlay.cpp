#include "speech/dictation_overlay.hpp"

#include <cstdio>
#include "app/dispatch.hpp"
#include "speech/audio_io.hpp"

namespace nib::app {
namespace {
// The overlay being animated. One at a time, and only while listening.
DictationOverlay* active = nullptr;
}  // namespace

DictationOverlay::DictationOverlay() : Surface(Kind::popup) {
    create(L"nib listening");
    ui::Button stop;
    stop.label = L"Stop";
    stop.mark = ui::colour::clay;
    stop.on_click = [this] {
        if (on_stop) on_stop();
    };
    buttons_.add(std::move(stop));
}

DictationOverlay::~DictationOverlay() {
    if (timer_) KillTimer(nullptr, timer_);
    if (active == this) active = nullptr;
}

std::wstring DictationOverlay::caption(double elapsed, double maximum) {
    if (elapsed < 10) return L"Listening";
    const int m = static_cast<int>(elapsed) / 60, s = static_cast<int>(elapsed) % 60;
    wchar_t buf[48];
    if (maximum - elapsed <= 60) swprintf(buf, 48, L"%d:%02d — stopping soon", m, s);
    else swprintf(buf, 48, L"%d:%02d", m, s);
    return buf;
}

void DictationOverlay::present() {
    const float w = 230, h = 44;
    width_ = w;
    height_ = h;
    auto& stop = buttons_.items()[0];
    const float bw = stop.natural_width();
    stop.rect = {w - 12 - bw, (h - ui::metric::control) / 2, w - 12, (h + ui::metric::control) / 2};
    stop.enabled = listening_;

    // Bottom centre of the screen the pointer is on.
    POINT cursor;
    GetCursorPos(&cursor);
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    const float scale = ui::scale_for_point(cursor);
    const int x = (info.rcWork.left + info.rcWork.right) / 2 - static_cast<int>(w * scale / 2);
    const int y = info.rcWork.bottom - static_cast<int>((h + 90) * scale);
    place(x, y, w, h);
    show();
}

void DictationOverlay::listening(const std::wstring& what) {
    what_ = what;
    listening_ = true;
    text_ = what;
    present();
    if (!timer_) {
        // 30Hz: enough for the meter to follow speech, cheap beside the audio
        // it is drawing.
        active = this;
        timer_ = SetTimer(nullptr, 0, 33, [](HWND, UINT, UINT_PTR, DWORD) {
            if (active) active->tick();
        });
    }
}

void DictationOverlay::working(const std::wstring& text) {
    listening_ = false;
    text_ = text;
    if (timer_) {
        KillTimer(nullptr, timer_);
        timer_ = 0;
    }
    present();
}

void DictationOverlay::dismiss() {
    listening_ = false;
    if (timer_) {
        KillTimer(nullptr, timer_);
        timer_ = 0;
    }
    if (active == this) active = nullptr;
    hide();
}

void DictationOverlay::tick() {
    if (!listening_ || !sample) return;
    const auto [level, elapsed] = sample();
    // Rises at once, falls slowly: a meter that tracks exactly flickers in
    // every gap between words.
    smoothed_ = level > smoothed_ ? level : smoothed_ * 0.85f + level * 0.15f;
    text_ = what_ == L"Listening" ? caption(elapsed, audio::Recorder::max_seconds) : what_;
    invalidate();
}

void DictationOverlay::paint(ID2D1RenderTarget* rt) {
    using namespace ui;
    aurora(rt, {0, 0, width_, height_}, metric::radius_window);
    const float cx = 22, cy = height_ / 2;
    if (listening_) {
        const float r = 7 * (0.55f + std::min(1.f, smoothed_) * 0.45f);
        fill_round(rt, {cx - r - 3, cy - r - 3, cx + r + 3, cy + r + 3}, r + 3, colour::listening.with_alpha(0.25f));
        fill_round(rt, {cx - r, cy - r, cx + r, cy + r}, r, colour::listening);
    } else {
        fill_round(rt, {cx - 4, cy - 4, cx + 4, cy + 4}, 4, colour::ink_muted);
    }
    const auto label = layout(text_, Font::control, 130, 1);
    label.draw(rt, 40, cy - label.height / 2, colour::ink_muted);
    buttons_.draw(rt);
}

void DictationOverlay::on_mouse_move(float x, float y) {
    if (buttons_.hover(x, y)) invalidate();
}
void DictationOverlay::on_mouse_down(float x, float y) {
    if (buttons_.down(x, y)) invalidate();
}
void DictationOverlay::on_mouse_up(float x, float y) {
    if (buttons_.up(x, y)) invalidate();
}
void DictationOverlay::on_mouse_leave() {
    if (buttons_.leave()) invalidate();
}

}  // namespace nib::app

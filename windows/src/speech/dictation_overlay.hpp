#pragma once
#include <functional>
#include <string>
#include "ui/surface.hpp"
#include "ui/widgets.hpp"

namespace nib::app {

// Port of DictationOverlay: the listening indicator. Above everything, never
// focused -- dictation is used while typing elsewhere, and taking focus would
// move the caret away from the field the words are for.
class DictationOverlay : public ui::Surface {
public:
    DictationOverlay();
    ~DictationOverlay() override;

    // level 0..1 and seconds elapsed, sampled at 30Hz while listening.
    std::function<std::pair<float, double>()> sample;
    std::function<void()> on_stop;

    void listening(const std::wstring& what = L"Listening");
    void working(const std::wstring& text);
    void dismiss();

    static std::wstring caption(double elapsed, double maximum);

protected:
    void paint(ID2D1RenderTarget* rt) override;
    void on_mouse_move(float x, float y) override;
    void on_mouse_down(float x, float y) override;
    void on_mouse_up(float x, float y) override;
    void on_mouse_leave() override;

private:
    void present();
    void tick();

    ui::Buttons buttons_;
    std::wstring text_;
    std::wstring what_ = L"Listening";
    bool listening_ = false;
    float smoothed_ = 0;
    UINT_PTR timer_ = 0;
};

}  // namespace nib::app

#pragma once
#include <functional>
#include <string>
#include <vector>
#include "lint/suggestion.hpp"
#include "present/presentation.hpp"
#include "ui/surface.hpp"
#include "ui/widgets.hpp"

namespace nib::app {

// Port of FixCard: what a hovered mark is about, the change it proposes, and
// Accept / Dismiss / step through the rest. Never takes focus: clicking it
// must leave the caret in the field the fix is for.
class FixCard : public ui::Surface {
public:
    FixCard();

    std::function<void(const Suggestion&, const std::u16string&)> on_accept;
    std::function<void(const Suggestion&)> on_dismiss;
    std::function<void(int)> on_step;

    // Shows `s` below an anchor in screen pixels.
    void present(const Suggestion& s, const std::u16string& context, size_t index, size_t total, POINT below);
    void reset() { shown_id_ = 0; }
    bool mouse_inside() const;
    uint64_t shown_id() const { return shown_id_; }

protected:
    void paint(ID2D1RenderTarget* rt) override;
    void on_mouse_move(float x, float y) override;
    void on_mouse_down(float x, float y) override;
    void on_mouse_up(float x, float y) override;
    void on_mouse_leave() override;

private:
    void build(const std::u16string& context, size_t index, size_t total);

    Suggestion suggestion_;
    uint64_t shown_id_ = 0;
    std::vector<present::Run> runs_;
    ui::ComPtr<IDWriteTextLayout> diff_layout_;
    float diff_height_ = 0;
    std::wstring explanation_;
    std::wstring counter_;
    ui::Buttons buttons_;
};

}  // namespace nib::app

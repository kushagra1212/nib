#pragma once
#include <functional>
#include <optional>
#include <string>
#include "lint/writing_score.hpp"
#include "rewrite/rewrite_mode.hpp"
#include "rewrite/rewrite_text.hpp"
#include "ui/surface.hpp"
#include "ui/widgets.hpp"

namespace nib::app {

// Port of SelectionBar: appears above selected text offering rewrites, runs
// Fix, then Clearer, then Native on its own and shows the first that changes
// anything -- tagged with the mode that wrote it -- and the proposal itself is
// what you click to accept. Never takes focus.
class SelectionBar : public ui::Surface {
public:
    struct Answer {
        std::optional<RewriteOutcome> outcome;
        std::optional<RewriteError> error;
    };
    using Rewrite = std::function<void(RewriteMode, std::function<void(Answer)>)>;
    using Score = std::function<void(std::function<void(std::optional<WritingScore>)>)>;

    SelectionBar();

    // `anchor` is the selection in screen pixels: what the bar must not cover.
    void present(const RECT& anchor, const std::u16string& original, Rewrite rewrite, Score score,
                 std::function<void(const std::u16string&)> accept);
    void dismiss();

protected:
    void paint(ID2D1RenderTarget* rt) override;
    void on_mouse_move(float x, float y) override;
    void on_mouse_down(float x, float y) override;
    void on_mouse_up(float x, float y) override;
    void on_mouse_leave() override;

private:
    void layout_controls();
    void reposition();
    void run_auto();
    void run(RewriteMode mode);
    void show_proposal(const std::u16string& text, RewriteMode mode);
    void set_status(const std::wstring& text, ui::Colour tint, bool busy = false);
    void accept();

    RECT anchor_{};
    std::u16string original_;
    Rewrite rewrite_;
    Score score_;
    std::function<void(const std::u16string&)> accept_;

    std::optional<std::u16string> proposal_;
    RewriteMode proposal_mode_ = RewriteMode::fix_grammar;
    bool diff_ = false;
    bool expanded_ = false;
    bool busy_ = false;
    std::wstring status_;
    ui::Colour status_tint_ = ui::colour::ink_muted;
    std::wstring score_text_;
    ui::Colour score_tint_ = ui::colour::ink_muted;
    uint64_t generation_ = 0;

    ui::Buttons buttons_;
    D2D1_RECT_F proposal_rect_{};
    D2D1_RECT_F expander_rect_{};
    bool proposal_hovered_ = false;
    ui::ComPtr<IDWriteTextLayout> proposal_layout_;
    bool moved_ = false;
    bool dragging_ = false;
    POINT drag_from_{};
    RECT drag_window_{};
};

}  // namespace nib::app

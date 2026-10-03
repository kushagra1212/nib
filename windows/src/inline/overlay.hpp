#pragma once
#include <functional>
#include <optional>
#include <string>
#include <vector>
#include "inline/fix_card.hpp"
#include "present/presentation.hpp"
#include "ui/surface.hpp"

namespace nib::app {

// Port of InlineOverlay: the underlines, drawn in a click-through window laid
// exactly over the field, and the fix card that hovering one opens.
//
// The window takes no input -- the field underneath must keep every click --
// so hover is read by sampling the pointer while marks are up, the same way
// macOS nib had to for its badge.
class Overlay : public ui::Surface {
public:
    Overlay();

    std::function<void(const Suggestion&, const std::u16string&)> on_accept;
    std::function<void(const Suggestion&)> on_dismiss;

    // Rects are relative to `field` (screen pixels), as present::place gives.
    void show_marks(const RECT& field, std::vector<present::Mark> marks, const std::u16string& context);
    void hide_all();

    // No marks to hover -- the badge's case. The card hangs off the pointer and
    // stays while the pointer is on it or on `keep_alive`.
    void show_detached(const std::vector<Suggestion>& list, const std::u16string& context, POINT below,
                       RECT keep_alive);
    void hide_detached();
    void schedule_detached_hide();

    // The rewrite bar owns the region; the card must not open over it.
    void suppress(bool suppressed);

    // Called at 30Hz by the live checker while anything is visible.
    void pointer_moved(POINT screen);

    bool card_visible() const { return card_.visible(); }
    bool detached() const { return detached_anchor_.has_value(); }

protected:
    void paint(ID2D1RenderTarget* rt) override;

private:
    void present_card(size_t index);
    void step(int delta);
    void schedule_card_hide();
    const present::Mark* mark_at(POINT local) const;

    FixCard card_;
    std::vector<present::Mark> marks_;
    std::vector<Suggestion> ordered_;
    std::u16string context_;
    RECT field_{};
    std::optional<size_t> shown_;
    uint64_t hovered_ = 0;
    std::optional<POINT> detached_anchor_;
    RECT keep_alive_{};
    bool suppressed_ = false;
    UINT_PTR hide_timer_ = 0;
};

}  // namespace nib::app

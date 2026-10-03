#include "inline/overlay.hpp"

#include "app/dispatch.hpp"

namespace nib::app {
namespace {

// The marks keep the system's red and blue, as on macOS: red for spelling and
// grammar, blue for clarity, the colours every spell checker has taught.
constexpr ui::Colour mark_red = {1.f, 0.231f, 0.188f, 1.f};
constexpr ui::Colour mark_blue = {0.f, 0.478f, 1.f, 1.f};

bool inside(const RECT& r, POINT p, int slack) {
    return p.x >= r.left - slack && p.x < r.right + slack && p.y >= r.top - slack && p.y < r.bottom + slack;
}

}  // namespace

Overlay::Overlay() : Surface(Kind::click_through) {
    create(L"nib marks");
    card_.on_accept = [this](const Suggestion& s, const std::u16string& r) {
        card_.hide();
        card_.reset();
        shown_.reset();
        if (on_accept) on_accept(s, r);
    };
    card_.on_dismiss = [this](const Suggestion& s) {
        card_.hide();
        card_.reset();
        shown_.reset();
        if (on_dismiss) on_dismiss(s);
    };
    card_.on_step = [this](int delta) { step(delta); };
}

void Overlay::show_marks(const RECT& field, std::vector<present::Mark> marks, const std::u16string& context) {
    if (marks.empty() || field.right <= field.left || field.bottom <= field.top) {
        hide_all();
        return;
    }
    detached_anchor_.reset();
    context_ = context;
    // A card anchored to a mark that just moved is dropped rather than chased
    // mid-scroll; the pointer is over the text, so it returns on the next move.
    if (card_.visible() && shown_ && *shown_ < ordered_.size()) {
        const auto id = ordered_[*shown_].id;
        RECT old{}, now{};
        bool had = false, has = false;
        for (const auto& m : marks_) {
            if (m.suggestion.id == id && !m.rects.empty()) {
                old = {m.rects[0].left + field_.left, m.rects[0].top + field_.top, 0, 0};
                had = true;
            }
        }
        for (const auto& m : marks) {
            if (m.suggestion.id == id && !m.rects.empty()) {
                now = {m.rects[0].left + field.left, m.rects[0].top + field.top, 0, 0};
                has = true;
            }
        }
        if (!had || !has || std::abs(old.left - now.left) > 1 || std::abs(old.top - now.top) > 1) {
            card_.hide();
            card_.reset();
            shown_.reset();
        }
    }
    field_ = field;
    marks_ = std::move(marks);
    ordered_.clear();
    for (const auto& m : marks_) ordered_.push_back(m.suggestion);

    POINT origin{field.left, field.top};
    const float s = ui::scale_for_point(origin);
    place(field.left, field.top, (field.right - field.left) / s, (field.bottom - field.top) / s);
    show();
}

void Overlay::hide_all() {
    marks_.clear();
    ordered_.clear();
    shown_.reset();
    hovered_ = 0;
    detached_anchor_.reset();
    card_.reset();
    card_.hide();
    hide();
}

void Overlay::paint(ID2D1RenderTarget* rt) {
    // Rects are in physical pixels relative to the field; the surface draws
    // in DIPs, so they are scaled back.
    const float s = scale_;
    for (const auto& m : marks_) {
        const bool hovered = m.suggestion.id == hovered_;
        const bool correction = m.suggestion.kind == SuggestionKind::correction;
        const ui::Colour tint = correction ? mark_red : mark_blue;
        const float base = correction ? 0.10f : 0.055f;
        for (const auto& r : m.rects) {
            const D2D1_RECT_F rect{r.left / s - 1, r.top / s - 1, r.right / s + 1, r.bottom / s + 1};
            ui::fill_round(rt, rect, 2, tint.with_alpha(hovered ? 0.20f : base));
            const float y = r.bottom / s;
            // A 2-point bar just under the text, solid where hovered.
            ui::fill_round(rt, {r.left / s, y - 1, r.right / s, y + 1}, 0, tint.with_alpha(hovered ? 1.f : 0.7f));
        }
    }
}

const present::Mark* Overlay::mark_at(POINT local) const {
    // Corrections come first in the list, so a word-level fix wins over the
    // clarity mark covering the same sentence.
    for (const auto& m : marks_) {
        for (const auto& r : m.rects) {
            if (local.x >= r.left - 2 && local.x < r.right + 2 && local.y >= r.top - 4 && local.y < r.bottom + 4) return &m;
        }
    }
    return nullptr;
}

void Overlay::suppress(bool suppressed) {
    suppressed_ = suppressed;
    if (suppressed && card_.visible()) {
        card_.hide();
        card_.reset();
        shown_.reset();
        hovered_ = 0;
        invalidate();
    }
}

void Overlay::pointer_moved(POINT p) {
    if (detached_anchor_) {
        if (!card_.visible()) return;
        if (card_.mouse_inside() || inside(keep_alive_, p, 6)) {
            cancel(hide_timer_);
            hide_timer_ = 0;
        } else {
            schedule_card_hide();
        }
        return;
    }
    if (!visible() || suppressed_) return;
    // Keep the card while the pointer is on it, so its buttons can be reached.
    if (card_.visible() && card_.mouse_inside()) {
        cancel(hide_timer_);
        hide_timer_ = 0;
        return;
    }
    const POINT local{p.x - field_.left, p.y - field_.top};
    const auto* mark = mark_at(local);
    if (!mark) {
        if (hovered_) {
            hovered_ = 0;
            invalidate();
        }
        schedule_card_hide();
        return;
    }
    cancel(hide_timer_);
    hide_timer_ = 0;
    if (hovered_ != mark->suggestion.id) {
        hovered_ = mark->suggestion.id;
        invalidate();
    }
    for (size_t i = 0; i < ordered_.size(); ++i) {
        if (ordered_[i].id == mark->suggestion.id) {
            if (!shown_ || *shown_ != i || !card_.visible()) present_card(i);
            break;
        }
    }
}

void Overlay::present_card(size_t index) {
    if (index >= ordered_.size()) return;
    POINT anchor;
    if (detached_anchor_) {
        anchor = *detached_anchor_;
    } else {
        const auto& s = ordered_[index];
        const present::Mark* found = nullptr;
        for (const auto& m : marks_) {
            if (m.suggestion.id == s.id) found = &m;
        }
        if (!found || found->rects.empty()) return;
        hovered_ = s.id;
        invalidate();
        anchor = {field_.left + found->rects[0].left, field_.top + found->rects[0].bottom};
    }
    shown_ = index;
    card_.present(ordered_[index], context_, index, ordered_.size(), anchor);
}

void Overlay::step(int delta) {
    if (!shown_ || ordered_.empty()) return;
    const int count = static_cast<int>(ordered_.size());
    const int next = ((static_cast<int>(*shown_) + delta) % count + count) % count;
    card_.reset();
    present_card(static_cast<size_t>(next));
}

void Overlay::schedule_card_hide() {
    if (hide_timer_ || !card_.visible()) return;
    hide_timer_ = after(400, [this] {
        hide_timer_ = 0;
        if (card_.mouse_inside()) return;
        card_.hide();
        card_.reset();
        shown_.reset();
        detached_anchor_.reset();
        if (hovered_) {
            hovered_ = 0;
            invalidate();
        }
    });
}

void Overlay::show_detached(const std::vector<Suggestion>& list, const std::u16string& context, POINT below,
                            RECT keep_alive) {
    if (list.empty()) {
        hide_detached();
        return;
    }
    context_ = context;
    detached_anchor_ = below;
    keep_alive_ = keep_alive;
    cancel(hide_timer_);
    hide_timer_ = 0;
    // Rebuilding on every move would reset the card to the first issue while
    // the user is stepping through them.
    bool same = list.size() == ordered_.size();
    for (size_t i = 0; same && i < list.size(); ++i) same = list[i].id == ordered_[i].id;
    if (!same) {
        ordered_ = list;
        card_.reset();
        shown_.reset();
    }
    present_card(shown_.value_or(0));
}

void Overlay::hide_detached() {
    if (!detached_anchor_) return;
    detached_anchor_.reset();
    card_.hide();
    card_.reset();
    shown_.reset();
}

void Overlay::schedule_detached_hide() {
    if (detached_anchor_) schedule_card_hide();
}

}  // namespace nib::app

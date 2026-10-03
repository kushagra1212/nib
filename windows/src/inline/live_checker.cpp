#include "inline/live_checker.hpp"

#include "lint/edit_planner.hpp"
#include "lint/suggestion_filter.hpp"
#include "lint/writing_score.hpp"
#include "present/presentation.hpp"
#include "support/log.hpp"
#include "text/keystroke.hpp"
#include "text/unicode.hpp"

namespace nib::app {
namespace {

LiveChecker* ticking = nullptr;

std::wstring brief(const RECT& r) {
    return std::to_wstring(r.left) + L"," + std::to_wstring(r.top) + L" " + std::to_wstring(r.right - r.left) + L"x"
           + std::to_wstring(r.bottom - r.top);
}

}  // namespace

LiveChecker::LiveChecker(std::shared_ptr<HarperEngine> harper, std::shared_ptr<SerialQueue> lint_queue,
                         std::shared_ptr<ModelChecker> model, std::shared_ptr<SerialQueue> model_queue)
    : harper_(std::move(harper)), lint_queue_(std::move(lint_queue)), model_(std::move(model)),
      model_queue_(std::move(model_queue)) {
    watcher_.on_focus = [this](auto focus, auto text) { focus_changed(std::move(focus), std::move(text)); };
    watcher_.on_text = [this](auto text) { text_changed(std::move(text)); };
    watcher_.on_selection = [this](auto selected, auto range) { selection_changed(std::move(selected), range); };
    watcher_.on_geometry = [this] {
        redraw();
        bar_.dismiss();
        overlay_.suppress(false);
    };
    badge_.on_open = [this] {
        overlay_.hide_detached();
        if (on_open_panel) on_open_panel();
    };
    overlay_.on_accept = [this](const Suggestion& s, const std::u16string& r) { apply(s, r); };
    overlay_.on_dismiss = [this](const Suggestion& s) { dismiss(s); };
}

LiveChecker::~LiveChecker() { stop(); }

void LiveChecker::start() {
    log::write("live checker start requested");
    if (running_) return;
    running_ = true;
    watcher_.start();
}

void LiveChecker::stop() {
    if (!running_) return;
    log::write("live checker stopping");
    running_ = false;
    watcher_.stop();
    for (UINT_PTR* t : {&lint_timer_, &model_timer_, &selection_timer_}) {
        cancel(*t);
        *t = 0;
    }
    ++lint_generation_;
    ++selection_generation_;
    bar_.dismiss();
    overlay_.suppress(false);
    hide_marks();
    focus_.reset();
}

void LiveChecker::dismiss_everything() {
    if (!(overlay_.visible() || overlay_.card_visible() || bar_.visible() || badge_.visible())) return;
    log::write("escape: dismissing everything");
    ++selection_generation_;
    bar_.dismiss();
    overlay_.hide_detached();
    overlay_.suppress(false);
    hide_marks();
}

// --- Reacting to the field ------------------------------------------------------------

void LiveChecker::focus_changed(std::optional<UiaWatcher::Focus> focus, std::u16string text) {
    log::write("focus -> " + (focus ? narrow(focus->role) + " app=" + narrow(focus->app) : std::string("none"))
               + " len=" + std::to_string(text.size()));
    focus_ = std::move(focus);
    text_ = std::move(text);
    suggestions_.clear();
    dismissed_.clear();
    hide_marks();
    // The bar belongs to a selection in the field that just lost focus --
    // unless focus went nowhere readable, which a popup in the same app does.
    if (focus_) {
        bar_.dismiss();
        overlay_.suppress(false);
        schedule_lint();
    }
}

void LiveChecker::text_changed(std::u16string text) {
    text_ = std::move(text);
    // Marks from the previous text are in the wrong places now, and the
    // selection the bar was offering to rewrite no longer exists.
    hide_marks();
    bar_.dismiss();
    overlay_.suppress(false);
    ++selection_generation_;
    schedule_lint();
}

void LiveChecker::schedule_lint() {
    cancel(lint_timer_);
    lint_timer_ = 0;
    ++lint_generation_;
    if (text_.empty()) {
        suggestions_.clear();
        return;
    }
    if (text_.size() > present::max_live_length) {
        // Said rather than done silently: this branch made long documents
        // look clean when nothing had been checked.
        suggestions_.clear();
        last_note_ = L"field is " + std::to_wstring(text_.size()) + L" characters, over the "
                     + std::to_wstring(present::max_live_length) + L" limit -- not checked";
        log::write("live: " + narrow(last_note_));
        return;
    }
    const auto generation = lint_generation_;
    // harper answers in ~30ms, so a long debounce is dead time: just enough to
    // coalesce a burst of keystrokes.
    lint_timer_ = after(150, [this, generation] {
        lint_timer_ = 0;
        if (generation != lint_generation_) return;
        const auto snapshot = text_;
        auto harper = harper_;
        lint_queue_->post([this, harper, snapshot, generation] {
            std::vector<Suggestion> filled;
            int count = -1;
            try {
                const auto found = harper->lint(snapshot);
                count = static_cast<int>(found.size());
                // Replacements up front here, unlike the panel: the card must
                // offer a fix the instant the pointer arrives.
                std::vector<Suggestion> capped(found.begin(), found.begin() + std::min<size_t>(40, found.size()));
                filled = harper->with_replacements(capped, snapshot);
            } catch (const std::exception& e) {
                log::write(std::string("live: lint failed: ") + e.what());
            }
            on_ui([this, generation, snapshot, filled, count] {
                if (generation != lint_generation_ || snapshot != text_) return;
                last_lint_count_ = count;
                if (count < 0) {
                    last_note_ = L"lint threw or was cancelled";
                    return;
                }
                suggestions_ = filled;
                redraw();
                schedule_model_pass(snapshot);
            });
        });
    });
}

void LiveChecker::schedule_model_pass(const std::u16string& snapshot) {
    if (!model_ || !runs_model_pass) return;
    cancel(model_timer_);
    const auto generation = lint_generation_;
    model_timer_ = after(900, [this, generation, snapshot] {
        model_timer_ = 0;
        if (generation != lint_generation_ || snapshot != text_) return;
        auto model = model_;
        model_queue_->post([this, model, generation, snapshot] {
            auto found = model->check(snapshot);
            on_ui([this, generation, snapshot, found] {
                if (generation != lint_generation_ || snapshot != text_) return;
                if (!found.empty()) {
                    std::vector<Suggestion> harper;
                    for (const auto& s : suggestions_) {
                        if (s.kind == SuggestionKind::correction) harper.push_back(s);
                    }
                    suggestions_ = present::merge(harper, suggestion_filter::apply(found, snapshot), snapshot);
                    redraw();
                }
            });
            // Clarity last: slowest and least urgent, so corrections are
            // already on screen when it lands.
            auto clarity = model->clarity(snapshot);
            on_ui([this, generation, snapshot, clarity] {
                if (generation != lint_generation_ || snapshot != text_ || clarity.empty()) return;
                std::vector<Suggestion> corrections;
                for (const auto& s : suggestions_) {
                    if (s.kind == SuggestionKind::correction) corrections.push_back(s);
                }
                suggestions_ = present::settle_clarity(corrections, clarity);
                redraw();
            });
        });
    });
}

void LiveChecker::selection_changed(std::u16string selected, nib_range range) {
    cancel(selection_timer_);
    selection_timer_ = 0;
    const auto generation = ++selection_generation_;
    // A click or a double-clicked word: nothing worth rewriting in either.
    if (!present::worth_rewriting(selected) || !model_) {
        bar_.dismiss();
        overlay_.suppress(false);
        return;
    }
    const auto trimmed_text = trimmed(selected);
    // Debounced: a drag reports a selection per pixel.
    selection_timer_ = after(250, [this, generation, trimmed_text, selected, range] {
        selection_timer_ = 0;
        if (generation != selection_generation_) return;
        watcher_.post([this, generation, trimmed_text, selected, range](text::Uia& uia, const text::Field* field) {
            std::vector<RECT> rects;
            if (field) {
                rects = uia.bounds(*field, range);
                // Some editors answer neither range query; asking for the
                // selection in its own terms needs no offsets.
                if (rects.empty()) rects = uia.selection_bounds(*field);
            }
            on_ui([this, generation, trimmed_text, selected, range, rects] {
                if (generation != selection_generation_) return;
                if (rects.empty()) {
                    log::write("selection bar: no bounds for the selected range");
                    return;
                }
                RECT anchor = rects[0];
                for (const auto& r : rects) UnionRect(&anchor, &anchor, &r);

                auto model = model_;
                auto model_queue = model_queue_;
                auto harper = harper_;
                auto lint_queue = lint_queue_;
                overlay_.suppress(true);
                bar_.present(
                    anchor, trimmed_text,
                    [model, model_queue, trimmed_text](RewriteMode mode, std::function<void(SelectionBar::Answer)> done) {
                        model_queue->post([model, trimmed_text, mode, done] {
                            SelectionBar::Answer answer;
                            try {
                                answer.outcome = model->rewrite_selection(trimmed_text, mode);
                            } catch (const RewriteException& e) {
                                answer.error = e.error;
                            } catch (const std::exception& e) {
                                answer.error = RewriteError{RewriteError::Kind::server_failed, utf8_to_utf16(e.what())};
                            }
                            on_ui([done, answer] { done(answer); });
                        });
                    },
                    // harper, not the model: on screen before the rewrite has
                    // started, and every mistake it counts can be clicked.
                    [harper, lint_queue, trimmed_text](std::function<void(std::optional<WritingScore>)> done) {
                        lint_queue->post([harper, trimmed_text, done] {
                            std::optional<WritingScore> score;
                            try {
                                score = WritingScore(harper->lint(trimmed_text), trimmed_text);
                            } catch (...) {
                            }
                            on_ui([done, score] { done(score); });
                        });
                    },
                    [this, range, selected](const std::u16string& replacement) {
                        Suggestion s;
                        s.range = range;
                        s.message = u"Rewrite";
                        s.replacements = {replacement};
                        apply(s, replacement);
                    });
            });
        });
    });
}

// --- Drawing -----------------------------------------------------------------------

void LiveChecker::redraw() {
    // Coalesced: geometry polls and model passes can ask several times a frame.
    if (redraw_pending_) return;
    redraw_pending_ = true;
    after(16, [this] {
        redraw_pending_ = false;
        redraw_now();
    });
}

void LiveChecker::update_geometry_watch() {
    watcher_.watch_geometry(!suggestions_.empty(),
                            suggestions_.empty() ? std::nullopt : std::optional<nib_range>(suggestions_.front().range));
}

void LiveChecker::redraw_now() {
    update_geometry_watch();
    if (!focus_) {
        last_note_ = L"no element";
        hide_marks();
        return;
    }
    std::vector<Suggestion> live;
    size_t all = 0;
    for (const auto& s : suggestions_) {
        if (dismissed_.count(present::dismissal_key(s, text_))) continue;
        ++all;
        // Capped before the bounds calls, which is where the cost is.
        if (live.size() < present::max_drawn_marks) live.push_back(s);
    }
    if (live.empty()) {
        last_note_ = L"no suggestions to draw";
        hide_marks();
        return;
    }
    const auto context = text_;
    watcher_.post([this, live, all, context](text::Uia& uia, const text::Field* field) {
        std::optional<RECT> frame;
        std::vector<present::Mark> marks;
        if (field) {
            frame = uia.frame(*field);
            for (const auto& s : live) {
                present::Mark m{s, {}};
                for (const auto& r : uia.bounds(*field, s.range)) m.rects.push_back({r.left, r.top, r.right, r.bottom});
                if (!m.rects.empty()) marks.push_back(std::move(m));
            }
        }
        on_ui([this, live, all, context, frame, marks] {
            if (context != text_) return;
            if (!frame) {
                last_note_ = L"element reports no frame";
                hide_marks();
                return;
            }
            last_field_ = *frame;
            last_rect_count_ = 0;
            for (const auto& m : marks) last_rect_count_ += static_cast<int>(m.rects.size());
            // Clipped to the field: a scrolled-away line still reports bounds.
            const auto placed = present::place(marks, {frame->left, frame->top, frame->right, frame->bottom});
            last_visible_count_ = 0;
            for (const auto& m : placed) last_visible_count_ += static_cast<int>(m.rects.size());
            last_note_ = placed.empty() ? (marks.empty() ? L"no bounds returned for any range"
                                                         : L"every rect fell outside the field frame")
                                        : L"drew " + std::to_wstring(placed.size()) + L" marks";
            if (placed.empty()) {
                // Plenty found, nowhere to draw: say so rather than look broken.
                overlay_.hide_all();
                badge_suggestions_ = live;
                badge_.present(all, hotkey_label, *frame);
            } else {
                badge_suggestions_.clear();
                badge_.dismiss();
                overlay_.show_marks(*frame, placed, context);
            }
            if (!tick_timer_) {
                ticking = this;
                tick_timer_ = SetTimer(nullptr, 0, 33, [](HWND, UINT, UINT_PTR, DWORD) {
                    if (ticking) ticking->tick();
                });
            }
        });
    });
}

void LiveChecker::hide_marks() {
    overlay_.hide_all();
    badge_suggestions_.clear();
    badge_.dismiss();
    pointer_on_badge_ = false;
    update_geometry_watch();
}

void LiveChecker::tick() {
    const bool anything = overlay_.visible() || overlay_.card_visible() || badge_.visible() || bar_.visible();
    if (!anything) {
        KillTimer(nullptr, tick_timer_);
        tick_timer_ = 0;
        if (ticking == this) ticking = nullptr;
        return;
    }
    // Esc closes whatever nib shows. Read, not hooked: none of these windows
    // can take the keyboard, and the key still reaches the app underneath.
    if (GetAsyncKeyState(VK_ESCAPE) & 0x8000) {
        dismiss_everything();
        return;
    }
    POINT p;
    GetCursorPos(&p);
    if (badge_.visible() && !badge_suggestions_.empty()) {
        RECT r = badge_.screen_rect();
        InflateRect(&r, 6, 6);
        const bool on = PtInRect(&r, p) != FALSE;
        badge_.set_hovered(on);
        if (on && !pointer_on_badge_) {
            pointer_on_badge_ = true;
            // Anchored to the pointer, and only on the way in: a card that
            // follows the pointer walks away from its buttons.
            overlay_.show_detached(badge_suggestions_, text_, {p.x - 12, p.y + 6}, badge_.screen_rect());
        } else if (!on && pointer_on_badge_) {
            pointer_on_badge_ = false;
            overlay_.schedule_detached_hide();
        }
    }
    overlay_.pointer_moved(p);
}

// --- Acting on a suggestion ---------------------------------------------------------

void LiveChecker::dismiss(const Suggestion& s) {
    dismissed_.insert(present::dismissal_key(s, text_));
    redraw();
}

void LiveChecker::apply(const Suggestion& suggestion, const std::u16string& replacement) {
    hide_marks();
    const auto cached = text_;
    watcher_.post([this, suggestion, replacement, cached](text::Uia& uia, const text::Field* field) {
        if (!field) return;
        // Re-read: the user may have typed between the lint and the click,
        // which moves every offset.
        const auto current = uia.text(*field).value_or(cached);
        TextEdit edit{suggestion.range, replacement, suggestion.excerpt(current).value_or(u"")};
        // The expected text is what the suggestion covered in the text it was
        // made against, not whatever sits at that range now.
        if (auto original = suggestion.excerpt(cached)) edit.expected = *original;
        if (!edit_planner::is_valid(edit, current)) {
            auto moved = edit_planner::relocate(edit, current);
            if (!moved) {
                on_ui([this] { schedule_lint(); });
                return;
            }
            edit = *moved;
        }
        const auto updated = edit_planner::apply(edit, current);
        if (!updated) return;

        auto settled = [&](int attempts) {
            // Apps apply writes asynchronously; checking at once saw stale
            // text, declared failure, and applied the fix a second time.
            for (int i = 0; i < attempts; ++i) {
                if (uia.text(*field) == std::optional<std::u16string>(*updated)) return true;
                Sleep(40);
            }
            return uia.text(*field) == std::optional<std::u16string>(*updated);
        };

        bool done = false;
        // 1. Select and type over it: the app's own input path, so Ctrl+Z
        //    reverts it.
        if (uia.select(*field, edit.range)) {
            text::type(replacement);
            done = settled(8);
            if (done) log::write("applied by typing -- undo will work");
        }
        // 2. Rewrite the whole value: widest support, no undo entry.
        if (!done && field->has_value && !field->read_only && uia.set_value(*field, *updated)) {
            done = settled(8);
            if (done) log::write("applied by value write -- no undo entry");
        }
        const auto final_text = uia.text(*field).value_or(*updated);
        on_ui([this, final_text] {
            text_ = final_text;
            hide_marks();
            schedule_lint();
        });
    });
}

// --- Diagnostics ------------------------------------------------------------------------

std::wstring LiveChecker::report() const {
    std::wstring out;
    auto line = [&](const std::wstring& k, const std::wstring& v) { out += k + v + L"\r\n"; };
    line(L"running:          ", running_ ? L"yes" : L"NO");
    if (focus_) {
        line(L"element role:     ", focus_->role);
        line(L"app:              ", focus_->app);
        line(L"text pattern:     ", focus_->has_text_pattern ? L"yes" : L"NO -- no character positions");
        line(L"field frame:      ", brief(focus_->frame));
    } else {
        line(L"element:          ", L"NONE -- no readable field has focus");
    }
    line(L"text length:      ", std::to_wstring(text_.size()));
    size_t corrections = 0, clarity = 0;
    for (const auto& s : suggestions_) (s.kind == SuggestionKind::correction ? corrections : clarity)++;
    line(L"suggestions:      ", std::to_wstring(suggestions_.size()) + L" (" + std::to_wstring(corrections)
                                     + L" correction, " + std::to_wstring(clarity) + L" clarity)");
    line(L"lint returned:    ", std::to_wstring(last_lint_count_));
    line(L"rects resolved:   ", std::to_wstring(last_rect_count_));
    line(L"rects visible:    ", std::to_wstring(last_visible_count_));
    line(L"overlay shown:    ", overlay_.visible() ? L"yes" : L"no");
    line(L"badge shown:      ", badge_.visible() ? L"yes" : L"no");
    line(L"model pass:       ", model_ ? (runs_model_pass ? L"on" : L"off -- model too large to run unbidden") : L"no model");
    line(L"note:             ", last_note_);
    return out;
}

}  // namespace nib::app

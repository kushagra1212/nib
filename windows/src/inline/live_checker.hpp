#pragma once
#include <functional>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>
#include "app/dispatch.hpp"
#include "inline/issue_badge.hpp"
#include "inline/overlay.hpp"
#include "inline/selection_bar.hpp"
#include "inline/uia_watcher.hpp"
#include "lint/harper_engine.hpp"
#include "rewrite/model_checker.hpp"

namespace nib::app {

// Port of LiveChecker: watches the focused field, lints it as you type, and
// keeps the underlines, the badge and the rewrite bar in step with it. The
// always-on mode; the hotkey panel stays for fields underlines cannot reach.
class LiveChecker {
public:
    // `lint` and `model` are the shared engines, each called only through its
    // queue so the live pass and the panel never race on one process.
    LiveChecker(std::shared_ptr<HarperEngine> harper, std::shared_ptr<SerialQueue> lint_queue,
                std::shared_ptr<ModelChecker> model, std::shared_ptr<SerialQueue> model_queue);
    ~LiveChecker();

    std::wstring hotkey_label = L"Ctrl+Alt+Space";
    std::function<void()> on_open_panel;
    // Whether the model may run on every typing pause (small models only).
    bool runs_model_pass = true;

    void start();
    void stop();
    bool running() const { return running_; }
    void dismiss_everything();

    // What the pipeline holds, stage by stage, for Diagnostics.
    std::wstring report() const;

private:
    void focus_changed(std::optional<UiaWatcher::Focus> focus, std::u16string text);
    void text_changed(std::u16string text);
    void selection_changed(std::u16string selected, nib_range range);
    void schedule_lint();
    void schedule_model_pass(const std::u16string& snapshot);
    void redraw();
    void redraw_now();
    void hide_marks();
    void tick();  // 30Hz while something is visible: hover and Esc
    void apply(const Suggestion& s, const std::u16string& replacement);
    void dismiss(const Suggestion& s);
    void update_geometry_watch();

    std::shared_ptr<HarperEngine> harper_;
    std::shared_ptr<SerialQueue> lint_queue_;
    std::shared_ptr<ModelChecker> model_;
    std::shared_ptr<SerialQueue> model_queue_;

    UiaWatcher watcher_;
    Overlay overlay_;
    IssueBadge badge_;
    SelectionBar bar_;

    bool running_ = false;
    std::optional<UiaWatcher::Focus> focus_;
    std::u16string text_;
    std::vector<Suggestion> suggestions_;
    std::vector<Suggestion> badge_suggestions_;
    std::set<std::u16string> dismissed_;
    uint64_t lint_generation_ = 0;
    uint64_t selection_generation_ = 0;
    UINT_PTR lint_timer_ = 0, model_timer_ = 0, selection_timer_ = 0, tick_timer_ = 0;
    bool redraw_pending_ = false;
    bool pointer_on_badge_ = false;

    // For the diagnostic.
    int last_lint_count_ = -1, last_rect_count_ = -1, last_visible_count_ = -1;
    RECT last_field_{};
    std::wstring last_note_ = L"nothing yet";
};

}  // namespace nib::app

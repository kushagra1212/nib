#include "inline/uia_watcher.hpp"

#include "app/dispatch.hpp"
#include "lint/suggestion.hpp"
#include "support/log.hpp"

namespace nib::app {
namespace {

bool same_rect(const RECT& a, const RECT& b) {
    return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
}

UiaWatcher::Focus snapshot(text::Uia& uia, const text::Field& f) {
    UiaWatcher::Focus out;
    out.role = f.role;
    out.app = f.app;
    out.label = f.label;
    out.window = f.window;
    out.has_text_pattern = f.has_text;
    if (auto r = uia.frame(f)) out.frame = *r;
    return out;
}

}  // namespace

UiaWatcher::UiaWatcher() = default;

UiaWatcher::~UiaWatcher() { stop(); }

void UiaWatcher::start() {
    if (running_) return;
    running_ = true;
    thread_ = std::thread([this] { run(); });
}

void UiaWatcher::stop() {
    if (!running_) return;
    running_ = false;
    wake_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void UiaWatcher::watch_geometry(bool needed, std::optional<nib_range> sentinel) {
    std::lock_guard lock(geometry_lock_);
    geometry_needed_ = needed;
    sentinel_ = sentinel;
}

void UiaWatcher::post(Task task) {
    {
        std::lock_guard lock(lock_);
        tasks_.push_back(std::move(task));
    }
    wake_.notify_all();
}

void UiaWatcher::expect_text(const std::u16string& text) {
    post([this, text](text::Uia&, const text::Field*) { last_text_ = text; });
}

void UiaWatcher::run() {
    text::Uia uia;
    if (!uia.ok()) {
        log::write("live: UI Automation is unavailable");
        running_ = false;
        return;
    }
    auto next_poll = std::chrono::steady_clock::now();
    while (running_) {
        std::deque<Task> batch;
        {
            std::unique_lock lock(lock_);
            wake_.wait_until(lock, next_poll, [&] { return !tasks_.empty() || !running_; });
            batch.swap(tasks_);
        }
        if (!running_) break;
        for (auto& task : batch) {
            try {
                task(uia, current_ ? &*current_ : nullptr);
            } catch (...) {
                // A provider that throws must not take the watcher down.
            }
        }
        if (std::chrono::steady_clock::now() >= next_poll) {
            try {
                poll(uia);
                poll_geometry(uia);
            } catch (...) {
            }
            next_poll = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
        }
    }
    current_.reset();
}

void UiaWatcher::poll(text::Uia& uia) {
    Microsoft::WRL::ComPtr<IUIAutomationElement> focused;
    if (FAILED(uia.automation()->GetFocusedElement(&focused)) || !focused) return;

    // nib's own windows taking focus -- the panel, a dialog -- is not the user
    // leaving their field.
    int pid = 0;
    focused->get_CurrentProcessId(&pid);
    if (static_cast<DWORD>(pid) == GetCurrentProcessId()) return;

    if (current_) {
        BOOL same = FALSE;
        uia.automation()->CompareElements(current_->element.Get(), focused.Get(), &same);
        if (same) {
            // Same field: report what changed in it. Bounded read: a field
            // over the live limit is not checked anyway.
            if (auto text = uia.text(*current_); text && *text != last_text_) {
                last_text_ = *text;
                on_ui([this, t = *text] {
                    if (on_text) on_text(t);
                });
            }
            if (auto sel = uia.selection(*current_)) {
                if (sel->text != last_selection_ || !(sel->range == last_range_)) {
                    last_selection_ = sel->text;
                    last_range_ = sel->range;
                    on_ui([this, s = *sel] {
                        if (on_selection) on_selection(s.text, s.range);
                    });
                }
            }
            return;
        }
    }

    auto field = uia.describe(focused.Get());
    // Eligibility covers more than the role: a password field is an ordinary
    // edit wearing IsPassword, and reading one hands a password to the linter.
    if (!field || !text::may_read(*field)) {
        if (current_) {
            current_.reset();
            last_text_.clear();
            last_selection_.clear();
            on_ui([this] {
                if (on_focus) on_focus(std::nullopt, u"");
            });
        }
        return;
    }
    current_ = std::move(field);
    last_text_ = uia.text(*current_).value_or(u"");
    last_selection_.clear();
    last_range_ = {0, 0};
    last_sentinel_.reset();
    auto focus = snapshot(uia, *current_);
    last_frame_ = focus.frame;
    on_ui([this, focus, t = last_text_] {
        if (on_focus) on_focus(focus, t);
    });
}

void UiaWatcher::poll_geometry(text::Uia& uia) {
    bool needed;
    std::optional<nib_range> sentinel;
    {
        std::lock_guard lock(geometry_lock_);
        needed = geometry_needed_;
        sentinel = sentinel_;
    }
    // Nothing on screen means nothing to reposition: skip the cross-process
    // calls while the text is clean.
    if (!current_ || !needed) return;
    bool moved = false;
    if (auto frame = uia.frame(*current_); frame && !same_rect(*frame, last_frame_)) {
        last_frame_ = *frame;
        moved = true;
    }
    // Scrolling inside a field moves the text, not the field; one marked
    // range's position catches that, and reflow too.
    if (sentinel && sentinel->length > 0) {
        const auto rects = uia.bounds(*current_, *sentinel);
        const std::optional<RECT> now = rects.empty() ? std::nullopt : std::optional<RECT>(rects.front());
        const bool differs = now.has_value() != last_sentinel_.has_value()
                             || (now && last_sentinel_ && !same_rect(*now, *last_sentinel_));
        if (differs) {
            last_sentinel_ = now;
            moved = true;
        }
    }
    if (moved) {
        on_ui([this] {
            if (on_geometry) on_geometry();
        });
    }
}

}  // namespace nib::app

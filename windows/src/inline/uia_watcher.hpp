#pragma once
#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include "text/uia.hpp"

namespace nib::app {

// Port of AXWatcher: follows the focused field and reports what changes.
//
// Runs on a thread of its own, which is also where every UI Automation call
// the live checker makes is executed: calls into another process can block on
// it, and none of that may stall nib's windows. Polled at 5Hz -- one cheap
// focus read, then the text and selection of the field already held. A field
// can move without its text changing (scrolling, a window drag), and nothing
// says so, so its frame and one marked range are sampled too.
class UiaWatcher {
public:
    struct Focus {
        std::wstring role;
        std::wstring app;
        std::wstring label;
        HWND window = nullptr;
        RECT frame{};
        bool has_text_pattern = false;
    };

    UiaWatcher();
    ~UiaWatcher();

    // Delivered on the UI thread.
    std::function<void(std::optional<Focus>, std::u16string text)> on_focus;
    std::function<void(std::u16string text)> on_text;
    std::function<void(std::u16string selected, nib_range range)> on_selection;
    std::function<void()> on_geometry;

    void start();
    void stop();
    bool running() const { return running_.load(); }

    // What the geometry poll should watch; set from the UI thread.
    void watch_geometry(bool needed, std::optional<nib_range> sentinel);

    // Runs `task` on the watcher thread with the field currently held (null
    // when none). Tasks run in order, before the next poll.
    using Task = std::function<void(text::Uia&, const text::Field*)>;
    void post(Task task);

    // Ignores the next text change: nib just wrote it.
    void expect_text(const std::u16string& text);

private:
    void run();
    void poll(text::Uia& uia);
    void poll_geometry(text::Uia& uia);

    std::thread thread_;
    std::atomic<bool> running_{false};
    std::mutex lock_;
    std::condition_variable wake_;
    std::deque<Task> tasks_;

    // Watcher-thread state.
    std::optional<text::Field> current_;
    std::u16string last_text_;
    std::u16string last_selection_;
    nib_range last_range_{0, 0};
    RECT last_frame_{};
    std::optional<RECT> last_sentinel_;

    std::mutex geometry_lock_;
    bool geometry_needed_ = false;
    std::optional<nib_range> sentinel_;
};

}  // namespace nib::app

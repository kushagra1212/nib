#pragma once
#include <windows.h>

#include <functional>
#include <string>
#include <string_view>

// Two threads matter in nib: the UI thread, which owns every window, and the
// workers the engines block on. The engines' calls block -- a lint is ~30ms, a
// rewrite seconds -- so they never run on the UI thread, and their results
// come back through the UI thread's message queue.

namespace nib::app {

// Called once, on the UI thread, before anything posts.
void init_dispatch();

// Runs `fn` on the UI thread, soon. Safe from any thread.
void on_ui(std::function<void()> fn);

// Runs `work` on a background thread, then `done` on the UI thread.
void in_background(std::function<void()> work);

// A queue served by one thread, for engines that must not be called
// concurrently and whose calls should run in order.
class SerialQueue {
public:
    explicit SerialQueue(const char* name);
    ~SerialQueue();
    void post(std::function<void()> task);
    // Drops tasks not yet started.
    void clear();

private:
    struct Impl;
    Impl* impl_;
};

// Fires `fn` on the UI thread after `ms`, once. Returns an id for cancel().
UINT_PTR after(unsigned ms, std::function<void()> fn);
void cancel(UINT_PTR id);

// The UTF-16 the core speaks and the wchar_t Win32 speaks are the same units.
inline std::wstring wide(std::u16string_view s) { return std::wstring(s.begin(), s.end()); }
inline std::u16string u16(std::wstring_view s) { return std::u16string(s.begin(), s.end()); }
std::wstring widen(std::string_view utf8);
std::string narrow(std::wstring_view s);

}  // namespace nib::app

#include "app/dispatch.hpp"

#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

namespace nib::app {
namespace {

constexpr UINT WM_NIB_RUN = WM_APP + 0x100;
HWND sink = nullptr;
DWORD ui_thread = 0;

std::mutex timers_lock;
std::map<UINT_PTR, std::function<void()>> timers;

LRESULT CALLBACK sink_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_NIB_RUN) {
        auto* fn = reinterpret_cast<std::function<void()>*>(lp);
        (*fn)();
        delete fn;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

void CALLBACK timer_proc(HWND, UINT, UINT_PTR id, DWORD) {
    KillTimer(nullptr, id);
    std::function<void()> fn;
    {
        std::lock_guard lock(timers_lock);
        const auto it = timers.find(id);
        if (it == timers.end()) return;
        fn = std::move(it->second);
        timers.erase(it);
    }
    if (fn) fn();
}

}  // namespace

void init_dispatch() {
    ui_thread = GetCurrentThreadId();
    WNDCLASSW wc{};
    wc.lpfnWndProc = sink_proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"nib.dispatch";
    RegisterClassW(&wc);
    // Message-only: never shown, never enumerated, only delivers.
    sink = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                           nullptr, wc.hInstance, nullptr);
}

void on_ui(std::function<void()> fn) {
    if (!sink) return;
    auto* boxed = new std::function<void()>(std::move(fn));
    if (!PostMessageW(sink, WM_NIB_RUN, 0, reinterpret_cast<LPARAM>(boxed))) delete boxed;
}

void in_background(std::function<void()> work) {
    std::thread(std::move(work)).detach();
}

struct SerialQueue::Impl {
    std::mutex lock;
    std::condition_variable wake;
    std::deque<std::function<void()>> tasks;
    bool closing = false;
    std::thread thread;
};

SerialQueue::SerialQueue(const char*) : impl_(new Impl) {
    impl_->thread = std::thread([impl = impl_] {
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock lock(impl->lock);
                impl->wake.wait(lock, [&] { return impl->closing || !impl->tasks.empty(); });
                if (impl->closing) return;
                task = std::move(impl->tasks.front());
                impl->tasks.pop_front();
            }
            try {
                task();
            } catch (...) {
                // An engine failure must not take the worker -- and with it
                // every later task -- down.
            }
        }
    });
}

SerialQueue::~SerialQueue() {
    {
        std::lock_guard lock(impl_->lock);
        impl_->closing = true;
        impl_->tasks.clear();
    }
    impl_->wake.notify_all();
    // Detached rather than joined: a task may be blocked for seconds inside a
    // model call, and quitting nib must not wait for it. The job object kills
    // the engine process, which unblocks the call.
    impl_->thread.detach();
}

void SerialQueue::post(std::function<void()> task) {
    {
        std::lock_guard lock(impl_->lock);
        impl_->tasks.push_back(std::move(task));
    }
    impl_->wake.notify_one();
}

void SerialQueue::clear() {
    std::lock_guard lock(impl_->lock);
    impl_->tasks.clear();
}

UINT_PTR after(unsigned ms, std::function<void()> fn) {
    std::lock_guard lock(timers_lock);
    const UINT_PTR id = SetTimer(nullptr, 0, ms, timer_proc);
    if (id) timers[id] = std::move(fn);
    return id;
}

void cancel(UINT_PTR id) {
    if (!id) return;
    KillTimer(nullptr, id);
    std::lock_guard lock(timers_lock);
    timers.erase(id);
}

std::wstring widen(std::string_view s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

std::string narrow(std::wstring_view s) {
    if (s.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0,
                                      nullptr, nullptr);
    std::string out(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n, nullptr,
                        nullptr);
    return out;
}

}  // namespace nib::app

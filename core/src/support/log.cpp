#include "support/log.hpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <fstream>
#include <mutex>
#include "platform/paths.hpp"

namespace nib::log {
namespace {

constexpr size_t ring_limit = 500;
constexpr std::uintmax_t file_limit = 4'000'000;

struct State {
    std::mutex lock;
    std::deque<std::string> ring;
    std::atomic<bool> file{std::getenv("NIB_LOG") != nullptr};
    const std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
};

State& state() {
    static State s;
    return s;
}

}  // namespace

void write(std::string_view message) {
    auto& s = state();
    const double seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - s.started).count();
    char stamp[32];
    std::snprintf(stamp, sizeof stamp, "%8.3f  ", seconds);
    std::string line = stamp;
    line.append(message);

    std::lock_guard lock(s.lock);
    s.ring.push_back(line);
    while (s.ring.size() > ring_limit) s.ring.pop_front();

    if (!s.file.load()) return;
    const auto path = platform::paths::log_file();
    if (path.empty()) return;
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    // Keep the file from growing without bound across long sessions.
    const bool too_big = std::filesystem::file_size(path, ec) > file_limit && !ec;
    std::ofstream out(path, std::ios::binary | (too_big ? std::ios::trunc : std::ios::app));
    out << line << '\n';
}

bool file_enabled() { return state().file.load(); }
void set_file_enabled(bool enabled) { state().file.store(enabled); }

std::vector<std::string> recent() {
    auto& s = state();
    std::lock_guard lock(s.lock);
    return std::vector<std::string>(s.ring.begin(), s.ring.end());
}

void reset() {
    auto& s = state();
    std::lock_guard lock(s.lock);
    s.ring.clear();
    if (!s.file.load()) return;
    const auto path = platform::paths::log_file();
    if (!path.empty()) std::ofstream(path, std::ios::trunc);
}

}  // namespace nib::log

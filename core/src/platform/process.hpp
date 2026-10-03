#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace nib::platform {

struct ProcessError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// A child process with pipes, owned by nib.
//
// Every child is placed in one job object created with KILL_ON_JOB_CLOSE, so
// when nib exits -- cleanly, by crash, or by Task Manager -- Windows kills
// harper-ls and llama-server with it. On macOS nib needed a reaper to collect
// llama-servers reparented to launchd, each holding 2.7GB; here the kernel
// does it and there is nothing to reap.
//
// Children are created without a console window. nib is a GUI process, and a
// console child would otherwise flash a black window for every spawn.
class ChildProcess {
public:
    struct Options {
        std::u16string              executable;
        std::vector<std::u16string> arguments;
        bool pipe_stdin = false;
        // Called on a reader thread with each chunk as it arrives. Null means
        // the stream is discarded.
        std::function<void(std::string_view)> on_stdout;
        std::function<void(std::string_view)> on_stderr;
        // Called once, on a watcher thread, when the process exits by itself.
        // Not called after terminate().
        std::function<void(uint32_t exit_code)> on_exit;
    };

    static std::unique_ptr<ChildProcess> start(Options options);
    ~ChildProcess();

    ChildProcess(const ChildProcess&) = delete;
    ChildProcess& operator=(const ChildProcess&) = delete;

    bool running() const;
    uint32_t pid() const;
    // False when the pipe is closed, which means the process has gone.
    bool write(std::string_view bytes);
    // Kills the process and waits for the reader threads to finish.
    void terminate();

private:
    struct Impl;
    explicit ChildProcess(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

uint32_t current_pid();

// An unused loopback port, found by binding port 0 and releasing it. 0 when
// the socket layer refuses.
uint16_t free_loopback_port();

// Logical processors, for sizing thread pools.
uint32_t processor_count();

// Quotes one argument the way CommandLineToArgvW will read it back.
std::u16string quote_argument(const std::u16string& argument);

}  // namespace nib::platform

#pragma once
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include "platform/process.hpp"
#include "rewrite/rewrite_mode.hpp"
#include "rewrite/rewrite_text.hpp"

namespace nib {

struct RewriteException : std::runtime_error {
    RewriteError error;
    explicit RewriteException(RewriteError e);
};

// What ModelChecker needs from an engine, so it can be tested with a fake.
class Rewriter {
public:
    virtual ~Rewriter() = default;
    // Throws RewriteException.
    virtual std::u16string rewrite(const std::u16string& text, RewriteMode mode) = 0;
};

// Port of RewriteEngine: runs a local GGUF model through llama-server.
//
// A subprocess rather than linked libllama: it isolates crashes, and killing
// the process is the simplest way to actually return the model's memory when
// it goes idle. The model is most of nib's footprint, so it is not resident.
class RewriteEngine : public Rewriter {
public:
    struct Config {
        std::filesystem::path server_binary;
        std::filesystem::path model_path;
        // Two minutes: the 4B holds 2.7GB, 96% of the footprint. Five minutes
        // of that after every rewrite was reported as "nib takes a lot of RAM".
        std::chrono::seconds idle_timeout{120};
        int32_t context_size = 2048;
        // A policy ceiling; token_budget clamps it against the window.
        int32_t max_tokens = 1024;
        // Greedy: a correction has a right answer, and the cache only works
        // if the same input yields the same output.
        double temperature = 0.0;
        // Half the cores, so a rewrite does not compete with the user.
        int32_t threads = default_threads();

        static int32_t default_threads();
    };

    explicit RewriteEngine(Config config);
    ~RewriteEngine() override;

    std::u16string rewrite(const std::u16string& text, RewriteMode mode) override;

    bool loaded() const;
    void shutdown();
    const Config& config() const { return config_; }

private:
    uint16_t ensure_running();
    void wait_until_healthy(uint16_t port);
    void schedule_idle_shutdown();
    void idle_loop();
    void shutdown_locked();

    Config config_;

    std::mutex request_lock_;  // one rewrite at a time: --parallel 1

    mutable std::mutex state_lock_;
    std::unique_ptr<platform::ChildProcess> process_;
    uint16_t port_ = 0;
    std::string error_log_;  // bounded tail of llama-server's stderr
    std::mutex error_lock_;

    std::condition_variable idle_wake_;
    std::chrono::steady_clock::time_point idle_deadline_{};
    bool idle_armed_ = false;
    bool closing_ = false;
    std::thread idle_thread_;
};

}  // namespace nib

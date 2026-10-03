#pragma once
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include <nlohmann/json.hpp>
#include "lint/message_framer.hpp"
#include "platform/process.hpp"

namespace nib {

struct LspError : std::runtime_error {
    enum class Kind { not_running, launch_failed, server, timed_out };
    Kind kind;
    LspError(Kind k, const std::string& what) : std::runtime_error(what), kind(k) {}
};

// Port of LSPClient: JSON-RPC over a language server's stdio.
//
// Deliberately untyped: LSP payloads are heterogeneous and modelling every
// message costs far more than it returns. Callers pluck out what they need.
//
// Requests block the calling thread until the matching response arrives or
// the timeout passes. Server-to-client traffic is handled on the reader thread.
class LspClient {
public:
    using json = nlohmann::json;

    // Answers a server-to-client request; return the `result` value.
    std::function<json(const std::string& method, const json& params)> on_request;
    std::function<void(const std::string& method, const json& params)> on_notification;
    // The server exited on its own.
    std::function<void(uint32_t code)> on_exit;

    ~LspClient();

    void start(const std::u16string& executable, const std::vector<std::u16string>& arguments);
    void stop();
    bool running() const;

    void notify(const std::string& method, const json& params);
    json request(const std::string& method, const json& params, int32_t timeout_ms = 10'000);

private:
    struct Pending {
        bool done = false;
        json result;
        std::unique_ptr<LspError> error;
    };

    void write(const json& message);
    void ingest(std::string_view bytes);
    void dispatch(const json& message);
    void resolve(int64_t id, json result, std::unique_ptr<LspError> error);
    void fail_all(const LspError& error);

    std::unique_ptr<platform::ChildProcess> process_;
    MessageFramer framer_;
    std::mutex framer_lock_;

    std::mutex lock_;
    std::condition_variable changed_;
    std::map<int64_t, std::shared_ptr<Pending>> pending_;
    int64_t next_id_ = 1;
};

}  // namespace nib

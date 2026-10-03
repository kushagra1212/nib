#include "lint/lsp_client.hpp"

#include <chrono>
#include "support/log.hpp"

namespace nib {

LspClient::~LspClient() { stop(); }

void LspClient::start(const std::u16string& executable,
                      const std::vector<std::u16string>& arguments) {
    platform::ChildProcess::Options options;
    options.executable = executable;
    options.arguments = arguments;
    options.pipe_stdin = true;
    options.on_stdout = [this](std::string_view bytes) { ingest(bytes); };
    options.on_stderr = [](std::string_view bytes) {
        // harper's own complaints, such as a missing "harper-ls" settings key,
        // arrive only here. Lengths only would hide them, and they carry no
        // document text, so the first line is kept.
        const auto nl = bytes.find('\n');
        log::write("[harper-ls] " + std::string(bytes.substr(0, std::min<size_t>(nl, 200))));
    };
    options.on_exit = [this](uint32_t code) {
        fail_all(LspError(LspError::Kind::not_running, "language server is not running"));
        if (on_exit) on_exit(code);
    };
    try {
        process_ = platform::ChildProcess::start(std::move(options));
    } catch (const std::exception& e) {
        throw LspError(LspError::Kind::launch_failed,
                       std::string("could not launch language server: ") + e.what());
    }
}

void LspClient::stop() {
    if (process_) {
        process_->terminate();
        process_.reset();
    }
    fail_all(LspError(LspError::Kind::not_running, "language server is not running"));
    std::lock_guard lock(framer_lock_);
    framer_ = MessageFramer();
}

bool LspClient::running() const { return process_ && process_->running(); }

void LspClient::notify(const std::string& method, const json& params) {
    write({{"jsonrpc", "2.0"}, {"method", method}, {"params", params}});
}

LspClient::json LspClient::request(const std::string& method, const json& params,
                                   int32_t timeout_ms) {
    if (!running()) throw LspError(LspError::Kind::not_running, "language server is not running");

    auto pending = std::make_shared<Pending>();
    int64_t id;
    {
        std::lock_guard lock(lock_);
        id = next_id_++;
        pending_[id] = pending;
    }
    write({{"jsonrpc", "2.0"}, {"id", id}, {"method", method}, {"params", params}});

    std::unique_lock lock(lock_);
    const bool answered = changed_.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                                            [&] { return pending->done; });
    if (!answered) {
        pending_.erase(id);
        throw LspError(LspError::Kind::timed_out, "timed out waiting for " + method);
    }
    if (pending->error) throw *pending->error;
    return std::move(pending->result);
}

void LspClient::write(const json& message) {
    // A broken pipe means the server died between the check and the write;
    // every waiter is failed rather than left to time out.
    const std::string framed = MessageFramer::encode(message.dump());
    if (!process_ || !process_->write(framed)) {
        fail_all(LspError(LspError::Kind::not_running, "language server is not running"));
    }
}

void LspClient::ingest(std::string_view bytes) {
    std::vector<std::string> messages;
    {
        std::lock_guard lock(framer_lock_);
        messages = framer_.push(bytes);
    }
    for (const auto& body : messages) {
        auto message = json::parse(body, nullptr, false);
        if (message.is_object()) dispatch(message);
    }
}

void LspClient::dispatch(const json& message) {
    const auto method = message.find("method");
    const auto id = message.find("id");
    const bool has_method = method != message.end() && method->is_string();
    const bool has_id = id != message.end() && !id->is_null();
    static const json empty = json::object();
    const auto params_it = message.find("params");
    const json& params = params_it != message.end() ? *params_it : empty;

    if (has_method && has_id) {
        // Server -> client request.
        json result = on_request ? on_request(method->get<std::string>(), params) : json();
        write({{"jsonrpc", "2.0"}, {"id", *id}, {"result", result}});
    } else if (has_method) {
        if (on_notification) on_notification(method->get<std::string>(), params);
    } else if (has_id && id->is_number_integer()) {
        const auto error = message.find("error");
        if (error != message.end() && error->is_object()) {
            const int code = error->value("code", -1);
            const std::string text = error->value("message", std::string("unknown"));
            resolve(id->get<int64_t>(), json(),
                    std::make_unique<LspError>(LspError::Kind::server,
                                               "server error " + std::to_string(code) + ": " + text));
        } else {
            const auto result = message.find("result");
            resolve(id->get<int64_t>(), result != message.end() ? *result : json(), nullptr);
        }
    }
}

void LspClient::resolve(int64_t id, json result, std::unique_ptr<LspError> error) {
    std::lock_guard lock(lock_);
    const auto it = pending_.find(id);
    if (it == pending_.end()) return;  // timed out already
    it->second->done = true;
    it->second->result = std::move(result);
    it->second->error = std::move(error);
    pending_.erase(it);
    changed_.notify_all();
}

void LspClient::fail_all(const LspError& error) {
    std::lock_guard lock(lock_);
    for (auto& [id, pending] : pending_) {
        pending->done = true;
        pending->error = std::make_unique<LspError>(error);
    }
    pending_.clear();
    changed_.notify_all();
}

}  // namespace nib

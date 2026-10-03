#include "rewrite/rewrite_engine.hpp"

#include <algorithm>
#include <nlohmann/json.hpp>
#include "platform/http.hpp"
#include "support/log.hpp"
#include "text/unicode.hpp"

namespace nib {
namespace {

std::string narrow(const std::u16string& s) { return utf16_to_utf8(s); }
std::u16string u16(const std::filesystem::path& p) {
    const std::wstring w = p.wstring();
    return std::u16string(w.begin(), w.end());
}

std::string base_url(uint16_t port) { return "http://127.0.0.1:" + std::to_string(port); }

}  // namespace

RewriteException::RewriteException(RewriteError e)
    : std::runtime_error(narrow(e.description())), error(std::move(e)) {}

int32_t RewriteEngine::Config::default_threads() {
    return std::max<int32_t>(2, static_cast<int32_t>(platform::processor_count() / 2));
}

RewriteEngine::RewriteEngine(Config config) : config_(std::move(config)) {
    idle_thread_ = std::thread([this] { idle_loop(); });
}

RewriteEngine::~RewriteEngine() {
    {
        std::lock_guard lock(state_lock_);
        closing_ = true;
        idle_wake_.notify_all();
    }
    idle_thread_.join();
    std::lock_guard lock(state_lock_);
    shutdown_locked();
}

bool RewriteEngine::loaded() const {
    std::lock_guard lock(state_lock_);
    return process_ && process_->running();
}

void RewriteEngine::shutdown() {
    std::lock_guard lock(state_lock_);
    shutdown_locked();
}

void RewriteEngine::shutdown_locked() {
    idle_armed_ = false;
    if (process_) {
        process_->terminate();
        process_.reset();
        log::write("llama-server stopped");
    }
    port_ = 0;
    std::lock_guard e(error_lock_);
    error_log_.clear();
}

std::u16string RewriteEngine::rewrite(const std::u16string& text, RewriteMode mode) {
    // Refused before the model is woken. A selection whose own tokens fill the
    // window leaves nothing for a reply, and paying a cold start plus two
    // requests to discover that is time spent watching dots.
    if (grapheme_count(text) / 4 + rewrite_text::prompt_overhead >= config_.context_size) {
        log::write("selection too long for the window: " + std::to_string(text.size()) + " units");
        throw RewriteException({RewriteError::Kind::truncated, {}, 0});
    }

    std::lock_guard request(request_lock_);
    const uint16_t port = ensure_running();
    schedule_idle_shutdown();

    // The instruction is a system message so it stays byte-identical between
    // calls, which lets the server reuse the cached prefix.
    nlohmann::json messages = nlohmann::json::array({
        {{"role", "system"}, {"content", narrow(rewrite_mode::system_prompt(mode))}},
        {{"role", "user"}, {"content", narrow(text)}},
    });

    int32_t budget = rewrite_text::token_budget(text, config_.max_tokens, config_.context_size);

    // Two attempts at most. A reply that stopped for room is a budget that was
    // too small, not a bad rewrite; doubling once fixes the common case.
    for (int attempt = 1; attempt <= 2; ++attempt) {
        const nlohmann::json body = {
            {"messages", messages},
            {"temperature", config_.temperature},
            {"top_k", 1},
            {"max_tokens", budget},
            {"stream", false},
            {"chat_template_kwargs", {{"enable_thinking", false}}},
        };
        {
            std::lock_guard e(error_lock_);
            error_log_.clear();
        }
        platform::http::Response response;
        try {
            response = platform::http::post_json(base_url(port) + "/v1/chat/completions",
                                                 body.dump(), 120'000);
        } catch (const platform::http::HttpError& e) {
            // A timeout and a dropped connection are not a missing model, and
            // reporting them as one sent people to reinstall a model that was
            // sitting right there.
            using K = platform::http::HttpError::Kind;
            const auto kind = e.kind == K::timed_out ? RewriteError::Kind::timed_out
                              : e.kind == K::other   ? RewriteError::Kind::server_failed
                                                     : RewriteError::Kind::connection_lost;
            throw RewriteException({kind, utf8_to_utf16(e.what()), 0});
        }

        if (response.status < 200 || response.status >= 300) {
            std::string log;
            {
                std::lock_guard e(error_lock_);
                log = error_log_;
            }
            throw RewriteException(rewrite_text::failure(response.status, response.body, log));
        }

        const auto json = nlohmann::json::parse(response.body, nullptr, false);
        const nlohmann::json* first = nullptr;
        if (json.is_object() && json.contains("choices") && json["choices"].is_array()
            && !json["choices"].empty()) {
            first = &json["choices"][0];
        }
        if (!first || !first->contains("message") || !(*first)["message"].is_object()
            || !(*first)["message"].contains("content")
            || !(*first)["message"]["content"].is_string()) {
            throw RewriteException({RewriteError::Kind::bad_response, {}, 0});
        }
        const std::string content = (*first)["message"]["content"].get<std::string>();

        // The server states this directly; a reply cut short by the cap looks
        // exactly like a model that chose to stop.
        if (first->value("finish_reason", std::string()) != "length") {
            return rewrite_text::clean(utf8_to_utf16(content));
        }

        log::write("rewrite hit the token cap at " + std::to_string(budget) + ", attempt "
                   + std::to_string(attempt));
        const int32_t room = rewrite_text::headroom(text, config_.context_size);
        const int32_t doubled = std::min(room, budget * 2);
        if (doubled <= budget) break;
        budget = doubled;
    }
    throw RewriteException({RewriteError::Kind::truncated, {}, 0});
}

uint16_t RewriteEngine::ensure_running() {
    {
        std::lock_guard lock(state_lock_);
        if (process_ && process_->running() && port_) return port_;
        shutdown_locked();
    }

    std::error_code ec;
    if (!std::filesystem::is_regular_file(config_.model_path, ec)) {
        throw RewriteException({RewriteError::Kind::model_missing, u16(config_.model_path), 0});
    }
    if (!std::filesystem::is_regular_file(config_.server_binary, ec)) {
        throw RewriteException({RewriteError::Kind::server_failed,
                                u"binary not found at " + u16(config_.server_binary), 0});
    }

    const uint16_t port = platform::free_loopback_port();
    if (!port) throw RewriteException({RewriteError::Kind::server_failed, u"no free port", 0});

    platform::ChildProcess::Options options;
    options.executable = u16(config_.server_binary);
    options.arguments = {
        u"--model", u16(config_.model_path),
        u"--port", to_u16(port),
        u"--host", u"127.0.0.1",
        u"--ctx-size", to_u16(config_.context_size),
        // --log-disable deliberately not passed: it silences the out-of-memory
        // report, the one message worth having. The output goes only to the
        // bounded buffer, read to find that failure and never shown.
        u"--n-gpu-layers", u"99",
        u"--flash-attn", u"on",
        // Qwen3 reasons out loud by default. Every token of that is latency
        // for output nib throws away -- the largest cost in the whole path.
        u"--reasoning", u"off",
        u"--reasoning-budget", u"0",
        // Reuse the cached prefix: only the user's sentence is new each time.
        u"--cache-reuse", u"128",
        // One slot: nib never issues concurrent rewrites, and each slot
        // reserves its own KV cache.
        u"--parallel", u"1",
        u"--threads", to_u16(config_.threads),
    };
    options.on_stderr = [this](std::string_view chunk) {
        std::lock_guard e(error_lock_);
        error_log_.append(chunk);
        if (error_log_.size() > 8'000) error_log_.erase(0, error_log_.size() - 4'000);
    };

    std::unique_ptr<platform::ChildProcess> child;
    try {
        child = platform::ChildProcess::start(std::move(options));
    } catch (const std::exception& e) {
        throw RewriteException({RewriteError::Kind::server_failed, utf8_to_utf16(e.what()), 0});
    }
    log::write("llama-server starting on port " + std::to_string(port));
    {
        std::lock_guard lock(state_lock_);
        process_ = std::move(child);
        port_ = port;
    }
    wait_until_healthy(port);
    return port;
}

void RewriteEngine::wait_until_healthy(uint16_t port) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
    while (std::chrono::steady_clock::now() < deadline) {
        {
            std::lock_guard lock(state_lock_);
            if (!process_ || !process_->running()) {
                std::string log;
                {
                    std::lock_guard e(error_lock_);
                    log = error_log_;
                }
                shutdown_locked();
                // A model too large fails here, at load, before any request.
                const auto lowered = lowercased(utf8_to_utf16(log));
                for (const char16_t* marker : {u"out of memory", u"failed to allocate",
                                               u"unable to allocate", u"insufficient memory"}) {
                    if (contains(lowered, marker)) {
                        throw RewriteException({RewriteError::Kind::out_of_memory, {}, 0});
                    }
                }
                throw RewriteException({RewriteError::Kind::server_failed, u"exited during startup", 0});
            }
        }
        try {
            if (platform::http::get(base_url(port) + "/health", 2'000).status == 200) return;
        } catch (const std::exception&) {
            // Not listening yet.
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    shutdown();
    throw RewriteException({RewriteError::Kind::server_failed, u"did not become healthy within 60s", 0});
}

void RewriteEngine::schedule_idle_shutdown() {
    std::lock_guard lock(state_lock_);
    idle_deadline_ = std::chrono::steady_clock::now() + config_.idle_timeout;
    idle_armed_ = true;
    idle_wake_.notify_all();
}

void RewriteEngine::idle_loop() {
    std::unique_lock lock(state_lock_);
    while (!closing_) {
        if (!idle_armed_) {
            idle_wake_.wait(lock);
            continue;
        }
        const auto deadline = idle_deadline_;
        if (idle_wake_.wait_until(lock, deadline) == std::cv_status::timeout
            && idle_armed_ && idle_deadline_ == deadline && !closing_) {
            // Not while a request is in flight: the deadline is pushed forward
            // by every request, so reaching it means none started since.
            if (request_lock_.try_lock()) {
                shutdown_locked();
                request_lock_.unlock();
            } else {
                idle_deadline_ = std::chrono::steady_clock::now() + config_.idle_timeout;
            }
        }
    }
}

}  // namespace nib

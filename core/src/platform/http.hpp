#pragma once
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>

namespace nib::platform::http {

struct HttpError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct Response {
    int32_t     status = 0;
    std::string body;
};

// A request to llama-server on loopback. Throws HttpError when no answer
// arrives at all (refused, timed out); a non-2xx status is a Response.
Response get(const std::string& url, int32_t timeout_ms);
Response post_json(const std::string& url, const std::string& body, int32_t timeout_ms);

// Streams `url` to `destination`, reporting (received, total) as it goes;
// total is 0 when the server does not say. Redirects are followed, which
// Hugging Face needs: every model URL answers 302 to a CDN.
//
// Returns the final HTTP status. Throws HttpError on a transport failure.
// Setting `cancel` stops the transfer and returns 0.
int32_t download(const std::string& url, const std::filesystem::path& destination,
                 const std::function<void(int64_t received, int64_t total)>& progress,
                 const std::atomic<bool>& cancel);

}  // namespace nib::platform::http

#include "lint/message_framer.hpp"

#include <cctype>
#include <charconv>

namespace nib {

std::vector<std::string> MessageFramer::push(std::string_view bytes) {
    buffer_.append(bytes);
    std::vector<std::string> out;
    // Loop until no more complete messages: take_one returns nullopt both for
    // "need more bytes" and after dropping a bad header, so a bad header is
    // retried from the next byte rather than ending the drain.
    for (;;) {
        const size_t before = buffer_.size();
        auto message = take_one();
        if (message) {
            out.push_back(std::move(*message));
            continue;
        }
        if (buffer_.size() == before) break;
    }
    return out;
}

std::optional<std::string> MessageFramer::take_one() {
    const size_t header_end = buffer_.find("\r\n\r\n");
    if (header_end == std::string::npos) return std::nullopt;

    const auto length = content_length(std::string_view(buffer_).substr(0, header_end));
    const size_t body_start = header_end + 4;
    if (!length) {
        // Unparseable header: drop it so one bad frame cannot wedge the stream.
        buffer_.erase(0, body_start);
        return std::nullopt;
    }
    if (buffer_.size() - body_start < *length) return std::nullopt;  // body incomplete

    std::string body = buffer_.substr(body_start, *length);
    buffer_.erase(0, body_start + *length);
    return body;
}

std::optional<size_t> MessageFramer::content_length(std::string_view header) {
    size_t pos = 0;
    while (pos <= header.size()) {
        size_t end = header.find("\r\n", pos);
        if (end == std::string_view::npos) end = header.size();
        const std::string_view line = header.substr(pos, end - pos);
        pos = end + 2;
        if (line.empty()) continue;

        const size_t colon = line.find(':');
        if (colon == std::string_view::npos) continue;
        std::string name(line.substr(0, colon));
        for (auto& c : name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if (name != "content-length") continue;

        std::string_view value = line.substr(colon + 1);
        while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) value.remove_prefix(1);
        while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) value.remove_suffix(1);
        size_t parsed = 0;
        const auto [ptr, ec] = std::from_chars(value.data(), value.data() + value.size(), parsed);
        if (ec != std::errc() || ptr != value.data() + value.size()) return std::nullopt;
        return parsed;
    }
    return std::nullopt;
}

std::string MessageFramer::encode(std::string_view body) {
    std::string out = "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n";
    out.append(body);
    return out;
}

}  // namespace nib

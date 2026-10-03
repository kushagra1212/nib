#pragma once
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace nib {

// Port of MessageFramer: splits a byte stream into LSP messages.
//
// LSP frames each JSON-RPC payload as `Content-Length: N\r\n\r\n<N bytes>`.
// Reads off a pipe arrive in arbitrary chunks, so the framer buffers until a
// full header and body are present and hands back only complete payloads.
class MessageFramer {
public:
    // Appends new bytes and returns every complete message body now available.
    std::vector<std::string> push(std::string_view bytes);

    // Wraps a payload in the LSP header framing.
    static std::string encode(std::string_view body);

private:
    std::optional<std::string> take_one();
    static std::optional<size_t> content_length(std::string_view header);

    std::string buffer_;
};

}  // namespace nib

#include "platform/http.hpp"

#include <windows.h>
#include <winhttp.h>

#include <fstream>
#include <vector>

// WinHTTP rather than a bundled client: it ships with every Windows, handles
// TLS through the system's certificate store and proxy settings, and costs
// nib nothing on disk.

namespace nib::platform::http {
namespace {

struct Handle {
    HINTERNET h = nullptr;
    Handle() = default;
    explicit Handle(HINTERNET v) : h(v) {}
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    Handle(Handle&& o) noexcept : h(o.h) { o.h = nullptr; }
    Handle& operator=(Handle&& o) noexcept {
        if (this != &o) {
            if (h) WinHttpCloseHandle(h);
            h = o.h;
            o.h = nullptr;
        }
        return *this;
    }
    ~Handle() { if (h) WinHttpCloseHandle(h); }
    explicit operator bool() const { return h != nullptr; }
};

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

[[noreturn]] void fail(const char* what) {
    const DWORD code = GetLastError();
    HttpError::Kind kind = HttpError::Kind::other;
    switch (code) {
    case ERROR_WINHTTP_TIMEOUT: kind = HttpError::Kind::timed_out; break;
    case ERROR_WINHTTP_CANNOT_CONNECT: kind = HttpError::Kind::cannot_connect; break;
    case ERROR_WINHTTP_CONNECTION_ERROR: kind = HttpError::Kind::connection_lost; break;
    default: break;
    }
    throw HttpError(std::string(what) + " (WinHTTP error " + std::to_string(code) + ")", kind);
}

struct Url {
    std::wstring host;
    std::wstring path;
    INTERNET_PORT port = 0;
    bool secure = false;
};

Url crack(const std::string& url) {
    const std::wstring wide = widen(url);
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof parts;
    wchar_t host[256]{}, path[4096]{}, extra[4096]{};
    parts.lpszHostName = host;
    parts.dwHostNameLength = 256;
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = 4096;
    parts.lpszExtraInfo = extra;
    parts.dwExtraInfoLength = 4096;
    if (!WinHttpCrackUrl(wide.c_str(), 0, 0, &parts)) fail("bad URL");
    return Url{host, std::wstring(path) + extra, parts.nPort,
               parts.nScheme == INTERNET_SCHEME_HTTPS};
}

HINTERNET session() {
    // One session for the process: it holds the connection pool and the
    // proxy configuration, and both are worth reusing.
    static HINTERNET s = WinHttpOpen(L"nib/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!s) fail("WinHttpOpen failed");
    return s;
}

struct Exchange {
    Handle connection;
    Handle request;
};

Exchange open(const Url& u, const wchar_t* verb, int32_t timeout_ms) {
    Exchange x;
    x.connection = Handle(WinHttpConnect(session(), u.host.c_str(), u.port, 0));
    if (!x.connection) fail("could not connect");
    x.request = Handle(WinHttpOpenRequest(x.connection.h, verb, u.path.c_str(), nullptr,
                                          WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                          u.secure ? WINHTTP_FLAG_SECURE : 0));
    if (!x.request) fail("could not open request");
    WinHttpSetTimeouts(x.request.h, timeout_ms, timeout_ms, timeout_ms, timeout_ms);
    return x;
}

int32_t status_of(HINTERNET request) {
    DWORD status = 0, size = sizeof status;
    WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX);
    return static_cast<int32_t>(status);
}

std::string read_all(HINTERNET request) {
    std::string body;
    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request, &available)) fail("read failed");
        if (available == 0) break;
        const size_t at = body.size();
        body.resize(at + available);
        DWORD read = 0;
        if (!WinHttpReadData(request, body.data() + at, available, &read)) fail("read failed");
        body.resize(at + read);
    }
    return body;
}

Response send(const std::string& url, const wchar_t* verb, const std::string* payload,
              int32_t timeout_ms) {
    const Url u = crack(url);
    Exchange x = open(u, verb, timeout_ms);
    const wchar_t* headers = payload ? L"Content-Type: application/json\r\n" : WINHTTP_NO_ADDITIONAL_HEADERS;
    const DWORD length = payload ? static_cast<DWORD>(payload->size()) : 0;
    if (!WinHttpSendRequest(x.request.h, headers, payload ? static_cast<DWORD>(-1L) : 0,
                            payload ? const_cast<char*>(payload->data()) : WINHTTP_NO_REQUEST_DATA,
                            length, length, 0)) {
        fail("request failed");
    }
    if (!WinHttpReceiveResponse(x.request.h, nullptr)) fail("no response");
    Response r;
    r.status = status_of(x.request.h);
    r.body = read_all(x.request.h);
    return r;
}

}  // namespace

Response get(const std::string& url, int32_t timeout_ms) {
    return send(url, L"GET", nullptr, timeout_ms);
}

Response post_json(const std::string& url, const std::string& body, int32_t timeout_ms) {
    return send(url, L"POST", &body, timeout_ms);
}

int32_t download(const std::string& url, const std::filesystem::path& destination,
                 const std::function<void(int64_t, int64_t)>& progress,
                 const std::atomic<bool>& cancel) {
    const Url u = crack(url);
    // A long timeout per read, not for the whole transfer: a 2.5GB model takes
    // minutes, but a stalled connection should still fail.
    Exchange x = open(u, L"GET", 60'000);
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    WinHttpSetOption(x.request.h, WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof redirects);

    if (!WinHttpSendRequest(x.request.h, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
        fail("download request failed");
    }
    if (!WinHttpReceiveResponse(x.request.h, nullptr)) fail("no response from download server");
    const int32_t status = status_of(x.request.h);
    if (status < 200 || status >= 300) return status;

    int64_t total = 0;
    {
        wchar_t buffer[32]{};
        DWORD size = sizeof buffer;
        if (WinHttpQueryHeaders(x.request.h, WINHTTP_QUERY_CONTENT_LENGTH,
                                WINHTTP_HEADER_NAME_BY_INDEX, buffer, &size,
                                WINHTTP_NO_HEADER_INDEX)) {
            total = _wtoi64(buffer);
        }
    }

    std::ofstream file(destination, std::ios::binary | std::ios::trunc);
    if (!file) throw HttpError("could not write " + destination.string());

    std::vector<char> chunk(1 << 20);
    int64_t received = 0;
    for (;;) {
        if (cancel.load()) return 0;
        DWORD read = 0;
        if (!WinHttpReadData(x.request.h, chunk.data(), static_cast<DWORD>(chunk.size()), &read)) {
            fail("download interrupted");
        }
        if (read == 0) break;
        file.write(chunk.data(), read);
        if (!file) throw HttpError("could not write " + destination.string() + " (disk full?)");
        received += read;
        if (progress) progress(received, total);
    }
    file.close();
    return status;
}

}  // namespace nib::platform::http

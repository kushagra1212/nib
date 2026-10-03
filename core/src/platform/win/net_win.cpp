#include "platform/process.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

namespace nib::platform {

uint16_t free_loopback_port() {
    static const bool ready = [] {
        WSADATA data;
        return WSAStartup(MAKEWORD(2, 2), &data) == 0;
    }();
    if (!ready) return 0;

    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return 0;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = 0;  // let the kernel pick
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    uint16_t port = 0;
    if (bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof addr) == 0) {
        int length = sizeof addr;
        if (getsockname(s, reinterpret_cast<sockaddr*>(&addr), &length) == 0) {
            port = ntohs(addr.sin_port);
        }
    }
    closesocket(s);
    return port;
}

uint32_t processor_count() {
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return info.dwNumberOfProcessors;
}

}  // namespace nib::platform

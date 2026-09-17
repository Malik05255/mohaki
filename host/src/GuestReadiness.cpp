#include "GuestReadiness.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <array>
#include <string>

namespace jawal {

bool GuestReadyFast() noexcept {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;

    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) {
        WSACleanup();
        return false;
    }

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(27185);
    InetPtonW(AF_INET, L"127.0.0.1", &address.sin_addr);

    bool ok = connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0;
    if (ok) {
        DWORD timeoutMs = 800;
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

        static constexpr char ping[] = "PING\n";
        ok = send(socket, ping, static_cast<int>(sizeof(ping) - 1), 0) == static_cast<int>(sizeof(ping) - 1);
        if (ok) {
            std::array<char, 64> buffer{};
            const int received = recv(socket, buffer.data(), static_cast<int>(buffer.size() - 1), 0);
            if (received > 0) {
                std::string reply(buffer.data(), static_cast<std::size_t>(received));
                ok = reply.rfind("OK", 0) == 0;
            } else {
                ok = false;
            }
        }
    }

    closesocket(socket);
    WSACleanup();
    return ok;
}

} // namespace jawal

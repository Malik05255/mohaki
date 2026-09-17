#include "GuestReadiness.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <array>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <string>

namespace jawal {
namespace {

std::filesystem::path SessionTokenPath() {
    std::array<wchar_t, 32768> buffer{};
    const DWORD chars = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer.data(), static_cast<DWORD>(buffer.size()));
    if (chars == 0 || chars >= buffer.size()) return {};
    return std::filesystem::path(buffer.data()) / L"Jawal" / L"session.token";
}

bool ReadSessionToken(std::string* token) {
    if (!token) return false;
    token->clear();
    const auto path = SessionTokenPath();
    if (path.empty()) return false;
    std::ifstream input(path);
    std::string value;
    if (!input || !std::getline(input, value) || value.size() != 64) return false;
    for (const unsigned char c : value) if (!std::isxdigit(c)) return false;
    *token = std::move(value);
    return true;
}

} // namespace

bool GuestReadyFast() noexcept {
    std::string sessionToken;
    if (!ReadSessionToken(&sessionToken)) return false;

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

        const std::string ping = "AUTH " + sessionToken + " PING\n";
        ok = send(socket, ping.data(), static_cast<int>(ping.size()), 0) == static_cast<int>(ping.size());
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

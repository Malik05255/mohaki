#include "PackageBridge.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <thread>

namespace jawal {
namespace {

constexpr std::uint32_t kMagic = 0x4A41504B; // JAPK
constexpr std::uint32_t kProtocolVersion = 1;
constexpr unsigned short kBridgePort = 27183;

bool SendAll(SOCKET socket, const char* data, std::size_t size) {
    while (size > 0) {
        const int sent = send(socket, data, static_cast<int>(size), 0);
        if (sent <= 0) return false;
        data += sent;
        size -= static_cast<std::size_t>(sent);
    }
    return true;
}

bool ReceiveAll(SOCKET socket, char* data, std::size_t size) {
    while (size > 0) {
        const int received = recv(socket, data, static_cast<int>(size), 0);
        if (received <= 0) return false;
        data += received;
        size -= static_cast<std::size_t>(received);
    }
    return true;
}

bool SendU32(SOCKET socket, std::uint32_t value) {
    value = htonl(value);
    return SendAll(socket, reinterpret_cast<const char*>(&value), sizeof(value));
}

bool SendU64(SOCKET socket, std::uint64_t value) {
    std::array<unsigned char, 8> bytes{};
    for (int i = 7; i >= 0; --i) {
        bytes[static_cast<std::size_t>(i)] = static_cast<unsigned char>(value & 0xFFu);
        value >>= 8u;
    }
    return SendAll(socket, reinterpret_cast<const char*>(bytes.data()), bytes.size());
}

SOCKET ConnectToGuest() {
    for (int attempt = 0; attempt < 60; ++attempt) {
        SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (socket == INVALID_SOCKET) return INVALID_SOCKET;

        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(kBridgePort);
        InetPtonW(AF_INET, L"127.0.0.1", &address.sin_addr);

        if (connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0) {
            return socket;
        }
        closesocket(socket);
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }
    return INVALID_SOCKET;
}

std::wstring StatusText(int status) {
    switch (status) {
    case 0: return L"تم تثبيت التطبيق بنجاح.";
    case -1: return L"Android طلب تأكيدًا من المستخدم لإكمال التثبيت.";
    case 1: return L"فشل التثبيت داخل Android.";
    case 2: return L"تم منع التثبيت بواسطة سياسة النظام أو أداة تحقق.";
    case 3: return L"تم إلغاء التثبيت.";
    case 4: return L"ملف APK غير صالح أو تالف أو توقيعه غير صحيح.";
    case 5: return L"يوجد تعارض مع تطبيق أو توقيع مثبت مسبقًا.";
    case 6: return L"لا توجد مساحة تخزين كافية داخل جوال.";
    case 7: return L"التطبيق غير متوافق مع معمارية أو مزايا جهاز جوال الحالية.";
    case 8: return L"انتهت مهلة تثبيت التطبيق.";
    case -10: return L"رفض Android قناة التثبيت لسبب أمني.";
    case -11: return L"إصدار قناة التثبيت غير متوافق.";
    case -12: return L"حجم ملف APK غير صالح.";
    default: return L"تعذر إكمال تثبيت APK.";
    }
}

} // namespace

PackageInstallResult InstallApk(const std::filesystem::path& apk) {
    PackageInstallResult result{};

    std::error_code ec;
    const auto size = std::filesystem::file_size(apk, ec);
    if (ec || size == 0) {
        result.status = -101;
        result.detail = L"تعذر قراءة ملف APK.";
        return result;
    }

    std::ifstream input(apk, std::ios::binary);
    if (!input) {
        result.status = -101;
        result.detail = L"تعذر فتح ملف APK.";
        return result;
    }

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        result.status = -102;
        result.detail = L"تعذر تهيئة قناة الاتصال المحلية.";
        return result;
    }

    SOCKET socket = ConnectToGuest();
    if (socket == INVALID_SOCKET) {
        WSACleanup();
        result.status = -103;
        result.detail = L"Android لم يجهز خدمة تثبيت التطبيقات بعد.";
        return result;
    }

    DWORD timeoutMs = 180000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO,
               reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

    bool ok = SendU32(socket, kMagic) &&
              SendU32(socket, kProtocolVersion) &&
              SendU64(socket, static_cast<std::uint64_t>(size));

    std::array<char, 256 * 1024> buffer{};
    while (ok && input) {
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto count = input.gcount();
        if (count > 0) {
            ok = SendAll(socket, buffer.data(), static_cast<std::size_t>(count));
        }
    }

    std::uint32_t networkStatus = 0;
    if (ok) ok = ReceiveAll(socket, reinterpret_cast<char*>(&networkStatus), sizeof(networkStatus));

    closesocket(socket);
    WSACleanup();

    if (!ok) {
        result.status = -104;
        result.detail = L"انقطع الاتصال أثناء إرسال التطبيق إلى Android.";
        return result;
    }

    result.status = static_cast<std::int32_t>(ntohl(networkStatus));
    result.detail = StatusText(result.status);
    return result;
}

} // namespace jawal

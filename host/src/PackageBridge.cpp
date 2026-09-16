#include "PackageBridge.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <string>
#include <thread>

namespace jawal {
namespace {

constexpr std::uint32_t kPackageMagic = 0x4A41504B; // JAPK
constexpr std::uint32_t kPackageProtocolVersion = 2;
constexpr std::uint32_t kFileMagic = 0x4A46494C; // JFIL
constexpr std::uint32_t kFileProtocolVersion = 1;
constexpr unsigned short kPackagePort = 27183;
constexpr unsigned short kControlPort = 27185;
constexpr unsigned short kFilePort = 27188;
constexpr std::uint64_t kMaximumTransferBytes = 16ull * 1024ull * 1024ull * 1024ull;

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

bool ReceiveU32(SOCKET socket, std::uint32_t* value) {
    std::uint32_t network = 0;
    if (!ReceiveAll(socket, reinterpret_cast<char*>(&network), sizeof(network))) return false;
    *value = ntohl(network);
    return true;
}

bool SendU64(SOCKET socket, std::uint64_t value) {
    std::array<unsigned char, 8> bytes{};
    for (int i = 7; i >= 0; --i) {
        bytes[static_cast<std::size_t>(i)] = static_cast<unsigned char>(value & 0xFFu);
        value >>= 8u;
    }
    return SendAll(socket, reinterpret_cast<const char*>(bytes.data()), bytes.size());
}

SOCKET ConnectToGuest(unsigned short port, int attempts) {
    for (int attempt = 0; attempt < attempts; ++attempt) {
        SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (socket == INVALID_SOCKET) return INVALID_SOCKET;

        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        InetPtonW(AF_INET, L"127.0.0.1", &address.sin_addr);

        if (connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0) {
            return socket;
        }
        closesocket(socket);
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }
    return INVALID_SOCKET;
}

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string out(static_cast<std::size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), bytes, nullptr, nullptr);
    return out;
}

std::wstring InstallStatusText(int status) {
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

bool StreamFile(SOCKET socket, std::ifstream& input) {
    std::array<char, 256 * 1024> buffer{};
    while (input) {
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto count = input.gcount();
        if (count > 0 && !SendAll(socket, buffer.data(), static_cast<std::size_t>(count))) return false;
    }
    return true;
}

} // namespace

PackageInstallResult InstallApk(const std::filesystem::path& apk) {
    PackageInstallResult result{};
    std::error_code ec;
    const auto size = std::filesystem::file_size(apk, ec);
    if (ec || size == 0 || size > kMaximumTransferBytes) {
        result.status = -101;
        result.detail = L"تعذر قراءة ملف APK أو أن حجمه غير مدعوم.";
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

    SOCKET socket = ConnectToGuest(kPackagePort, 60);
    if (socket == INVALID_SOCKET) {
        WSACleanup();
        result.status = -103;
        result.detail = L"Android لم يجهز خدمة تثبيت التطبيقات بعد.";
        return result;
    }

    DWORD timeoutMs = 180000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

    bool ok = SendU32(socket, kPackageMagic) &&
              SendU32(socket, kPackageProtocolVersion) &&
              SendU64(socket, static_cast<std::uint64_t>(size)) &&
              StreamFile(socket, input);

    std::uint32_t status = 0;
    std::uint32_t packageLength = 0;
    if (ok) ok = ReceiveU32(socket, &status) && ReceiveU32(socket, &packageLength);
    if (ok && packageLength > 4096) ok = false;
    if (ok && packageLength > 0) {
        result.packageName.resize(packageLength);
        ok = ReceiveAll(socket, result.packageName.data(), packageLength);
    }

    closesocket(socket);
    WSACleanup();

    if (!ok) {
        result.status = -104;
        result.detail = L"انقطع الاتصال أثناء إرسال التطبيق إلى Android.";
        result.packageName.clear();
        return result;
    }

    result.status = static_cast<std::int32_t>(status);
    result.detail = InstallStatusText(result.status);
    return result;
}

FileTransferResult SendFileToGuest(const std::filesystem::path& file) {
    FileTransferResult result{};
    std::error_code ec;
    const auto size = std::filesystem::file_size(file, ec);
    if (ec || size == 0 || size > kMaximumTransferBytes) {
        result.status = -201;
        result.detail = L"تعذر قراءة الملف أو أن حجمه غير مدعوم.";
        return result;
    }

    const std::string name = WideToUtf8(file.filename().wstring());
    if (name.empty() || name.size() > 1024) {
        result.status = -202;
        result.detail = L"اسم الملف غير مدعوم.";
        return result;
    }

    std::ifstream input(file, std::ios::binary);
    if (!input) {
        result.status = -201;
        result.detail = L"تعذر فتح الملف.";
        return result;
    }

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        result.status = -203;
        result.detail = L"تعذر تهيئة قناة نقل الملفات.";
        return result;
    }
    SOCKET socket = ConnectToGuest(kFilePort, 60);
    if (socket == INVALID_SOCKET) {
        WSACleanup();
        result.status = -204;
        result.detail = L"Android لم يجهز خدمة نقل الملفات بعد.";
        return result;
    }

    DWORD timeoutMs = 180000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

    bool ok = SendU32(socket, kFileMagic) &&
              SendU32(socket, kFileProtocolVersion) &&
              SendU32(socket, static_cast<std::uint32_t>(name.size())) &&
              SendU64(socket, static_cast<std::uint64_t>(size)) &&
              SendAll(socket, name.data(), name.size()) &&
              StreamFile(socket, input);

    std::uint32_t status = 0;
    if (ok) ok = ReceiveU32(socket, &status);
    closesocket(socket);
    WSACleanup();

    if (!ok) {
        result.status = -205;
        result.detail = L"انقطع الاتصال أثناء نقل الملف إلى Android.";
        return result;
    }
    result.status = static_cast<std::int32_t>(status);
    result.detail = result.status == 0
        ? L"تم نسخ الملف إلى Downloads/Jawal داخل Android."
        : L"فشل حفظ الملف داخل Android.";
    return result;
}

bool GuestControl(const std::string& command, std::string* response) {
    if (response) response->clear();

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;

    SOCKET socket = ConnectToGuest(kControlPort, 10);
    if (socket == INVALID_SOCKET) {
        WSACleanup();
        return false;
    }

    DWORD timeoutMs = 10000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

    const std::string payload = command + "\n";
    bool ok = SendAll(socket, payload.data(), payload.size());
    std::string reply;
    if (ok) {
        std::array<char, 4096> buffer{};
        while (reply.size() < 128 * 1024) {
            const int received = recv(socket, buffer.data(), static_cast<int>(buffer.size()), 0);
            if (received <= 0) break;
            reply.append(buffer.data(), static_cast<std::size_t>(received));
            if (reply.find('\n') != std::string::npos) break;
        }
        const auto newline = reply.find_first_of("\r\n");
        if (newline != std::string::npos) reply.resize(newline);
        if (reply.empty()) ok = false;
    }

    closesocket(socket);
    WSACleanup();
    if (response) *response = reply;
    return ok && reply.rfind("OK", 0) == 0;
}

} // namespace jawal

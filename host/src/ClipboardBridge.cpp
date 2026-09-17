#include "ClipboardBridge.hpp"
#include "PackageBridge.hpp"

#include <windows.h>

#include <chrono>
#include <string>
#include <thread>
#include <vector>

namespace jawal {
namespace {

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string out(static_cast<std::size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), bytes, nullptr, nullptr);
    return out;
}

std::wstring Utf8ToWide(const std::string& value) {
    if (value.empty()) return {};
    const int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (chars <= 0) return {};
    std::wstring out(static_cast<std::size_t>(chars), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), out.data(), chars);
    return out;
}

constexpr char kB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string Base64Encode(const std::string& input) {
    std::string out;
    out.reserve(((input.size() + 2) / 3) * 4);
    std::size_t i = 0;
    while (i < input.size()) {
        const unsigned a = static_cast<unsigned char>(input[i++]);
        const unsigned b = i < input.size() ? static_cast<unsigned char>(input[i++]) : 0;
        const unsigned c = i < input.size() ? static_cast<unsigned char>(input[i++]) : 0;
        const unsigned triple = (a << 16) | (b << 8) | c;
        out.push_back(kB64[(triple >> 18) & 63]);
        out.push_back(kB64[(triple >> 12) & 63]);
        out.push_back((i - 1) <= input.size() ? kB64[(triple >> 6) & 63] : '=');
        out.push_back(i <= input.size() ? kB64[triple & 63] : '=');
    }
    const std::size_t mod = input.size() % 3;
    if (mod != 0) {
        out[out.size() - 1] = '=';
        if (mod == 1) out[out.size() - 2] = '=';
    }
    return out;
}

int Base64Value(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

std::string Base64Decode(const std::string& input) {
    std::string out;
    int val = 0;
    int bits = -8;
    for (char c : input) {
        if (c == '=') break;
        const int decoded = Base64Value(c);
        if (decoded < 0) continue;
        val = (val << 6) | decoded;
        bits += 6;
        if (bits >= 0) {
            out.push_back(static_cast<char>((val >> bits) & 0xFF));
            bits -= 8;
        }
    }
    return out;
}

bool ReadClipboard(std::wstring* text) {
    if (!text) return false;
    if (!OpenClipboard(nullptr)) return false;
    HANDLE data = GetClipboardData(CF_UNICODETEXT);
    if (!data) {
        CloseClipboard();
        return false;
    }
    const auto* ptr = static_cast<const wchar_t*>(GlobalLock(data));
    if (!ptr) {
        CloseClipboard();
        return false;
    }
    *text = ptr;
    GlobalUnlock(data);
    CloseClipboard();
    return true;
}

bool WriteClipboard(const std::wstring& text) {
    if (!OpenClipboard(nullptr)) return false;
    if (!EmptyClipboard()) {
        CloseClipboard();
        return false;
    }
    const SIZE_T bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!memory) {
        CloseClipboard();
        return false;
    }
    void* target = GlobalLock(memory);
    if (!target) {
        GlobalFree(memory);
        CloseClipboard();
        return false;
    }
    memcpy(target, text.c_str(), bytes);
    GlobalUnlock(memory);
    if (!SetClipboardData(CF_UNICODETEXT, memory)) {
        GlobalFree(memory);
        CloseClipboard();
        return false;
    }
    CloseClipboard();
    return true;
}

} // namespace

ClipboardBridge::~ClipboardBridge() {
    Stop();
}

void ClipboardBridge::Start() {
    if (running_.exchange(true)) return;
    worker_ = std::thread(&ClipboardBridge::Loop, this);
}

void ClipboardBridge::Stop() noexcept {
    if (!running_.exchange(false)) return;
    if (worker_.joinable()) worker_.join();
}

void ClipboardBridge::Loop() {
    std::wstring lastHost;
    std::wstring lastGuest;

    while (running_.load()) {
        std::wstring host;
        if (ReadClipboard(&host) && host.size() <= 32768 && host != lastHost && host != lastGuest) {
            const std::string utf8 = WideToUtf8(host);
            const std::string payload = utf8.empty() ? "-" : Base64Encode(utf8);
            std::string reply;
            if (GuestControl("CLIPBOARD_SET " + payload, &reply)) {
                lastHost = host;
                lastGuest = host;
            }
        }

        std::string response;
        if (GuestControl("CLIPBOARD_GET", &response) && response.rfind("OK ", 0) == 0) {
            const std::string encoded = response.substr(3);
            const std::wstring guest = encoded == "-" ? L"" : Utf8ToWide(Base64Decode(encoded));
            if (guest.size() <= 32768 && guest != lastGuest) {
                lastGuest = guest;
                if (guest != host && WriteClipboard(guest)) lastHost = guest;
            }
        }

        for (int i = 0; i < 8 && running_.load(); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
}

} // namespace jawal

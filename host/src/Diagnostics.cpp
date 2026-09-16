#include "Diagnostics.hpp"

#include <windows.h>

#include <fstream>
#include <mutex>
#include <string>

namespace jawal {
namespace {

std::mutex gMutex;
std::filesystem::path gLogPath;

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return {};
    std::string out(static_cast<std::size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), bytes, nullptr, nullptr);
    return out;
}

void RotateIfNeeded() {
    std::error_code ec;
    if (!std::filesystem::exists(gLogPath, ec)) return;
    const auto size = std::filesystem::file_size(gLogPath, ec);
    if (ec || size < 1024 * 1024) return;
    const auto old = gLogPath.parent_path() / L"jawal.log.1";
    std::filesystem::remove(old, ec);
    ec.clear();
    std::filesystem::rename(gLogPath, old, ec);
}

} // namespace

void InitializeDiagnostics(const std::filesystem::path& dataDirectory) {
    std::lock_guard lock(gMutex);
    std::error_code ec;
    const auto logDir = dataDirectory / L"logs";
    std::filesystem::create_directories(logDir, ec);
    gLogPath = logDir / L"jawal.log";
    RotateIfNeeded();
}

void LogDiagnostic(const std::wstring& message) {
    std::lock_guard lock(gMutex);
    if (gLogPath.empty()) return;
    RotateIfNeeded();

    SYSTEMTIME now{};
    GetLocalTime(&now);
    char prefix[64]{};
    sprintf_s(prefix, "%04u-%02u-%02u %02u:%02u:%02u.%03u ",
              now.wYear, now.wMonth, now.wDay,
              now.wHour, now.wMinute, now.wSecond, now.wMilliseconds);

    std::ofstream out(gLogPath, std::ios::app | std::ios::binary);
    if (!out) return;
    out << prefix << WideToUtf8(message) << "\r\n";
}

} // namespace jawal

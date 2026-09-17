#include "RuntimeSettings.hpp"

#include <windows.h>

#include <filesystem>
#include <string>

namespace jawal {
namespace {

std::filesystem::path SettingsPath(const std::filesystem::path& dataDirectory) {
    return dataDirectory / L"jawal.ini";
}

unsigned ReadUnsigned(const std::filesystem::path& path,
                      const wchar_t* section,
                      const wchar_t* key,
                      unsigned fallback) {
    return static_cast<unsigned>(GetPrivateProfileIntW(section, key, static_cast<INT>(fallback), path.c_str()));
}

bool ReadBool(const std::filesystem::path& path,
              const wchar_t* section,
              const wchar_t* key,
              bool fallback) {
    return GetPrivateProfileIntW(section, key, fallback ? 1 : 0, path.c_str()) != 0;
}

bool WriteUnsigned(const std::filesystem::path& path,
                   const wchar_t* section,
                   const wchar_t* key,
                   unsigned value) {
    return WritePrivateProfileStringW(section, key, std::to_wstring(value).c_str(), path.c_str()) != FALSE;
}

bool WriteBool(const std::filesystem::path& path,
               const wchar_t* section,
               const wchar_t* key,
               bool value) {
    return WritePrivateProfileStringW(section, key, value ? L"1" : L"0", path.c_str()) != FALSE;
}

} // namespace

void EnsureDefaultSettingsFile(const std::filesystem::path& dataDirectory) {
    std::filesystem::create_directories(dataDirectory);
    const auto path = SettingsPath(dataDirectory);
    if (std::filesystem::exists(path)) return;

    WritePrivateProfileStringW(L"performance", L"ram_mb", L"0", path.c_str());
    WritePrivateProfileStringW(L"performance", L"cpu_cores", L"0", path.c_str());
    WritePrivateProfileStringW(L"display", L"width", L"1080", path.c_str());
    WritePrivateProfileStringW(L"display", L"height", L"1920", path.c_str());
    WritePrivateProfileStringW(L"display", L"refresh_hz", L"60", path.c_str());
    WritePrivateProfileStringW(L"integration", L"quick_resume", L"1", path.c_str());
    WritePrivateProfileStringW(L"integration", L"clipboard_sync", L"1", path.c_str());
}

RuntimeSettings LoadRuntimeSettings(const std::filesystem::path& dataDirectory) {
    EnsureDefaultSettingsFile(dataDirectory);
    const auto path = SettingsPath(dataDirectory);

    RuntimeSettings settings{};
    settings.memoryMb = ReadUnsigned(path, L"performance", L"ram_mb", 0);
    settings.cpuCores = ReadUnsigned(path, L"performance", L"cpu_cores", 0);
    settings.displayWidth = ReadUnsigned(path, L"display", L"width", 1080);
    settings.displayHeight = ReadUnsigned(path, L"display", L"height", 1920);
    settings.refreshRate = ReadUnsigned(path, L"display", L"refresh_hz", 60);
    settings.quickResume = ReadBool(path, L"integration", L"quick_resume", true);
    settings.clipboardSync = ReadBool(path, L"integration", L"clipboard_sync", true);
    return settings;
}

bool SaveRuntimeSettings(const std::filesystem::path& dataDirectory, const RuntimeSettings& settings) {
    std::filesystem::create_directories(dataDirectory);
    const auto path = SettingsPath(dataDirectory);
    return WriteUnsigned(path, L"performance", L"ram_mb", settings.memoryMb) &&
           WriteUnsigned(path, L"performance", L"cpu_cores", settings.cpuCores) &&
           WriteUnsigned(path, L"display", L"width", settings.displayWidth) &&
           WriteUnsigned(path, L"display", L"height", settings.displayHeight) &&
           WriteUnsigned(path, L"display", L"refresh_hz", settings.refreshRate) &&
           WriteBool(path, L"integration", L"quick_resume", settings.quickResume) &&
           WriteBool(path, L"integration", L"clipboard_sync", settings.clipboardSync);
}

} // namespace jawal

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

} // namespace

void EnsureDefaultSettingsFile(const std::filesystem::path& dataDirectory) {
    std::filesystem::create_directories(dataDirectory);
    const auto path = SettingsPath(dataDirectory);
    if (std::filesystem::exists(path)) return;

    WritePrivateProfileStringW(L"performance", L"ram_mb", L"0", path.c_str());
    WritePrivateProfileStringW(L"performance", L"cpu_cores", L"0", path.c_str());
    WritePrivateProfileStringW(L"performance", L"mode", L"auto", path.c_str());
}

RuntimeSettings LoadRuntimeSettings(const std::filesystem::path& dataDirectory) {
    EnsureDefaultSettingsFile(dataDirectory);
    const auto path = SettingsPath(dataDirectory);

    RuntimeSettings settings{};
    settings.memoryMb = ReadUnsigned(path, L"performance", L"ram_mb", 0);
    settings.cpuCores = ReadUnsigned(path, L"performance", L"cpu_cores", 0);
    return settings;
}

} // namespace jawal

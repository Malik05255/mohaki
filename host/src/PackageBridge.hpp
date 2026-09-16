#pragma once

#include <filesystem>
#include <string>

namespace jawal {

struct PackageInstallResult {
    int status{-100};
    std::wstring detail;

    bool success() const noexcept { return status == 0; }
};

// Streams an APK directly into Android's PackageInstaller through the
// localhost-only Jawal VM bridge. No temporary duplicate APK and no ADB UI.
PackageInstallResult InstallApk(const std::filesystem::path& apk);

// Sends a small management command over Jawal's localhost-only control bridge.
// Used by automated compatibility tests and internal lifecycle operations.
bool GuestControl(const std::string& command, std::string* response);

} // namespace jawal

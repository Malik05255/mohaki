#pragma once

#include <filesystem>
#include <string>

namespace jawal {

struct PackageInstallResult {
    int status{-100};
    std::wstring detail;
    std::string packageName;

    bool success() const noexcept { return status == 0; }
};

struct FileTransferResult {
    int status{-100};
    std::wstring detail;

    bool success() const noexcept { return status == 0; }
};

// Streams an APK directly into Android's PackageInstaller through the
// localhost-only Jawal VM bridge. No temporary duplicate APK and no ADB UI.
PackageInstallResult InstallApk(const std::filesystem::path& apk);

// Copies an ordinary file into Android's Downloads/Jawal directory through
// MediaStore. This is the drag/drop fast path for photos, documents, videos, etc.
FileTransferResult SendFileToGuest(const std::filesystem::path& file);

// Sends a small management command over Jawal's localhost-only control bridge.
// connectAttempts controls how long the caller is willing to wait for the guest.
bool GuestControl(const std::string& command, std::string* response, int connectAttempts = 10);

} // namespace jawal

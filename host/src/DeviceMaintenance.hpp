#pragma once

#include <filesystem>
#include <string>

namespace jawal {

struct MaintenanceResult {
    bool ok{false};
    std::filesystem::path artifact;
    std::wstring detail;
};

MaintenanceResult CreateDataBackup(const std::filesystem::path& runtimeDir,
                                   const std::filesystem::path& dataDirectory);
MaintenanceResult RestoreLatestDataBackup(const std::filesystem::path& runtimeDir,
                                          const std::filesystem::path& dataDirectory);
MaintenanceResult CheckAndCompactData(const std::filesystem::path& runtimeDir,
                                      const std::filesystem::path& dataDirectory);

} // namespace jawal

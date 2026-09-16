#pragma once

#include <filesystem>

namespace jawal {

struct RuntimeSettings {
    unsigned memoryMb{0}; // 0 = automatic
    unsigned cpuCores{0}; // 0 = automatic
};

RuntimeSettings LoadRuntimeSettings(const std::filesystem::path& dataDirectory);
void EnsureDefaultSettingsFile(const std::filesystem::path& dataDirectory);

} // namespace jawal

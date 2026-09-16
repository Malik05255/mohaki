#pragma once

#include <filesystem>

namespace jawal {

struct RuntimeSettings {
    unsigned memoryMb{0}; // 0 = automatic
    unsigned cpuCores{0}; // 0 = automatic
    unsigned displayWidth{1080};
    unsigned displayHeight{1920};
    unsigned refreshRate{60};
    bool quickResume{true};
    bool clipboardSync{true};
};

RuntimeSettings LoadRuntimeSettings(const std::filesystem::path& dataDirectory);
bool SaveRuntimeSettings(const std::filesystem::path& dataDirectory, const RuntimeSettings& settings);
void EnsureDefaultSettingsFile(const std::filesystem::path& dataDirectory);

} // namespace jawal

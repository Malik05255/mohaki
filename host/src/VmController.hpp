#pragma once

#include "RenderBridge.hpp"

#include <windows.h>
#include <filesystem>
#include <string>

namespace jawal {

struct VmConfig {
    std::filesystem::path qemuExe;
    std::filesystem::path runtimeDir;
    std::filesystem::path systemDisk;
    std::filesystem::path dataDisk;
    std::filesystem::path quickResumeMarker;
    unsigned memoryMb{4096};
    unsigned cpuCores{4};
    unsigned displayWidth{1080};
    unsigned displayHeight{1920};
    // 1080 px / 420 dpi ~= 411 dp: a normal Android phone-width UI rather than
    // the tablet-like 1080 dp layout produced by an mdpi default.
    unsigned displayDensityDpi{420};
    unsigned refreshRate{60};
    bool resumeQuickState{false};
};

class VmController final {
public:
    VmController() = default;
    ~VmController();

    VmController(const VmController&) = delete;
    VmController& operator=(const VmController&) = delete;

    bool Start(HWND renderParent, const VmConfig& config, std::wstring* error);
    bool SaveQuickResume(const std::filesystem::path& marker, std::wstring* error);
    void Stop(bool tryQuickResume = false,
              const std::filesystem::path& marker = {}) noexcept;
    void Resize() noexcept;
    bool Running() const noexcept;

private:
    std::wstring BuildCommandLine(HWND renderParent, const VmConfig& config) const;
    bool QmpCommand(const std::string& json, std::string* reply = nullptr) const;
    bool QmpHumanMonitor(const std::string& command, std::string* reply = nullptr) const;

    PROCESS_INFORMATION process_{};
    RenderBridge renderBridge_{};
    std::filesystem::path runtimeDir_{};
};

} // namespace jawal

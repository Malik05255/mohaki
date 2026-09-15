#pragma once

#include <windows.h>
#include <filesystem>
#include <string>

namespace jawal {

struct VmConfig {
    std::filesystem::path qemuExe;
    std::filesystem::path runtimeDir;
    std::filesystem::path systemDisk;
    std::filesystem::path dataDisk;
    unsigned memoryMb{4096};
    unsigned cpuCores{4};
};

class VmController final {
public:
    VmController() = default;
    ~VmController();

    VmController(const VmController&) = delete;
    VmController& operator=(const VmController&) = delete;

    bool Start(HWND renderParent, const VmConfig& config, std::wstring* error);
    void Stop() noexcept;
    bool Running() const noexcept;

private:
    std::wstring BuildCommandLine(HWND renderParent, const VmConfig& config) const;

    PROCESS_INFORMATION process_{};
};

} // namespace jawal

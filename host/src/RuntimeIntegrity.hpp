#pragma once

#include <filesystem>
#include <string>

namespace jawal {

// Verifies every file listed in runtime.sha256 before Android is allowed to boot.
// The packaging step regenerates the manifest after QEMU is assembled, so both
// the immutable Android payload and the Windows virtualization binaries are covered.
bool VerifyRuntimeIntegrity(const std::filesystem::path& runtimeDir, std::wstring* error);

} // namespace jawal

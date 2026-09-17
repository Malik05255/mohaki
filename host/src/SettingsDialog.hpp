#pragma once

#include <windows.h>
#include <filesystem>

namespace jawal {

// Shows a lightweight native settings window. Returns true when settings were saved.
bool ShowSettingsDialog(HWND owner, const std::filesystem::path& dataDirectory);

} // namespace jawal

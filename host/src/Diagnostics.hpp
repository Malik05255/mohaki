#pragma once

#include <filesystem>
#include <string>

namespace jawal {

void InitializeDiagnostics(const std::filesystem::path& dataDirectory);
void LogDiagnostic(const std::wstring& message);

} // namespace jawal

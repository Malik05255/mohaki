#include "PackageBridge.hpp"

#include <filesystem>
#include <iostream>
#include <string>

int wmain(int argc, wchar_t** argv) {
    if (argc != 3 || _wcsicmp(argv[1], L"install") != 0) {
        std::wcerr << L"Usage: JawalPkg install <apk>\n";
        return 2;
    }

    const std::filesystem::path apk(argv[2]);
    const auto result = jawal::InstallApk(apk);
    std::wcout << result.detail << L"\n";
    return result.success() ? 0 : (result.status == 0 ? 1 : static_cast<int>(result.status));
}

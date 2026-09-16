#include "PackageBridge.hpp"

#include <filesystem>
#include <iostream>
#include <string>

namespace {

std::string NarrowAscii(const wchar_t* value) {
    std::string out;
    while (value && *value) {
        const wchar_t c = *value++;
        if (c < 0 || c > 127) return {};
        out.push_back(static_cast<char>(c));
    }
    return out;
}

void Usage() {
    std::wcerr
        << L"Usage:\n"
        << L"  JawalPkg install <apk>\n"
        << L"  JawalPkg launch <package>\n"
        << L"  JawalPkg package <package>\n"
        << L"  JawalPkg gpu-result\n"
        << L"  JawalPkg arm64-reset\n"
        << L"  JawalPkg arm64-result\n";
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) {
        Usage();
        return 2;
    }

    if (_wcsicmp(argv[1], L"install") == 0) {
        if (argc != 3) {
            Usage();
            return 2;
        }
        const std::filesystem::path apk(argv[2]);
        const auto result = jawal::InstallApk(apk);
        std::wcout << result.detail << L"\n";
        return result.success() ? 0 : (result.status == 0 ? 1 : static_cast<int>(result.status));
    }

    std::string command;
    if (_wcsicmp(argv[1], L"launch") == 0 && argc == 3) {
        const auto packageName = NarrowAscii(argv[2]);
        if (packageName.empty()) return 2;
        command = "LAUNCH " + packageName;
    } else if (_wcsicmp(argv[1], L"package") == 0 && argc == 3) {
        const auto packageName = NarrowAscii(argv[2]);
        if (packageName.empty()) return 2;
        command = "PACKAGE " + packageName;
    } else if (_wcsicmp(argv[1], L"gpu-result") == 0 && argc == 2) {
        command = "GPU_RESULT";
    } else if (_wcsicmp(argv[1], L"arm64-reset") == 0 && argc == 2) {
        command = "RESET_ARM64";
    } else if (_wcsicmp(argv[1], L"arm64-result") == 0 && argc == 2) {
        command = "ARM64_RESULT";
    } else {
        Usage();
        return 2;
    }

    std::string response;
    if (!jawal::GuestControl(command, &response)) {
        std::cerr << (response.empty() ? "Jawal guest control unavailable" : response) << "\n";
        return 3;
    }
    std::cout << response << "\n";

    if (command == "ARM64_RESULT") {
        const auto space = response.find_last_of(' ');
        if (space == std::string::npos) return 4;
        try {
            return std::stoi(response.substr(space + 1)) == 42 ? 0 : 5;
        } catch (...) {
            return 4;
        }
    }
    if (command.rfind("PACKAGE ", 0) == 0) {
        return response == "OK INSTALLED" ? 0 : 6;
    }
    return 0;
}

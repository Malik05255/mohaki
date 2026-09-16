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

std::string JsonEscape(const std::string& value) {
    std::string out;
    for (char c : value) {
        if (c == '\\' || c == '"') out.push_back('\\');
        if (static_cast<unsigned char>(c) >= 0x20) out.push_back(c);
    }
    return out;
}

void Usage() {
    std::wcerr
        << L"Usage:\n"
        << L"  JawalPkg install <apk>\n"
        << L"  JawalPkg install-json <apk>\n"
        << L"  JawalPkg send-file <file>\n"
        << L"  JawalPkg launch <package>\n"
        << L"  JawalPkg package <package>\n"
        << L"  JawalPkg process <package>\n"
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

    if ((_wcsicmp(argv[1], L"install") == 0 || _wcsicmp(argv[1], L"install-json") == 0) && argc == 3) {
        const bool json = _wcsicmp(argv[1], L"install-json") == 0;
        const auto result = jawal::InstallApk(std::filesystem::path(argv[2]));
        if (json) {
            std::cout << "{\"success\":" << (result.success() ? "true" : "false")
                      << ",\"status\":" << result.status
                      << ",\"package\":\"" << JsonEscape(result.packageName) << "\"}\n";
        } else {
            std::wcout << result.detail;
            if (!result.packageName.empty()) std::cout << "\npackage=" << result.packageName;
            std::wcout << L"\n";
        }
        return result.success() ? 0 : (result.status == 0 ? 1 : static_cast<int>(result.status));
    }

    if (_wcsicmp(argv[1], L"send-file") == 0 && argc == 3) {
        const auto result = jawal::SendFileToGuest(std::filesystem::path(argv[2]));
        std::wcout << result.detail << L"\n";
        return result.success() ? 0 : 7;
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
    } else if (_wcsicmp(argv[1], L"process") == 0 && argc == 3) {
        const auto packageName = NarrowAscii(argv[2]);
        if (packageName.empty()) return 2;
        command = "PROCESS " + packageName;
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
    const bool ok = jawal::GuestControl(command, &response);
    if (!response.empty()) std::cout << response << "\n";
    if (!ok) {
        if (command.rfind("LAUNCH ", 0) == 0 && response == "ERR NO_LAUNCH_INTENT") return 8;
        if (response.empty()) std::cerr << "Jawal guest control unavailable\n";
        return 3;
    }

    if (command == "ARM64_RESULT") {
        const auto space = response.find_last_of(' ');
        if (space == std::string::npos) return 4;
        try {
            return std::stoi(response.substr(space + 1)) == 42 ? 0 : 5;
        } catch (...) {
            return 4;
        }
    }
    if (command.rfind("PACKAGE ", 0) == 0) return response == "OK INSTALLED" ? 0 : 6;
    if (command.rfind("PROCESS ", 0) == 0) return response == "OK RUNNING" ? 0 : 6;
    return 0;
}

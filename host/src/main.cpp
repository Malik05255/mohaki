#include "PackageBridge.hpp"
#include "VmController.hpp"

#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <windows.h>

#include <filesystem>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr wchar_t kWindowClass[] = L"JawalPhoneWindow";
constexpr int kInitialWidth = 450;
constexpr int kInitialHeight = 800;
constexpr UINT kStartRuntimeMessage = WM_APP + 1;
constexpr UINT kInstallCompleteMessage = WM_APP + 2;

struct InstallCompletion {
    jawal::PackageInstallResult result;
    std::wstring fileName;
};

jawal::VmController gVm;
HWND gRenderHost = nullptr;

std::filesystem::path ModuleDirectory() {
    std::vector<wchar_t> buffer(32768);
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    return std::filesystem::path(std::wstring(buffer.data(), length)).parent_path();
}

std::filesystem::path LocalDataDirectory() {
    PWSTR raw = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &raw))) {
        return ModuleDirectory() / L"data";
    }
    std::filesystem::path path(raw);
    CoTaskMemFree(raw);
    path /= L"Jawal";
    std::filesystem::create_directories(path);
    return path;
}

bool RunHiddenAndWait(const std::wstring& command, const std::filesystem::path& cwd) {
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, mutableCommand.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, cwd.c_str(), &si, &pi)) {
        return false;
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    return exitCode == 0;
}

bool EnsureDeviceOverlay(const std::filesystem::path& runtime,
                         const std::filesystem::path& base,
                         const std::filesystem::path& overlay) {
    if (std::filesystem::exists(overlay)) return true;
    std::filesystem::create_directories(overlay.parent_path());

    const auto qemuImg = runtime / L"qemu" / L"qemu-img.exe";
    if (!std::filesystem::exists(qemuImg) || !std::filesystem::exists(base)) return false;

    std::wstring command = L"\"" + qemuImg.wstring() + L"\" create -f qcow2 -F qcow2 -b \"" +
                           base.wstring() + L"\" \"" + overlay.wstring() + L"\"";
    return RunHiddenAndWait(command, runtime);
}

void ResizeEmbeddedSurface(HWND renderHost) {
    if (!renderHost) return;
    RECT rc{};
    GetClientRect(renderHost, &rc);
    HWND child = GetWindow(renderHost, GW_CHILD);
    while (child) {
        MoveWindow(child, 0, 0, rc.right - rc.left, rc.bottom - rc.top, TRUE);
        child = GetWindow(child, GW_HWNDNEXT);
    }
}

void StartRuntime(HWND owner) {
    const auto root = ModuleDirectory();
    const auto runtime = root / L"runtime";
    const auto baseDisk = runtime / L"images" / L"jawal-base.qcow2";
    const auto deviceDisk = LocalDataDirectory() / L"device.qcow2";

    if (!EnsureDeviceOverlay(runtime, baseDisk, deviceDisk)) {
        MessageBoxW(owner,
                    L"ملفات نظام جوال غير مكتملة. يجب إنشاء حزمة Android الأساسية قبل التشغيل.",
                    L"جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
        return;
    }

    jawal::VmConfig config{};
    config.qemuExe = runtime / L"qemu" / L"qemu-system-x86_64.exe";
    config.runtimeDir = runtime;
    config.systemDisk = baseDisk;
    config.userDisk = deviceDisk;

    SYSTEM_INFO info{};
    GetSystemInfo(&info);
    config.cpuCores = info.dwNumberOfProcessors >= 8 ? 4 : 2;

    MEMORYSTATUSEX memory{};
    memory.dwLength = sizeof(memory);
    GlobalMemoryStatusEx(&memory);
    const auto totalMb = static_cast<unsigned>(memory.ullTotalPhys / (1024ull * 1024ull));
    config.memoryMb = totalMb >= 24576 ? 6144 : (totalMb >= 12288 ? 4096 : 3072);

    std::wstring error;
    if (!gVm.Start(gRenderHost, config, &error)) {
        MessageBoxW(owner, error.c_str(), L"جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
    }
}

void InstallDroppedApk(HWND owner, std::filesystem::path file) {
    std::thread([owner, file = std::move(file)]() {
        auto* completion = new InstallCompletion{jawal::InstallApk(file), file.filename().wstring()};
        if (!PostMessageW(owner, kInstallCompleteMessage, 0, reinterpret_cast<LPARAM>(completion))) {
            delete completion;
        }
    }).detach();
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        DragAcceptFiles(hwnd, TRUE);
        gRenderHost = CreateWindowExW(0, L"STATIC", nullptr,
                                      WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                                      0, 0, 1, 1, hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
        PostMessageW(hwnd, kStartRuntimeMessage, 0, 0);
        return 0;
    }
    case kStartRuntimeMessage:
        StartRuntime(hwnd);
        return 0;
    case kInstallCompleteMessage: {
        auto* completion = reinterpret_cast<InstallCompletion*>(lParam);
        if (!completion) return 0;
        const UINT icon = completion->result.success() ? MB_ICONINFORMATION : MB_ICONERROR;
        std::wstring message = completion->fileName + L"\n\n" + completion->result.detail;
        MessageBoxW(hwnd, message.c_str(), L"جوال", MB_OK | icon | MB_RTLREADING);
        delete completion;
        return 0;
    }
    case WM_SIZE: {
        RECT rc{};
        GetClientRect(hwnd, &rc);
        if (gRenderHost) {
            MoveWindow(gRenderHost, 0, 0, rc.right - rc.left, rc.bottom - rc.top, TRUE);
            ResizeEmbeddedSurface(gRenderHost);
        }
        return 0;
    }
    case WM_DROPFILES: {
        HDROP drop = reinterpret_cast<HDROP>(wParam);
        const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT index = 0; index < count; ++index) {
            const UINT chars = DragQueryFileW(drop, index, nullptr, 0);
            std::wstring path(chars + 1, L'\0');
            DragQueryFileW(drop, index, path.data(), chars + 1);
            path.resize(chars);

            std::filesystem::path file(path);
            if (_wcsicmp(file.extension().c_str(), L".apk") == 0) {
                InstallDroppedApk(hwnd, std::move(file));
            }
        }
        DragFinish(drop);
        return 0;
    }
    case WM_DESTROY:
        gVm.Stop();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.hInstance = instance;
    wc.lpfnWndProc = WindowProc;
    wc.lpszClassName = kWindowClass;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    if (!RegisterClassExW(&wc)) return 1;

    RECT desktop{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &desktop, 0);
    const int x = desktop.left + ((desktop.right - desktop.left) - kInitialWidth) / 2;
    const int y = desktop.top + ((desktop.bottom - desktop.top) - kInitialHeight) / 2;

    HWND hwnd = CreateWindowExW(
        WS_EX_APPWINDOW,
        kWindowClass,
        L"جوال",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        x, y, kInitialWidth, kInitialHeight,
        nullptr, nullptr, instance, nullptr);
    if (!hwnd) return 2;

    constexpr DWORD DWMWA_WINDOW_CORNER_PREFERENCE_LOCAL = 33;
    constexpr int DWMWCP_ROUND = 2;
    int corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE_LOCAL, &corner, sizeof(corner));

    ShowWindow(hwnd, showCommand);
    UpdateWindow(hwnd);

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return static_cast<int>(message.wParam);
}

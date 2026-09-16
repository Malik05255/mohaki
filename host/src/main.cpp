#include "PackageBridge.hpp"
#include "RuntimeSettings.hpp"
#include "VmController.hpp"

#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <windows.h>

#include <algorithm>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr wchar_t kWindowClass[] = L"JawalPhoneWindow";
constexpr wchar_t kSingleInstanceMutex[] = L"Local\\Jawal.SingleInstance";
constexpr int kInitialWidth = 450;
constexpr int kInitialHeight = 800;
constexpr UINT kStartRuntimeMessage = WM_APP + 1;
constexpr UINT kInstallCompleteMessage = WM_APP + 2;
constexpr UINT kMenuSettings = 0x1100;
constexpr UINT kMenuFactoryReset = 0x1110;

struct InstallCompletion {
    jawal::PackageInstallResult result;
    std::wstring fileName;
};

jawal::VmController gVm;
HWND gRenderHost = nullptr;
HANDLE gSingleInstance = nullptr;

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

bool EnsureDataOverlay(const std::filesystem::path& runtime,
                       const std::filesystem::path& dataTemplate,
                       const std::filesystem::path& userData) {
    if (std::filesystem::exists(userData)) return true;
    std::filesystem::create_directories(userData.parent_path());

    const auto qemuImg = runtime / L"qemu" / L"qemu-img.exe";
    if (!std::filesystem::exists(qemuImg) || !std::filesystem::exists(dataTemplate)) return false;

    std::wstring command = L"\"" + qemuImg.wstring() + L"\" create -f qcow2 -F qcow2 -b \"" +
                           dataTemplate.wstring() + L"\" \"" + userData.wstring() + L"\"";
    return RunHiddenAndWait(command, runtime);
}

bool WhpxReady(std::wstring* reason) {
    if (!IsProcessorFeaturePresent(PF_VIRT_FIRMWARE_ENABLED)) {
        if (reason) {
            *reason = L"المحاكاة الافتراضية غير مفعلة من BIOS/UEFI. فعّل Intel VT-x أو AMD-V ثم أعد تشغيل Windows.";
        }
        return false;
    }

    HMODULE whpx = LoadLibraryExW(L"WinHvPlatform.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!whpx) {
        if (reason) {
            *reason = L"Windows Hypervisor Platform غير متاح. فعّل Windows Hypervisor Platform من ميزات Windows.";
        }
        return false;
    }
    FreeLibrary(whpx);
    return true;
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

unsigned AutomaticCpuCores(unsigned logicalProcessors) {
    if (logicalProcessors >= 12) return 6;
    if (logicalProcessors >= 8) return 4;
    if (logicalProcessors >= 4) return 2;
    return 1;
}

unsigned MaximumCpuCores(unsigned logicalProcessors) {
    if (logicalProcessors <= 2) return 1;
    return std::max(1u, std::min(8u, logicalProcessors - 2));
}

unsigned AutomaticMemoryMb(unsigned totalMb) {
    if (totalMb >= 32768) return 8192;
    if (totalMb >= 24576) return 6144;
    if (totalMb >= 12288) return 4096;
    return 3072;
}

unsigned MaximumMemoryMb(unsigned totalMb) {
    const unsigned reserve = totalMb >= 16384 ? 4096u : 3072u;
    if (totalMb <= reserve + 2048u) return 2048u;
    return std::min(12288u, totalMb - reserve);
}

void StartRuntime(HWND owner) {
    std::wstring virtualizationError;
    if (!WhpxReady(&virtualizationError)) {
        MessageBoxW(owner, virtualizationError.c_str(), L"جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
        return;
    }

    const auto root = ModuleDirectory();
    const auto runtime = root / L"runtime";
    const auto dataDirectory = LocalDataDirectory();
    const auto systemDisk = runtime / L"images" / L"jawal-system.qcow2";
    const auto dataTemplate = runtime / L"images" / L"jawal-data-template.qcow2";
    const auto userData = dataDirectory / L"data.qcow2";

    if (!std::filesystem::exists(systemDisk) ||
        !EnsureDataOverlay(runtime, dataTemplate, userData)) {
        MessageBoxW(owner,
                    L"ملفات نظام جوال غير مكتملة. يجب إنشاء حزمة Android الأساسية قبل التشغيل.",
                    L"جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
        return;
    }

    SYSTEM_INFO info{};
    GetSystemInfo(&info);
    const unsigned logicalProcessors = std::max(1u, static_cast<unsigned>(info.dwNumberOfProcessors));

    MEMORYSTATUSEX memory{};
    memory.dwLength = sizeof(memory);
    GlobalMemoryStatusEx(&memory);
    const unsigned totalMb = static_cast<unsigned>(memory.ullTotalPhys / (1024ull * 1024ull));

    const auto settings = jawal::LoadRuntimeSettings(dataDirectory);
    const unsigned automaticCpu = AutomaticCpuCores(logicalProcessors);
    const unsigned maximumCpu = MaximumCpuCores(logicalProcessors);
    const unsigned automaticRam = AutomaticMemoryMb(totalMb);
    const unsigned maximumRam = MaximumMemoryMb(totalMb);

    jawal::VmConfig config{};
    config.qemuExe = runtime / L"qemu" / L"qemu-system-x86_64.exe";
    config.runtimeDir = runtime;
    config.systemDisk = systemDisk;
    config.dataDisk = userData;
    config.cpuCores = settings.cpuCores == 0
        ? automaticCpu
        : std::clamp(settings.cpuCores, 1u, maximumCpu);
    config.memoryMb = settings.memoryMb == 0
        ? std::min(automaticRam, maximumRam)
        : std::clamp(settings.memoryMb, 2048u, maximumRam);

    std::wstring error;
    if (!gVm.Start(gRenderHost, config, &error)) {
        MessageBoxW(owner, error.c_str(), L"جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
    }
}

bool FactoryReset(HWND owner) {
    const int confirm = MessageBoxW(
        owner,
        L"سيتم حذف جميع التطبيقات والحسابات والملفات الموجودة داخل جوال وإعادته إلى حالته النظيفة.\n\nإعدادات الأداء في Windows ستبقى كما هي. هل تريد المتابعة؟",
        L"فورمات جوال",
        MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING | MB_RTLREADING);
    if (confirm != IDYES) return false;

    gVm.Stop();

    const auto root = ModuleDirectory();
    const auto runtime = root / L"runtime";
    const auto dataTemplate = runtime / L"images" / L"jawal-data-template.qcow2";
    const auto userData = LocalDataDirectory() / L"data.qcow2";

    std::error_code ec;
    std::filesystem::remove(userData, ec);
    if (ec && std::filesystem::exists(userData)) {
        MessageBoxW(owner,
                    L"تعذر حذف بيانات الجوال الحالية. أغلق أي برنامج يستخدم ملفات Jawal ثم حاول مرة أخرى.",
                    L"فورمات جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
        return false;
    }

    if (!EnsureDataOverlay(runtime, dataTemplate, userData)) {
        MessageBoxW(owner,
                    L"تم حذف البيانات لكن تعذر إنشاء مساحة جوال نظيفة جديدة. تحقق من ملفات Runtime والمساحة الحرة.",
                    L"فورمات جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
        return false;
    }

    MessageBoxW(owner,
                L"تمت تهيئة جوال بنجاح. سيبدأ الآن كجهاز Android نظيف بدون التطبيقات والحسابات السابقة.",
                L"فورمات جوال", MB_OK | MB_ICONINFORMATION | MB_RTLREADING);
    StartRuntime(owner);
    return true;
}

void OpenRuntimeSettings(HWND owner) {
    const auto settingsPath = LocalDataDirectory() / L"jawal.ini";
    if (!std::filesystem::exists(settingsPath)) {
        jawal::LoadRuntimeSettings(LocalDataDirectory());
    }
    HINSTANCE result = ShellExecuteW(owner, L"open", settingsPath.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(result) <= 32) {
        MessageBoxW(owner,
                    L"تعذر فتح إعدادات جوال.",
                    L"جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
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

void AddJawalSystemMenu(HWND hwnd) {
    HMENU menu = GetSystemMenu(hwnd, FALSE);
    if (!menu) return;
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kMenuSettings, L"إعدادات جوال");
    AppendMenuW(menu, MF_STRING, kMenuFactoryReset, L"فورمات الجوال");
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        DragAcceptFiles(hwnd, TRUE);
        AddJawalSystemMenu(hwnd);
        gRenderHost = CreateWindowExW(0, L"STATIC", nullptr,
                                      WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                                      0, 0, 1, 1, hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
        PostMessageW(hwnd, kStartRuntimeMessage, 0, 0);
        return 0;
    }
    case WM_SYSCOMMAND:
        if ((wParam & 0xFFF0u) == kMenuSettings) {
            OpenRuntimeSettings(hwnd);
            return 0;
        }
        if ((wParam & 0xFFF0u) == kMenuFactoryReset) {
            FactoryReset(hwnd);
            return 0;
        }
        break;
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

    gSingleInstance = CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
    if (!gSingleInstance) return 1;
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        if (HWND existing = FindWindowW(kWindowClass, L"جوال")) {
            ShowWindow(existing, SW_RESTORE);
            SetForegroundWindow(existing);
        }
        CloseHandle(gSingleInstance);
        gSingleInstance = nullptr;
        return 0;
    }

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.hInstance = instance;
    wc.lpfnWndProc = WindowProc;
    wc.lpszClassName = kWindowClass;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    if (!RegisterClassExW(&wc)) return 2;

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
    if (!hwnd) return 3;

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

    if (gSingleInstance) {
        ReleaseMutex(gSingleInstance);
        CloseHandle(gSingleInstance);
        gSingleInstance = nullptr;
    }
    return static_cast<int>(message.wParam);
}

#include "VmController.hpp"

#include <dwmapi.h>
#include <chrono>
#include <sstream>
#include <thread>
#include <vector>

namespace jawal {
namespace {

struct WindowSearch {
    DWORD pid{};
    HWND hwnd{};
};

BOOL CALLBACK FindProcessWindow(HWND hwnd, LPARAM param) {
    auto* search = reinterpret_cast<WindowSearch*>(param);
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == search->pid && IsWindowVisible(hwnd) && GetWindow(hwnd, GW_OWNER) == nullptr) {
        search->hwnd = hwnd;
        return FALSE;
    }
    return TRUE;
}

HWND WaitForVmWindow(DWORD pid, std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        WindowSearch search{pid, nullptr};
        EnumWindows(FindProcessWindow, reinterpret_cast<LPARAM>(&search));
        if (search.hwnd) return search.hwnd;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return nullptr;
}

std::wstring Quote(const std::filesystem::path& value) {
    return L"\"" + value.wstring() + L"\"";
}

} // namespace

VmController::~VmController() {
    Stop();
}

bool VmController::Running() const noexcept {
    if (!process_.hProcess) return false;
    return WaitForSingleObject(process_.hProcess, 0) == WAIT_TIMEOUT;
}

std::wstring VmController::BuildCommandLine(HWND, const VmConfig& c) const {
    const auto firmware = c.runtimeDir / L"firmware" / L"edk2-x86_64-code.fd";

    std::wostringstream cmd;
    cmd << Quote(c.qemuExe)
        << L" -name JawalRuntime"
        << L" -nodefaults -no-user-config"
        << L" -accel whpx"
        << L" -machine q35"
        << L" -smp " << c.cpuCores
        << L" -m " << c.memoryMb
        << L" -bios " << Quote(firmware)
        << L" -device virtio-vga-gl"
        << L" -display sdl,gl=on,window-close=off"
        << L" -device qemu-xhci"
        << L" -device usb-tablet"
        << L" -device usb-kbd"
        << L" -device virtio-rng-pci"
        << L" -nic user,model=virtio-net-pci"
        << L" -drive file=" << Quote(c.userDisk)
        << L",if=virtio,format=qcow2,cache=writeback,discard=unmap"
        << L" -monitor none -serial none"
        << L" -qmp tcp:127.0.0.1:45454,server=on,wait=off";
    return cmd.str();
}

bool VmController::Start(HWND renderParent, const VmConfig& config, std::wstring* error) {
    if (Running()) return true;

    if (!std::filesystem::exists(config.qemuExe)) {
        if (error) *error = L"QEMU runtime is missing.";
        return false;
    }
    if (!std::filesystem::exists(config.userDisk)) {
        if (error) *error = L"Jawal device disk is missing. Packaging must create the copy-on-write device image first.";
        return false;
    }

    std::wstring command = BuildCommandLine(renderParent, config);
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);

    PROCESS_INFORMATION pi{};
    const BOOL created = CreateProcessW(
        config.qemuExe.c_str(),
        mutableCommand.data(),
        nullptr,
        nullptr,
        FALSE,
        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
        nullptr,
        config.runtimeDir.c_str(),
        &startup,
        &pi);

    if (!created) {
        if (error) *error = L"Unable to start the Android runtime. Windows error: " + std::to_wstring(GetLastError());
        return false;
    }

    process_ = pi;
    CloseHandle(process_.hThread);
    process_.hThread = nullptr;

    // QEMU's SDL window stays the actual GPU presentation surface. We re-parent
    // that native window into Jawal instead of encoding/streaming frames.
    HWND vmWindow = WaitForVmWindow(process_.dwProcessId, std::chrono::seconds(12));
    if (!vmWindow) {
        if (error) *error = L"Android started but its render surface did not become available.";
        Stop();
        return false;
    }

    LONG_PTR style = GetWindowLongPtrW(vmWindow, GWL_STYLE);
    style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU | WS_POPUP);
    style |= WS_CHILD | WS_VISIBLE;
    SetWindowLongPtrW(vmWindow, GWL_STYLE, style);
    SetParent(vmWindow, renderParent);

    RECT rc{};
    GetClientRect(renderParent, &rc);
    SetWindowPos(vmWindow, nullptr, 0, 0, rc.right - rc.left, rc.bottom - rc.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    return true;
}

void VmController::Stop() noexcept {
    if (!process_.hProcess) return;

    WindowSearch search{process_.dwProcessId, nullptr};
    EnumWindows(FindProcessWindow, reinterpret_cast<LPARAM>(&search));
    if (search.hwnd) PostMessageW(search.hwnd, WM_CLOSE, 0, 0);

    if (WaitForSingleObject(process_.hProcess, 2500) == WAIT_TIMEOUT) {
        TerminateProcess(process_.hProcess, 0);
        WaitForSingleObject(process_.hProcess, 1000);
    }

    CloseHandle(process_.hProcess);
    process_ = {};
}

} // namespace jawal

#include "VmController.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>
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

bool SendSocketAll(SOCKET socket, const char* data, int size) {
    while (size > 0) {
        const int sent = send(socket, data, size, 0);
        if (sent <= 0) return false;
        data += sent;
        size -= sent;
    }
    return true;
}

bool QmpCommand(const char* command) {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;

    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) {
        WSACleanup();
        return false;
    }

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(45454);
    InetPtonW(AF_INET, L"127.0.0.1", &address.sin_addr);

    bool ok = connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0;
    if (ok) {
        DWORD timeoutMs = 1000;
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
        char greeting[2048]{};
        recv(socket, greeting, sizeof(greeting), 0); // QMP greeting; content isn't needed here.

        static constexpr char capabilities[] = "{\"execute\":\"qmp_capabilities\"}\r\n";
        ok = SendSocketAll(socket, capabilities, static_cast<int>(sizeof(capabilities) - 1));
        if (ok) {
            char reply[512]{};
            recv(socket, reply, sizeof(reply), 0);
            std::string payload = std::string("{\"execute\":\"") + command + "\"}\r\n";
            ok = SendSocketAll(socket, payload.c_str(), static_cast<int>(payload.size()));
        }
    }

    closesocket(socket);
    WSACleanup();
    return ok;
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
    const auto kernel = c.runtimeDir / L"android" / L"kernel";
    const auto initrd = c.runtimeDir / L"android" / L"initrd.img";

    std::wostringstream cmd;
    cmd << Quote(c.qemuExe)
        << L" -name JawalRuntime"
        << L" -nodefaults -no-user-config"
        << L" -accel whpx"
        << L" -machine q35"
        << L" -smp " << c.cpuCores
        << L" -m " << c.memoryMb;

    if (std::filesystem::exists(firmware)) {
        cmd << L" -bios " << Quote(firmware);
    }

    cmd << L" -kernel " << Quote(kernel)
        << L" -initrd " << Quote(initrd)
        << L" -append \"root=/dev/ram0 SRC=/AndroidOS DATA=vdb HWC=drm_minigbm GRALLOC=minigbm_arcvm FFMPEG_CODEC=1 FFMPEG_PREFER_C2=1 quiet\""
        << L" -device virtio-vga-gl"
        << L" -display sdl,gl=on,window-close=off"
        << L" -audiodev sdl,id=jawal_audio"
        << L" -device ich9-intel-hda"
        << L" -device hda-duplex,audiodev=jawal_audio"
        << L" -device qemu-xhci"
        << L" -device usb-tablet"
        << L" -device usb-kbd"
        << L" -device virtio-rng-pci"
        << L" -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:27183-:27183"
        << L" -drive file=" << Quote(c.systemDisk)
        << L",if=virtio,format=qcow2,readonly=on,cache=none"
        << L" -drive file=" << Quote(c.dataDisk)
        << L",if=virtio,format=qcow2,cache=writeback,discard=unmap"
        << L" -monitor none -serial none"
        << L" -qmp tcp:127.0.0.1:45454,server=on,wait=off";
    return cmd.str();
}

bool VmController::Start(HWND renderParent, const VmConfig& config, std::wstring* error) {
    if (Running()) return true;

    const auto kernel = config.runtimeDir / L"android" / L"kernel";
    const auto initrd = config.runtimeDir / L"android" / L"initrd.img";
    if (!std::filesystem::exists(config.qemuExe) ||
        !std::filesystem::exists(kernel) ||
        !std::filesystem::exists(initrd) ||
        !std::filesystem::exists(config.systemDisk) ||
        !std::filesystem::exists(config.dataDisk)) {
        if (error) *error = L"حزمة تشغيل جوال غير مكتملة.";
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
        if (error) *error = L"تعذر تشغيل Android. خطأ Windows: " + std::to_wstring(GetLastError());
        return false;
    }

    process_ = pi;
    CloseHandle(process_.hThread);
    process_.hThread = nullptr;

    // Keep QEMU's accelerated native presentation surface; embedding avoids a
    // video encode/decode pipeline and its latency/copy overhead.
    HWND vmWindow = WaitForVmWindow(process_.dwProcessId, std::chrono::seconds(15));
    if (!vmWindow) {
        if (error) *error = L"بدأ Android لكن سطح العرض المسرّع لم يظهر.";
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

    // Ask Android/ACPI to shut down first so ext4 user data isn't torn down by
    // killing the VM process. Force quit is only the last fallback.
    QmpCommand("system_powerdown");
    if (WaitForSingleObject(process_.hProcess, 8000) == WAIT_TIMEOUT) {
        QmpCommand("quit");
        if (WaitForSingleObject(process_.hProcess, 1500) == WAIT_TIMEOUT) {
            TerminateProcess(process_.hProcess, 0);
            WaitForSingleObject(process_.hProcess, 1000);
        }
    }

    CloseHandle(process_.hProcess);
    process_ = {};
}

} // namespace jawal

#include "VmController.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <chrono>
#include <fstream>
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

std::string EscapeJson(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (const char c : value) {
        if (c == '\\' || c == '"') out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

} // namespace

VmController::~VmController() {
    Stop(false);
}

bool VmController::Running() const noexcept {
    if (!process_.hProcess) return false;
    return WaitForSingleObject(process_.hProcess, 0) == WAIT_TIMEOUT;
}

std::wstring VmController::BuildCommandLine(HWND, const VmConfig& c) const {
    const auto firmware = c.runtimeDir / L"firmware" / L"edk2-x86_64-code.fd";
    const auto kernel = c.runtimeDir / L"android" / L"kernel";
    const auto initrd = c.runtimeDir / L"android" / L"initrd.img";

    std::wostringstream video;
    video << L"video=Virtual-1:" << c.displayWidth << L"x" << c.displayHeight << L"@" << c.refreshRate;

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
        << L" -append \"root=/dev/ram0 SRC=/AndroidOS DATA=/dev/vdb HWC=drm_minigbm GRALLOC=minigbm_arcvm FFMPEG_CODEC=1 FFMPEG_PREFER_C2=1 "
        << video.str() << L" quiet\""
        << L" -device virtio-vga-gl"
        << L" -display sdl,gl=on,window-close=off"
        << L" -audiodev sdl,id=jawal_audio"
        << L" -device ich9-intel-hda"
        << L" -device hda-duplex,audiodev=jawal_audio"
        << L" -device qemu-xhci"
        << L" -device usb-tablet"
        << L" -device usb-kbd"
        << L" -device virtio-rng-pci"
        << L" -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:27183-:27183,hostfwd=tcp:127.0.0.1:27184-:27184,hostfwd=tcp:127.0.0.1:27185-:27185,hostfwd=tcp:127.0.0.1:27188-:27188"
        << L" -drive file=" << Quote(c.systemDisk)
        << L",if=virtio,format=qcow2,readonly=on,cache=none"
        << L" -drive file=" << Quote(c.dataDisk)
        << L",if=virtio,format=qcow2,cache=writeback,discard=unmap"
        << L" -monitor none -serial none"
        << L" -qmp tcp:127.0.0.1:45454,server=on,wait=off";

    if (c.resumeQuickState) {
        cmd << L" -loadvm jawal_quick_resume";
    }
    return cmd.str();
}

bool VmController::QmpCommand(const std::string& json, std::string* replyOut) const {
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
    std::string reply;
    if (ok) {
        DWORD timeoutMs = 30000;
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

        char buffer[8192]{};
        recv(socket, buffer, sizeof(buffer) - 1, 0);

        static constexpr char capabilities[] = "{\"execute\":\"qmp_capabilities\"}\r\n";
        ok = SendSocketAll(socket, capabilities, static_cast<int>(sizeof(capabilities) - 1));
        if (ok) {
            recv(socket, buffer, sizeof(buffer) - 1, 0);
            std::string payload = json + "\r\n";
            ok = SendSocketAll(socket, payload.c_str(), static_cast<int>(payload.size()));
        }
        if (ok) {
            const int received = recv(socket, buffer, sizeof(buffer) - 1, 0);
            if (received > 0) {
                buffer[received] = '\0';
                reply.assign(buffer, static_cast<std::size_t>(received));
                ok = reply.find("\"return\"") != std::string::npos &&
                     reply.find("\"error\"") == std::string::npos;
            } else {
                ok = false;
            }
        }
    }

    closesocket(socket);
    WSACleanup();
    if (replyOut) *replyOut = std::move(reply);
    return ok;
}

bool VmController::QmpHumanMonitor(const std::string& command, std::string* reply) const {
    return QmpCommand("{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"" +
                      EscapeJson(command) + "\"}}", reply);
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
        config.qemuExe.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr,
        config.runtimeDir.c_str(), &startup, &pi);

    if (!created) {
        if (error) *error = L"تعذر تشغيل Android. خطأ Windows: " + std::to_wstring(GetLastError());
        return false;
    }

    process_ = pi;
    CloseHandle(process_.hThread);
    process_.hThread = nullptr;

    HWND vmWindow = WaitForVmWindow(process_.dwProcessId, std::chrono::seconds(config.resumeQuickState ? 8 : 15));
    if (!vmWindow) {
        const bool retryCold = config.resumeQuickState;
        Stop(false);
        if (retryCold) {
            std::error_code ec;
            if (!config.quickResumeMarker.empty()) std::filesystem::remove(config.quickResumeMarker, ec);
            VmConfig cold = config;
            cold.resumeQuickState = false;
            return Start(renderParent, cold, error);
        }
        if (error) *error = L"بدأ Android لكن سطح العرض المسرّع لم يظهر.";
        return false;
    }

    if (!renderBridge_.Attach(renderParent, vmWindow)) {
        if (error) *error = L"تعذر دمج سطح Android داخل نافذة جوال.";
        Stop(false);
        return false;
    }
    return true;
}

bool VmController::SaveQuickResume(const std::filesystem::path& marker, std::wstring* error) {
    if (!Running()) return false;

    std::string ignored;
    QmpHumanMonitor("delvm jawal_quick_resume", &ignored);

    std::string reply;
    if (!QmpHumanMonitor("savevm jawal_quick_resume", &reply)) {
        if (error) *error = L"تعذر حفظ حالة الاستئناف السريع؛ سيتم الإغلاق العادي.";
        return false;
    }

    std::error_code ec;
    std::filesystem::create_directories(marker.parent_path(), ec);
    std::ofstream out(marker, std::ios::trunc);
    if (!out) {
        if (error) *error = L"تم حفظ Snapshot لكن تعذر إنشاء علامة الاستئناف.";
        return false;
    }
    out << "jawal_quick_resume\n";
    return true;
}

void VmController::Stop(bool tryQuickResume, const std::filesystem::path& marker) noexcept {
    if (!process_.hProcess) return;

    bool saved = false;
    if (tryQuickResume && !marker.empty()) {
        std::wstring ignored;
        saved = SaveQuickResume(marker, &ignored);
    }

    renderBridge_.Detach();

    if (saved) {
        QmpCommand("{\"execute\":\"quit\"}", nullptr);
        WaitForSingleObject(process_.hProcess, 5000);
    } else {
        QmpCommand("{\"execute\":\"system_powerdown\"}", nullptr);
        if (WaitForSingleObject(process_.hProcess, 8000) == WAIT_TIMEOUT) {
            QmpCommand("{\"execute\":\"quit\"}", nullptr);
            if (WaitForSingleObject(process_.hProcess, 1500) == WAIT_TIMEOUT) {
                TerminateProcess(process_.hProcess, 0);
                WaitForSingleObject(process_.hProcess, 1000);
            }
        }
    }

    CloseHandle(process_.hProcess);
    process_ = {};
}

void VmController::Resize() noexcept {
    renderBridge_.Resize();
}

} // namespace jawal

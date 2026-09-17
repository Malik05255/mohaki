#include "VmController.hpp"

#include "RuntimeIntegrity.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <bcrypt.h>

#include <array>
#include <chrono>
#include <cctype>
#include <fstream>
#include <sstream>
#include <thread>
#include <vector>

namespace jawal {
namespace {

constexpr std::size_t kSessionTokenBytes = 32;
constexpr std::size_t kSessionTokenChars = kSessionTokenBytes * 2;

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

bool ValidSessionToken(const std::string& token) {
    if (token.size() != kSessionTokenChars) return false;
    for (const unsigned char c : token) {
        if (!std::isxdigit(c)) return false;
    }
    return true;
}

bool GenerateSessionToken(std::string* token) {
    if (!token) return false;
    std::array<unsigned char, kSessionTokenBytes> random{};
    if (BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()),
                        BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        return false;
    }

    static constexpr char hex[] = "0123456789abcdef";
    token->clear();
    token->reserve(kSessionTokenChars);
    for (const unsigned char value : random) {
        token->push_back(hex[(value >> 4) & 0x0F]);
        token->push_back(hex[value & 0x0F]);
    }
    return true;
}

bool WriteSessionTokenFile(const std::filesystem::path& path, const std::string& token) {
    if (path.empty() || !ValidSessionToken(token)) return false;

    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    if (ec) return false;

    auto temporary = path;
    temporary += L".tmp";
    std::filesystem::remove(temporary, ec);
    ec.clear();

    {
        std::ofstream output(temporary, std::ios::trunc);
        if (!output) return false;
        output << token << "\n";
        if (!output.good()) {
            output.close();
            std::filesystem::remove(temporary, ec);
            return false;
        }
    }

    if (!MoveFileExW(temporary.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        std::filesystem::remove(temporary, ec);
        return false;
    }
    return true;
}

bool QuickResumeMatchesRuntime(const std::filesystem::path& marker,
                               const std::filesystem::path& runtimeDir,
                               std::string* sessionToken) {
    if (sessionToken) sessionToken->clear();
    if (marker.empty() || !std::filesystem::exists(marker)) return false;

    std::string fingerprint;
    if (!RuntimeManifestFingerprint(runtimeDir, &fingerprint)) return false;

    std::ifstream input(marker);
    if (!input) return false;

    std::string version;
    std::string runtimeLine;
    std::string sessionLine;
    if (!std::getline(input, version) ||
        !std::getline(input, runtimeLine) ||
        !std::getline(input, sessionLine)) {
        return false;
    }
    if (version != "jawal_quick_resume_v3" || runtimeLine != "runtime=" + fingerprint) return false;
    static constexpr char prefix[] = "session=";
    if (sessionLine.rfind(prefix, 0) != 0) return false;
    const std::string token = sessionLine.substr(sizeof(prefix) - 1);
    if (!ValidSessionToken(token)) return false;
    if (sessionToken) *sessionToken = token;
    return true;
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
    const std::wstring sessionToken(sessionToken_.begin(), sessionToken_.end());

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
        << L" -append \"root=/dev/ram0 SRC=/AndroidOS DATA=/dev/vdb HWC=drm_minigbm GRALLOC=minigbm_arcvm FFMPEG_CODEC2_PREFER=1 DPI="
        << c.displayDensityDpi
        << L" androidboot.jawal_session=" << sessionToken << L" "
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

    VmConfig effective = config;
    std::string resumeSessionToken;
    if (effective.resumeQuickState &&
        !QuickResumeMatchesRuntime(effective.quickResumeMarker, effective.runtimeDir, &resumeSessionToken)) {
        std::error_code ec;
        if (!effective.quickResumeMarker.empty()) std::filesystem::remove(effective.quickResumeMarker, ec);
        effective.resumeQuickState = false;
    }

    if (effective.resumeQuickState) {
        sessionToken_ = std::move(resumeSessionToken);
    } else if (!GenerateSessionToken(&sessionToken_)) {
        if (error) *error = L"تعذر إنشاء مفتاح جلسة آمن لجوال.";
        return false;
    }

    sessionTokenFile_ = effective.dataDisk.parent_path() / L"session.token";
    if (!WriteSessionTokenFile(sessionTokenFile_, sessionToken_)) {
        sessionToken_.clear();
        sessionTokenFile_.clear();
        if (error) *error = L"تعذر تجهيز مفتاح جلسة جوال المحلي.";
        return false;
    }

    const auto kernel = effective.runtimeDir / L"android" / L"kernel";
    const auto initrd = effective.runtimeDir / L"android" / L"initrd.img";
    if (!std::filesystem::exists(effective.qemuExe) ||
        !std::filesystem::exists(kernel) ||
        !std::filesystem::exists(initrd) ||
        !std::filesystem::exists(effective.systemDisk) ||
        !std::filesystem::exists(effective.dataDisk)) {
        std::error_code ec;
        std::filesystem::remove(sessionTokenFile_, ec);
        sessionToken_.clear();
        sessionTokenFile_.clear();
        if (error) *error = L"حزمة تشغيل جوال غير مكتملة.";
        return false;
    }

    runtimeDir_ = effective.runtimeDir;
    std::wstring command = BuildCommandLine(renderParent, effective);
    std::vector<wchar_t> mutableCommand(command.begin(), command.end());
    mutableCommand.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);

    PROCESS_INFORMATION pi{};
    const BOOL created = CreateProcessW(
        effective.qemuExe.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr,
        effective.runtimeDir.c_str(), &startup, &pi);

    if (!created) {
        std::error_code ec;
        std::filesystem::remove(sessionTokenFile_, ec);
        runtimeDir_.clear();
        sessionToken_.clear();
        sessionTokenFile_.clear();
        if (error) *error = L"تعذر تشغيل Android. خطأ Windows: " + std::to_wstring(GetLastError());
        return false;
    }

    process_ = pi;
    CloseHandle(process_.hThread);
    process_.hThread = nullptr;

    HWND vmWindow = WaitForVmWindow(process_.dwProcessId,
                                    std::chrono::seconds(effective.resumeQuickState ? 8 : 15));
    if (!vmWindow) {
        const bool retryCold = effective.resumeQuickState;
        Stop(false);
        if (retryCold) {
            std::error_code ec;
            if (!effective.quickResumeMarker.empty()) std::filesystem::remove(effective.quickResumeMarker, ec);
            effective.resumeQuickState = false;
            return Start(renderParent, effective, error);
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
    if (!Running() || runtimeDir_.empty() || !ValidSessionToken(sessionToken_)) return false;

    // Remove the previous authorization marker before touching VM state. If
    // savevm fails or Windows exits mid-save, a stale marker can never make the
    // next launch attempt an old/incomplete snapshot.
    std::error_code ec;
    std::filesystem::remove(marker, ec);

    std::string ignored;
    QmpHumanMonitor("delvm jawal_quick_resume", &ignored);

    std::string reply;
    if (!QmpHumanMonitor("savevm jawal_quick_resume", &reply)) {
        if (error) *error = L"تعذر حفظ حالة الاستئناف السريع؛ سيتم الإغلاق العادي.";
        return false;
    }

    std::string fingerprint;
    if (!RuntimeManifestFingerprint(runtimeDir_, &fingerprint)) {
        if (error) *error = L"تم حفظ Snapshot لكن تعذر ربطه بإصدار Runtime الحالي.";
        return false;
    }

    std::filesystem::create_directories(marker.parent_path(), ec);
    std::ofstream out(marker, std::ios::trunc);
    if (!out) {
        if (error) *error = L"تم حفظ Snapshot لكن تعذر إنشاء علامة الاستئناف.";
        return false;
    }
    out << "jawal_quick_resume_v3\n"
        << "runtime=" << fingerprint << "\n"
        << "session=" << sessionToken_ << "\n";
    return out.good();
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

    std::error_code ec;
    if (!sessionTokenFile_.empty()) std::filesystem::remove(sessionTokenFile_, ec);
    runtimeDir_.clear();
    sessionTokenFile_.clear();
    sessionToken_.clear();
}

void VmController::Resize() noexcept {
    renderBridge_.Resize();
}

} // namespace jawal

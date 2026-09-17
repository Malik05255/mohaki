#include "RuntimeWatchdog.hpp"

#include "Diagnostics.hpp"
#include "GuestReadiness.hpp"

#include <chrono>

namespace jawal {
namespace {

constexpr auto kBootGrace = std::chrono::seconds(90);
constexpr auto kProbeInterval = std::chrono::seconds(5);
constexpr unsigned kFailureThreshold = 3;

} // namespace

RuntimeWatchdog::~RuntimeWatchdog() {
    Stop();
}

void RuntimeWatchdog::Start(HWND owner, UINT recoveryMessage) {
    Stop();
    running_.store(true);
    worker_ = std::thread(&RuntimeWatchdog::Run, this, owner, recoveryMessage);
}

void RuntimeWatchdog::Stop() noexcept {
    running_.store(false);
    wake_.notify_all();
    if (worker_.joinable()) worker_.join();
}

void RuntimeWatchdog::Run(HWND owner, UINT recoveryMessage) {
    // Do not count normal Android boot as a health failure. Wait until the guest
    // control service answers once, while still treating a guest that never
    // becomes ready within the boot grace period as recoverable.
    const auto bootDeadline = std::chrono::steady_clock::now() + kBootGrace;
    bool guestBecameReady = false;

    while (running_.load() && std::chrono::steady_clock::now() < bootDeadline) {
        if (GuestReadyFast()) {
            guestBecameReady = true;
            LogDiagnostic(L"Guest watchdog armed after first successful health ping");
            break;
        }

        std::unique_lock lock(mutex_);
        if (wake_.wait_for(lock, kProbeInterval, [this] { return !running_.load(); })) return;
    }

    if (!running_.load()) return;
    if (!guestBecameReady) {
        LogDiagnostic(L"Guest watchdog requested recovery after boot readiness timeout");
        PostMessageW(owner, recoveryMessage, 0, 0);
        return;
    }

    unsigned failures = 0;
    while (running_.load()) {
        std::unique_lock lock(mutex_);
        if (wake_.wait_for(lock, kProbeInterval, [this] { return !running_.load(); })) return;
        lock.unlock();

        if (GuestReadyFast()) {
            if (failures != 0) LogDiagnostic(L"Guest watchdog health recovered before restart threshold");
            failures = 0;
            continue;
        }

        ++failures;
        LogDiagnostic(L"Guest watchdog ping failed (" + std::to_wstring(failures) +
                      L"/" + std::to_wstring(kFailureThreshold) + L")");
        if (failures >= kFailureThreshold) {
            LogDiagnostic(L"Guest watchdog requested runtime recovery");
            PostMessageW(owner, recoveryMessage, 0, 0);
            return;
        }
    }
}

} // namespace jawal

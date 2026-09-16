#include "RuntimeWatchdog.hpp"

#include "Diagnostics.hpp"
#include "PackageBridge.hpp"

#include <chrono>
#include <string>

namespace jawal {

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
    {
        std::unique_lock lock(mutex_);
        if (wake_.wait_for(lock, std::chrono::seconds(45), [this] { return !running_.load(); })) return;
    }

    unsigned failures = 0;
    while (running_.load()) {
        std::string response;
        if (GuestControl("PING", &response)) {
            failures = 0;
        } else {
            ++failures;
            LogDiagnostic(L"Guest watchdog ping failed (" + std::to_wstring(failures) + L"/3)");
            if (failures >= 3) {
                LogDiagnostic(L"Guest watchdog requested runtime recovery");
                PostMessageW(owner, recoveryMessage, 0, 0);
                return;
            }
        }

        std::unique_lock lock(mutex_);
        if (wake_.wait_for(lock, std::chrono::seconds(15), [this] { return !running_.load(); })) return;
    }
}

} // namespace jawal

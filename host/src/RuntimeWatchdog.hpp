#pragma once

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace jawal {

class RuntimeWatchdog final {
public:
    RuntimeWatchdog() = default;
    ~RuntimeWatchdog();

    RuntimeWatchdog(const RuntimeWatchdog&) = delete;
    RuntimeWatchdog& operator=(const RuntimeWatchdog&) = delete;

    void Start(HWND owner, UINT recoveryMessage);
    void Stop() noexcept;

private:
    void Run(HWND owner, UINT recoveryMessage);

    std::atomic<bool> running_{false};
    std::thread worker_;
    std::mutex mutex_;
    std::condition_variable wake_;
};

} // namespace jawal

#pragma once

#include <atomic>
#include <thread>

namespace jawal {

class ClipboardBridge final {
public:
    ClipboardBridge() = default;
    ~ClipboardBridge();

    ClipboardBridge(const ClipboardBridge&) = delete;
    ClipboardBridge& operator=(const ClipboardBridge&) = delete;

    void Start();
    void Stop() noexcept;
    bool Running() const noexcept { return running_.load(); }

private:
    void Loop();

    std::atomic<bool> running_{false};
    std::thread worker_;
};

} // namespace jawal

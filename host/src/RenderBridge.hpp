#pragma once

#include <windows.h>

#include <atomic>
#include <thread>

namespace jawal {

// Owns the low-latency embedding of QEMU's accelerated SDL surface inside the
// phone-shaped Jawal host window. It also owns a tiny host-side boot overlay so
// Android's stock boot animation can be disabled without showing a black screen.
class RenderBridge final {
public:
    RenderBridge() = default;
    ~RenderBridge();

    RenderBridge(const RenderBridge&) = delete;
    RenderBridge& operator=(const RenderBridge&) = delete;

    bool Attach(HWND parent, HWND vmWindow);
    void Resize() noexcept;
    void Detach() noexcept;
    HWND Surface() const noexcept { return surface_; }

private:
    void StartReadyProbe();
    void StopReadyProbe() noexcept;

    HWND parent_{};
    HWND surface_{};
    HWND overlay_{};
    std::atomic_bool probing_{false};
    std::thread probeThread_;
};

} // namespace jawal

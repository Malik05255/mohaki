#pragma once

#include <windows.h>

namespace jawal {

// Owns the low-latency embedding of QEMU's accelerated SDL surface inside the
// phone-shaped Jawal host window. This is the production fallback renderer
// until a shared-texture/Direct3D transport is benchmarked better on Windows.
class RenderBridge final {
public:
    bool Attach(HWND parent, HWND vmWindow);
    void Resize() noexcept;
    void Detach() noexcept;
    HWND Surface() const noexcept { return surface_; }

private:
    HWND parent_{};
    HWND surface_{};
};

} // namespace jawal

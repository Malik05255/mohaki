#include "RenderBridge.hpp"

#include <dwmapi.h>

namespace jawal {

bool RenderBridge::Attach(HWND parent, HWND vmWindow) {
    if (!parent || !vmWindow) return false;

    LONG_PTR style = GetWindowLongPtrW(vmWindow, GWL_STYLE);
    style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU | WS_POPUP);
    style |= WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN;
    SetWindowLongPtrW(vmWindow, GWL_STYLE, style);

    LONG_PTR exStyle = GetWindowLongPtrW(vmWindow, GWL_EXSTYLE);
    exStyle &= ~(WS_EX_APPWINDOW | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE);
    SetWindowLongPtrW(vmWindow, GWL_EXSTYLE, exStyle);

    if (!SetParent(vmWindow, parent)) {
        const DWORD error = GetLastError();
        if (error != ERROR_SUCCESS) return false;
    }

    BOOL disableTransitions = TRUE;
    DwmSetWindowAttribute(vmWindow, DWMWA_TRANSITIONS_FORCEDISABLED,
                          &disableTransitions, sizeof(disableTransitions));

    parent_ = parent;
    surface_ = vmWindow;
    Resize();
    ShowWindow(surface_, SW_SHOW);
    UpdateWindow(surface_);
    return true;
}

void RenderBridge::Resize() noexcept {
    if (!parent_ || !surface_) return;
    RECT rc{};
    GetClientRect(parent_, &rc);
    SetWindowPos(surface_, nullptr, 0, 0,
                 rc.right - rc.left,
                 rc.bottom - rc.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS | SWP_FRAMECHANGED);
}

void RenderBridge::Detach() noexcept {
    if (surface_ && IsWindow(surface_)) ShowWindow(surface_, SW_HIDE);
    surface_ = nullptr;
    parent_ = nullptr;
}

} // namespace jawal

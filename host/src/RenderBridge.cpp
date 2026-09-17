#include "RenderBridge.hpp"

#include "GuestReadiness.hpp"

#include <dwmapi.h>

#include <chrono>

namespace jawal {
namespace {

constexpr wchar_t kBootOverlayClass[] = L"JawalBootOverlay";

LRESULT CALLBACK BootOverlayProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        HDC dc = BeginPaint(hwnd, &ps);
        RECT rc{};
        GetClientRect(hwnd, &rc);
        HBRUSH background = CreateSolidBrush(RGB(250, 250, 250));
        FillRect(dc, &rc, background);
        DeleteObject(background);

        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(32, 32, 32));
        HFONT oldFont = static_cast<HFONT>(SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT)));
        DrawTextW(dc, L"جاري تشغيل جوالك…", -1, &rc,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_RTLREADING | DT_NOPREFIX);
        SelectObject(dc, oldFont);
        EndPaint(hwnd, &ps);
        return 0;
    }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

ATOM EnsureBootOverlayClass() {
    static ATOM atom = [] {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = BootOverlayProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.lpszClassName = kBootOverlayClass;
        return RegisterClassExW(&wc);
    }();
    return atom;
}

} // namespace

RenderBridge::~RenderBridge() {
    Detach();
}

bool RenderBridge::Attach(HWND parent, HWND vmWindow) {
    if (!parent || !vmWindow) return false;

    LONG_PTR style = GetWindowLongPtrW(vmWindow, GWL_STYLE);
    style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU | WS_POPUP);
    style |= WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN;
    SetWindowLongPtrW(vmWindow, GWL_STYLE, style);

    LONG_PTR exStyle = GetWindowLongPtrW(vmWindow, GWL_EXSTYLE);
    exStyle &= ~(WS_EX_APPWINDOW | WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE);
    SetWindowLongPtrW(vmWindow, GWL_EXSTYLE, exStyle);

    SetLastError(ERROR_SUCCESS);
    HWND previousParent = SetParent(vmWindow, parent);
    if (!previousParent && GetLastError() != ERROR_SUCCESS) return false;

    BOOL disableTransitions = TRUE;
    DwmSetWindowAttribute(vmWindow, DWMWA_TRANSITIONS_FORCEDISABLED,
                          &disableTransitions, sizeof(disableTransitions));

    parent_ = parent;
    surface_ = vmWindow;

    if (!EnsureBootOverlayClass()) return false;
    overlay_ = CreateWindowExW(
        WS_EX_LAYOUTRTL,
        kBootOverlayClass,
        nullptr,
        WS_CHILD | WS_VISIBLE,
        0, 0, 1, 1,
        parent_, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!overlay_) return false;

    Resize();
    ShowWindow(surface_, SW_SHOW);
    UpdateWindow(surface_);
    ShowWindow(overlay_, SW_SHOW);
    SetWindowPos(overlay_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    UpdateWindow(overlay_);
    StartReadyProbe();
    return true;
}

void RenderBridge::StartReadyProbe() {
    StopReadyProbe();
    probing_.store(true);
    probeThread_ = std::thread([this] {
        using namespace std::chrono_literals;
        const auto deadline = std::chrono::steady_clock::now() + 3min;
        while (probing_.load() && std::chrono::steady_clock::now() < deadline) {
            if (GuestReadyFast()) {
                probing_.store(false);
                if (overlay_ && IsWindow(overlay_)) ShowWindowAsync(overlay_, SW_HIDE);
                return;
            }
            for (int i = 0; i < 10 && probing_.load(); ++i) {
                std::this_thread::sleep_for(100ms);
            }
        }
    });
}

void RenderBridge::StopReadyProbe() noexcept {
    probing_.store(false);
    if (probeThread_.joinable()) probeThread_.join();
}

void RenderBridge::Resize() noexcept {
    if (!parent_ || !surface_) return;
    RECT rc{};
    GetClientRect(parent_, &rc);
    const int width = rc.right - rc.left;
    const int height = rc.bottom - rc.top;
    SetWindowPos(surface_, nullptr, 0, 0, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS | SWP_FRAMECHANGED);
    if (overlay_ && IsWindow(overlay_) && IsWindowVisible(overlay_)) {
        SetWindowPos(overlay_, HWND_TOP, 0, 0, width, height,
                     SWP_NOACTIVATE | SWP_NOCOPYBITS);
    }
}

void RenderBridge::Detach() noexcept {
    StopReadyProbe();
    if (overlay_ && IsWindow(overlay_)) DestroyWindow(overlay_);
    overlay_ = nullptr;
    if (surface_ && IsWindow(surface_)) ShowWindow(surface_, SW_HIDE);
    surface_ = nullptr;
    parent_ = nullptr;
}

} // namespace jawal

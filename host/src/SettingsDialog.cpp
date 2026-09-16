#include "SettingsDialog.hpp"
#include "RuntimeSettings.hpp"

#include <windows.h>

#include <algorithm>
#include <string>

namespace jawal {
namespace {

constexpr wchar_t kClassName[] = L"JawalSettingsWindow";
constexpr int kSave = 1001;
constexpr int kCancel = 1002;
constexpr int kRam = 1101;
constexpr int kCpu = 1102;
constexpr int kWidth = 1103;
constexpr int kHeight = 1104;
constexpr int kRefresh = 1105;
constexpr int kQuickResume = 1106;
constexpr int kClipboard = 1107;

struct DialogState {
    std::filesystem::path dataDirectory;
    RuntimeSettings settings;
    bool saved{false};
};

void ApplyFont(HWND control) {
    SendMessageW(control, WM_SETFONT,
                 reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
}

HWND AddLabel(HWND parent, const wchar_t* text, int x, int y, int w = 170) {
    HWND h = CreateWindowExW(WS_EX_TRANSPARENT, L"STATIC", text,
                             WS_CHILD | WS_VISIBLE | SS_RIGHT,
                             x, y, w, 24, parent, nullptr, GetModuleHandleW(nullptr), nullptr);
    ApplyFont(h);
    return h;
}

HWND AddEdit(HWND parent, int id, unsigned value, int x, int y) {
    HWND h = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", std::to_wstring(value).c_str(),
                             WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_NUMBER | ES_RIGHT,
                             x, y, 150, 25, parent,
                             reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                             GetModuleHandleW(nullptr), nullptr);
    ApplyFont(h);
    return h;
}

bool ReadUnsigned(HWND hwnd, int id, unsigned* out) {
    wchar_t buffer[32]{};
    GetDlgItemTextW(hwnd, id, buffer, static_cast<int>(std::size(buffer)));
    try {
        std::wstring text(buffer);
        if (text.empty()) return false;
        const unsigned long value = std::stoul(text);
        *out = static_cast<unsigned>(value);
        return true;
    } catch (...) {
        return false;
    }
}

void ValidationError(HWND hwnd, const wchar_t* message) {
    MessageBoxW(hwnd, message, L"إعدادات جوال", MB_OK | MB_ICONWARNING | MB_RTLREADING);
}

LRESULT CALLBACK SettingsProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<DialogState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        state = reinterpret_cast<DialogState*>(create->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
    }

    switch (message) {
    case WM_CREATE: {
        if (!state) return -1;
        int y = 24;
        AddLabel(hwnd, L"RAM (MB) — 0 تلقائي", 215, y); AddEdit(hwnd, kRam, state->settings.memoryMb, 45, y); y += 40;
        AddLabel(hwnd, L"أنوية CPU — 0 تلقائي", 215, y); AddEdit(hwnd, kCpu, state->settings.cpuCores, 45, y); y += 40;
        AddLabel(hwnd, L"عرض Android", 215, y); AddEdit(hwnd, kWidth, state->settings.displayWidth, 45, y); y += 40;
        AddLabel(hwnd, L"ارتفاع Android", 215, y); AddEdit(hwnd, kHeight, state->settings.displayHeight, 45, y); y += 40;
        AddLabel(hwnd, L"معدل التحديث Hz", 215, y); AddEdit(hwnd, kRefresh, state->settings.refreshRate, 45, y); y += 44;

        HWND quick = CreateWindowExW(0, L"BUTTON", L"الاستئناف السريع Quick Resume",
                                     WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX | BS_RIGHTBUTTON,
                                     45, y, 340, 26, hwnd,
                                     reinterpret_cast<HMENU>(static_cast<INT_PTR>(kQuickResume)),
                                     GetModuleHandleW(nullptr), nullptr);
        ApplyFont(quick);
        SendMessageW(quick, BM_SETCHECK, state->settings.quickResume ? BST_CHECKED : BST_UNCHECKED, 0);
        y += 34;

        HWND clip = CreateWindowExW(0, L"BUTTON", L"مزامنة الحافظة Windows ↔ Android",
                                    WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX | BS_RIGHTBUTTON,
                                    45, y, 340, 26, hwnd,
                                    reinterpret_cast<HMENU>(static_cast<INT_PTR>(kClipboard)),
                                    GetModuleHandleW(nullptr), nullptr);
        ApplyFont(clip);
        SendMessageW(clip, BM_SETCHECK, state->settings.clipboardSync ? BST_CHECKED : BST_UNCHECKED, 0);

        HWND save = CreateWindowExW(0, L"BUTTON", L"حفظ وإعادة التشغيل",
                                    WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                                    215, 330, 170, 32, hwnd,
                                    reinterpret_cast<HMENU>(static_cast<INT_PTR>(kSave)),
                                    GetModuleHandleW(nullptr), nullptr);
        HWND cancel = CreateWindowExW(0, L"BUTTON", L"إلغاء",
                                      WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                                      45, 330, 150, 32, hwnd,
                                      reinterpret_cast<HMENU>(static_cast<INT_PTR>(kCancel)),
                                      GetModuleHandleW(nullptr), nullptr);
        ApplyFont(save); ApplyFont(cancel);
        return 0;
    }
    case WM_COMMAND:
        if (!state) break;
        if (LOWORD(wParam) == kCancel) {
            DestroyWindow(hwnd);
            return 0;
        }
        if (LOWORD(wParam) == kSave) {
            RuntimeSettings next = state->settings;
            if (!ReadUnsigned(hwnd, kRam, &next.memoryMb) ||
                !ReadUnsigned(hwnd, kCpu, &next.cpuCores) ||
                !ReadUnsigned(hwnd, kWidth, &next.displayWidth) ||
                !ReadUnsigned(hwnd, kHeight, &next.displayHeight) ||
                !ReadUnsigned(hwnd, kRefresh, &next.refreshRate)) {
                ValidationError(hwnd, L"تأكد أن جميع الحقول الرقمية تحتوي أرقامًا صحيحة.");
                return 0;
            }
            if (next.memoryMb != 0 && (next.memoryMb < 2048 || next.memoryMb > 12288)) {
                ValidationError(hwnd, L"RAM يجب أن تكون 0 للتلقائي أو بين 2048 و12288 MB."); return 0;
            }
            if (next.cpuCores > 8) {
                ValidationError(hwnd, L"CPU يجب أن يكون 0 للتلقائي أو من 1 إلى 8 أنوية."); return 0;
            }
            if (next.displayWidth < 720 || next.displayWidth > 2160 ||
                next.displayHeight < 1280 || next.displayHeight > 3840) {
                ValidationError(hwnd, L"الدقة المدعومة: عرض 720–2160 وارتفاع 1280–3840."); return 0;
            }
            if (next.refreshRate < 30 || next.refreshRate > 144) {
                ValidationError(hwnd, L"معدل التحديث يجب أن يكون بين 30 و144 Hz."); return 0;
            }
            next.quickResume = SendDlgItemMessageW(hwnd, kQuickResume, BM_GETCHECK, 0, 0) == BST_CHECKED;
            next.clipboardSync = SendDlgItemMessageW(hwnd, kClipboard, BM_GETCHECK, 0, 0) == BST_CHECKED;
            if (!SaveRuntimeSettings(state->dataDirectory, next)) {
                MessageBoxW(hwnd, L"تعذر حفظ إعدادات جوال.", L"جوال", MB_OK | MB_ICONERROR | MB_RTLREADING);
                return 0;
            }
            state->settings = next;
            state->saved = true;
            DestroyWindow(hwnd);
            return 0;
        }
        break;
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

} // namespace

bool ShowSettingsDialog(HWND owner, const std::filesystem::path& dataDirectory) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpfnWndProc = SettingsProc;
        wc.lpszClassName = kClassName;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
        if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
        registered = true;
    }

    DialogState state{};
    state.dataDirectory = dataDirectory;
    state.settings = LoadRuntimeSettings(dataDirectory);

    RECT ownerRect{};
    GetWindowRect(owner, &ownerRect);
    const int width = 440;
    const int height = 410;
    const int x = ownerRect.left + ((ownerRect.right - ownerRect.left) - width) / 2;
    const int y = ownerRect.top + ((ownerRect.bottom - ownerRect.top) - height) / 2;

    HWND dialog = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT,
                                  kClassName, L"إعدادات جوال",
                                  WS_POPUP | WS_CAPTION | WS_SYSMENU,
                                  x, y, width, height,
                                  owner, nullptr, GetModuleHandleW(nullptr), &state);
    if (!dialog) return false;

    EnableWindow(owner, FALSE);
    ShowWindow(dialog, SW_SHOW);
    UpdateWindow(dialog);

    MSG msg{};
    while (IsWindow(dialog) && GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(dialog, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    EnableWindow(owner, TRUE);
    SetForegroundWindow(owner);
    return state.saved;
}

} // namespace jawal

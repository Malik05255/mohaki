# Jawal Runtime Architecture

## Goal

Jawal must behave like a phone application, not a traditional emulator frontend. Normal startup has one visible window: the Android surface.

## Runtime path

1. `Jawal.exe` starts and reads `runtime.json`.
2. Host verifies WHPX availability and the integrity of the runtime bundle.
3. Host resumes the most recent clean VM snapshot when possible; otherwise it cold boots the guest.
4. QEMU runs without its stock GUI/control windows.
5. Android output is rendered through a modern virtual GPU path; the host window owns presentation, input mapping and window chrome.
6. Host/guest management traffic uses a dedicated IPC channel. ADB is treated as an install/debug fallback, not the main application protocol.

## Host components

- `JawalApp`: window lifecycle and Arabic-first shell.
- `VmController`: QEMU process, WHPX detection, lifecycle and recovery.
- `RenderBridge`: low-latency presentation path. Avoid encode/decode video streaming.
- `InputBridge`: pointer, wheel and keyboard -> Android input events.
- `PackageBridge`: validates dropped APKs and requests installation.
- `SnapshotManager`: quick resume and clean-shutdown snapshots.
- `RuntimeHealth`: startup self-test and crash diagnostics.

## Guest components

The Android image is built as a dedicated product. Do not build a normal phone image and delete files after the fact.

Keep compatibility-critical Android services:

- ART / Zygote
- Binder
- ActivityManager and PackageManager
- SurfaceFlinger and graphics stack
- PermissionController
- Keystore/KeyMint software-backed path
- Storage framework and DocumentsProvider
- DownloadManager
- WebView
- networking and DNS
- AudioFlinger and media framework/codecs
- notifications
- input framework
- PackageInstaller

Omit by default when no Jawal feature depends on them:

- Dialer, Contacts, Messaging
- telephony/IMS/SIM Toolkit/carrier UI
- Cell Broadcast and cellular emergency UI
- FM radio
- live wallpapers and bundled wallpaper packs
- Email, Calendar, Gallery, Music and Camera stock applications
- print spooler/services
- TV/Automotive/Wear packages
- NFC user components when NFC pass-through is not implemented
- demo/sample/test packages
- developer-oriented applications and debug artifacts in production
- traditional OTA UI when Jawal owns image updates
- hardware HAL variants for physical devices that the VM never exposes
- excessive locales/fonts/ringtones outside the supported language set

## App store policy

Open AOSP does not contain Google Play. The base Jawal image therefore exposes an app-store integration point but does not commit proprietary Google packages. A licensed GMS/Google Play flavor may be produced separately when redistribution rights and compatibility requirements are satisfied. The open flavor must remain usable with sideloading and an AOSP-compatible store.

## ARM APK compatibility

Native x86_64 execution is the primary fast path. ARM/ARM64 translation is an optional native-bridge module. Jawal must not silently redistribute proprietary translation libraries. The runtime reports whether the native bridge is installed and compatible before advertising ARM-only APK support.

## Performance rules

- WHPX/Hyper-V acceleration is mandatory for the high-performance profile.
- Never use legacy VGA for the production Android display path.
- Prefer virtio devices for block/network/input/graphics where the guest supports them.
- Use a sparse/dynamic userdata disk.
- Keep one recent clean quick-resume snapshot, not an unbounded snapshot history.
- No H.264 screen encode/decode loop between guest and host.
- Host UI must not poll ADB continuously.

## Compatibility over size

Size budgets are gates, not excuses to break framework behavior. If removing a component causes failures in the smoke-test app matrix, restore it and document the cost.

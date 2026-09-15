# Jawal (جوال)

Jawal is a Windows-first Android runtime designed to feel like opening a phone, not an emulator control panel.

## Product principles

- Double-click `Jawal.exe` -> Android resumes directly.
- No game-emulator dashboard, ads, side toolbar, or device-manager UI in normal use.
- AOSP is built as a dedicated product (`jawal_x86_64`) with non-useful phone hardware/services omitted at build time.
- Performance-sensitive path: WHPX/Hyper-V acceleration, virtio devices, GPU acceleration, sparse user-data disk, quick-resume snapshots.
- APK installation is available by drag-and-drop and through Android itself.
- Arabic-first host UX; technical names remain in their original form.
- Compatibility wins over extreme stripping: core Android framework, media, WebView, keystore, permissions, storage and networking are never removed merely to save disk space.

## Important compatibility note

AOSP itself does not include Google Play. Jawal therefore keeps the Android runtime independent from proprietary Google packages. A licensed Google Play/GMS image can be supported as a separate product flavor when redistribution rights are available. The open build is designed around AOSP-compatible app stores/services and sideloaded APKs.

## Repository layout

- `host/` Windows launcher/runtime host.
- `android/` Jawal AOSP product definitions, overlays, service and build scripts.
- `virtualization/` QEMU/WHPX configuration and VM lifecycle files.
- `packaging/` installer and runtime packaging.
- `tools/` validation and size-budget scripts.
- `docs/` architecture and compatibility policy.

## Status

Initial architecture and build scaffold. The repository intentionally does not commit an Android system image or proprietary ARM translation/GMS binaries. Those are generated or supplied only through legally redistributable build inputs.

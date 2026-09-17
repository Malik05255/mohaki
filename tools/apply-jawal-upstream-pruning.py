#!/usr/bin/env python3
"""Apply guarded, Jawal-specific reductions to the synced Android-x86 device tree.

The synced Bliss/Android-Generic source targets arbitrary physical PCs. Jawal is a
fixed QEMU/WHPX virtual phone, so Bluetooth/GPS physical hardware, generic sensor
HALs and their physical-PC init paths are dead weight. Patches are exact and fail
closed when upstream changes, preventing silent edits to unexpected source.
"""
from __future__ import annotations

import argparse
from pathlib import Path


class PatchError(RuntimeError):
    pass


def replace_exact(path: Path, old: str, new: str, label: str) -> None:
    if not path.is_file():
        raise PatchError(f"{label}: missing file: {path}")
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count == 0:
        # Idempotent rerun: accept an already-patched tree.
        if new in text:
            print(f"PASS already patched: {label}")
            return
        raise PatchError(f"{label}: expected source fragment not found in {path}")
    if count != 1:
        raise PatchError(f"{label}: expected one source fragment, found {count} in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"PASS patched: {label}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("aosp_dir", type=Path)
    args = ap.parse_args()
    root = args.aosp_dir.resolve()

    board = root / "device/generic/common/BoardConfig.mk"
    device = root / "device/generic/common/device.mk"
    init_sh = root / "device/generic/common/init.sh"

    replacements = [
        (board, "BOARD_HAVE_BLUETOOTH := true", "BOARD_HAVE_BLUETOOTH := false", "disable physical Bluetooth board support"),
        (board, "BOARD_HAVE_BLUETOOTH_LINUX := true", "BOARD_HAVE_BLUETOOTH_LINUX := false", "disable Linux Bluetooth vendor support"),
        (board, "BUILD_WITH_ALSA_UTILS ?= true", "BUILD_WITH_ALSA_UTILS ?= false", "omit ALSA command-line utilities while retaining audio HAL"),
        (board, "BOARD_HAS_GPS_HARDWARE ?= true", "BOARD_HAS_GPS_HARDWARE ?= false", "disable physical GPS board support"),
        (
            device,
            "$(call inherit-product-if-exists,device/common/gps/gps_as.mk)",
            "# Jawal: physical GPS configuration intentionally omitted",
            "omit generic physical GPS product inheritance",
        ),
        (
            device,
            "$(call inherit-product-if-exists,hardware/libsensors/sensors.mk)",
            "# Jawal: physical sensor HAL inheritance intentionally omitted",
            "omit generic physical sensors product inheritance",
        ),
        (init_sh, "\tset_custom_ota\n", "\t# Jawal: Android-x86 OTA setup omitted\n", "skip Android-x86 OTA init"),
        (init_sh, "\tinit_hal_brcm_wifi\n", "\t# Jawal: physical Wi-Fi init omitted\n", "skip physical Wi-Fi init"),
        (init_sh, "\tinit_hal_bluetooth\n", "\t# Jawal: physical Bluetooth init omitted\n", "skip physical Bluetooth init"),
        (init_sh, "\tinit_hal_camera\n", "\t# Jawal: physical camera init omitted\n", "skip physical camera init"),
        (init_sh, "\tinit_hal_gps\n", "\t# Jawal: physical GPS init omitted\n", "skip physical GPS init"),
        (init_sh, "\tinit_hal_sensors\n", "\t# Jawal: physical sensor init omitted\n", "skip physical sensors init"),
        (init_sh, "\tinit_hal_surface\n", "\t# Jawal: Microsoft Surface hardware init omitted\n", "skip Surface-specific init"),
        (init_sh, "\tinit_tscal\n", "\t# Jawal: physical touchscreen calibration omitted\n", "skip touchscreen calibration init"),
        (init_sh, "\tinit_ril\n", "\t# Jawal: radio/RIL init omitted\n", "skip telephony RIL init"),
        (init_sh, "\tinit_prepare_ota\n", "\t# Jawal: OTA preparation omitted\n", "skip OTA preparation"),
    ]

    try:
        for path, old, new, label in replacements:
            replace_exact(path, old, new, label)
    except PatchError as exc:
        print(f"FAIL {exc}")
        return 2

    print("Jawal guarded upstream pruning complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

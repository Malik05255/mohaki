#!/usr/bin/env python3
"""Apply guarded, Jawal-specific reductions to the synced Android-x86 device tree.

The synced Bliss/Android-Generic source targets arbitrary physical PCs. Jawal is a
fixed QEMU/WHPX virtual phone, so Bluetooth/GPS physical hardware and generic
sensor HALs are dead weight. Patches are exact and fail closed when upstream
changes, preventing silent edits to unexpected source.
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

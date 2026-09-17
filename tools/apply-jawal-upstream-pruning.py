#!/usr/bin/env python3
"""Apply guarded, Jawal-specific reductions to the synced Android-x86 device tree.

The synced Bliss/Android-Generic source targets arbitrary physical PCs. Jawal is a
fixed QEMU/WHPX virtual phone, so physical Bluetooth/GPS/sensor stacks, physical
GPU/media driver families, generic PC firmware and their init paths are dead weight.
Patches are exact and fail closed when upstream changes, preventing silent edits
to unexpected source.
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
        if new in text:
            print(f"PASS already patched: {label}")
            return
        raise PatchError(f"{label}: expected source fragment not found in {path}")
    if count != 1:
        raise PatchError(f"{label}: expected one source fragment, found {count} in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"PASS patched: {label}")


def ensure_after(path: Path, marker: str, line: str, label: str) -> None:
    if not path.is_file():
        raise PatchError(f"{label}: missing file: {path}")
    text = path.read_text(encoding="utf-8")
    if line in text:
        print(f"PASS already patched: {label}")
        return
    count = text.count(marker)
    if count != 1:
        raise PatchError(f"{label}: expected one marker, found {count} in {path}")
    path.write_text(text.replace(marker, marker + "\n" + line, 1), encoding="utf-8")
    print(f"PASS patched: {label}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("aosp_dir", type=Path)
    args = ap.parse_args()
    root = args.aosp_dir.resolve()

    board = root / "device/generic/common/BoardConfig.mk"
    device = root / "device/generic/common/device.mk"
    init_sh = root / "device/generic/common/init.sh"
    kernel_task = root / "device/generic/common/build/tasks/kernel.mk"

    replacements = [
        (board, "BOARD_HAVE_BLUETOOTH := true", "BOARD_HAVE_BLUETOOTH := false", "disable physical Bluetooth board support"),
        (board, "BOARD_HAVE_BLUETOOTH_LINUX := true", "BOARD_HAVE_BLUETOOTH_LINUX := false", "disable Linux Bluetooth vendor support"),
        (board, "BOARD_HAVE_BLUETOOTH_INTEL_ICNV := true", "BOARD_HAVE_BLUETOOTH_INTEL_ICNV := false", "disable Intel physical Bluetooth support"),
        (board, "BUILD_WITH_ALSA_UTILS ?= true", "BUILD_WITH_ALSA_UTILS ?= false", "omit ALSA command-line utilities while retaining audio HAL"),
        (board, "BOARD_HAS_GPS_HARDWARE ?= true", "BOARD_HAS_GPS_HARDWARE ?= false", "disable physical GPS board support"),
        (
            board,
            "BOARD_GPU_DRIVERS ?= crocus i915 iris freedreno panfrost nouveau r300g r600g radeonsi virgl vmwgfx",
            "BOARD_GPU_DRIVERS ?= virgl",
            "build only the virtual GPU driver exposed by QEMU",
        ),
        (
            board,
            "BOARD_MESA3D_GALLIUM_DRIVERS := crocus iris i915 nouveau r600 radeonsi svga virgl zink softpipe llvmpipe",
            "BOARD_MESA3D_GALLIUM_DRIVERS := virgl zink",
            "drop physical and software Gallium renderers; Jawal requires accelerated virtual GPU",
        ),
        (
            board,
            "BOARD_MESA3D_VULKAN_DRIVERS := amd intel intel_hasvk virtio swrast nouveau",
            "BOARD_MESA3D_VULKAN_DRIVERS := virtio",
            "drop physical and software Vulkan renderers; keep Virtio Vulkan only",
        ),
        (board, "BOARD_USE_LIBVA_INTEL_DRIVER := true", "BOARD_USE_LIBVA_INTEL_DRIVER := false", "disable Intel VA driver under Virtio GPU"),
        (board, "BOARD_USE_LIBVA := true", "BOARD_USE_LIBVA := false", "disable VAAPI stack without a physical Intel GPU"),
        (board, "BOARD_USE_LIBMIX := true", "BOARD_USE_LIBMIX := false", "disable Intel libmix media path"),
        (board, "BOARD_USES_WRS_OMXIL_CORE := true", "BOARD_USES_WRS_OMXIL_CORE := false", "disable Intel WRS OMX core"),
        (board, "USE_INTEL_OMX_COMPONENTS := true", "USE_INTEL_OMX_COMPONENTS := false", "disable Intel OMX components"),
        (board, "BOARD_USES_IA_HWCOMPOSER := true", "BOARD_USES_IA_HWCOMPOSER := false", "disable Intel hardware composer path"),
        (board, "BOARD_MESA3D_GALLIUM_VA := enabled", "BOARD_MESA3D_GALLIUM_VA := disabled", "disable Gallium VA frontend under Virtio GPU"),
        (board, "BOARD_USES_MINIGBM_INTEL := true", "BOARD_USES_MINIGBM_INTEL := false", "disable Intel-only minigbm backend"),
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
        (
            kernel_task,
            "\t$(COPY_FIRMWARE_SCRIPT) --zstd -v $(FIRMWARE_DEST)\n",
            "\t# Jawal: generic physical-PC firmware catalogue intentionally omitted\n",
            "skip generic Linux PC firmware copy",
        ),
        (
            kernel_task,
            "\t$(if $(TARGET_HAS_SILEAD_FIRMWARE), $(COPY_FIRMWARE_SILEAD_SCRIPT) --zstd -v $(FIRMWARE_DEST))\n",
            "\t# Jawal: Silead touchscreen firmware intentionally omitted\n",
            "skip Silead touchscreen firmware",
        ),
        (
            kernel_task,
            "\t$(if $(TARGET_HAS_SOF_FIRMWARE), FW_DEST=$(FIRMWARE_DEST)/intel FW_LOCATION=$(SOF_FIRMWARE_DIR) $(COPY_FIRMWARE_SOF_SCRIPT) $(SOF_FIRMWARE_VERSION))\n",
            "\t# Jawal: Intel SOF firmware intentionally omitted; guest audio is emulated HDA\n",
            "skip Intel SOF physical-audio firmware",
        ),
        (
            kernel_task,
            "\t$(if $(FIRMWARE_ENABLED),$(mk_kernel) INSTALL_MOD_PATH=$(abspath $(TARGET_OUT)) firmware_install)\n",
            "\t# Jawal: kernel firmware_install intentionally omitted for fixed QEMU hardware\n",
            "skip kernel external firmware installation",
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

        ensure_after(
            board,
            "TARGET_EXTRA_KERNEL_MODULES := ",
            "TARGET_KERNEL_DIFFCONFIG ?= device/jawal/jawal-kernel-minimal.config",
            "use Jawal minimal virtual-hardware kernel diffconfig",
        )
    except PatchError as exc:
        print(f"FAIL {exc}")
        return 2

    print("Jawal guarded upstream pruning complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

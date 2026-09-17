#!/usr/bin/env python3
"""Remove Android-x86 product machinery Jawal never uses.

Jawal updates its immutable Android runtime from the Windows host and recreates
user data separately. Android A/B OTA, recovery and physical-PC calibration
components are therefore build-time dead weight. Edits are exact and fail closed
when BlissOS changes its product file so upstream updates cannot silently
reintroduce them.
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("aosp_dir", type=Path)
    args = ap.parse_args()
    device = args.aosp_dir.resolve() / "device/generic/common/device.mk"

    replacements = [
        (
            "PRODUCT_BUILD_GENERIC_OTA_PACKAGE := true",
            "PRODUCT_BUILD_GENERIC_OTA_PACKAGE := false",
            "disable generic Android OTA package",
        ),
        (
            "AB_OTA_POSTINSTALL_CONFIG += \\\n    RUN_POSTINSTALL_system=true \\\n    POSTINSTALL_PATH_system=system/bin/otapreopt_script \\\n    FILESYSTEM_TYPE_system=ext4 \\\n    POSTINSTALL_OPTIONAL_system=true",
            "# Jawal: A/B postinstall configuration omitted",
            "remove A/B postinstall configuration",
        ),
        (
            "PRODUCT_PACKAGES += \\\n    otapreopt_script",
            "# Jawal: OTA dex postinstall utility omitted",
            "remove OTA dex postinstall script",
        ),
        (
            "PRODUCT_PACKAGES_DEBUG += \\\n    bootctl",
            "# Jawal: A/B boot control utility omitted",
            "remove A/B boot control utility",
        ),
        (
            "PRODUCT_PACKAGES += \\\n    update_engine \\\n    update_engine_sideload \\\n    update_verifier",
            "# Jawal: Android updater packages omitted; Windows host owns runtime updates",
            "remove Android update engine packages",
        ),
        (
            "PRODUCT_PACKAGES_DEBUG += \\\n    update_engine_client",
            "# Jawal: updater debug client omitted",
            "remove update engine debug client",
        ),
        (
            "# Recovery\nPRODUCT_COPY_FILES += \\\n    $(if $(wildcard $(PRODUCT_DIR)init.recovery.$(TARGET_PRODUCT).rc),$(PRODUCT_DIR)init.recovery.$(TARGET_PRODUCT).rc,$(LOCAL_PATH)/init.recovery.x86.rc):$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.$(TARGET_PRODUCT).rc \\\n    $(if $(wildcard $(PRODUCT_DIR)init.recovery.sh),$(PRODUCT_DIR),$(LOCAL_PATH)/)init.recovery.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/init.recovery.sh \\\n    $(if $(wildcard $(PRODUCT_DIR)init.fstab.sh),$(PRODUCT_DIR),$(LOCAL_PATH)/)init.fstab.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/init.fstab.sh \\\n",
            "# Jawal: recovery copy-file block omitted; runtime is serviced by Windows host\n",
            "remove recovery copy-file block",
        ),
        (
            "$(call inherit-product-if-exists,external/tslib/tslib.mk)",
            "# Jawal: physical touchscreen calibration stack omitted; QEMU usb-tablet is calibrated input",
            "remove physical touchscreen calibration product",
        ),
    ]

    try:
        for old, new, label in replacements:
            replace_exact(device, old, new, label)
    except PatchError as exc:
        print(f"FAIL {exc}")
        return 2

    print("Jawal product OTA/recovery/physical-input pruning complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

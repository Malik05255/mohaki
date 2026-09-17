#!/usr/bin/env bash
set -euo pipefail

PRODUCT_OUT="${1:?usage: validate-kernel-profile.sh PRODUCT_OUT [REPORT_DIR]}"
REPORT_DIR="${2:-$(pwd)/dist/validation}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/kernel-profile.txt"
MODULES_REPORT="$REPORT_DIR/kernel-modules.tsv"
: > "$REPORT"
: > "$MODULES_REPORT"
FAILED=0

pass() { printf 'PASS  %s\n' "$*" | tee -a "$REPORT"; }
info() { printf 'INFO  %s\n' "$*" | tee -a "$REPORT"; }
fail() { printf 'FAIL  %s\n' "$*" | tee -a "$REPORT"; FAILED=1; }

KCONFIG="$PRODUCT_OUT/obj/kernel/.config"
if [[ ! -f "$KCONFIG" ]]; then
  fail "Built kernel config missing: $KCONFIG"
else
  pass "Built kernel config found"
fi

require_enabled() {
  local symbol="$1"
  if [[ -f "$KCONFIG" ]] && grep -Eq "^${symbol}=(y|m)$" "$KCONFIG"; then
    pass "Kernel preserves $symbol"
  else
    fail "Required virtual-hardware kernel option missing: $symbol"
  fi
}

require_disabled() {
  local symbol="$1"
  if [[ -f "$KCONFIG" ]] && grep -Eq "^${symbol}=(y|m)$" "$KCONFIG"; then
    fail "Physical/dead kernel option still enabled: $symbol"
  else
    pass "Kernel pruned $symbol"
  fi
}

# Jawal's fixed QEMU machine contract. These are required to boot, display,
# accept input and reach the network through the exact devices VmController adds.
for symbol in \
  CONFIG_VIRTIO \
  CONFIG_VIRTIO_PCI \
  CONFIG_VIRTIO_NET \
  CONFIG_VIRTIO_BLK \
  CONFIG_DRM_VIRTIO_GPU \
  CONFIG_HW_RANDOM_VIRTIO \
  CONFIG_USB_XHCI_HCD \
  CONFIG_USB_HID \
  CONFIG_HID_GENERIC \
  CONFIG_INPUT_EVDEV; do
  require_enabled "$symbol"
done

# Physical radios are never exposed by Jawal v1.
for symbol in \
  CONFIG_BT \
  CONFIG_WLAN \
  CONFIG_CFG80211 \
  CONFIG_MAC80211 \
  CONFIG_NFC \
  CONFIG_WWAN; do
  require_disabled "$symbol"
done

# Only Virtio GPU is exposed. These drivers target physical GPUs or other VM
# display models and add kernel/modules size without improving Jawal quality.
for symbol in \
  CONFIG_DRM_I915 \
  CONFIG_DRM_RADEON \
  CONFIG_DRM_AMDGPU \
  CONFIG_DRM_NOUVEAU \
  CONFIG_DRM_VMWGFX \
  CONFIG_DRM_QXL \
  CONFIG_DRM_GMA500 \
  CONFIG_DRM_UDL \
  CONFIG_DRM_AST \
  CONFIG_DRM_MGAG200 \
  CONFIG_DRM_VGEM \
  CONFIG_DRM_VKMS; do
  require_disabled "$symbol"
done

# Networking is always virtio-net. Disable the largest common physical NIC
# families while keeping the Android IP stack and virtio network driver intact.
for symbol in \
  CONFIG_NET_VENDOR_INTEL \
  CONFIG_NET_VENDOR_REALTEK \
  CONFIG_NET_VENDOR_BROADCOM \
  CONFIG_NET_VENDOR_BROCADE \
  CONFIG_NET_VENDOR_MARVELL \
  CONFIG_NET_VENDOR_AMD \
  CONFIG_NET_VENDOR_ATHEROS \
  CONFIG_NET_VENDOR_NVIDIA \
  CONFIG_NET_VENDOR_3COM \
  CONFIG_NET_VENDOR_ADAPTEC \
  CONFIG_NET_VENDOR_CHELSIO \
  CONFIG_NET_VENDOR_CISCO \
  CONFIG_NET_VENDOR_DEC \
  CONFIG_NET_VENDOR_DLINK \
  CONFIG_NET_VENDOR_EMULEX \
  CONFIG_NET_VENDOR_MELLANOX \
  CONFIG_NET_VENDOR_MICREL \
  CONFIG_NET_VENDOR_NATSEMI \
  CONFIG_NET_VENDOR_SIS \
  CONFIG_NET_VENDOR_SMSC \
  CONFIG_NET_VENDOR_VIA \
  CONFIG_NET_VENDOR_XIRCOM \
  CONFIG_USB_NET_DRIVERS; do
  require_disabled "$symbol"
done

# Jawal's virtio/HDA/xHCI devices need no physical-PC firmware blobs. The
# upstream Android-x86 kernel task normally copies a very large generic Linux
# firmware catalogue, so any payload here is an accidental size regression.
FIRMWARE_DIR="$PRODUCT_OUT/vendor/firmware"
if [[ -d "$FIRMWARE_DIR" ]]; then
  firmware_files="$(find "$FIRMWARE_DIR" -type f | wc -l)"
  firmware_bytes="$(find "$FIRMWARE_DIR" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
  if (( firmware_files > 0 )); then
    fail "Physical firmware leaked into JawalOS: $firmware_files files, $((firmware_bytes / 1048576)) MiB"
    find "$FIRMWARE_DIR" -type f -printf '%s\t%p\n' | sort -nr | head -n 50 >> "$REPORT"
  else
    pass "No physical firmware payload installed"
  fi
else
  pass "No vendor/firmware directory installed"
fi

# Report measured kernel module footprint for the next pruning pass. This is
# evidence only; never delete modules post-build because dependencies/modules.dep
# must remain coherent.
MODULE_ROOT="$PRODUCT_OUT/system/lib/modules"
[[ -d "$MODULE_ROOT" ]] || MODULE_ROOT="$PRODUCT_OUT/lib/modules"
if [[ -d "$MODULE_ROOT" ]]; then
  find "$MODULE_ROOT" -type f \( -name '*.ko' -o -name '*.ko.*' \) -printf '%s\t%p\n' | sort -nr > "$MODULES_REPORT"
  module_count="$(wc -l < "$MODULES_REPORT")"
  module_bytes="$(awk -F '\t' '{s+=$1} END {print s+0}' "$MODULES_REPORT")"
  info "Kernel module payload: $module_count files, $((module_bytes / 1048576)) MiB"
else
  info "No external kernel module directory found; required drivers may be built-in"
fi

if (( FAILED != 0 )); then
  echo "Jawal kernel profile validation failed. See $REPORT" >&2
  exit 1
fi

pass "Minimal virtual-hardware kernel profile gate complete"

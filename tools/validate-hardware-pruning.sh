#!/usr/bin/env bash
set -euo pipefail

PRODUCT_OUT="${1:?usage: validate-hardware-pruning.sh PRODUCT_OUT [REPORT_DIR]}"
REPORT_DIR="${2:-$(pwd)/dist/validation}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/hardware-pruning.txt"
: > "$REPORT"
FAILED=0

pass() { printf 'PASS  %s\n' "$*" | tee -a "$REPORT"; }
fail() { printf 'FAIL  %s\n' "$*" | tee -a "$REPORT"; FAILED=1; }

BANNED_PATTERNS=(
  '*/bin/hw/android.hardware.radio-service.ranchu'
  '*/bin/hw/android.hardware.gnss-service.ranchu'
  '*android.hardware.sensors@2.1-impl.ranchu*'
  '*/bin/hw/android.hardware.camera.provider.ranchu'
  '*/bin/hw/android.hardware.camera.provider.ranchu_minigbm'
  '*/bin/hw/android.hardware.bluetooth-service.default'
  '*/bin/wpa_supplicant'
  '*/bin/hostapd'
  '*/bin/wpa_cli'
  '*/bin/bt_vhci_forwarder'
  '*/bin/mac80211_create_radios'
  '*/bin/hw/android.hardware.usb-service.example'
  '*/bin/hw/android.hardware.lights-service.example'
  '*/bin/hw/android.hardware.identity-service.example'
  '*BluetoothMidiService*'
  '*microdroid*'
  '*virtualizationservice*'
)

for pattern in "${BANNED_PATTERNS[@]}"; do
  hit="$(find "$PRODUCT_OUT" -path "$pattern" -print -quit 2>/dev/null || true)"
  if [[ -n "$hit" ]]; then
    fail "Unused hardware/runtime component remains: ${hit#$PRODUCT_OUT/}"
  else
    pass "Absent: $pattern"
  fi
done

# Networking is still mandatory; only physical Wi-Fi radio components are gone.
for required in '*/bin/netd' '*/NetworkStack*' '*/com.android.tethering*'; do
  if find "$PRODUCT_OUT" -path "$required" -print -quit | grep -q .; then
    pass "Networking core preserved: $required"
  else
    fail "Networking core missing: $required"
  fi
done

# Rendering/media quality must remain intact.
for required in \
  '*/bin/surfaceflinger' \
  '*vulkan*' \
  '*minigbm*' \
  '*/bin/audioserver' \
  '*media.swcodec*' \
  '*libstagefright*'; do
  if find "$PRODUCT_OUT" -path "$required" -print -quit | grep -q .; then
    pass "Quality/runtime core preserved: $required"
  else
    fail "Quality/runtime core missing: $required"
  fi
done

if (( FAILED != 0 )); then
  echo "Jawal hardware pruning validation failed. See $REPORT" >&2
  exit 1
fi

pass "Fixed-VM hardware pruning gate complete"

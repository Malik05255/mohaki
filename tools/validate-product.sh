#!/usr/bin/env bash
set -euo pipefail

PRODUCT_OUT="${1:?usage: validate-product.sh PRODUCT_OUT [REPORT_DIR]}"
REPORT_DIR="${2:-$(pwd)/dist/validation}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/validation.txt"
: > "$REPORT"

pass() { printf 'PASS  %s\n' "$*" | tee -a "$REPORT"; }
warn() { printf 'WARN  %s\n' "$*" | tee -a "$REPORT"; }
fail() { printf 'FAIL  %s\n' "$*" | tee -a "$REPORT"; FAILED=1; }
FAILED=0

BANNED_APPS=(
  Aperture BlissUpdater Updater SetupWizard LineageSetupWizard BOSWallpapers
  Browser2 Calendar Camera2 Contacts DeskClock Dialer Email Etar ExactCalculator
  Exchange2 Gallery2 GameSpace Glimpse Jelly LiveWallpapers LiveWallpapersPicker
  messaging Music MusicFX OmniJaws ParallelSpace QuickSearchBox Recorder Seedvault
  Stk Taskbar Twelve WallpaperPicker2 WallpaperBackup Eleven FMRadio FM2
  CarrierConfigUI CarrierDefaultApp CellBroadcastReceiver CellBroadcastService
  CellBroadcastApp EmergencyInfo MmsService SimAppDialog ONS WAPPushManager
  NfcNci Tag SecureElement ManagedProvisioning CompanionDeviceManager
  DynamicSystemInstallationService MtpService OsuLogin SharedStorageBackup
  LocalTransport BackupRestoreConfirmation CaptivePortalLogin WifiDialog
  Development SampleLocationAttribution CtsShimPrebuilt CtsShimPrivPrebuilt
  EmulatedCamera DeviceAsWebcam Uwb UwbService SatelliteService
  VirtualizationService microdroid microdroid_manager
)

for app in "${BANNED_APPS[@]}"; do
  if find "$PRODUCT_OUT" -type d -name "$app" -print -quit | grep -q .; then
    fail "Unused package still present: $app"
  else
    pass "Removed unused package: $app"
  fi
done

BANNED_FILES=(
  '*/bin/sshd' '*/bin/htop' '*/bin/nano' '*/bin/vim' '*/bin/tcpdump'
  '*/bin/ntfs-3g' '*/bin/mkntfs' '*/bin/dmidecode' '*/bin/lspci'
  '*/bin/thermal-daemon' '*/bin/hcitool' '*/bin/simpleperf' '*/bin/strace'
  '*/bin/virtualizationservice' '*/bin/vm' '*/bin/vm_shell'
  '*/bin/fastboot' '*/bin/lpdump' '*/bin/lpmake' '*/bin/lpadd' '*/bin/lpflash'
  '*/bin/hw/android.hardware.camera.provider.ranchu'
  '*/bin/hw/android.hardware.camera.provider.ranchu_minigbm'
)

for pattern in "${BANNED_FILES[@]}"; do
  if find "$PRODUCT_OUT" -path "$pattern" -print -quit | grep -q .; then
    fail "Unused bare-metal/hardware file still present: $pattern"
  else
    pass "Removed unused bare-metal/hardware file: $pattern"
  fi
done

require_path() {
  local label="$1"; shift
  local found=""
  for pattern in "$@"; do
    found="$(find "$PRODUCT_OUT" -path "$pattern" -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] && break
  done
  if [[ -n "$found" ]]; then pass "$label -> ${found#$PRODUCT_OUT/}"; else fail "$label missing"; fi
}

# Protected compatibility/quality core. Size optimization may not remove these.
require_path "ART app_process64" '*/bin/app_process64'
require_path "SurfaceFlinger" '*/bin/surfaceflinger'
require_path "Android framework" '*/framework/framework.jar'
require_path "SystemUI" '*/SystemUI*'
require_path "Launcher" '*/Launcher3*' '*/Trebuchet*' '*/Quickstep*'
require_path "Settings" '*/Settings*'
require_path "PermissionController" '*/PermissionController*'
require_path "WebView implementation" '*/WebView*' '*/webview*'
require_path "Media framework/codecs" '*/bin/mediaserver' '*/bin/media.swcodec' '*/lib64/libstagefright*'
require_path "Audio server" '*/bin/audioserver'
require_path "Package installer" '*/PackageInstaller*' '*/PackageInstallerService*'
require_path "Documents UI" '*/DocumentsUI*'
require_path "Download provider" '*/DownloadProvider*'
require_path "Network service" '*/bin/netd'
require_path "NetworkStack" '*/NetworkStack*' '*/com.android.tethering*'
require_path "Storage daemon" '*/bin/vold'
require_path "Keystore" '*/bin/keystore2'
require_path "Input method" '*/LatinIME*' '*/InputMethod*'
require_path "ext4 recovery/fsck" '*/bin/e2fsck'
require_path "Jawal system bridge" '*/JawalSystemBridge*'
require_path "Jawal Store" '*/JawalStore*'
require_path "Handheld core features" '*/etc/permissions/handheld_core_hardware.xml'

if find "$PRODUCT_OUT" -path '*/etc/permissions/tablet_core_hardware.xml' -print -quit | grep -q .; then
  fail "Tablet core feature declaration leaked into phone product"
else
  pass "Tablet core feature declaration removed"
fi

for feature in \
  '*/etc/permissions/android.hardware.camera*.xml' \
  '*/etc/permissions/android.hardware.nfc*.xml' \
  '*/etc/permissions/android.hardware.uwb*.xml'; do
  if find "$PRODUCT_OUT" -path "$feature" -print -quit | grep -q .; then
    fail "Unsupported hardware feature declaration still present: $feature"
  else
    pass "Unsupported hardware feature declaration removed: $feature"
  fi
done

# Stock audio catalogue is intentionally reduced, but audio quality/codec stack
# remains untouched. Keep only a tiny default selection.
require_path "Default ringtone" '*/media/audio/ringtones/Ring_Synth_04.ogg'
require_path "Default alarm" '*/media/audio/alarms/Alarm_Classic.ogg'
require_path "Default notification" '*/media/audio/notifications/pixiedust.ogg' '*/media/audio/notifications/OnTheHunt.ogg'
for category in alarms notifications ringtones; do
  count="$(find "$PRODUCT_OUT" -path "*/media/audio/$category/*.ogg" -type f | wc -l)"
  if (( count > 3 )); then
    fail "Too many stock $category sounds remain: $count"
  else
    pass "Minimal $category sound set: $count"
  fi
done

find "$PRODUCT_OUT" -type f -printf '%s\t%p\n' | sort -nr | head -n 150 > "$REPORT_DIR/largest-files.tsv"

ISO="${REPORT_DIR}/jawal-android.iso"
if [[ -f "$ISO" ]]; then
  bytes="$(stat -c '%s' "$ISO")"
  mib=$(( (bytes + 1048575) / 1048576 ))
  printf 'INFO  compressed ISO size: %s MiB\n' "$mib" | tee -a "$REPORT"
  if (( mib <= 650 )); then
    pass "Aggressive compressed-image target <= 650 MiB"
  elif (( mib <= 900 )); then
    warn "Image is above 650 MiB; continue measured pruning from largest-files.tsv"
  else
    warn "Image is > 900 MiB; another measured pruning pass is required"
  fi

  if [[ "${JAWAL_STRICT_SIZE:-0}" == "1" && $mib -gt 1000 ]]; then
    fail "Strict production image budget exceeded (1000 MiB)"
  fi
fi

if (( FAILED != 0 )); then
  echo "Jawal product validation failed. See $REPORT" >&2
  exit 1
fi

pass "Aggressive pruning + compatibility quality gate complete"

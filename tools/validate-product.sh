#!/usr/bin/env bash
set -euo pipefail

PRODUCT_OUT="${1:?usage: validate-product.sh PRODUCT_OUT [REPORT_DIR]}"
REPORT_DIR="${2:-$(pwd)/dist/validation}"
SERVICES_VARIANT="${JAWAL_SERVICES_VARIANT:-vanilla}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/validation.txt"
: > "$REPORT"

pass() { printf 'PASS  %s\n' "$*" | tee -a "$REPORT"; }
warn() { printf 'WARN  %s\n' "$*" | tee -a "$REPORT"; }
fail() { printf 'FAIL  %s\n' "$*" | tee -a "$REPORT"; FAILED=1; }
FAILED=0

case "$SERVICES_VARIANT" in
  vanilla|microg) pass "Services variant: $SERVICES_VARIANT" ;;
  *) fail "Unexpected JAWAL_SERVICES_VARIANT: $SERVICES_VARIANT" ;;
esac

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
  VirtualizationService microdroid microdroid_manager BluetoothMidiService
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
  '*/bin/update_engine' '*/bin/update_verifier' '*/bin/snapshotctl'
  '*/bin/bootanimation'
  '*/bin/wpa_supplicant' '*/bin/hostapd' '*/bin/wpa_cli'
  '*/bin/hw/android.hardware.camera.provider.ranchu'
  '*/bin/hw/android.hardware.camera.provider.ranchu_minigbm'
  '*/bootanimation.zip'
  '*/etc/external_camera_config.xml'
  '*/etc/wifi/wpa_supplicant.conf'
  '*/etc/wifi/wpa_supplicant_overlay.conf'
  '*/etc/ppp/peers/gprs'
  '*/vendor/etc/pci.ids'
  '*/vendor/etc/usb.ids'
)

for pattern in "${BANNED_FILES[@]}"; do
  if find "$PRODUCT_OUT" -path "$pattern" -print -quit | grep -q .; then
    fail "Unused bare-metal/hardware/visual file still present: $pattern"
  else
    pass "Removed unused bare-metal/hardware/visual file: $pattern"
  fi
done

# Jawal never boots Android recovery or A/B update slots; lifecycle/update logic
# lives in the Windows host around an immutable system disk and user-data qcow2.
for dead_image in recovery.img ramdisk-recovery.img; do
  if [[ -e "$PRODUCT_OUT/$dead_image" ]]; then
    fail "Unused recovery artifact still produced: $dead_image"
  else
    pass "Recovery artifact disabled: $dead_image"
  fi
done

if find "$PRODUCT_OUT" -name build.prop -type f -exec grep -Hq '^debug\.sf\.nobootanimation=1$' {} + 2>/dev/null; then
  pass "Android boot animation disabled; Jawal host owns boot UX"
else
  fail "debug.sf.nobootanimation=1 missing from built product properties"
fi

# The upstream x86 product identifies itself as a tablet. Jawal must override
# that inherited value after product inheritance so framework/app configuration
# is consistently phone-oriented as well as visually portrait-shaped.
characteristics="$(find "$PRODUCT_OUT" -name build.prop -type f -exec grep -h '^ro\.build\.characteristics=' {} + 2>/dev/null || true)"
if grep -Eq '(^|=|,)phone(,|$)' <<<"$characteristics"; then
  pass "Build characteristics include phone"
else
  fail "ro.build.characteristics does not include phone"
fi
if grep -Eq '(^|=|,)tablet(,|$)' <<<"$characteristics"; then
  fail "Tablet build characteristic leaked into JawalOS"
else
  pass "Tablet build characteristic absent"
fi

require_path() {
  local label="$1"; shift
  local found=""
  for pattern in "$@"; do
    found="$(find "$PRODUCT_OUT" -path "$pattern" -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] && break
  done
  if [[ -n "$found" ]]; then pass "$label -> ${found#$PRODUCT_OUT/}"; else fail "$label missing"; fi
}

path_exists() {
  local pattern
  for pattern in "$@"; do
    if find "$PRODUCT_OUT" -path "$pattern" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
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
# BlissOS QPR2 init.sh invokes these during boot-complete to initialize HDA
# mixer/capture state. They are runtime dependencies, not optional CLI extras.
require_path "ALSA state control" '*/bin/alsa_ctl'
require_path "ALSA mixer control" '*/bin/alsa_amixer'
require_path "ALSA UCM control" '*/bin/alsa_ucm' '*/bin/alsaucm'
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
require_path "Jawal core hardware profile" '*/etc/permissions/jawal_core_hardware.xml'

# The open build defaults to vanilla because voyager-x86-qpr2 currently does
# not resolve a vendor/microg project. microG remains a supported opt-in only
# when the builder supplies a compatible vendor tree explicitly. Validate the
# resulting image so neither flavor can silently turn into the other.
if [[ "$SERVICES_VARIANT" == "microg" ]]; then
  require_path "microG Services Core" '*/GmsCore*' '*/MicroG*GmsCore*'
  require_path "microG FakeStore identity" '*/FakeStore*'
  if path_exists '*/GsfProxy*'; then
    pass "microG GSF proxy present"
  else
    warn "microG GSF proxy is absent; verify supplied microG package set"
  fi
else
  if path_exists '*/GmsCore*' '*/MicroG*GmsCore*' '*/FakeStore*'; then
    fail "microG packages leaked into vanilla services variant"
  else
    pass "Vanilla services variant contains no microG packages"
  fi
fi

# Stock tablet/handheld profiles claim physical hardware Jawal does not expose.
for leaked in handheld_core_hardware.xml tablet_core_hardware.xml; do
  if find "$PRODUCT_OUT" -path "*/etc/permissions/$leaked" -print -quit | grep -q .; then
    fail "Stock hardware profile leaked into JawalOS: $leaked"
  else
    pass "Stock hardware profile removed: $leaked"
  fi
done

# Optional physical-radio/hardware declarations must not leak back in through an
# upstream device/product update.
for feature in \
  '*/etc/permissions/android.hardware.camera*.xml' \
  '*/etc/permissions/android.hardware.nfc*.xml' \
  '*/etc/permissions/android.hardware.uwb*.xml' \
  '*/etc/permissions/android.hardware.bluetooth*.xml' \
  '*/etc/permissions/android.hardware.wifi*.xml' \
  '*/etc/permissions/android.hardware.telephony*.xml' \
  '*/etc/permissions/android.hardware.location*.xml' \
  '*/etc/permissions/android.hardware.sensor.*.xml' \
  '*/etc/permissions/android.hardware.fingerprint*.xml'; do
  if find "$PRODUCT_OUT" -path "$feature" -print -quit | grep -q .; then
    fail "Unsupported hardware feature declaration still present: $feature"
  else
    pass "Unsupported hardware feature declaration removed: $feature"
  fi
done

CORE_PROFILE="$(find "$PRODUCT_OUT" -path '*/etc/permissions/jawal_core_hardware.xml' -print -quit || true)"
if [[ -n "$CORE_PROFILE" ]]; then
  FORBIDDEN_FEATURES=(
    android.hardware.camera
    android.hardware.bluetooth
    android.hardware.wifi
    android.hardware.nfc
    android.hardware.uwb
    android.hardware.telephony
    android.hardware.location
    android.hardware.fingerprint
    android.hardware.sensor.accelerometer
    android.hardware.sensor.compass
    android.software.telecom
    android.software.print
    android.software.backup
    android.software.companion_device_setup
  )
  for feature in "${FORBIDDEN_FEATURES[@]}"; do
    if grep -Fq "name=\"$feature" "$CORE_PROFILE"; then
      fail "Unsupported capability declared in Jawal core profile: $feature"
    else
      pass "Core profile does not claim: $feature"
    fi
  done

  if grep -Fq 'name="android.hardware.microphone"' "$CORE_PROFILE"; then
    pass "Core profile declares duplex microphone support"
  else
    fail "Jawal duplex audio is enabled but microphone capability is missing"
  fi
fi

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
    warn "Image is above 650 MiB; continue measured pruning from pruning-plan.md"
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

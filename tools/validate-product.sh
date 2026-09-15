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

# Exact app module directory names. Providers with similar names (for example
# CalendarProvider / ContactsProvider) are intentionally allowed because third
# party applications use their public framework contracts.
BANNED_APPS=(
  Aperture BlissUpdater BOSWallpapers Browser2 Calendar Camera2 Contacts
  DeskClock Dialer Email Etar ExactCalculator Exchange2 Gallery2 GameSpace
  Glimpse Jelly LiveWallpapers LiveWallpapersPicker messaging Music MusicFX
  OmniJaws ParallelSpace QuickSearchBox Recorder Seedvault Stk Twelve
  WallpaperPicker2
)

for app in "${BANNED_APPS[@]}"; do
  if find "$PRODUCT_OUT" -type d -name "$app" -print -quit | grep -q .; then
    fail "Bundled app still present: $app"
  else
    pass "Removed bundled app: $app"
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

# Compatibility-critical runtime pieces. Do not trade these away for size.
require_path "ART app_process64" '*/bin/app_process64'
require_path "SurfaceFlinger" '*/bin/surfaceflinger'
require_path "Android framework" '*/framework/framework.jar'
require_path "SystemUI" '*/SystemUI*'
require_path "Settings" '*/Settings*'
require_path "PermissionController" '*/PermissionController*'
require_path "WebView implementation" '*/WebView*' '*/webview*'
require_path "Jawal system bridge" '*/JawalSystemBridge*'
require_path "Jawal Store" '*/JawalStore*'

# Report large files so every size decision is evidence-based.
find "$PRODUCT_OUT" -type f -printf '%s\t%p\n' | sort -nr | head -n 80 > "$REPORT_DIR/largest-files.tsv"

ISO="${REPORT_DIR}/jawal-android.iso"
if [[ -f "$ISO" ]]; then
  bytes="$(stat -c '%s' "$ISO")"
  mib=$(( (bytes + 1048575) / 1048576 ))
  printf 'INFO  compressed ISO size: %s MiB\n' "$mib" | tee -a "$REPORT"
  if (( mib <= 700 )); then
    pass "Initial compressed-image target <= 700 MiB"
  elif (( mib <= 1100 )); then
    warn "Image is above the 700 MiB stretch target; optimize using largest-files.tsv, not blind framework deletion"
  else
    warn "Image is > 1.1 GiB and needs another measured pruning pass"
  fi

  if [[ "${JAWAL_STRICT_SIZE:-0}" == "1" && $mib -gt 1100 ]]; then
    fail "Strict image budget exceeded (1100 MiB)"
  fi
fi

if (( FAILED != 0 )); then
  echo "Jawal product validation failed. See $REPORT" >&2
  exit 1
fi

pass "Static product compatibility gate complete"

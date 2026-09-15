#!/usr/bin/env bash
set -euo pipefail

# Reproducible open-build store input. The official APK is not committed to
# Jawal; it is fetched for the local image build and its signing certificate is
# verified before Soong is allowed to package it.

VERSION="${AURORA_VERSION:-4.8.3}"
DEST="${1:-android/store/AuroraStore.apk}"
API="https://gitlab.com/api/v4/projects/AuroraOSS%2FAuroraStore/releases/${VERSION}"
EXPECTED_SHA256_CERT="4C626157AD02BDA3401A7263555F68A79663FC3E13A4D4369A12570941AA280F"

if [[ -n "${AURORA_APK_URL:-}" ]]; then
  APK_URL="$AURORA_APK_URL"
else
  release_json="$(curl --fail --silent --show-error --location "$API")"
  APK_URL="$(python3 -c '
import json,sys
r=json.load(sys.stdin)
want="AuroraStore-'"$VERSION"'.apk"
for link in r.get("assets",{}).get("links",[]):
    if link.get("name") == want or link.get("url","").endswith("/"+want):
        print(link.get("direct_asset_url") or link.get("url")); raise SystemExit(0)
raise SystemExit("release APK not found in official GitLab release")
' <<<"$release_json")"
fi

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp --suffix=.apk)"
trap 'rm -f "$tmp"' EXIT
curl --fail --location --retry 3 --output "$tmp" "$APK_URL"

APKSIGNER_BIN="${APKSIGNER:-}"
if [[ -z "$APKSIGNER_BIN" ]]; then
  APKSIGNER_BIN="$(command -v apksigner || true)"
fi
if [[ -z "$APKSIGNER_BIN" && -n "${AOSP_DIR:-}" ]]; then
  candidate="$AOSP_DIR/prebuilts/sdk/tools/linux/bin/apksigner"
  [[ -x "$candidate" ]] && APKSIGNER_BIN="$candidate"
fi
if [[ -z "$APKSIGNER_BIN" ]]; then
  echo "apksigner is required to verify the official Aurora signing certificate." >&2
  exit 2
fi

cert="$($APKSIGNER_BIN verify --print-certs "$tmp" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n1 | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')"
if [[ "$cert" != "$EXPECTED_SHA256_CERT" ]]; then
  echo "Refusing store APK: signing certificate mismatch." >&2
  echo "Expected: $EXPECTED_SHA256_CERT" >&2
  echo "Actual:   $cert" >&2
  exit 3
fi

mv "$tmp" "$DEST"
trap - EXIT
printf 'Verified Aurora Store %s -> %s\n' "$VERSION" "$DEST"

#!/usr/bin/env bash
set -euo pipefail

MANIFEST_URL="${JAWAL_MANIFEST_URL:-https://github.com/BlissOS/platform_manifest.git}"
MANIFEST_BRANCH="${JAWAL_ANDROID_BRANCH:-voyager-x86-qpr2}"
WORKDIR="${1:-$(mktemp -d)}"
KEEP_WORKDIR="${JAWAL_KEEP_MANIFEST_WORKDIR:-0}"

cleanup() {
  if [[ "$KEEP_WORKDIR" != "1" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

for tool in git repo python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 2
  }
done

mkdir -p "$WORKDIR"
cd "$WORKDIR"
# This gate inspects only manifest structure; it deliberately does not sync
# project objects or require Git LFS. The real Android build enables --git-lfs.
repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" >/dev/null

manifest_paths() {
  local output="$1"
  repo manifest -o "$output" >/dev/null
  python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for project in root.findall('project'):
    path = project.get('path') or project.get('name')
    if path:
        print(path)
PY
}

before="$(manifest_paths "$WORKDIR/resolved-before.xml")"

# These paths are intentionally removed by Jawal before source sync. If BlissOS
# renames or removes one, fail here so the pruning manifest is reviewed instead
# of discovering an invalid remove-project after a large builder is allocated.
required_prunable_paths=(
  device/generic/firmware
  vendor/intel/proprietary/sof-bin
  vendor/silead/proprietary/firmware
  external/libva
  external/libva-utils
  hardware/intel/common/gmmlib
  hardware/intel/common/media-driver
  hardware/intel/common/vaapi
)

failed=0
for path in "${required_prunable_paths[@]}"; do
  if grep -Fxq "$path" <<<"$before"; then
    printf 'PASS manifest path: %s\n' "$path"
  else
    printf 'FAIL manifest path missing or renamed: %s\n' "$path" >&2
    failed=1
  fi
done

# microG is deliberately optional. As of the current voyager-x86-qpr2 manifest
# it is absent, so Jawal's production default is vanilla + Aurora. If upstream
# restores vendor/microg, record that fact without making the manifest gate fail.
if grep -Fxq 'vendor/microg' <<<"$before"; then
  echo "INFO upstream vendor/microg is present; Jawal microG builds may use it after product validation"
else
  echo "INFO upstream vendor/microg is absent; Jawal defaults to vanilla and requires an explicit compatible tree for microG"
fi

if (( failed != 0 )); then
  echo "BlissOS manifest contract changed before Jawal pruning was applied." >&2
  exit 3
fi

mkdir -p .repo/local_manifests
cat > .repo/local_manifests/jawal-contract-test.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remove-project name="device_generic_firmware" />
  <remove-project name="vendor_intel_proprietary_sof-bin" />
  <remove-project name="vendor_silead_proprietary_firmware" />
  <remove-project name="hardware_intel_common_libva" />
  <remove-project name="external_libva-utils" />
  <remove-project name="hardware_intel_common_gmmlib" />
  <remove-project name="hardware_intel_common_media-driver" />
  <remove-project name="platform_hardware_intel_common_vaapi" />
</manifest>
XML

after="$(manifest_paths "$WORKDIR/resolved-after.xml")"
for path in "${required_prunable_paths[@]}"; do
  if grep -Fxq "$path" <<<"$after"; then
    printf 'FAIL local manifest did not remove: %s\n' "$path" >&2
    failed=1
  else
    printf 'PASS local manifest removes: %s\n' "$path"
  fi
done

if (( failed != 0 )); then
  exit 4
fi

echo "PASS: BlissOS $MANIFEST_BRANCH manifest still satisfies Jawal's source-pruning contract."

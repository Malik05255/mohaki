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

required_paths=(
  vendor/microg
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
for path in "${required_paths[@]}"; do
  if grep -Fxq "$path" <<<"$before"; then
    printf 'PASS manifest path: %s\n' "$path"
  else
    printf 'FAIL manifest path missing: %s\n' "$path" >&2
    failed=1
  fi
done

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
pruned_paths=(
  device/generic/firmware
  vendor/intel/proprietary/sof-bin
  vendor/silead/proprietary/firmware
  external/libva
  external/libva-utils
  hardware/intel/common/gmmlib
  hardware/intel/common/media-driver
  hardware/intel/common/vaapi
)

for path in "${pruned_paths[@]}"; do
  if grep -Fxq "$path" <<<"$after"; then
    printf 'FAIL local manifest did not remove: %s\n' "$path" >&2
    failed=1
  else
    printf 'PASS local manifest removes: %s\n' "$path"
  fi
done

if ! grep -Fxq 'vendor/microg' <<<"$after"; then
  echo "FAIL Jawal pruning unexpectedly removed vendor/microg." >&2
  failed=1
else
  echo "PASS vendor/microg survives Jawal hardware pruning"
fi

if (( failed != 0 )); then
  exit 4
fi

echo "PASS: BlissOS $MANIFEST_BRANCH manifest still satisfies Jawal's source contract."

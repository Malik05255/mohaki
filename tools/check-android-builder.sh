#!/usr/bin/env bash
set -euo pipefail

MIN_RAM_GIB="${JAWAL_MIN_BUILD_RAM_GIB:-20}"
MIN_DISK_GIB="${JAWAL_MIN_BUILD_DISK_GIB:-220}"

ram_kib="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
ram_gib=$((ram_kib / 1024 / 1024))
disk_kib="$(df -Pk "${JAWAL_AOSP_DIR:-.}" | awk 'NR==2 {print $4}')"
disk_gib=$((disk_kib / 1024 / 1024))
cores="$(nproc)"

printf 'Jawal Android builder preflight:\n'
printf '  RAM:  %s GiB (minimum %s)\n' "$ram_gib" "$MIN_RAM_GIB"
printf '  Disk: %s GiB free (minimum %s)\n' "$disk_gib" "$MIN_DISK_GIB"
printf '  CPU:  %s logical cores\n' "$cores"

failed=0
if (( ram_gib < MIN_RAM_GIB )); then
  echo "FAIL: insufficient RAM for a reliable Android 15 QPR2 build." >&2
  failed=1
fi
if (( disk_gib < MIN_DISK_GIB )); then
  echo "FAIL: insufficient free disk for source sync + Android build output." >&2
  failed=1
fi
if (( cores < 4 )); then
  echo "WARN: fewer than 4 logical cores; build will be unusually slow." >&2
fi

if (( failed != 0 )); then
  echo "Use a Linux builder with at least 24 GiB RAM and roughly 250 GiB free disk for comfortable headroom." >&2
  exit 2
fi

echo "PASS: Android builder resources are acceptable."

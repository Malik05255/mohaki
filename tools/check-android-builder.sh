#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AOSP_DIR="${JAWAL_AOSP_DIR:-$ROOT/.work/android-src}"
REPORT="${JAWAL_BUILDER_REPORT:-$ROOT/dist/preflight/android-builder.json}"
MIN_RAM_GIB="${JAWAL_MIN_BUILD_RAM_GIB:-20}"
MIN_DISK_GIB="${JAWAL_MIN_BUILD_DISK_GIB:-220}"
MIN_CORES="${JAWAL_MIN_BUILD_CORES:-4}"

mkdir -p "$AOSP_DIR" "$(dirname "$REPORT")"

ram_kib="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
swap_kib="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
ram_gib=$((ram_kib / 1024 / 1024))
swap_gib=$((swap_kib / 1024 / 1024))
disk_kib="$(df -Pk "$AOSP_DIR" | awk 'NR==2 {print $4}')"
disk_gib=$((disk_kib / 1024 / 1024))
cores="$(nproc)"
open_files="$(ulimit -n)"
arch="$(uname -m)"
kernel="$(uname -sr)"
fs_type="$(df -PT "$AOSP_DIR" | awk 'NR==2 {print $2}')"

printf 'Jawal Android builder preflight:\n'
printf '  Kernel: %s\n' "$kernel"
printf '  Arch:   %s\n' "$arch"
printf '  RAM:    %s GiB (minimum %s)\n' "$ram_gib" "$MIN_RAM_GIB"
printf '  Swap:   %s GiB\n' "$swap_gib"
printf '  Disk:   %s GiB free (minimum %s)\n' "$disk_gib" "$MIN_DISK_GIB"
printf '  CPU:    %s logical cores (minimum %s)\n' "$cores" "$MIN_CORES"
printf '  FS:     %s\n' "$fs_type"
printf '  nofile: %s\n' "$open_files"

failed=0
warnings=()
missing=()

case "$arch" in
  x86_64|amd64) ;;
  *) echo "FAIL: Android builder must be x86_64." >&2; failed=1 ;;
esac

if (( ram_gib < MIN_RAM_GIB )); then
  echo "FAIL: insufficient RAM for a reliable Android 15 QPR2 build." >&2
  failed=1
fi
if (( disk_gib < MIN_DISK_GIB )); then
  echo "FAIL: insufficient free disk for source sync + Android build output." >&2
  failed=1
fi
if (( cores < MIN_CORES )); then
  echo "FAIL: fewer than $MIN_CORES logical cores." >&2
  failed=1
fi
if (( open_files < 4096 )); then
  warnings+=("open-file limit is below 4096; large Android builds may hit descriptor pressure")
fi
case "$fs_type" in
  nfs|nfs4|cifs|smb3|fuse.*)
    warnings+=("AOSP workspace is on $fs_type; local SSD/NVMe storage is strongly preferred")
    ;;
esac
if (( ram_gib < 24 && swap_gib == 0 )); then
  warnings+=("builder has under 24 GiB RAM and no swap; upstream BlissOS recommends 24 GiB RAM")
fi

# Tools required by BlissOS voyager-x86-qpr2 plus Jawal's post-build runtime
# packaging. Catch all of these before the very large repo sync starts.
required_tools=(
  git git-lfs repo rsync python3 curl make gcc g++ flex bison gperf zip unzip
  ccache ninja xorriso xmlstarlet meson glslangValidator zstd rdfind nasm kmod
  aapt lunzip genisoimage bsdtar qemu-img mkfs.ext4 mount umount truncate
  sha256sum cargo rustc rustup cargo-ndk bindgen cbindgen
)

for tool in "${required_tools[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  PASS tool: %s\n' "$tool"
  else
    printf '  FAIL tool: %s missing\n' "$tool" >&2
    missing+=("$tool")
    failed=1
  fi
done

rust_targets_ok=true
if command -v rustup >/dev/null 2>&1; then
  installed_targets="$(rustup target list --installed 2>/dev/null || true)"
  for target in x86_64-linux-android i686-linux-android; do
    if grep -Fxq "$target" <<<"$installed_targets"; then
      printf '  PASS rust target: %s\n' "$target"
    else
      printf '  FAIL rust target: %s missing\n' "$target" >&2
      missing+=("rust-target:$target")
      rust_targets_ok=false
      failed=1
    fi
  done
else
  rust_targets_ok=false
fi

if command -v git >/dev/null 2>&1 && command -v git-lfs >/dev/null 2>&1; then
  if git lfs version >/dev/null 2>&1; then
    printf '  PASS git-lfs invocation\n'
  else
    echo '  FAIL git-lfs is installed but not usable through git lfs' >&2
    missing+=("git-lfs-usable")
    failed=1
  fi
fi

for warning in "${warnings[@]}"; do
  printf 'WARN: %s\n' "$warning" >&2
done

status="pass"
(( failed == 0 )) || status="fail"

MISSING_TEXT="$(printf '%s\n' "${missing[@]:-}")" \
WARNINGS_TEXT="$(printf '%s\n' "${warnings[@]:-}")" \
JAWAL_PREFLIGHT_STATUS="$status" \
JAWAL_PREFLIGHT_REPORT="$REPORT" \
JAWAL_PREFLIGHT_RAM="$ram_gib" \
JAWAL_PREFLIGHT_SWAP="$swap_gib" \
JAWAL_PREFLIGHT_DISK="$disk_gib" \
JAWAL_PREFLIGHT_CORES="$cores" \
JAWAL_PREFLIGHT_NOFILE="$open_files" \
JAWAL_PREFLIGHT_ARCH="$arch" \
JAWAL_PREFLIGHT_KERNEL="$kernel" \
JAWAL_PREFLIGHT_FS="$fs_type" \
JAWAL_PREFLIGHT_MIN_RAM="$MIN_RAM_GIB" \
JAWAL_PREFLIGHT_MIN_DISK="$MIN_DISK_GIB" \
JAWAL_PREFLIGHT_MIN_CORES="$MIN_CORES" \
python3 - <<'PY'
import json, os
from pathlib import Path

def lines(name):
    return [x for x in os.environ.get(name, "").splitlines() if x]

out = Path(os.environ["JAWAL_PREFLIGHT_REPORT"])
data = {
    "status": os.environ["JAWAL_PREFLIGHT_STATUS"],
    "host": {
        "kernel": os.environ["JAWAL_PREFLIGHT_KERNEL"],
        "arch": os.environ["JAWAL_PREFLIGHT_ARCH"],
        "filesystem": os.environ["JAWAL_PREFLIGHT_FS"],
        "ramGiB": int(os.environ["JAWAL_PREFLIGHT_RAM"]),
        "swapGiB": int(os.environ["JAWAL_PREFLIGHT_SWAP"]),
        "diskFreeGiB": int(os.environ["JAWAL_PREFLIGHT_DISK"]),
        "logicalCores": int(os.environ["JAWAL_PREFLIGHT_CORES"]),
        "openFileLimit": int(os.environ["JAWAL_PREFLIGHT_NOFILE"]),
    },
    "minimum": {
        "ramGiB": int(os.environ["JAWAL_PREFLIGHT_MIN_RAM"]),
        "diskFreeGiB": int(os.environ["JAWAL_PREFLIGHT_MIN_DISK"]),
        "logicalCores": int(os.environ["JAWAL_PREFLIGHT_MIN_CORES"]),
    },
    "missing": lines("MISSING_TEXT"),
    "warnings": lines("WARNINGS_TEXT"),
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"Preflight report: {out}")
PY

if (( failed != 0 )); then
  echo "Jawal Android builder is not ready." >&2
  echo "Run tools/setup-android-builder.sh on an Ubuntu/Debian x86_64 builder, then re-run this check." >&2
  exit 2
fi

echo "PASS: Android builder resources and toolchain are ready for BlissOS Android 15 QPR2."

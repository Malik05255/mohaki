#!/usr/bin/env bash
set -euo pipefail

QEMU_SRC="${1:?usage: build-minimal-qemu-msys2.sh QEMU_SOURCE_DIR OUTPUT_DIR}"
OUTPUT_DIR="${2:?usage: build-minimal-qemu-msys2.sh QEMU_SOURCE_DIR OUTPUT_DIR}"

QEMU_SRC="$(cd "$QEMU_SRC" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
BUILD_DIR="$QEMU_SRC/build-jawal-win64"

if [[ -z "${MSYSTEM:-}" || -z "${MINGW_PREFIX:-}" ]]; then
  echo "This script must run inside an MSYS2 MinGW/UCRT/Clang64 shell." >&2
  exit 2
fi

for tool in python3 ninja pkg-config grep sed; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 2; }
done
[[ -x "$QEMU_SRC/configure" ]] || { echo "QEMU configure script missing: $QEMU_SRC/configure" >&2; exit 2; }

# Jawal needs only Windows x86_64 system emulation. WHPX is mandatory in the
# product, while SDL/OpenGL + virglrenderer provide the accelerated display path
# and slirp provides the user-mode/NAT network used by the guest.
CONFIGURE_HELP="$($QEMU_SRC/configure --help)"
ARGS=(
  "--target-list=x86_64-softmmu"
)

require_option() {
  local option="$1"
  if ! grep -Fq -- "$option" <<<"$CONFIGURE_HELP"; then
    echo "Required QEMU configure option is unavailable: $option" >&2
    exit 3
  fi
  ARGS+=("$option")
}

add_option_if_supported() {
  local option="$1"
  if grep -Fq -- "$option" <<<"$CONFIGURE_HELP"; then
    ARGS+=("$option")
  fi
}

require_option "--enable-whpx"
require_option "--enable-sdl"
require_option "--enable-opengl"
require_option "--enable-virglrenderer"
require_option "--enable-slirp"

# Jawal refuses to start without WHPX, so TCG adds fallback CPU emulation that
# the product never uses. Disable it when supported. All other switches below
# remove frontends, remote protocols, host-passthrough helpers and storage/network
# backends that are absent from Jawal's fixed command line. Unknown options are
# simply skipped so the script stays usable across nearby QEMU releases.
for option in \
  --disable-tcg \
  --disable-docs \
  --disable-gtk \
  --disable-curses \
  --disable-vnc \
  --disable-spice \
  --disable-rdma \
  --disable-libiscsi \
  --disable-libnfs \
  --disable-glusterfs \
  --disable-rbd \
  --disable-vde \
  --disable-libssh \
  --disable-brlapi \
  --disable-cacard \
  --disable-smartcard \
  --disable-usb-redir \
  --disable-libusb \
  --disable-guest-agent \
  --disable-qga-vss \
  --disable-fuse \
  --disable-plugins \
  --disable-debug-info \
  --disable-werror; do
  add_option_if_supported "$option"
done

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
(
  cd "$BUILD_DIR"
  "$QEMU_SRC/configure" "${ARGS[@]}"
  ninja qemu-system-x86_64.exe qemu-img.exe
)

SYSTEM_EXE="$BUILD_DIR/qemu-system-x86_64.exe"
IMG_EXE="$BUILD_DIR/qemu-img.exe"
[[ -f "$SYSTEM_EXE" ]] || { echo "qemu-system-x86_64.exe was not produced" >&2; exit 4; }
[[ -f "$IMG_EXE" ]] || { echo "qemu-img.exe was not produced" >&2; exit 4; }

rm -rf "$OUTPUT_DIR"/*
mkdir -p "$OUTPUT_DIR"
cp -f "$SYSTEM_EXE" "$OUTPUT_DIR/qemu-system-x86_64.exe"
cp -f "$IMG_EXE" "$OUTPUT_DIR/qemu-img.exe"

# Resolve only DLLs reachable from the two binaries. Search the QEMU build tree
# plus MSYS2's active toolchain bin directory, but copy the dependency closure
# into one self-contained folder for the normal Jawal packaging step.
SCANNER="$REPO_ROOT/tools/pe-dependency-closure.py"
REPORT="$OUTPUT_DIR/qemu-build-dependencies.json"
WINDOWS_SYSTEM=""
if command -v cygpath >/dev/null && [[ -n "${WINDIR:-}" ]]; then
  WINDOWS_SYSTEM="$(cygpath -u "$WINDIR/System32")"
fi

SCAN_ARGS=(
  "$SCANNER" "$OUTPUT_DIR"
  qemu-system-x86_64.exe qemu-img.exe
  --search-dir "$BUILD_DIR"
  --search-dir "$MINGW_PREFIX/bin"
  --json "$REPORT"
)
if [[ -n "$WINDOWS_SYSTEM" && -d "$WINDOWS_SYSTEM" ]]; then
  SCAN_ARGS+=(--system-dir "$WINDOWS_SYSTEM")
fi

mapfile -t DLLS < <(python3 "${SCAN_ARGS[@]}")
for dll in "${DLLS[@]}"; do
  [[ -n "$dll" ]] || continue
  source=""
  for candidate in "$BUILD_DIR/$dll" "$MINGW_PREFIX/bin/$dll"; do
    if [[ -f "$candidate" ]]; then source="$candidate"; break; fi
  done
  [[ -n "$source" ]] || { echo "Resolved DLL disappeared before staging: $dll" >&2; exit 5; }
  cp -f "$source" "$OUTPUT_DIR/$dll"
done

# Strip only copies in the staging directory. Never modify the toolchain or QEMU
# build tree because the same builder may be reused for diagnostics.
if command -v strip >/dev/null; then
  strip --strip-unneeded "$OUTPUT_DIR/qemu-system-x86_64.exe" "$OUTPUT_DIR/qemu-img.exe" || true
  while IFS= read -r -d '' dll; do strip --strip-unneeded "$dll" || true; done < <(find "$OUTPUT_DIR" -maxdepth 1 -iname '*.dll' -print0)
fi

# Include only firmware needed by Jawal's q35/virtio-vga machine. The later
# assemble-windows-runtime.ps1 step treats edk2-x86_64-code.fd as mandatory.
copy_first() {
  local target="$1"; shift
  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      cp -f "$candidate" "$OUTPUT_DIR/$target"
      return 0
    fi
  done
  return 1
}

copy_first edk2-x86_64-code.fd \
  "$BUILD_DIR/pc-bios/edk2-x86_64-code.fd" \
  "$QEMU_SRC/pc-bios/edk2-x86_64-code.fd" \
  "$MINGW_PREFIX/share/qemu/edk2-x86_64-code.fd" || {
    echo "Required edk2-x86_64-code.fd firmware was not found." >&2
    exit 6
  }

copy_first vgabios-virtio.bin \
  "$BUILD_DIR/pc-bios/vgabios-virtio.bin" \
  "$QEMU_SRC/pc-bios/vgabios-virtio.bin" \
  "$MINGW_PREFIX/share/qemu/vgabios-virtio.bin" || true

# Re-scan the final folder in strict mode. At this point every non-Windows DLL
# must be physically present beside the QEMU binaries.
FINAL_ARGS=(
  "$SCANNER" "$OUTPUT_DIR"
  qemu-system-x86_64.exe qemu-img.exe
  --json "$OUTPUT_DIR/qemu-final-dependencies.json"
  --strict-local
)
if [[ -n "$WINDOWS_SYSTEM" && -d "$WINDOWS_SYSTEM" ]]; then
  FINAL_ARGS+=(--system-dir "$WINDOWS_SYSTEM")
fi
python3 "${FINAL_ARGS[@]}" >/dev/null

for license in COPYING COPYING.LIB LICENSE LICENSE.txt; do
  [[ -f "$QEMU_SRC/$license" ]] && cp -f "$QEMU_SRC/$license" "$OUTPUT_DIR/$license"
done

bytes="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
python3 - "$OUTPUT_DIR/qemu-minimal-build.json" "$bytes" "${MSYSTEM:-unknown}" "${ARGS[*]}" <<'PY'
import json, sys
out, size, msystem, args = sys.argv[1:]
with open(out, "w", encoding="utf-8") as f:
    json.dump({
        "bytes": int(size),
        "mib": round(int(size) / 1024 / 1024, 2),
        "msystem": msystem,
        "configureArgs": args.split(),
    }, f, indent=2)
PY

printf 'Minimal Jawal QEMU staged at %s\n' "$OUTPUT_DIR"
printf 'Payload size: %.2f MiB\n' "$(python3 -c "print($bytes/1024/1024)")"

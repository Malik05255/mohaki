#!/usr/bin/env bash
set -euo pipefail

SRC="${1:?usage: build-minimal-qemu-msys2.sh QEMU_SOURCE_DIR OUTPUT_DIR}"
OUT="${2:?usage: build-minimal-qemu-msys2.sh QEMU_SOURCE_DIR OUTPUT_DIR}"
JOBS="${JAWAL_QEMU_JOBS:-$(nproc 2>/dev/null || echo 4)}"

SRC="$(cd "$SRC" && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
BUILD="$OUT/build"
INSTALL="$OUT/runtime"
rm -rf "$BUILD" "$INSTALL"
mkdir -p "$BUILD" "$INSTALL"

[[ -x "$SRC/configure" ]] || { echo "QEMU configure script missing: $SRC/configure" >&2; exit 2; }

# Build only the x86_64 system emulator and qemu-img that Jawal executes.
# Jawal requires WHPX and deliberately has no software-emulation fallback.
required=(
  --target-list=x86_64-softmmu
  --enable-whpx
  --enable-sdl
  --enable-opengl
  --enable-slirp
  --enable-tools
)

# Optional switches are applied only when supported by the selected QEMU release.
# They remove UI/server/debug/features that Jawal never invokes.
optional=(
  --disable-tcg
  --disable-gtk
  --disable-vnc
  --disable-spice
  --disable-curses
  --disable-curl
  --disable-libssh
  --disable-guest-agent
  --disable-docs
  --disable-debug-info
  --disable-debug-tcg
  --disable-qom-cast-debug
  --disable-werror
  --disable-strip
  --disable-user
  --disable-linux-user
  --disable-bsd-user
  --disable-capstone
  --disable-fdt
  --disable-rdma
  --disable-numa
  --disable-replication
  --disable-bochs
  --disable-cloop
  --disable-dmg
  --disable-qed
  --disable-parallels
  --disable-vdi
  --disable-vvfat
)

help="$($SRC/configure --help 2>&1)"
args=()
for flag in "${required[@]}"; do
  key="${flag%%=*}"
  if ! grep -Fq -- "$key" <<<"$help"; then
    echo "Required QEMU configure option not supported: $flag" >&2
    exit 3
  fi
  args+=("$flag")
done
for flag in "${optional[@]}"; do
  key="${flag%%=*}"
  if grep -Fq -- "$key" <<<"$help"; then
    args+=("$flag")
  fi
done

pushd "$BUILD" >/dev/null
"$SRC/configure" --prefix="$INSTALL" "${args[@]}"
make -j"$JOBS"
make install
popd >/dev/null

# Keep only the executables Jawal uses. The Windows packager computes the exact
# recursive DLL closure and copies firmware/license files separately.
find "$INSTALL" -maxdepth 1 -type f -name 'qemu-system-*.exe' ! -name 'qemu-system-x86_64.exe' -delete || true
for required_file in qemu-system-x86_64.exe qemu-img.exe; do
  [[ -f "$INSTALL/$required_file" ]] || { echo "Minimal QEMU build missing $required_file" >&2; exit 4; }
done

printf 'Minimal Jawal QEMU build complete:\n  %s\n' "$INSTALL"

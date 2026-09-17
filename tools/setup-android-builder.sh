#!/usr/bin/env bash
set -euo pipefail

# Prepare a Debian/Ubuntu x86_64 machine for the BlissOS Android 15 QPR2 JawalOS
# build. This script is intentionally host-only; it does not alter Android source.
# Re-running it is safe.

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Jawal Android builder setup supports Linux only." >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) echo "Jawal Android builder must be x86_64." >&2; exit 2 ;;
esac

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This setup helper currently supports apt-based Debian/Ubuntu builders." >&2
  exit 2
fi

SUDO=()
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo "sudo is required to install build packages." >&2; exit 2; }
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive
"${SUDO[@]}" apt-get update

# BlissOS voyager-x86-qpr2 upstream dependencies, plus runtime-packaging tools
# Jawal itself needs after iso_img completes. Modern Ubuntu ncurses package names
# are used instead of the obsolete libncurses5 variants from older build docs.
packages=(
  git git-lfs gnupg flex bison gperf build-essential zip unzip curl rsync
  zlib1g-dev gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses-dev
  libncurses-dev x11proto-core-dev libx11-dev lib32z1-dev ccache libgl1-mesa-dev
  libxml2-utils xsltproc squashfs-tools python3 python3-mako libssl-dev
  ninja-build lunzip syslinux syslinux-utils gettext genisoimage bc xorriso
  xmlstarlet meson glslang-tools libelf-dev aapt zstd rdfind nasm kmod
  libarchive-tools qemu-utils e2fsprogs util-linux ca-certificates
)

# repo is packaged by supported Ubuntu releases. Keep it separate so a distro
# without the package gets a precise error instead of a partially configured host.
if apt-cache show repo >/dev/null 2>&1; then
  packages+=(repo)
fi

"${SUDO[@]}" apt-get install -y --no-install-recommends "${packages[@]}"

git lfs install --skip-repo

if ! command -v repo >/dev/null 2>&1; then
  cat >&2 <<'EOF'
The distro did not provide the Android repo launcher.
Install the official repo launcher as `repo` in PATH, then re-run this script.
EOF
  exit 3
fi

# BlissOS QPR2 explicitly requires the Rust toolchain plus these host utilities.
if ! command -v rustup >/dev/null 2>&1; then
  if [[ ! -t 0 ]]; then
    echo "rustup is missing. Install rustup for the runner user, then re-run setup." >&2
    exit 4
  fi
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi

command -v cargo >/dev/null 2>&1 || { echo "cargo is missing after rustup setup." >&2; exit 4; }
command -v rustup >/dev/null 2>&1 || { echo "rustup is missing after setup." >&2; exit 4; }

rustup default stable
rustup target add x86_64-linux-android i686-linux-android

install_cargo_tool() {
  local binary="$1" package="$2" version="${3:-}"
  if command -v "$binary" >/dev/null 2>&1; then
    printf 'PASS  %s already installed\n' "$binary"
    return 0
  fi
  if [[ -n "$version" ]]; then
    cargo install --locked --version "$version" "$package"
  else
    cargo install --locked "$package"
  fi
}

install_cargo_tool cargo-ndk cargo-ndk
install_cargo_tool bindgen bindgen-cli 0.69.1
install_cargo_tool cbindgen cbindgen

printf '\nJawal Android builder packages installed. Running strict preflight...\n'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/check-android-builder.sh"

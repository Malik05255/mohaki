#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AOSP_DIR="${JAWAL_AOSP_DIR:-$ROOT/.work/android-src}"
OUT_DIR="${JAWAL_ARTIFACTS_DIR:-$ROOT/dist/android}"
RUNTIME_DIR="${JAWAL_RUNTIME_DIR:-$ROOT/dist/runtime}"
MANIFEST_URL="https://github.com/BlissOS/platform_manifest.git"
MANIFEST_BRANCH="${JAWAL_ANDROID_BRANCH:-voyager-x86}"
BUILD_VARIANT="${JAWAL_SERVICES_VARIANT:-microg}"
BUILD_TYPE="${JAWAL_BUILD_TYPE:-userdebug}"
LUNCH_TARGET="jawal_x86_64-ap4a-${BUILD_TYPE}"

case "$BUILD_VARIANT" in
  vanilla|microg) ;;
  *) echo "JAWAL_SERVICES_VARIANT must be vanilla or microg for the open build." >&2; exit 2 ;;
esac

for tool in git repo rsync python3 curl; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 2; }
done

mkdir -p "$AOSP_DIR" "$OUT_DIR" "$RUNTIME_DIR"
cd "$AOSP_DIR"

if [[ ! -d .repo ]]; then
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs
fi

# Source is large; keep tags/history out of the working tree.
repo sync -c --force-sync --no-tags --no-clone-bundle --optimized-fetch --prune -j"${JAWAL_SYNC_JOBS:-8}"

# Overlay the Jawal product definitions into the checked-out Android tree.
rm -rf device/jawal vendor/jawal
mkdir -p device/jawal vendor/jawal
rsync -a --delete "$ROOT/android/device/jawal/" device/jawal/
rsync -a --delete "$ROOT/android/jawal-system/" vendor/jawal/jawal-system/
rsync -a --delete "$ROOT/android/store/" vendor/jawal/store/

# Fetch only the store APK used by the open flavor. It is signature-verified
# against the publisher certificate before Soong is allowed to package it.
export AOSP_DIR
"$ROOT/tools/fetch-store.sh" "$AOSP_DIR/vendor/jawal/store/AuroraStore.apk"

# Bliss' source tree supplies the optional microG product when requested.
# microG is background compatibility plumbing; Jawal does not add extra user
# applications from FOSS bundles.
export BLISS_BUILD_VARIANT="$BUILD_VARIANT"

# The runtime image is intentionally built as a phone-shaped x86_64 product.
# First engineering passes use userdebug for diagnostics. Release packaging must
# use a signed user build after all compatibility/performance gates pass.
source build/envsetup.sh
lunch "$LUNCH_TARGET"

JOBS="${JAWAL_BUILD_JOBS:-$(nproc)}"
m -j"$JOBS" iso_img

PRODUCT_OUT="${ANDROID_PRODUCT_OUT:?ANDROID_PRODUCT_OUT was not set by lunch}"
ISO="$(find "$PRODUCT_OUT" -maxdepth 1 -type f -name '*.iso' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
if [[ -z "$ISO" || ! -f "$ISO" ]]; then
  echo "Build completed but no ISO image was found in $PRODUCT_OUT" >&2
  exit 3
fi

cp -f "$ISO" "$OUT_DIR/jawal-android.iso"

# Save a machine-readable package list and size report for the validation gate.
find "$PRODUCT_OUT" -type f -printf '%s\t%p\n' | sort -nr > "$OUT_DIR/product-files.tsv"
du -b "$OUT_DIR/jawal-android.iso" > "$OUT_DIR/image-size.txt"

"$ROOT/tools/validate-product.sh" "$PRODUCT_OUT" "$OUT_DIR"

# Convert the validated ISO output immediately into the immutable-system +
# sparse-userdata layout consumed by Jawal.exe. The Windows app never presents
# the Android-x86 installer UI to the user.
rm -rf "$RUNTIME_DIR/android" "$RUNTIME_DIR/images"
"$ROOT/android/scripts/package-runtime.sh" "$OUT_DIR/jawal-android.iso" "$RUNTIME_DIR"

printf '\nJawal Android build complete:\n  ISO:     %s\n  Runtime: %s\n' \
       "$OUT_DIR/jawal-android.iso" "$RUNTIME_DIR"

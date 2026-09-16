#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AOSP_DIR="${JAWAL_AOSP_DIR:-$ROOT/.work/android-src}"
OUT_DIR="${JAWAL_ARTIFACTS_DIR:-$ROOT/dist/android}"
MANIFEST_URL="https://github.com/BlissOS/platform_manifest.git"
MANIFEST_BRANCH="${JAWAL_ANDROID_BRANCH:-voyager-x86-qpr2}"
BUILD_VARIANT="${JAWAL_SERVICES_VARIANT:-microg}"
BUILD_TYPE="${JAWAL_BUILD_TYPE:-userdebug}"
NATIVE_BRIDGE="${JAWAL_NATIVE_BRIDGE:-none}"
LUNCH_TARGET="jawal_x86_64-ap4a-${BUILD_TYPE}"

case "$BUILD_VARIANT" in
  vanilla|microg) ;;
  *) echo "JAWAL_SERVICES_VARIANT must be vanilla or microg for the open build." >&2; exit 2 ;;
esac

case "$BUILD_TYPE" in
  user|userdebug) ;;
  *) echo "JAWAL_BUILD_TYPE must be user or userdebug." >&2; exit 2 ;;
esac

case "$NATIVE_BRIDGE" in
  none|libndk) ;;
  *) echo "JAWAL_NATIVE_BRIDGE must be none or libndk." >&2; exit 2 ;;
esac

for tool in git repo rsync python3 curl; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 2; }
done

mkdir -p "$AOSP_DIR" "$OUT_DIR"
cd "$AOSP_DIR"

if [[ ! -d .repo ]]; then
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs
else
  current_manifest="$(git -C .repo/manifests rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$current_manifest" != "$MANIFEST_BRANCH" ]]; then
    repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs
  fi
fi

repo sync -c --force-sync --no-tags --no-clone-bundle --optimized-fetch --prune -j"${JAWAL_SYNC_JOBS:-8}"

rm -rf device/jawal vendor/jawal
mkdir -p device/jawal vendor/jawal
rsync -a --delete "$ROOT/android/device/jawal/" device/jawal/
rsync -a --delete "$ROOT/android/jawal-system/" vendor/jawal/jawal-system/
rsync -a --delete "$ROOT/android/store/" vendor/jawal/store/
rsync -a --delete "$ROOT/android/smoke-app/" vendor/jawal/smoke-app/

export AOSP_DIR
"$ROOT/tools/fetch-store.sh" "$AOSP_DIR/vendor/jawal/store/AuroraStore.apk"

export BLISS_BUILD_VARIANT="$BUILD_VARIANT"

unset USE_LIBNDK_TRANSLATION_NB
if [[ "$NATIVE_BRIDGE" == "libndk" ]]; then
  bridge_mk="vendor/google/emu-x86/target/libndk_translation.mk"
  if [[ ! -f "$bridge_mk" ]]; then
    echo "JAWAL_NATIVE_BRIDGE=libndk requested, but $bridge_mk is missing." >&2
    echo "Provide the native-bridge vendor tree separately; Jawal does not redistribute proprietary/native-bridge blobs." >&2
    exit 4
  fi
  export USE_LIBNDK_TRANSLATION_NB=true
fi

source build/envsetup.sh
lunch "$LUNCH_TARGET"

JOBS="${JAWAL_BUILD_JOBS:-$(nproc)}"
m -j"$JOBS" iso_img JawalSmokeApp

PRODUCT_OUT="${ANDROID_PRODUCT_OUT:?ANDROID_PRODUCT_OUT was not set by lunch}"
ISO="$(find "$PRODUCT_OUT" -maxdepth 1 -type f -name '*.iso' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
if [[ -z "$ISO" || ! -f "$ISO" ]]; then
  echo "Build completed but no ISO image was found in $PRODUCT_OUT" >&2
  exit 3
fi

cp -f "$ISO" "$OUT_DIR/jawal-android.iso"

SMOKE_APK="$(find "$PRODUCT_OUT" -type f -name 'JawalSmokeApp.apk' -print -quit || true)"
if [[ -z "$SMOKE_APK" || ! -f "$SMOKE_APK" ]]; then
  echo "JawalSmokeApp.apk was not produced by the Android build." >&2
  exit 5
fi
cp -f "$SMOKE_APK" "$OUT_DIR/JawalSmokeApp.apk"

chmod +x "$ROOT/tools/build-arm64-smoke.sh"
"$ROOT/tools/build-arm64-smoke.sh" "$OUT_DIR/JawalArm64Smoke.apk"

find "$PRODUCT_OUT" -type f -printf '%s\t%p\n' | sort -nr > "$OUT_DIR/product-files.tsv"
du -b "$OUT_DIR/jawal-android.iso" > "$OUT_DIR/image-size.txt"

# Produce measured category/largest-file evidence for the next pruning pass.
python3 "$ROOT/tools/analyze-jawalos-size.py" \
  "$OUT_DIR/product-files.tsv" \
  --output "$OUT_DIR/size-analysis.json" \
  --markdown "$OUT_DIR/size-analysis.md"

{
  printf 'android_branch=%s\n' "$MANIFEST_BRANCH"
  printf 'services_variant=%s\n' "$BUILD_VARIANT"
  printf 'build_type=%s\n' "$BUILD_TYPE"
  printf 'native_bridge=%s\n' "$NATIVE_BRIDGE"
  printf 'lunch_target=%s\n' "$LUNCH_TARGET"
} > "$OUT_DIR/build-metadata.txt"

"$ROOT/tools/validate-product.sh" "$PRODUCT_OUT" "$OUT_DIR"

printf '\nJawal Android build complete:\n  %s\n  %s\n  %s\n  %s\n' \
  "$OUT_DIR/jawal-android.iso" \
  "$OUT_DIR/JawalSmokeApp.apk" \
  "$OUT_DIR/JawalArm64Smoke.apk" \
  "$OUT_DIR/size-analysis.md"

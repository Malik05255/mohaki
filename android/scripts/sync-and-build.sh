#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AOSP_DIR="${JAWAL_AOSP_DIR:-$ROOT/.work/android-src}"
OUT_DIR="${JAWAL_ARTIFACTS_DIR:-$ROOT/dist/android}"
MANIFEST_URL="https://github.com/BlissOS/platform_manifest.git"
MANIFEST_BRANCH="${JAWAL_ANDROID_BRANCH:-voyager-x86-qpr2}"
BUILD_VARIANT="${JAWAL_SERVICES_VARIANT:-microg}"
BUILD_TYPE="${JAWAL_BUILD_TYPE:-user}"
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

# These projects exist only to support arbitrary physical PCs. Jawal's fixed
# QEMU/WHPX machine uses virtio devices plus emulated HDA/xHCI and needs none of
# their firmware or Intel physical-GPU VA/OMX stack. Excluding them before repo
# sync saves builder disk/network; FFmpeg/MediaCodec/Codec2 remain in-tree.
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/jawal-minimal-physical-hardware.xml <<'XML'
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
rm -f .repo/local_manifests/jawal-minimal-firmware.xml

repo sync -c --force-sync --no-tags --no-clone-bundle --optimized-fetch --prune -j"${JAWAL_SYNC_JOBS:-8}"

rm -rf device/jawal vendor/jawal
mkdir -p device/jawal vendor/jawal
rsync -a --delete "$ROOT/android/device/jawal/" device/jawal/
rsync -a --delete "$ROOT/android/jawal-system/" vendor/jawal/jawal-system/
rsync -a --delete "$ROOT/android/store/" vendor/jawal/store/
rsync -a --delete "$ROOT/android/smoke-app/" vendor/jawal/smoke-app/

# The synced Android-x86 device tree targets arbitrary physical PCs. Apply only
# exact, guarded edits that remove hardware Jawal's fixed QEMU/WHPX machine can
# never expose. The patcher fails closed when upstream source changes.
python3 "$ROOT/tools/apply-jawal-upstream-pruning.py" "$AOSP_DIR"

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

python3 "$ROOT/tools/analyze-jawalos-size.py" \
  "$OUT_DIR/product-files.tsv" \
  --output "$OUT_DIR/size-analysis.json" \
  --markdown "$OUT_DIR/size-analysis.md" \
  --plan "$OUT_DIR/pruning-plan.md"

{
  printf 'android_branch=%s\n' "$MANIFEST_BRANCH"
  printf 'services_variant=%s\n' "$BUILD_VARIANT"
  printf 'build_type=%s\n' "$BUILD_TYPE"
  printf 'native_bridge=%s\n' "$NATIVE_BRIDGE"
  printf 'lunch_target=%s\n' "$LUNCH_TARGET"
  printf 'kernel_diffconfig=%s\n' 'device/jawal/jawal-kernel-minimal.config'
  printf 'physical_firmware_projects=%s\n' 'excluded-before-sync'
  printf 'intel_physical_media_projects=%s\n' 'excluded-before-sync'
} > "$OUT_DIR/build-metadata.txt"

"$ROOT/tools/validate-product.sh" "$PRODUCT_OUT" "$OUT_DIR"
bash "$ROOT/tools/validate-hardware-pruning.sh" "$PRODUCT_OUT" "$OUT_DIR"
bash "$ROOT/tools/validate-kernel-profile.sh" "$PRODUCT_OUT" "$OUT_DIR"
{
  printf '\n===== Fixed-VM hardware pruning =====\n'
  cat "$OUT_DIR/hardware-pruning.txt"
  printf '\n===== Minimal kernel/firmware profile =====\n'
  cat "$OUT_DIR/kernel-profile.txt"
} >> "$OUT_DIR/validation.txt"

printf '\nJawal Android build complete:\n  %s\n  %s\n  %s\n  %s\n  %s\n  %s\n' \
  "$OUT_DIR/jawal-android.iso" \
  "$OUT_DIR/JawalSmokeApp.apk" \
  "$OUT_DIR/JawalArm64Smoke.apk" \
  "$OUT_DIR/size-analysis.md" \
  "$OUT_DIR/pruning-plan.md" \
  "$OUT_DIR/kernel-profile.txt"

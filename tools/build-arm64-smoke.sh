#!/usr/bin/env bash
set -euo pipefail

OUT_APK="${1:?usage: build-arm64-smoke.sh OUTPUT_APK}"
: "${ANDROID_BUILD_TOP:?Run after source build/envsetup.sh + lunch}"
: "${ANDROID_HOST_OUT:?ANDROID_HOST_OUT is required}"

for tool in zip find sort; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done

AAPT2="$ANDROID_HOST_OUT/bin/aapt2"
APKSIGNER="$ANDROID_HOST_OUT/bin/apksigner"
CLANG="$(find "$ANDROID_BUILD_TOP/prebuilts/clang/host/linux-x86" -type f -path '*/bin/clang' | sort | tail -n1)"
ANDROID_JAR="$(find "$ANDROID_BUILD_TOP/prebuilts/sdk" -type f -path '*/public/android.jar' | sort -V | tail -n1)"
KEY="$ANDROID_BUILD_TOP/build/make/target/product/security/testkey.pk8"
CERT="$ANDROID_BUILD_TOP/build/make/target/product/security/testkey.x509.pem"

for file in "$AAPT2" "$APKSIGNER" "$CLANG" "$ANDROID_JAR" "$KEY" "$CERT"; do
  [[ -f "$file" ]] || { echo "ARM64 smoke dependency missing: $file" >&2; exit 3; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lib/arm64-v8a" "$(dirname "$OUT_APK")"

cat > "$work/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.jawal.arm64smoke">
    <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="35" />
    <application android:hasCode="false" android:label="Jawal ARM64 Smoke" />
</manifest>
EOF

cat > "$work/probe.c" <<'EOF'
__attribute__((visibility("default"))) int jawal_arm64_probe(void) { return 42; }
EOF

"$CLANG" \
  --target=aarch64-linux-android35 \
  -shared -fPIC -nostdlib \
  -Wl,-soname,libjawalarm64smoke.so \
  -o "$work/lib/arm64-v8a/libjawalarm64smoke.so" \
  "$work/probe.c"

"$AAPT2" link \
  -I "$ANDROID_JAR" \
  --manifest "$work/AndroidManifest.xml" \
  -o "$work/unsigned.apk"

(
  cd "$work"
  zip -q -r unsigned.apk lib/arm64-v8a/libjawalarm64smoke.so
)

"$APKSIGNER" sign \
  --key "$KEY" \
  --cert "$CERT" \
  --out "$OUT_APK" \
  "$work/unsigned.apk"

"$APKSIGNER" verify --verbose "$OUT_APK"

echo "Built ARM64-only smoke APK: $OUT_APK"

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
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        android:allowBackup="false"
        android:extractNativeLibs="true"
        android:hasCode="false"
        android:label="Jawal ARM64 Smoke">
        <activity
            android:name="android.app.NativeActivity"
            android:exported="true"
            android:screenOrientation="portrait">
            <meta-data android:name="android.app.lib_name" android:value="jawalarm64smoke" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

cat > "$work/probe.c" <<'EOF'
#include <android/native_activity.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define JAWAL_ARM64_MAGIC 0x4A415236u
#define JAWAL_ARM64_PORT 27187

static void report_result(int result) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(JAWAL_ARM64_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr*)&address, sizeof(address)) == 0) {
        uint32_t payload[2];
        payload[0] = htonl(JAWAL_ARM64_MAGIC);
        payload[1] = htonl((uint32_t)result);
        (void)send(fd, payload, sizeof(payload), 0);
    }
    close(fd);
}

__attribute__((visibility("default")))
void ANativeActivity_onCreate(ANativeActivity* activity, void* saved_state, size_t saved_state_size) {
    (void)saved_state;
    (void)saved_state_size;
    report_result(42);
    ANativeActivity_finish(activity);
}
EOF

"$CLANG" \
  --target=aarch64-linux-android23 \
  -shared -fPIC \
  -Wl,-soname,libjawalarm64smoke.so \
  -Wl,--no-undefined \
  -o "$work/lib/arm64-v8a/libjawalarm64smoke.so" \
  "$work/probe.c" \
  -landroid

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

echo "Built executable ARM64-only NativeActivity smoke APK: $OUT_APK"

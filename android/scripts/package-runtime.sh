#!/usr/bin/env bash
set -euo pipefail

ISO="${1:?usage: package-runtime.sh JAWAL_ANDROID_ISO OUTPUT_RUNTIME_DIR}"
RUNTIME="${2:?usage: package-runtime.sh JAWAL_ANDROID_ISO OUTPUT_RUNTIME_DIR}"
DATA_GIB="${JAWAL_DATA_GIB:-128}"

for tool in bsdtar qemu-img mkfs.ext4 mount umount truncate; do
  command -v "$tool" >/dev/null || { echo "Missing packaging tool: $tool" >&2; exit 2; }
done

ROOTCMD=()
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null || { echo "Root or sudo is required to build ext4 runtime images." >&2; exit 2; }
  ROOTCMD=(sudo)
fi

work="$(mktemp -d)"
cleanup() {
  set +e
  if mountpoint -q "$work/system-mnt"; then "${ROOTCMD[@]}" umount "$work/system-mnt"; fi
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/iso" "$work/system-mnt" "$RUNTIME/android" "$RUNTIME/images"
bsdtar -xf "$ISO" -C "$work/iso"

find_one() {
  local name="$1"
  find "$work/iso" -type f -name "$name" -print -quit
}

kernel="$(find_one kernel)"
initrd="$(find_one initrd.img)"
ramdisk="$(find_one ramdisk.img || true)"
system_payload="$(find_one system.sfs || true)"
[[ -n "$system_payload" ]] || system_payload="$(find_one system.img || true)"

[[ -f "$kernel" ]] || { echo "kernel missing from Android image" >&2; exit 3; }
[[ -f "$initrd" ]] || { echo "initrd.img missing from Android image" >&2; exit 3; }
[[ -f "$system_payload" ]] || { echo "system.sfs/system.img missing from Android image" >&2; exit 3; }

cp -f "$kernel" "$RUNTIME/android/kernel"
cp -f "$initrd" "$RUNTIME/android/initrd.img"

# Source disk contains only immutable Android boot/system payload. Give it a
# measured margin instead of a multi-gigabyte arbitrary fixed allocation.
payload_bytes="$(stat -c '%s' "$system_payload")"
[[ -z "$ramdisk" ]] || payload_bytes=$((payload_bytes + $(stat -c '%s' "$ramdisk")))
margin_bytes=$((256 * 1024 * 1024))
system_mib=$(( (payload_bytes + margin_bytes + 1048575) / 1048576 ))
truncate -s "${system_mib}M" "$work/system.raw"
mkfs.ext4 -q -F -L JAWALSYSTEM -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$work/system.raw"
"${ROOTCMD[@]}" mount -o loop "$work/system.raw" "$work/system-mnt"
"${ROOTCMD[@]}" mkdir -p "$work/system-mnt/AndroidOS"
"${ROOTCMD[@]}" cp -f "$system_payload" "$work/system-mnt/AndroidOS/$(basename "$system_payload")"
if [[ -n "$ramdisk" && -f "$ramdisk" ]]; then
  "${ROOTCMD[@]}" cp -f "$ramdisk" "$work/system-mnt/AndroidOS/ramdisk.img"
fi
"${ROOTCMD[@]}" touch "$work/system-mnt/AndroidOS/android.boot"
sync
"${ROOTCMD[@]}" umount "$work/system-mnt"

qemu-img convert -c -p -f raw -O qcow2 "$work/system.raw" "$RUNTIME/images/jawal-system.qcow2"

# Empty ext4 data template. The apparent capacity is intentionally phone-like
# (128 GiB by default), but qcow2 stores only allocated blocks. A clean install
# therefore stays tiny and grows only as the user installs apps and stores data.
truncate -s "${DATA_GIB}G" "$work/data.raw"
mkfs.ext4 -q -F -L JAWALDATA -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$work/data.raw"
qemu-img convert -c -p -f raw -O qcow2 "$work/data.raw" "$RUNTIME/images/jawal-data-template.qcow2"

(
  cd "$RUNTIME"
  sha256sum android/kernel android/initrd.img images/jawal-system.qcow2 images/jawal-data-template.qcow2 > runtime.sha256
)

printf 'Jawal Android runtime packaged (data capacity: %s GiB):\n' "$DATA_GIB"
du -h "$RUNTIME/android/kernel" "$RUNTIME/android/initrd.img" \
      "$RUNTIME/images/jawal-system.qcow2" "$RUNTIME/images/jawal-data-template.qcow2"

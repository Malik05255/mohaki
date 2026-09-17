#!/usr/bin/env bash
set -euo pipefail

ISO="${1:?usage: package-runtime.sh JAWAL_ANDROID_ISO OUTPUT_RUNTIME_DIR}"
RUNTIME="${2:?usage: package-runtime.sh JAWAL_ANDROID_ISO OUTPUT_RUNTIME_DIR}"
DATA_GIB="${JAWAL_DATA_GIB:-128}"
SOURCE_REPORT_DIR="$(cd "$(dirname "$ISO")" && pwd)"

for tool in bsdtar qemu-img mkfs.ext4 mount umount mountpoint truncate python3; do
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

mkdir -p "$work/iso" "$work/system-mnt" "$RUNTIME/android" "$RUNTIME/images" "$RUNTIME/reports"
bsdtar -xf "$ISO" -C "$work/iso"

find_one() {
  local name="$1"
  find "$work/iso" -type f -name "$name" -print -quit
}

kernel="$(find_one kernel)"
initrd="$(find_one initrd.img)"
ramdisk="$(find_one ramdisk.img || true)"
# BlissOS voyager-x86-qpr2 uses EROFS and names the compressed Android system
# payload system.efs. Older/fallback Android-x86 builds may still emit sfs/img.
system_payload="$(find_one system.efs || true)"
[[ -n "$system_payload" ]] || system_payload="$(find_one system.sfs || true)"
[[ -n "$system_payload" ]] || system_payload="$(find_one system.img || true)"

[[ -f "$kernel" ]] || { echo "kernel missing from Android image" >&2; exit 3; }
[[ -f "$initrd" ]] || { echo "initrd.img missing from Android image" >&2; exit 3; }
[[ -f "$system_payload" ]] || { echo "system.efs/system.sfs/system.img missing from Android image" >&2; exit 3; }

cp -f "$kernel" "$RUNTIME/android/kernel"
cp -f "$initrd" "$RUNTIME/android/initrd.img"

# Preserve measured Android-build evidence with the runtime artifact. This makes
# the next pruning pass deterministic instead of relying on stale CI logs.
for report in \
  validation.txt \
  largest-files.tsv \
  product-files.tsv \
  size-analysis.json \
  size-analysis.md \
  pruning-plan.md \
  build-metadata.txt \
  image-size.txt \
  hardware-pruning.txt \
  kernel-profile.txt \
  kernel-modules.tsv; do
  if [[ -f "$SOURCE_REPORT_DIR/$report" ]]; then
    cp -f "$SOURCE_REPORT_DIR/$report" "$RUNTIME/reports/$report"
  fi
done

# The immutable system disk only contains Android's already-compressed EROFS,
# SquashFS or fallback system image plus optional ramdisk. It is always attached
# read-only by Jawal, so an ext4 journal provides no recovery value. Omitting it
# saves metadata and boot I/O without changing Android APIs/codecs/app behavior.
payload_bytes="$(stat -c '%s' "$system_payload")"
[[ -z "$ramdisk" ]] || payload_bytes=$((payload_bytes + $(stat -c '%s' "$ramdisk")))
margin_bytes=$((128 * 1024 * 1024))
system_mib=$(( (payload_bytes + margin_bytes + 1048575) / 1048576 ))
truncate -s "${system_mib}M" "$work/system.raw"
mkfs.ext4 -q -F -L JAWALSYSTEM -m 0 -O ^has_journal \
  -E lazy_itable_init=1 "$work/system.raw"
"${ROOTCMD[@]}" mount -o loop "$work/system.raw" "$work/system-mnt"
"${ROOTCMD[@]}" mkdir -p "$work/system-mnt/AndroidOS"
"${ROOTCMD[@]}" cp -f "$system_payload" "$work/system-mnt/AndroidOS/$(basename "$system_payload")"
if [[ -n "$ramdisk" && -f "$ramdisk" ]]; then
  "${ROOTCMD[@]}" cp -f "$ramdisk" "$work/system-mnt/AndroidOS/ramdisk.img"
fi
"${ROOTCMD[@]}" touch "$work/system-mnt/AndroidOS/android.boot"
sync
"${ROOTCMD[@]}" umount "$work/system-mnt"

# Do not double-compress the read-only system disk. system.efs/system.sfs is
# already compressed; QCOW2 cluster compression adds CPU work for little gain.
qemu-img convert -p -S 4k -f raw -O qcow2 \
  "$work/system.raw" "$RUNTIME/images/jawal-system.qcow2"

# Empty ext4 data template. The apparent capacity is intentionally phone-like
# (128 GiB by default), but qcow2 stores only allocated blocks. Keep journaling on
# user data for crash resilience. Compressing this one-time empty template only
# affects its tiny initial metadata; normal future guest writes are not converted.
truncate -s "${DATA_GIB}G" "$work/data.raw"
mkfs.ext4 -q -F -L JAWALDATA -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$work/data.raw"
qemu-img convert -c -p -f raw -O qcow2 "$work/data.raw" "$RUNTIME/images/jawal-data-template.qcow2"

(
  cd "$RUNTIME"
  sha256sum android/kernel android/initrd.img images/jawal-system.qcow2 images/jawal-data-template.qcow2 > runtime.sha256
)

payload_size="$(stat -c '%s' "$system_payload")"
system_qcow_size="$(stat -c '%s' "$RUNTIME/images/jawal-system.qcow2")"
data_qcow_size="$(stat -c '%s' "$RUNTIME/images/jawal-data-template.qcow2")"
kernel_size="$(stat -c '%s' "$RUNTIME/android/kernel")"
initrd_size="$(stat -c '%s' "$RUNTIME/android/initrd.img")"
payload_name="$(basename "$system_payload")"
python3 - "$RUNTIME/reports/android-runtime-size.json" \
  "$payload_size" "$system_qcow_size" "$data_qcow_size" "$kernel_size" "$initrd_size" "$DATA_GIB" "$payload_name" <<'PY'
import json, sys
out, payload, system_qcow, data_qcow, kernel, initrd, data_gib, payload_name = sys.argv[1:]
values = {
    "systemPayloadName": payload_name,
    "systemPayloadBytes": int(payload),
    "systemQcow2Bytes": int(system_qcow),
    "dataTemplateQcow2Bytes": int(data_qcow),
    "kernelBytes": int(kernel),
    "initrdBytes": int(initrd),
    "apparentDataGiB": int(data_gib),
    "systemExt4Journal": False,
    "systemQcow2Compression": False,
    "dataTemplateQcow2Compression": True,
}
values["initialRuntimeBytes"] = values["systemQcow2Bytes"] + values["dataTemplateQcow2Bytes"] + values["kernelBytes"] + values["initrdBytes"]
with open(out, "w", encoding="utf-8") as f:
    json.dump(values, f, indent=2)
PY

printf 'Jawal Android runtime packaged (payload: %s, data capacity: %s GiB):\n' "$payload_name" "$DATA_GIB"
du -h "$RUNTIME/android/kernel" "$RUNTIME/android/initrd.img" \
      "$RUNTIME/images/jawal-system.qcow2" "$RUNTIME/images/jawal-data-template.qcow2"
printf 'Runtime size report: %s\n' "$RUNTIME/reports/android-runtime-size.json"

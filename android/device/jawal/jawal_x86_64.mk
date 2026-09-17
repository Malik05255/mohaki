# Jawal production-oriented Android x86_64 product.
# The upstream PC device layer comes from Android-Generic/BlissOS, while the
# visible product remains a minimal Android phone runtime.

# Disable entire Goldfish/emulator hardware families before the upstream x86
# product inherits them. This is smaller and safer than building their HALs,
# init scripts and manifests and trying to delete the output afterward.
TARGET_FACE_UNLOCK_SUPPORTED := false
EMULATOR_DISABLE_RADIO := true
EMULATOR_VENDOR_NO_BIOMETRICS := true
EMULATOR_VENDOR_NO_THREADNETWORK := true
EMULATOR_VENDOR_NO_UWB := true
EMULATOR_VENDOR_NO_GNSS := true
EMULATOR_VENDOR_NO_SENSORS := true
EMULATOR_VENDOR_NO_CAMERA := true
EMULATOR_VENDOR_NO_REBOOT_ESCROW := true

$(call inherit-product, device/generic/common/x86_64.mk)

# Strip inherited Android/Bliss user apps, PC-distribution utilities and fixed-
# VM hardware helpers only after the upstream x86 device layer declares them.
$(call inherit-product, device/jawal/prune.mk)
$(call inherit-product, device/jawal/prune-hardware.mk)
$(call inherit-product, device/jawal/prune-copyfiles.mk)

PRODUCT_NAME := jawal_x86_64
PRODUCT_DEVICE := x86_64
PRODUCT_BRAND := Jawal
PRODUCT_MODEL := Jawal Virtual Phone
PRODUCT_MANUFACTURER := Jawal

# Shipping only the primary UX languages avoids a large locale/resource
# footprint. Framework/font pieces needed for application rendering remain.
PRODUCT_LOCALES := ar_SA en_US

# Compress pre-installed APEX payloads. This is a packaging/storage optimization
# supported by modern Android; it does not remove APIs or runtime functionality.
# Keep it enabled for the production-oriented Jawal image so system size is not
# wasted on uncompressed modular system payloads.
PRODUCT_COMPRESSED_APEX := true

PRODUCT_SYSTEM_PROPERTIES += \
    ro.jawal.runtime=true \
    ro.jawal.form_factor=virtual_phone \
    debug.sf.nobootanimation=1

# System integration + the only bundled consumer-facing app.
# Launcher/SystemUI/Settings remain because they are part of the operating
# environment, not bundled content applications.
PRODUCT_PACKAGES += \
    JawalSystemBridge \
    JawalStore

# No proprietary GMS/Google Play or proprietary ARM native-bridge blobs are
# committed here. Licensed product overlays can add them separately.

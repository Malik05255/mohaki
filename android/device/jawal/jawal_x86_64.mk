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

# The Android-x86 QPR2 manifest still syncs Bliss' vendor/microg tree, but the
# x86-specific vendor/bliss overlay does not currently inherit it from
# BLISS_BUILD_VARIANT. Make Jawal's service contract explicit so a requested
# microG image cannot silently become vanilla when upstream product wiring
# changes. sync-and-build.sh validates this file before Soong starts, and the
# post-build gate proves GmsCore/FakeStore actually reached PRODUCT_OUT.
ifeq ($(JAWAL_SERVICES_VARIANT),microg)
$(call inherit-product, vendor/microg/products/gms.mk)
endif

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
# device/generic/common declares `tablet`; Jawal deliberately overrides that
# inherited PC/tablet classification after all common product inheritance.
PRODUCT_CHARACTERISTICS := phone

# The upstream PC product prefers mdpi/hdpi resources. Jawal boots at 420 dpi,
# close to Android's xxhdpi bucket, so retain phone-quality density assets and
# prefer xxhdpi instead of upscaling low-density system artwork. Default/vector
# resources remain available through normal AAPT fallback behavior.
PRODUCT_AAPT_CONFIG := normal large xlarge mdpi hdpi xhdpi xxhdpi
PRODUCT_AAPT_PREF_CONFIG := xxhdpi

# Shipping only the primary UX languages avoids a large locale/resource
# footprint. Framework/font pieces needed for application rendering remain.
PRODUCT_LOCALES := ar_SA en_US

# Keep APEX uncompressed at the Android layer. Compressed APEX can make the
# immutable system image look smaller while requiring decompression/caching on
# user data during boot. Jawal optimizes true installed/runtime size by removing
# unused modules instead of trading boot latency and writable-data growth for an
# artificially smaller system artifact.
PRODUCT_COMPRESSED_APEX := false

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

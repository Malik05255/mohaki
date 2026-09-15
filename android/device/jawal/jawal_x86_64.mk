# Jawal production-oriented AOSP product.
# Base target intentionally stays close to AOSP x86_64 for framework compatibility.

$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_x86_64.mk)

PRODUCT_NAME := jawal_x86_64
PRODUCT_DEVICE := generic_x86_64
PRODUCT_BRAND := Jawal
PRODUCT_MODEL := Jawal Virtual Phone
PRODUCT_MANUFACTURER := Jawal

PRODUCT_LOCALES := ar_SA en_US

# Jawal runtime identity and conservative production defaults.
PRODUCT_SYSTEM_PROPERTIES += \
    ro.jawal.runtime=true \
    ro.jawal.form_factor=virtual_phone

# Remove stock applications that add size/background work but are not part of
# the Jawal experience. Compatibility-critical framework components are kept.
PRODUCT_PACKAGES -= \
    BasicDreams \
    Calendar \
    Camera2 \
    Contacts \
    DeskClock \
    Dialer \
    EasterEgg \
    Email \
    Gallery2 \
    LiveWallpapersPicker \
    Messaging \
    Music \
    PhotoTable \
    PrintSpooler \
    QuickSearchBox \
    Stk

# Jawal host integration service is added after its Android module exists.
# PRODUCT_PACKAGES += JawalSystemService

# No proprietary GMS/Play or ARM native-bridge blobs are committed here.
# Those belong in separately licensed product overlays.

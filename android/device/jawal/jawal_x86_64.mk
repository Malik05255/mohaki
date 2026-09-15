# Jawal production-oriented Android x86_64 product.
# The upstream PC device layer comes from Android-Generic/BlissOS, while the
# visible product remains a minimal Android phone runtime.

$(call inherit-product, device/generic/common/x86_64.mk)

PRODUCT_NAME := jawal_x86_64
PRODUCT_DEVICE := x86_64
PRODUCT_BRAND := Jawal
PRODUCT_MODEL := Jawal Virtual Phone
PRODUCT_MANUFACTURER := Jawal

# Shipping only the primary UX languages avoids a large locale/font/resource
# footprint. More languages can be added without changing the runtime design.
PRODUCT_LOCALES := ar_SA en_US

PRODUCT_SYSTEM_PROPERTIES += \
    ro.jawal.runtime=true \
    ro.jawal.form_factor=virtual_phone

# System integration + the only bundled consumer-facing app.
# Launcher/SystemUI/Settings remain because they are part of the operating
# environment, not bundled content applications.
PRODUCT_PACKAGES += \
    JawalSystemBridge \
    JawalStore

# No proprietary GMS/Google Play or proprietary ARM native-bridge blobs are
# committed here. Licensed product overlays can add them separately.

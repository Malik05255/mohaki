# Additional fixed-VM hardware pruning for JawalOS.
# Keep performance/security/media/networking HALs unless measured tests prove
# they are unnecessary. This file targets only host hardware Jawal v1 does not expose.

JAWAL_REMOVE_HARDWARE_PACKAGES := \
    android.hardware.usb-service.example \
    com.android.hardware.contexthub \
    com.android.hardware.dumpstate \
    android.hardware.lights-service.example \
    com.android.hardware.vibrator \
    android.hardware.identity-service.example \
    bt_vhci_forwarder \
    mac80211_create_radios \
    SdkSetup \
    atrace \
    bugreport \
    bugreportz \
    dumpstate \
    incident \
    incidentd \
    perfetto_cmd \
    traced \
    traced_probes

# Intentionally retained despite size:
# - android.hardware.drm-service-lazy.clearkey: media/DRM compatibility
# - keymint/gatekeeper/auth security services
# - health/power/thermal: runtime stability and scheduling behavior
# - neuralnetworks: NNAPI compatibility
# - graphics/audio/media C2 services and codecs
# - netd/NetworkStack/DnsResolver and virtio networking path
PRODUCT_PACKAGES := $(filter-out $(JAWAL_REMOVE_HARDWARE_PACKAGES),$(PRODUCT_PACKAGES))
PRODUCT_PACKAGES_DEBUG := $(filter-out $(JAWAL_REMOVE_HARDWARE_PACKAGES),$(PRODUCT_PACKAGES_DEBUG))

# PRODUCT_COPY_FILES cleanup is finalized in prune-copyfiles.mk after this file.
# Keeping all copy-file filtering in one place avoids fragile GNU make wildcard
# behavior and makes the final image policy auditable.

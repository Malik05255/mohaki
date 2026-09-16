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
    atrace

PRODUCT_PACKAGES := $(filter-out $(JAWAL_REMOVE_HARDWARE_PACKAGES),$(PRODUCT_PACKAGES))
PRODUCT_PACKAGES_DEBUG := $(filter-out $(JAWAL_REMOVE_HARDWARE_PACKAGES),$(PRODUCT_PACKAGES_DEBUG))

# Bluetooth hardware/audio policy is meaningless when the Bluetooth HAL and
# radio are absent. Internet still uses virtio-net and the Android NetworkStack.
PRODUCT_COPY_FILES := $(filter-out \
    %/bluetooth_audio_policy_configuration%.xml:% \
    %/android.hardware.usb.host.xml:% \
    %/android.hardware.usb.accessory.xml:%,$(PRODUCT_COPY_FILES))

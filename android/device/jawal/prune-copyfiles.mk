# Deterministic PRODUCT_COPY_FILES pruning.
# GNU make pattern matching is easy to get wrong when source:destination words
# contain more than one wildcard-like segment. Match each complete copy-file word
# by substring instead, remove it, then add back the tiny Jawal defaults.

define jawal_drop_copy_containing
PRODUCT_COPY_FILES := $(filter-out $(foreach f,$(PRODUCT_COPY_FILES),$(if $(findstring $(1),$(f)),$(f))),$(PRODUCT_COPY_FILES))
endef

# Stock device capability profiles and unsupported physical hardware declarations.
$(eval $(call jawal_drop_copy_containing,handheld_core_hardware.xml))
$(eval $(call jawal_drop_copy_containing,tablet_core_hardware.xml))
$(eval $(call jawal_drop_copy_containing,android.hardware.camera))
$(eval $(call jawal_drop_copy_containing,android.hardware.nfc))
$(eval $(call jawal_drop_copy_containing,android.hardware.uwb))
$(eval $(call jawal_drop_copy_containing,android.hardware.bluetooth))
$(eval $(call jawal_drop_copy_containing,android.hardware.wifi))
$(eval $(call jawal_drop_copy_containing,android.hardware.telephony))
$(eval $(call jawal_drop_copy_containing,bluetooth_audio_policy_configuration))
$(eval $(call jawal_drop_copy_containing,android.hardware.usb.host.xml))
$(eval $(call jawal_drop_copy_containing,android.hardware.usb.accessory.xml))

# Jawal owns the visible boot experience on Windows. Android's stock/custom boot
# animation archives are redundant once debug.sf.nobootanimation=1 is set.
# Keep the tiny bootanimation binary for service compatibility until the first
# full production build proves it can also be removed safely.
$(eval $(call jawal_drop_copy_containing,bootanimation.zip))

# Remove the large stock ringtone/alarm/notification catalogue. This does not
# remove AudioFlinger, Audio HALs, MediaCodec or any playback/recording codec.
$(eval $(call jawal_drop_copy_containing,/media/audio/alarms/))
$(eval $(call jawal_drop_copy_containing,/media/audio/notifications/))
$(eval $(call jawal_drop_copy_containing,/media/audio/ringtones/))

# Re-add the truthful Jawal hardware contract and a tiny default sound set.
PRODUCT_COPY_FILES += \
    device/jawal/jawal_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/jawal_core_hardware.xml \
    frameworks/base/data/sounds/Alarm_Classic.ogg:$(TARGET_COPY_OUT_PRODUCT)/media/audio/alarms/Alarm_Classic.ogg \
    frameworks/base/data/sounds/notifications/pixiedust.ogg:$(TARGET_COPY_OUT_PRODUCT)/media/audio/notifications/pixiedust.ogg \
    frameworks/base/data/sounds/newwavelabs/OnTheHunt.ogg:$(TARGET_COPY_OUT_PRODUCT)/media/audio/notifications/OnTheHunt.ogg \
    frameworks/base/data/sounds/Ring_Synth_04.ogg:$(TARGET_COPY_OUT_PRODUCT)/media/audio/ringtones/Ring_Synth_04.ogg

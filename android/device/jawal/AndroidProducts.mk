PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/jawal_x86_64.mk

# voyager-x86 tracks Android 15/AP4A. Keep production and test variants explicit.
COMMON_LUNCH_CHOICES := \
    jawal_x86_64-ap4a-user \
    jawal_x86_64-ap4a-userdebug

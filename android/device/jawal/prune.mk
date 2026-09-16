# Jawal is a virtual Android phone runtime, not a general-purpose PC distro.
# Prune only components that provide no useful function inside Jawal's fixed
# QEMU/WHPX machine. Compatibility-critical Android framework/media/networking
# pieces are intentionally kept and validated after every production build.

JAWAL_REMOVE_PACKAGES := \
    7z \
    AccessibilityMenu \
    Aperture \
    AvatarPicker \
    BasicDreams \
    BlissUpdater \
    BOSWallpapers \
    Browser2 \
    BuiltInPrintService \
    Calendar \
    Camera2 \
    Contacts \
    CubeLiveWallpapers \
    Datura \
    DeskClock \
    DesktopMode \
    Dialer \
    EasterEgg \
    Email \
    Etar \
    ExactCalculator \
    Exchange2 \
    FaceUnlockService \
    Gallery2 \
    GameSpace \
    Glimpse \
    Jelly \
    LiveWallpapers \
    LiveWallpapersPicker \
    LMOFreeform \
    LMOFreeformSidebar \
    messaging \
    Music \
    MusicFX \
    OmniJaws \
    ParallelSpace \
    PhotoTable \
    PrintRecommendationService \
    PrintSpooler \
    Profiles \
    QuickSearchBox \
    Recorder \
    Seedvault \
    Stk \
    Taskbar \
    ThemePicker \
    ThemesStub \
    TouchGestures \
    Traceur \
    Twelve \
    VisualizationWallpapers \
    WallpaperPicker2 \
    WeatherIcons \
    Eleven \
    CarrierConfigUI \
    CellBroadcastReceiver \
    CellBroadcastService \
    CellBroadcastApp \
    EmergencyInfo \
    MmsService \
    SimAppDialog \
    ONS \
    WAPPushManager \
    NfcNci \
    NfcNciApex \
    Tag \
    com.android.nfcservices \
    ManagedProvisioning \
    CompanionDeviceManager \
    DynamicSystemInstallationService \
    MtpService \
    OsuLogin \
    SharedStorageBackup \
    LocalTransport \
    BackupRestoreConfirmation \
    CtsShimPrebuilt \
    CtsShimPrivPrebuilt \
    CaptivePortalLogin \
    WifiDialog \
    Development \
    SampleLocationAttribution \
    EmulatedCamera \
    android.hardware.camera.provider.ranchu \
    android.hardware.camera.provider.ranchu_minigbm \
    awk \
    bash \
    bzip2 \
    curl \
    getcap \
    htop \
    lib7z \
    nano \
    pigz \
    rsync \
    scp \
    setcap \
    sftp \
    ssh \
    ssh-keygen \
    sshd \
    sshd_config \
    start-ssh \
    unrar \
    vim \
    zip \
    update_engine \
    update_engine_sideload \
    update_verifier \
    otapreopt_script \
    chat \
    eject \
    gps.huawei \
    io_switch \
    libhuaweigeneric-ril \
    parted \
    rtk_hciattach \
    tablet-mode \
    v86d \
    wacom-input \
    fsck.exfat \
    fsck.f2fs \
    make_f2fs \
    mkfs.exfat \
    mkntfs \
    mount.exfat \
    ntfs-3g \
    ntfsfix \
    btattach \
    btmon \
    hciconfig \
    hcitool \
    thermsys \
    thermal-daemon \
    tcpdump \
    tput \
    dialog \
    alsa-info.sh \
    tree \
    lspci \
    dmidecode \
    vainfo \
    evtest \
    efibootmgr \
    x86_dhcpclient.recovery

PRODUCT_PACKAGES := $(filter-out $(JAWAL_REMOVE_PACKAGES),$(PRODUCT_PACKAGES))
PRODUCT_PACKAGES_DEBUG := $(filter-out $(JAWAL_REMOVE_PACKAGES),$(PRODUCT_PACKAGES_DEBUG))

# Camera APIs remain in framework for application compatibility, but Jawal v1
# has no camera passthrough. Remove emulator camera HAL/provider modules and any
# inherited camera feature declarations so applications receive "no camera"
# rather than paying for a fake/unused camera implementation.
PRODUCT_COPY_FILES := $(filter-out \
    %/android.hardware.camera.xml:% \
    %/android.hardware.camera.front.xml:% \
    %/android.hardware.camera.any.xml:% \
    %/android.hardware.camera.full.xml:% \
    %/android.hardware.camera.autofocus.xml:% \
    %/android.hardware.camera.raw.xml:% \
    %/android.hardware.nfc.xml:% \
    %/android.hardware.nfc.hce.xml:% \
    %/android.hardware.nfc.hcef.xml:% \
    frameworks/native/data/etc/tablet_core_hardware.xml:%,$(PRODUCT_COPY_FILES))

# Keep the normal handheld contract for app/UI selection while omitting
# hardware-specific features Jawal does not expose.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/handheld_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml

# Windows/Jawal owns runtime updates and full-device backup. Android-side OTA,
# DSU, Seedvault/local backup transports, printing and MTP are deliberately out.
PRODUCT_BUILD_GENERIC_OTA_PACKAGE := false

# Strip Java local-variable debug metadata in production. Stack traces keep
# source/line information; this reduces image size without changing runtime
# behavior or application rendering/media quality.
PRODUCT_MINIMIZE_JAVA_DEBUG_INFO := true
WITH_DEXPREOPT_DEBUG_INFO := false

# App resource/layout selection should behave as a phone even though the
# underlying PC support originated from Android-x86 targets.
PRODUCT_CHARACTERISTICS := phone

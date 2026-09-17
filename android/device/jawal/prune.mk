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
    Updater \
    SetupWizard \
    LineageSetupWizard \
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
    WallpaperBackup \
    WeatherIcons \
    Eleven \
    FMRadio \
    FM2 \
    CarrierConfigUI \
    CarrierDefaultApp \
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
    SecureElement \
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
    DeviceAsWebcam \
    Uwb \
    UwbService \
    com.android.uwb \
    SatelliteService \
    com.android.satellite \
    VirtualizationService \
    virtualizationservice \
    com.android.virt \
    microdroid \
    microdroid_manager \
    vm \
    vm_shell \
    fastboot \
    fastbootd \
    lpdump \
    lpadd \
    lpflash \
    lpmake \
    snapshotctl \
    simpleperf \
    strace \
    heapprofd \
    bootanimation \
    wpa_supplicant \
    wpa_supplicant.conf \
    wpa_cli \
    hostapd \
    hostapd_cli \
    android.hardware.wifi-service \
    android.hardware.wifi-service.default \
    android.hardware.wifi.supplicant-service \
    android.hardware.wifi.supplicant-service.default \
    android.hardware.wifi.hostapd-service \
    android.hardware.wifi.hostapd-service.default \
    android.hardware.bluetooth-service.default \
    android.hardware.bluetooth@1.0-service \
    android.hardware.bluetooth@1.0-impl \
    android.hardware.bluetooth.audio-impl \
    audio.bluetooth.default \
    com.android.btservices \
    BluetoothMidiService \
    rfkill \
    iw \
    iwconfig \
    crda \
    wireless-regdb \
    lsusb \
    usb_modeswitch \
    usb_modeswitch_dispatcher \
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

ifeq ($(TARGET_BUILD_VARIANT),user)
JAWAL_REMOVE_PACKAGES += adbd
endif

PRODUCT_PACKAGES := $(filter-out $(JAWAL_REMOVE_PACKAGES),$(PRODUCT_PACKAGES))
PRODUCT_PACKAGES_DEBUG := $(filter-out $(JAWAL_REMOVE_PACKAGES),$(PRODUCT_PACKAGES_DEBUG))

# PRODUCT_COPY_FILES pruning is intentionally centralized in prune-copyfiles.mk.
# Keeping package and copy-file policies separate avoids duplicate destinations
# and makes failures from upstream inheritance easier to audit.

PRODUCT_BUILD_GENERIC_OTA_PACKAGE := false
PRODUCT_MINIMIZE_JAVA_DEBUG_INFO := true
WITH_DEXPREOPT_DEBUG_INFO := false
PRODUCT_CHARACTERISTICS := phone

# Jawal is a virtual phone runtime, not a BlissOS desktop distribution.
# The upstream Android-x86 device layer is retained for kernel/HAL/graphics
# compatibility, while consumer apps, PC-distribution utilities and bare-metal
# hardware tools that can never be used inside the fixed QEMU machine are removed.

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

# The generic Android-x86 layer advertises tablet core hardware because it also
# targets bare-metal PCs. Jawal is intentionally a phone-shaped handheld VM, so
# remove that declaration and publish Android's normal handheld core feature set.
PRODUCT_COPY_FILES := $(filter-out frameworks/native/data/etc/tablet_core_hardware.xml:%,$(PRODUCT_COPY_FILES))
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/handheld_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml

# Jawal owns runtime/image updates at the Windows layer.
PRODUCT_BUILD_GENERIC_OTA_PACKAGE := false

# App resource/layout selection should behave as a phone even though the
# underlying PC device support originated from Android-x86 tablet targets.
PRODUCT_CHARACTERISTICS := phone

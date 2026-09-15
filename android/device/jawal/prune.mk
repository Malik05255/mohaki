# Jawal is a virtual phone runtime, not a BlissOS desktop distribution.
# The upstream Android-x86 device layer is retained for kernel/HAL/graphics
# compatibility, while consumer apps and PC-distribution utilities are removed.

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
    ThemePicker \
    ThemesStub \
    TouchGestures \
    Traceur \
    Twelve \
    VisualizationWallpapers \
    WallpaperPicker2 \
    WeatherIcons \
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
    otapreopt_script

PRODUCT_PACKAGES := $(filter-out $(JAWAL_REMOVE_PACKAGES),$(PRODUCT_PACKAGES))
PRODUCT_PACKAGES_DEBUG := $(filter-out $(JAWAL_REMOVE_PACKAGES),$(PRODUCT_PACKAGES_DEBUG))

# Jawal owns runtime/image updates at the Windows layer.
PRODUCT_BUILD_GENERIC_OTA_PACKAGE := false

# App resource/layout selection should behave as a phone even though the
# underlying PC device support originated from Android-x86 tablet targets.
PRODUCT_CHARACTERISTICS := phone

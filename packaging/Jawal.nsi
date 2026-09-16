Unicode True
Name "جوال"
OutFile "..\dist\JawalSetup.exe"
InstallDir "$PROGRAMFILES64\Jawal"
InstallDirRegKey HKLM "Software\Jawal" "InstallDir"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
SetCompressorDictSize 64

!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\orange-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\orange-uninstall.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "Arabic"
!insertmacro MUI_LANGUAGE "English"

Section "Jawal" SEC_MAIN
    SetShellVarContext all
    SetOutPath "$INSTDIR"
    SetOverwrite on

    File "..\build\host\Release\Jawal.exe"

    SetOutPath "$INSTDIR\runtime"
    File /r "..\dist\runtime\*.*"

    SetOutPath "$INSTDIR"
    WriteUninstaller "$INSTDIR\Uninstall.exe"

    WriteRegStr HKLM "Software\Jawal" "InstallDir" "$INSTDIR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jawal" "DisplayName" "جوال"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jawal" "Publisher" "Jawal"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jawal" "DisplayIcon" "$INSTDIR\Jawal.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jawal" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jawal" "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jawal" "NoRepair" 1

    CreateDirectory "$SMPROGRAMS\Jawal"
    CreateShortcut "$SMPROGRAMS\Jawal\جوال.lnk" "$INSTDIR\Jawal.exe"
    CreateShortcut "$DESKTOP\جوال.lnk" "$INSTDIR\Jawal.exe"
SectionEnd

Section "Uninstall"
    SetShellVarContext all

    Delete "$DESKTOP\جوال.lnk"
    Delete "$SMPROGRAMS\Jawal\جوال.lnk"
    RMDir "$SMPROGRAMS\Jawal"

    # User apps/accounts live under %LOCALAPPDATA%\Jawal and are intentionally
    # preserved so uninstall/reinstall does not silently destroy the virtual phone.
    RMDir /r "$INSTDIR\runtime"
    Delete "$INSTDIR\Jawal.exe"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"

    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jawal"
    DeleteRegKey HKLM "Software\Jawal"
SectionEnd

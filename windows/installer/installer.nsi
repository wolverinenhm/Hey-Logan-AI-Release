;=============================================================================
; Hey Logan AI - Windows Setup (NSIS 3 / Modern UI 2)
;
; Per-user installer: no administrator rights, no UAC prompt.
;   Default install dir : %LOCALAPPDATA%\Programs\HeyLoganAI
;   Custom dir          : Setup.exe /D=C:\some\dir      (NSIS: last parameter,
;                                                         no quotes around path)
;   Silent install      : Setup.exe /S
;   Uninstall (keep data): Uninstall.exe /S            (also: /KEEPDATA)
;   Uninstall (purge data): Uninstall.exe /S /PURGEDATA
;
; Build it with build-setup.ps1 - do not edit generated artifacts.
;=============================================================================

Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WinVer.nsh"
!include "x64.nsh"
!include "Sections.nsh"

;--- Build-time defines (provided by build-setup.ps1) ------------------------
!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "1.0.0"
!endif
!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR is not defined. Run build-setup.ps1 to build the installer."
!endif
!ifndef OUTFILE
  !define OUTFILE "HeyLoganAI-Setup-${PRODUCT_VERSION}-win-x64.exe"
!endif
!ifndef ICON_FILE
  !define ICON_FILE "${PAYLOAD_DIR}\heylogan.ico"
!endif

;--- Product identity --------------------------------------------------------
!define PRODUCT_NAME      "Hey Logan AI"
!define PRODUCT_PUBLISHER "Hey Logan AI"
!define PRODUCT_URL       "https://github.com/wolverinenhm/hey-logan-ai"
!define APP_REG_KEY       "Software\HeyLoganAI"
!define ARP_REG_KEY       "Software\Microsoft\Windows\CurrentVersion\Uninstall\HeyLoganAI"
!define RUN_REG_KEY       "Software\Microsoft\Windows\CurrentVersion\Run"
!define RUN_VALUE_NAME    "HeyLoganAI"
!define SM_GROUP          "Hey Logan AI"
!define DATA_MOVE_NAME    ".hl-data-keep"

;--- Installer appearance / metadata ----------------------------------------
Name "${PRODUCT_NAME}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\HeyLoganAI"
InstallDirRegKey HKCU "${APP_REG_KEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
BrandingText "${PRODUCT_NAME} ${PRODUCT_VERSION}"
Caption "${PRODUCT_NAME} Setup"

Icon "${ICON_FILE}"
UninstallIcon "${ICON_FILE}"

VIProductVersion "${PRODUCT_VERSION}.0"
VIFileVersion "${PRODUCT_VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName"     "${PRODUCT_NAME}"
VIAddVersionKey /LANG=1033 "FileDescription" "${PRODUCT_NAME} Setup"
VIAddVersionKey /LANG=1033 "CompanyName"     "${PRODUCT_PUBLISHER}"
VIAddVersionKey /LANG=1033 "LegalCopyright"  "Copyright (c) 2026 ${PRODUCT_PUBLISHER}"
VIAddVersionKey /LANG=1033 "FileVersion"     "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "ProductVersion"  "${PRODUCT_VERSION}"
VIAddVersionKey /LANG=1033 "Comments"        "Per-user installer for ${PRODUCT_NAME}"

;--- Variables ---------------------------------------------------------------
Var DataKept        ; "1" when an existing app\data folder is being preserved by the installer
Var UnPurgeData     ; "1" when the uninstaller must delete app\data

;=============================================================================
; Modern UI 2 pages
;=============================================================================
!define MUI_ABORTWARNING
!define MUI_ICON   "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"

!define MUI_WELCOMEPAGE_TITLE "Welcome to the ${PRODUCT_NAME} Setup Wizard"
!define MUI_WELCOMEPAGE_TEXT "This wizard will install ${PRODUCT_NAME} for the current Windows user.$\r$\n$\r$\n${PRODUCT_NAME} turns this PC into a voice command center and runs entirely on your own machine. No administrator rights are needed and nothing is installed system-wide.$\r$\n$\r$\nClick Next to continue."

!define MUI_COMPONENTSPAGE_SMALLDESC

!define MUI_DIRECTORYPAGE_TEXT_TOP "${PRODUCT_NAME} will be installed in the folder below. Click Install to start the installation, or click Browse to choose another folder.$\r$\n$\r$\nA per-user install in your own profile does not require administrator rights."

!define MUI_FINISHPAGE_TITLE "${PRODUCT_NAME} is installed"
!define MUI_FINISHPAGE_TEXT "${PRODUCT_NAME} has been installed on your PC.$\r$\n$\r$\nDouble-click the ${PRODUCT_NAME} shortcut on your Desktop to start it. Use Pairing.cmd in the Start Menu when you want to connect your Android phone.$\r$\n$\r$\nClick Finish to close Setup."
!define MUI_FINISHPAGE_RUN "$SYSDIR\wscript.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Run ${PRODUCT_NAME}"
!define MUI_FINISHPAGE_RUN_PARAMETERS "$\"$INSTDIR\Launch.vbs$\""

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;=============================================================================
; Initialisation (defined after the sections so it can reference section ids)
;=============================================================================

;=============================================================================
; Helpers
;=============================================================================
; Stop a Hey Logan AI server that is currently running from $INSTDIR.
; tools\stop.ps1 (shipped by the app) matches only node.exe processes whose
; command line points into this installation folder, so unrelated Node.js
; applications are left alone. It exits 1 when nothing is running - harmless.
Function StopRunningServer
  ${If} ${FileExists} "$INSTDIR\tools\stop.ps1"
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\tools\stop.ps1"'
    Pop $0
    Sleep 400
  ${EndIf}
FunctionEnd

;=============================================================================
; Main installation section
;=============================================================================
Section "Hey Logan AI (required)" SEC_MAIN
  SectionIn RO
  SetShellVarContext current

  Call StopRunningServer

  ; --- upgrade: preserve app\data (settings, access token, certificates) ---
  ; The stash-then-RMDir pattern below must NEVER continue if the stash
  ; (Rename) fails: the following RMDir /r would delete the user's settings,
  ; token and certificates even though Setup promises to keep them.
  StrCpy $DataKept "0"

  ; Recover a data folder that a previously interrupted run left stashed away.
  ${If} ${FileExists} "$INSTDIR\${DATA_MOVE_NAME}\*.*"
    ${IfNot} ${FileExists} "$INSTDIR\app\data\*.*"
      Rename "$INSTDIR\${DATA_MOVE_NAME}" "$INSTDIR\app\data"
    ${Else}
      RMDir /r "$INSTDIR\${DATA_MOVE_NAME}"
    ${EndIf}
  ${EndIf}

  ${If} ${FileExists} "$INSTDIR\app\data\*.*"
    ClearErrors
    Rename "$INSTDIR\app\data" "$INSTDIR\${DATA_MOVE_NAME}"
    ${If} ${Errors}
      ; Abort BEFORE deleting anything: the previous installation is intact.
      ${IfNot} ${Silent}
        MessageBox MB_OK|MB_ICONSTOP "Setup could not move your existing data folder:$\r$\n$\r$\n$INSTDIR\app\data$\r$\n$\r$\nYour settings, access token and HTTPS certificate are still there and have NOT been changed. Nothing was installed, replaced or removed.$\r$\n$\r$\nClose any program that may be using this folder (for example a Hey Logan AI app window, a backup or an antivirus scan), then run Setup again."
      ${EndIf}
      SetErrorLevel 1
      Abort
    ${EndIf}
    StrCpy $DataKept "1"
  ${EndIf}

  ; --- remove the previous program files (never touches app\data) ---------
  RMDir /r "$INSTDIR\app"
  RMDir /r "$INSTDIR\runtime"
  RMDir /r "$INSTDIR\tools"
  Delete "$INSTDIR\*.vbs"
  Delete "$INSTDIR\*.cmd"
  Delete "$INSTDIR\*.txt"
  Delete "$INSTDIR\*.ico"
  Delete "$INSTDIR\Uninstall.exe"

  ; --- install this build's files -----------------------------------------
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD_DIR}\*"

  ; --- restore the user's data --------------------------------------------
  ${If} $DataKept == "1"
    RMDir /r "$INSTDIR\app\data"
    ClearErrors
    Rename "$INSTDIR\${DATA_MOVE_NAME}" "$INSTDIR\app\data"
    ${If} ${Errors}
      ; The program is installed and the data is intact, but still stashed.
      ; Keep the stash (never delete it here) and tell the user where it is.
      ${IfNot} ${Silent}
        MessageBox MB_OK|MB_ICONEXCLAMATION "Setup finished, but could not move your data back into:$\r$\n$\r$\n$INSTDIR\app\data$\r$\n$\r$\nYour settings, access token and certificate are safe in:$\r$\n$\r$\n$INSTDIR\${DATA_MOVE_NAME}$\r$\n$\r$\nClose any program using that folder and rename it back to app\data."
      ${EndIf}
    ${EndIf}
  ${EndIf}
  ${If} $DataKept == "0"
    RMDir /r "$INSTDIR\${DATA_MOVE_NAME}"
  ${EndIf}

  ; --- uninstaller ---------------------------------------------------------
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; --- start-at-login is opt-in per section; clear a stale value first -----
  DeleteRegValue HKCU "${RUN_REG_KEY}" "${RUN_VALUE_NAME}"

  ; --- application registry ------------------------------------------------
  WriteRegStr HKCU "${APP_REG_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${APP_REG_KEY}" "Version" "${PRODUCT_VERSION}"
  WriteRegStr HKCU "${APP_REG_KEY}" "DataDir" "$INSTDIR\app\data"

  ; --- Add/Remove Programs entry (per user) --------------------------------
  DeleteRegKey HKCU "${ARP_REG_KEY}"
  WriteRegStr   HKCU "${ARP_REG_KEY}" "DisplayName"     "${PRODUCT_NAME}"
  WriteRegStr   HKCU "${ARP_REG_KEY}" "DisplayVersion"  "${PRODUCT_VERSION}"
  WriteRegStr   HKCU "${ARP_REG_KEY}" "Publisher"       "${PRODUCT_PUBLISHER}"
  WriteRegStr   HKCU "${ARP_REG_KEY}" "DisplayIcon"     "$INSTDIR\heylogan.ico"
  WriteRegStr   HKCU "${ARP_REG_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${ARP_REG_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr   HKCU "${ARP_REG_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegStr   HKCU "${ARP_REG_KEY}" "URLInfoAbout"    "${PRODUCT_URL}"
  WriteRegStr   HKCU "${ARP_REG_KEY}" "HelpLink"        "$INSTDIR\HELP.txt"
  WriteRegDWORD HKCU "${ARP_REG_KEY}" "NoModify"        1
  WriteRegDWORD HKCU "${ARP_REG_KEY}" "NoRepair"        1
  WriteRegDWORD HKCU "${ARP_REG_KEY}" "VersionMajor"    1
  WriteRegDWORD HKCU "${ARP_REG_KEY}" "VersionMinor"    0
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "${ARP_REG_KEY}" "EstimatedSize" "$0"

  ; --- shortcuts: Start Menu group ----------------------------------------
  CreateDirectory "$SMPROGRAMS\${SM_GROUP}"
  CreateShortCut "$SMPROGRAMS\${SM_GROUP}\${PRODUCT_NAME}.lnk" \
                 "$SYSDIR\wscript.exe" '"$INSTDIR\Launch.vbs"' \
                 "$INSTDIR\heylogan.ico" 0 SW_SHOWNORMAL "" "Start ${PRODUCT_NAME}"
  CreateShortCut "$SMPROGRAMS\${SM_GROUP}\Start Console.lnk" \
                 "$INSTDIR\Start Console.cmd" "" \
                 "$INSTDIR\heylogan.ico" 0 SW_SHOWNORMAL "" "Start the ${PRODUCT_NAME} server with a visible console window"
  CreateShortCut "$SMPROGRAMS\${SM_GROUP}\Pairing.lnk" \
                 "$INSTDIR\Pairing.cmd" "" \
                 "$INSTDIR\heylogan.ico" 0 SW_SHOWNORMAL "" "Show the access token, phone links and QR code"
  CreateShortCut "$SMPROGRAMS\${SM_GROUP}\Stop Server.lnk" \
                 "$INSTDIR\Stop.cmd" "" \
                 "$INSTDIR\heylogan.ico" 0 SW_SHOWNORMAL "" "Stop the background ${PRODUCT_NAME} server"
  CreateShortCut "$SMPROGRAMS\${SM_GROUP}\Allow through Firewall.lnk" \
                 "$INSTDIR\Allow through Firewall.cmd" "" \
                 "$INSTDIR\heylogan.ico" 0 SW_SHOWNORMAL "" "Allow your phone to reach ${PRODUCT_NAME} through Windows Firewall"
  CreateShortCut "$SMPROGRAMS\${SM_GROUP}\Uninstall.lnk" \
                 "$INSTDIR\Uninstall.exe" "" \
                 "$INSTDIR\heylogan.ico" 0 SW_SHOWNORMAL "" "Uninstall ${PRODUCT_NAME}"

  ; --- shortcuts: Desktop --------------------------------------------------
  CreateShortCut "$DESKTOP\${PRODUCT_NAME}.lnk" \
                 "$SYSDIR\wscript.exe" '"$INSTDIR\Launch.vbs"' \
                 "$INSTDIR\heylogan.ico" 0 SW_SHOWNORMAL "" "Start ${PRODUCT_NAME}"

  ${RefreshShellIcons}
SectionEnd

;=============================================================================
; Optional component: start at sign-in (HKCU Run key)
;=============================================================================
Section "Start Hey Logan AI when I sign in" SEC_AUTOSTART
  ; The matching "delete" happened at the top of SEC_MAIN, so deselecting this
  ; component on an upgrade removes a previously installed Run value.
  WriteRegStr HKCU "${RUN_REG_KEY}" "${RUN_VALUE_NAME}" '"$SYSDIR\wscript.exe" "$INSTDIR\Launch.vbs"'
SectionEnd

;=============================================================================
; Initialisation (defined after the sections so it can reference ${SEC_AUTOSTART})
;=============================================================================
Function .onInit
  ; The payload contains a 64-bit Node.js runtime and the app targets x64.
  ${IfNot} ${RunningX64}
    ${IfNot} ${Silent}
      MessageBox MB_OK|MB_ICONSTOP "${PRODUCT_NAME} requires 64-bit Windows 10 or newer. This PC cannot run it."
    ${EndIf}
    SetErrorLevel 1
    Quit
  ${EndIf}

  ; Node.js 22 needs Windows 10 or newer.
  ${IfNot} ${AtLeastWin10}
    ${IfNot} ${Silent}
      MessageBox MB_OK|MB_ICONSTOP "${PRODUCT_NAME} requires Windows 10 or newer. Please update Windows and try again."
    ${EndIf}
    SetErrorLevel 1
    Quit
  ${EndIf}

  ; Everything is per-user: shortcuts, registry and the install folder.
  SetShellVarContext current

  ; /NOAUTOSTART: skip the start-at-login component (HKCU Run value).
  ; Works together with /S and /D=; the interactive wizard simply shows the
  ; "Start Hey Logan AI when I sign in" checkbox unchecked.
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} "$R0" "/NOAUTOSTART" $R1
  ${IfNot} ${Errors}
    !insertmacro UnselectSection ${SEC_AUTOSTART}
  ${EndIf}
FunctionEnd

;=============================================================================
; Component descriptions
;=============================================================================
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_MAIN} "The Hey Logan AI application, its private Node.js runtime and all launcher shortcuts. This component is required."
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_AUTOSTART} "Start Hey Logan AI automatically, hidden in the background, when you sign in to Windows. You can turn this off again by uninstalling, or by re-running Setup and clearing this checkbox."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

;=============================================================================
; Uninstaller
;=============================================================================
Function un.onInit
  SetShellVarContext current

  ; Find the installation: registry first (works for custom /D folders too),
  ; then the folder this uninstaller lives in.
  ReadRegStr $INSTDIR HKCU "${APP_REG_KEY}" "InstallDir"
  ${If} $INSTDIR == ""
    ReadRegStr $INSTDIR HKCU "${ARP_REG_KEY}" "InstallLocation"
  ${EndIf}
  ${If} $INSTDIR == ""
    StrCpy $INSTDIR $EXEDIR
  ${EndIf}

  ; --- should app\data (settings / access token / certificates) be kept? --
  StrCpy $UnPurgeData "0"
  ${GetParameters} $R0

  ClearErrors
  ${GetOptions} "$R0" "/PURGEDATA" $R1
  ${IfNot} ${Errors}
    StrCpy $UnPurgeData "1"
  ${EndIf}

  ClearErrors
  ${GetOptions} "$R0" "/KEEPDATA" $R1
  ${IfNot} ${Errors}
    StrCpy $UnPurgeData "0"
  ${EndIf}

  ${If} $UnPurgeData != "1"
  ${AndIfNot} ${Silent}
    MessageBox MB_YESNO|MB_ICONQUESTION "Keep your settings, access token and HTTPS certificate (the app\data folder)?$\r$\n$\r$\nYes - keep them (recommended). Your phone stays paired if you reinstall later.$\r$\nNo - delete them as well." \
               IDYES un_keep_data
    StrCpy $UnPurgeData "1"
    un_keep_data:
  ${EndIf}
FunctionEnd

Function un.StopRunningServer
  ${If} ${FileExists} "$INSTDIR\tools\stop.ps1"
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\tools\stop.ps1"'
    Pop $0
    Sleep 400
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetShellVarContext current

  Call un.StopRunningServer

  ; --- shortcuts -----------------------------------------------------------
  Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
  Delete "$SMPROGRAMS\${SM_GROUP}\${PRODUCT_NAME}.lnk"
  Delete "$SMPROGRAMS\${SM_GROUP}\Start Console.lnk"
  Delete "$SMPROGRAMS\${SM_GROUP}\Pairing.lnk"
  Delete "$SMPROGRAMS\${SM_GROUP}\Stop Server.lnk"
  Delete "$SMPROGRAMS\${SM_GROUP}\Allow through Firewall.lnk"
  Delete "$SMPROGRAMS\${SM_GROUP}\Uninstall.lnk"
  RMDir "$SMPROGRAMS\${SM_GROUP}"

  ; --- registry ------------------------------------------------------------
  DeleteRegValue HKCU "${RUN_REG_KEY}" "${RUN_VALUE_NAME}"
  DeleteRegKey HKCU "${ARP_REG_KEY}"
  DeleteRegKey HKCU "${APP_REG_KEY}"

  ; --- data decision -------------------------------------------------------
  ; Keep-data must be unable to destroy user data if the stash rename fails.
  ; Recover a data folder stashed by a previously interrupted run first.
  ${If} ${FileExists} "$INSTDIR\${DATA_MOVE_NAME}\*.*"
    ${IfNot} ${FileExists} "$INSTDIR\app\data\*.*"
      Rename "$INSTDIR\${DATA_MOVE_NAME}" "$INSTDIR\app\data"
    ${Else}
      RMDir /r "$INSTDIR\${DATA_MOVE_NAME}"
    ${EndIf}
  ${EndIf}

  ${If} $UnPurgeData == "1"
    ; Remove everything, including app\data (explicitly requested).
    RMDir /r "$INSTDIR\app"
  ${Else}
    ; Keep app\data: stash it, remove the program, restore it afterwards.
    StrCpy $DataKept "0"
    ${If} ${FileExists} "$INSTDIR\app\data\*.*"
      ClearErrors
      Rename "$INSTDIR\app\data" "$INSTDIR\${DATA_MOVE_NAME}"
      ${If} ${Errors}
        ; Never run the RMDir below after a failed stash: that would delete the
        ; token and certificates the user asked to keep.
        ${IfNot} ${Silent}
          MessageBox MB_OK|MB_ICONSTOP "Uninstall could not move your data folder aside:$\r$\n$\r$\n$INSTDIR\app\data$\r$\n$\r$\nYour settings, access token and HTTPS certificate have NOT been deleted. The uninstall was stopped before any program files were removed.$\r$\n$\r$\nClose any program using that folder (for example a Hey Logan AI app window or an antivirus scan) and run Uninstall again."
        ${EndIf}
        SetErrorLevel 1
        Abort
      ${EndIf}
      StrCpy $DataKept "1"
    ${EndIf}
    RMDir /r "$INSTDIR\app"
  ${EndIf}

  RMDir /r "$INSTDIR\runtime"
  RMDir /r "$INSTDIR\tools"
  Delete "$INSTDIR\*.vbs"
  Delete "$INSTDIR\*.cmd"
  Delete "$INSTDIR\*.txt"
  Delete "$INSTDIR\*.ico"
  Delete "$INSTDIR\Uninstall.exe"

  ${If} $UnPurgeData != "1"
    CreateDirectory "$INSTDIR\app"
    ${If} $DataKept == "1"
      ClearErrors
      Rename "$INSTDIR\${DATA_MOVE_NAME}" "$INSTDIR\app\data"
      ${If} ${Errors}
        ; Program removed, data intact but still stashed. Never delete the stash.
        ${IfNot} ${Silent}
          MessageBox MB_OK|MB_ICONEXCLAMATION "Uninstall finished, but your data folder could not be moved back to:$\r$\n$\r$\n$INSTDIR\app\data$\r$\n$\r$\nYour settings, access token and certificate are safe in:$\r$\n$\r$\n$INSTDIR\${DATA_MOVE_NAME}$\r$\n$\r$\nClose any program using that folder and rename it back to app\data."
        ${EndIf}
      ${EndIf}
    ${EndIf}
    RMDir "$INSTDIR\app"
  ${EndIf}
  RMDir "$INSTDIR"

  ; A per-user uninstall must always report success to Add/Remove Programs.
  SetErrorLevel 0
SectionEnd

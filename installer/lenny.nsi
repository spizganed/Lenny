; Lenny Desktop installer (ADR-0008). Build with installer\build.ps1, which compiles the binaries first.
; Every install step has its uninstall counterpart in the same order below: keep them paired.

Unicode true
!include "MUI2.nsh"
!include "x64.nsh"

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!define TARGET "..\target"
!define ICON "..\app\windows\runner\resources\app_icon.ico"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Lenny"

Name "Lenny"
OutFile "..\target\Lenny-Setup-${VERSION}.exe"
InstallDir "$PROGRAMFILES64\Lenny"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
; The installer is elevated; start the app through explorer so it runs as the normal user, like every later launch.
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION StartApp
!define MUI_FINISHPAGE_RUN_TEXT "Start Lenny"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH ; says so when files still in use go at the next reboot
!insertmacro MUI_LANGUAGE "English"

; A camera DLL loaded in a running Zoom/Chrome/... can't be overwritten, but it can be renamed: move it aside (deleted
; on the next reboot) and put the new one in place.
!macro PutDll SRC DIR
  SetOutPath "${DIR}"
  Delete "${DIR}\lenny_vcam_com.dll.old"
  Rename "${DIR}\lenny_vcam_com.dll" "${DIR}\lenny_vcam_com.dll.old"
  Delete /REBOOTOK "${DIR}\lenny_vcam_com.dll.old"
  File "${SRC}"
!macroend

; Uninstall: a camera DLL is kept loaded by every app that listed cameras (browsers, Discord, Frame Server...), so it
; can't be deleted, but it can be moved on the same drive. Move it to TEMP and delete it there at the next reboot, so
; the install folder goes now. Other drive (or no TEMP): delete in place at the next reboot.
!macro un.DropDll FILE
  Delete "${FILE}"
  ${If} ${FileExists} "${FILE}"
    GetTempFileName $R0
    Delete $R0
    ClearErrors
    Rename "${FILE}" $R0
    ${If} ${Errors}
      Delete /REBOOTOK "${FILE}"
    ${Else}
      Delete /REBOOTOK $R0
    ${EndIf}
  ${EndIf}
!macroend

Function StartApp
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\lenny-desktop.exe"'
FunctionEnd

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "Lenny needs 64-bit Windows 10 or 11."
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext all
FunctionEnd

Function un.onInit
  SetRegView 64
  SetShellVarContext all
FunctionEnd

Section "Lenny"
  ; An upgrade overwrites in place; the app and the broker must not be running.
  nsExec::Exec 'taskkill /F /IM lenny-desktop.exe'
  nsExec::Exec 'net stop LennyBroker'

  SetOutPath "$INSTDIR"
  File "${TARGET}\release\lenny-desktop.exe"
  File "${TARGET}\release\lenny-broker.exe"
  File "${ICON}"
  !insertmacro PutDll "${TARGET}\release\lenny_vcam_com.dll" "$INSTDIR"
  !insertmacro PutDll "${TARGET}\i686-pc-windows-msvc\release\lenny_vcam_com.dll" "$INSTDIR\x86"
  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Both virtual cameras. NSIS is 32-bit: Sysnative reaches the 64-bit regsvr32 (else it lands in the 32-bit hive).
  ExecWait '"$WINDIR\Sysnative\regsvr32.exe" /s "$INSTDIR\lenny_vcam_com.dll"' $0
  ExecWait '"$WINDIR\SysWOW64\regsvr32.exe" /s "$INSTDIR\x86\lenny_vcam_com.dll"' $1
  ${If} $0 != 0
  ${OrIf} $1 != 0
    MessageBox MB_ICONEXCLAMATION "Registering the virtual camera failed (x64: $0, x86: $1). Lenny runs, but other apps won't see its camera."
  ${EndIf}

  ; Broker service (architecture.md §7.3): holds the Global\ frame buffer, so the app needs no admin rights and the MF
  ; camera (Frame Server, session 0) sees the frames. "Already exists" on an upgrade is fine: same path.
  nsExec::Exec 'sc.exe create LennyBroker binPath= "\"$INSTDIR\lenny-broker.exe\"" start= auto DisplayName= "Lenny frame broker"'
  nsExec::Exec 'sc.exe description LennyBroker "Shares the Lenny virtual camera picture with other apps and Windows Frame Server."'
  nsExec::Exec 'net start LennyBroker'

  ; Phones reach the app (TCP stream, UDP discovery) on any network profile: Windows marks most home Wi-Fi "Public".
  ; Scoped to the app, like Windows' own "Allow" prompt; unknown phones still need the user's OK or the QR token.
  ; Delete first so a reinstall doesn't stack duplicates.
  nsExec::Exec 'netsh advfirewall firewall delete rule name="Lenny"'
  nsExec::Exec 'netsh advfirewall firewall add rule name="Lenny" dir=in action=allow program="$INSTDIR\lenny-desktop.exe" profile=any'

  CreateShortcut "$SMPROGRAMS\Lenny.lnk" "$INSTDIR\lenny-desktop.exe" "" "$INSTDIR\app_icon.ico"
  CreateShortcut "$DESKTOP\Lenny.lnk" "$INSTDIR\lenny-desktop.exe" "" "$INSTDIR\app_icon.ico"

  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "Lenny"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "Lenny"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\app_icon.ico"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; taskkill returns before the process is gone: wait, or deleting the exe fails and the folder stays.
  nsExec::Exec 'taskkill /F /IM lenny-desktop.exe'
  Sleep 1000

  ; Tolerates a partial install: every step ignores "not found".
  ExecWait '"$WINDIR\Sysnative\regsvr32.exe" /s /u "$INSTDIR\lenny_vcam_com.dll"'
  ExecWait '"$WINDIR\SysWOW64\regsvr32.exe" /s /u "$INSTDIR\x86\lenny_vcam_com.dll"'

  nsExec::Exec 'net stop LennyBroker'
  nsExec::Exec 'sc.exe delete LennyBroker'
  nsExec::Exec 'taskkill /F /IM lenny-broker.exe'
  Sleep 500

  nsExec::Exec 'netsh advfirewall firewall delete rule name="Lenny"'

  Delete "$SMPROGRAMS\Lenny.lnk"
  Delete "$DESKTOP\Lenny.lnk"

  Delete /REBOOTOK "$INSTDIR\lenny-desktop.exe"
  Delete /REBOOTOK "$INSTDIR\lenny-broker.exe"
  Delete "$INSTDIR\app_icon.ico"
  !insertmacro un.DropDll "$INSTDIR\lenny_vcam_com.dll"
  !insertmacro un.DropDll "$INSTDIR\lenny_vcam_com.dll.old"
  !insertmacro un.DropDll "$INSTDIR\x86\lenny_vcam_com.dll"
  !insertmacro un.DropDll "$INSTDIR\x86\lenny_vcam_com.dll.old"
  Delete "$INSTDIR\uninstall.exe"
  RMDir /REBOOTOK "$INSTDIR\x86"
  RMDir /REBOOTOK "$INSTDIR"

  DeleteRegKey HKLM "${UNINST_KEY}"
  ; Known phones and the log in %APPDATA%\Lenny stay (per-user data).
SectionEnd

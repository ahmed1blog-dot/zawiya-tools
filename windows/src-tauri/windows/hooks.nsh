; Per-user Explorer verb "أداة زاوية…" for files and folders (HKCU, no admin).
; Opens the quick wheel at the cursor: "<exe>" --wheel "%1". Saved as UTF-8 with BOM for NSIS.

!macro ZAWIYA_VERB ROOT
  WriteRegStr HKCU "Software\Classes\${ROOT}\shell\ZawiyaTools" "MUIVerb" "أداة زاوية…"
  WriteRegStr HKCU "Software\Classes\${ROOT}\shell\ZawiyaTools" "Icon" '"$INSTDIR\${MAINBINARYNAME}.exe",0'
  WriteRegStr HKCU "Software\Classes\${ROOT}\shell\ZawiyaTools\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" --wheel "%1"'
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro ZAWIYA_VERB "*"
  !insertmacro ZAWIYA_VERB "Directory"
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  DeleteRegKey HKCU "Software\Classes\*\shell\ZawiyaTools"
  DeleteRegKey HKCU "Software\Classes\Directory\shell\ZawiyaTools"
!macroend

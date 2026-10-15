param([Parameter(Mandatory=$true)][string]$ScriptPath)
$ErrorActionPreference='Stop'
# Apply only to the known Tauri-generated AgentBarBar per-user template.
# Fail closed on a template change rather than producing an unreviewed installer.
$text=[IO.File]::ReadAllText($ScriptPath)
foreach($guard in @('!define PRODUCTNAME "AgentBarBar"','!define INSTALLMODE "currentUser"')) {
 if(!$text.Contains($guard)){throw 'UNEXPECTED_INSTALLER_IDENTITY'}
}
$old='StrCpy $INSTDIR "$LOCALAPPDATA\${PRODUCTNAME}"'
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'DEFAULT_DIRECTORY_TEMPLATE_CHANGED'}
$text=$text.Replace($old,'StrCpy $INSTDIR "$LOCALAPPDATA\Programs\${PRODUCTNAME}"')
$old='    RmDir /r "$LOCALAPPDATA\${BUNDLEID}"'
if(([regex]::Matches($text,[regex]::Escape($old))).Count -ne 1){throw 'OPTIONAL_DATA_REMOVAL_TEMPLATE_CHANGED'}
# This stays inside the existing explicit checkbox and UpdateMode!=1 guard.
$text=$text.Replace($old,$old+"`r`n"+'    RmDir /r "$LOCALAPPDATA\AgentBarBar"')
[IO.File]::WriteAllText($ScriptPath,$text,(New-Object Text.UTF8Encoding($true)))

$utilsPath=Join-Path ([IO.Path]::GetDirectoryName($ScriptPath)) 'utils.nsh'
$utils=[IO.File]::ReadAllText($utilsPath)
$pattern='(?s)!macro CheckIfAppIsRunning executablePath productName.*?!macroend'
if(([regex]::Matches($utils,$pattern)).Count -ne 1){throw 'RUNNING_APP_TEMPLATE_CHANGED'}
# Installation/uninstallation may request the user to quit, but must never force
# terminate a collector with an active SQLite transaction.
$replacement=@'
!macro CheckIfAppIsRunning executablePath productName
  nsis_tauri_utils::StrReplace "$(appRunning)" "{{product_name}}" "${productName}"
  Pop $R1
  !insertmacro RestartManager_StartSession $R0
  ${If} $R0 == ""
    Abort "AgentBarBar: unable to verify whether application files are in use."
  ${EndIf}
  !insertmacro RestartManager_RegisterFile $R0 "${executablePath}"
  ${If} $0 != 0
    !insertmacro RestartManager_EndSession $R0
    Abort "AgentBarBar: unable to verify whether application files are in use."
  ${EndIf}
  System::Call 'RSTRTMGR::RmGetList(p R0, *i .r1, *i .r2, p 0, *i .r3) i .r0'
  ${If} $0 = ${ERROR_MORE_DATA}
    !insertmacro RestartManager_EndSession $R0
    Abort $R1
  ${ElseIf} $0 != 0
    !insertmacro RestartManager_EndSession $R0
    Abort "AgentBarBar: unable to verify whether application files are in use."
  ${EndIf}
  !insertmacro RestartManager_EndSession $R0
!macroend
'@
$utils=[regex]::Replace($utils,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match) $replacement})
[IO.File]::WriteAllText($utilsPath,$utils,(New-Object Text.UTF8Encoding($true)))

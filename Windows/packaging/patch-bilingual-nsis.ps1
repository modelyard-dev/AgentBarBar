param([Parameter(Mandatory=$true)][string]$ScriptPath)
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText($ScriptPath)
if(!$text.Contains('!define PRODUCTNAME "AgentBarBar"') -or !$text.Contains('!define INSTALLMODE "currentUser"')){throw 'UNEXPECTED_INSTALLER_IDENTITY'}
if($text.Contains('AGENTBAR_INLINE_BILINGUAL')){throw 'ALREADY_BILINGUAL'}
$dir=[IO.Path]::GetDirectoryName($ScriptPath)
$lang=Join-Path $dir 'bilingual'
New-Item -ItemType Directory -Path $lang -Force|Out-Null
Copy-Item (Join-Path $PSScriptRoot 'bilingual\*') $lang -Force
$start=';Languages'
$finish='Function .onInit'
$a=$text.IndexOf($start);$b=$text.IndexOf($finish,$a)
if($a -lt 0 -or $b -lt 0){throw 'LANGUAGE_TEMPLATE_CHANGED'}
$replacement=";Languages - AGENTBAR_INLINE_BILINGUAL`r`n!insertmacro MUI_LANGUAGEEX `"$lang`" `"English`"`r`n!include `"$lang\tauri-bilingual.nsh`"`r`n`r`n"
$text=$text.Substring(0,$a)+$replacement+$text.Substring($b)
$text=$text.Replace('!define DISPLAYLANGUAGESELECTOR "true"','!define DISPLAYLANGUAGESELECTOR "false"')
$text=$text.Replace('!insertmacro MUI_PAGE_WELCOME',"!define MUI_WELCOMEPAGE_TITLE_3LINES`r`n!insertmacro MUI_PAGE_WELCOME")
# Allow bilingual maintenance options enough vertical space to wrap safely.
$text=$text.Replace('${NSD_CreateLabel} 0 0 100% 24u $R1','${NSD_CreateLabel} 0 0 100% 48u $R1')
$text=$text.Replace('${NSD_CreateRadioButton} 30u 50u -30u 8u $R2','${NSD_CreateRadioButton} 0 60u 100% 22u $R2')
$text=$text.Replace('${NSD_CreateRadioButton} 30u 70u -30u 8u $R3','${NSD_CreateRadioButton} 0 88u 100% 32u $R3')
[IO.File]::WriteAllText($ScriptPath,$text,(New-Object Text.UTF8Encoding($true)))

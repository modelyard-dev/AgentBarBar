param(
 [Parameter(Mandatory=$true)][string]$SourceRoot,
 [Parameter(Mandatory=$true)][string]$TargetDir,
 [string]$TauriCli='tauri.cmd',
 [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding
$SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
$TargetDir=[IO.Path]::GetFullPath($TargetDir)
$version=(Get-Content -LiteralPath (Join-Path $SourceRoot 'Windows\src-tauri\tauri.conf.json') -Raw|ConvertFrom-Json).version
$build=(Get-Content -LiteralPath (Join-Path $SourceRoot 'Windows\BUILD_NUMBER') -Raw).Trim()
if($version -notmatch '^\d+\.\d+\.\d+$' -or $build -notmatch '^[1-9]\d*$'){throw 'INVALID_WINDOWS_VERSION'}
if(!$OutputDirectory){$OutputDirectory=Join-Path $SourceRoot ('build\windows-'+$version+'\delivery')}
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$configPath=Join-Path $OutputDirectory 'release-package.json'
$exe=Join-Path $TargetDir 'release\AgentBarBar.exe'
if((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne $version){throw 'BINARY_VERSION_MISMATCH'}
$config=@{
 version=$version
 bundle=@{
  active=$true;targets=@('nsis');publisher='y2zyyr'
  shortDescription='Local AI Agent usage statistics'
  windows=@{webviewInstallMode=@{type='downloadBootstrapper';silent=$true};nsis=@{installMode='currentUser';languages=@('SimpChinese','English');displayLanguageSelector=$true}}
 }
}
[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
$env:CARGO_TARGET_DIR=$TargetDir
Set-Location (Join-Path $SourceRoot 'Windows')
$command='"'+$TauriCli+'" bundle --bundles nsis --config "'+$configPath+'" --no-sign'
$command+=' 1>"'+$OutputDirectory+'\package.stdout" 2>"'+$OutputDirectory+'\package.stderr"'
& $env:COMSPEC /d /s /c ('"'+$command+'"')
if($LASTEXITCODE -ne 0){Get-Content ($OutputDirectory+'\package.stderr') -Tail 60;throw ('TAURI_PACKAGE_FAILED_'+$LASTEXITCODE)}
$nsi=Join-Path $TargetDir 'release\nsis\x64\installer.nsi'
& (Join-Path $PSScriptRoot 'patch-internal-nsis.ps1') -ScriptPath $nsi
& (Join-Path $PSScriptRoot 'patch-bilingual-nsis.ps1') -ScriptPath $nsi
Set-Location ([IO.Path]::GetDirectoryName($nsi))
$command='"'+$env:LOCALAPPDATA+'\tauri\NSIS\makensis.exe" /V3 installer.nsi 1>"'+$OutputDirectory+'\nsis.stdout" 2>"'+$OutputDirectory+'\nsis.stderr"'
& $env:COMSPEC /d /s /c ('"'+$command+'"')
if($LASTEXITCODE -ne 0){Get-Content ($OutputDirectory+'\nsis.stderr') -Tail 60;throw ('NSIS_PACKAGE_FAILED_'+$LASTEXITCODE)}
$dest=Join-Path $OutputDirectory ('AgentBarBar-'+$version+'-Windows-x64-Setup.exe')
Copy-Item (Join-Path ([IO.Path]::GetDirectoryName($nsi)) 'nsis-output.exe') $dest -Force
$sha=(Get-FileHash $dest -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($dest+'.sha256'),($sha+'  '+[IO.Path]::GetFileName($dest)+"`n"),(New-Object Text.UTF8Encoding($false)))
$manifest=@{platform='Windows';version=$version;build=[int]$build;channel='local-delivery';inlineBilingual=$true;sha256=$sha;installer=[IO.Path]::GetFileName($dest);size=(Get-Item $dest).Length;executableSHA=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant();signed=$false}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'build-manifest.json'),($manifest|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$manifest|ConvertTo-Json

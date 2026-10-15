param([Parameter(Mandatory=$true)][string]$InstallerPath)
$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskVersion=(Get-Content -LiteralPath (Join-Path $taskRoot 'Windows\src-tauri\tauri.conf.json') -Raw|ConvertFrom-Json).version
$taskInstaller=[IO.Path]::GetFullPath($InstallerPath)
$taskManifest=Get-Content -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($taskInstaller)) 'build-manifest.json') -Raw|ConvertFrom-Json
if($taskManifest.version -ne $taskVersion -or $taskManifest.build -ne [int](Get-Content -LiteralPath (Join-Path $taskRoot 'Windows\BUILD_NUMBER'))){throw 'PACKAGE_VERSION_MISMATCH'}
if((Get-FileHash -LiteralPath $taskInstaller -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskManifest.sha256){throw 'INSTALLER_CHECKSUM_MISMATCH'}
$taskDestination=Join-Path $env:LOCALAPPDATA 'Programs\AgentBarBar'
$taskExecutable=Join-Path $taskDestination 'AgentBarBar.exe'
if(Get-Process -Name AgentBarBar -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $taskExecutable}){throw 'QUIT_INSTALLED_AGENTBARBAR_BEFORE_INSTALLING'}
if(Test-Path -LiteralPath $taskExecutable){
    $taskPrevious=(Get-Item -LiteralPath $taskExecutable).VersionInfo.ProductVersion
    if($taskPrevious -eq $taskVersion){
        if((Get-FileHash -LiteralPath $taskExecutable -Algorithm SHA256).Hash.ToLowerInvariant() -eq $taskManifest.executableSHA){throw 'BUILD_ALREADY_INSTALLED'}
        $taskInstalledRecord=Join-Path $taskDestination 'installed-build.json'
        if(Test-Path -LiteralPath $taskInstalledRecord){
            $taskInstalled=Get-Content -LiteralPath $taskInstalledRecord -Raw|ConvertFrom-Json
            if($taskInstalled.version -eq $taskVersion -and [int]$taskManifest.build -le [int]$taskInstalled.build){throw 'BUMP_BUILD_NUMBER_BEFORE_REPLACING_INSTALLED_BUILD'}
        }
    }
    $taskBackup=Join-Path $taskRoot ('build\install-backups\Windows-'+$taskPrevious+'-'+(Get-Date -Format yyyyMMddHHmmss))
    New-Item -ItemType Directory -Path $taskBackup -Force|Out-Null
    Copy-Item -LiteralPath $taskDestination -Destination (Join-Path $taskBackup 'app') -Recurse
}
$taskProcess=Start-Process -FilePath $taskInstaller -ArgumentList '/S' -WindowStyle Hidden -PassThru
if(!$taskProcess.WaitForExit(60000)){throw 'INSTALLATION_STILL_RUNNING_CHECK_BEFORE_RETRY'}
if($taskProcess.ExitCode -ne 0){throw ('INSTALLER_EXIT_'+$taskProcess.ExitCode)}
if((Get-Item -LiteralPath $taskExecutable).VersionInfo.ProductVersion -ne $taskVersion){throw 'INSTALLED_VERSION_MISMATCH'}
if((Get-FileHash -LiteralPath $taskExecutable -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskManifest.executableSHA){throw 'INSTALLED_BINARY_CHECKSUM_MISMATCH'}
$taskManifest|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $taskDestination 'installed-build.json') -Encoding utf8
@{platform='Windows';version=$taskVersion;build=$taskManifest.build;installed=$true;binaryChecksumVerified=$true;backupCreated=[bool]$taskBackup}|ConvertTo-Json

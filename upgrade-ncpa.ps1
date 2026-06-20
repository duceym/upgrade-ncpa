<#
Nagios/NCPA plugin that upgrades NCPA from a central HTTP or FTP URL.

This mirrors the common manual workflow:
  http://servername/nagios/ncpa/ncpa-latest.exe /S /TOKEN='TOKEN'
  copy scripts into C:\Program Files\Nagios\NCPA\plugins

The installer and copy steps run in a detached worker process because the NCPA
service may restart while the check is running.

Usage examples:
  HTTP:
    upgrade-ncpa.ps1 -SourceRoot http://servername/ncpa -Token YOUR_TOKEN

  FTP:
    upgrade-ncpa.ps1 -SourceRoot ftp://servername/ncpa -User nagios -Password nagios -Token YOUR_TOKEN

  Force reinstall/downgrade:
    upgrade-ncpa.ps1 -SourceRoot http://servername/ncpa -Token YOUR_TOKEN -Force

Nagios exit codes:
  0 OK       - upgrade was started or NCPA already up to date
  1 WARNING  - install already appears to be running
  2 CRITICAL - validation failed
  3 UNKNOWN  - unexpected error
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [string]$User,

    [string]$Password,

    [string]$InstallerName = "ncpa-latest.exe",

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [string]$PluginDir = "C:\Program Files\Nagios\NCPA\plugins",

    [string]$WorkDir = "$env:ProgramData\Nagios\NCPA-Upgrade",

    [int]$LockMinutes = 60,

    [switch]$Force,

    [switch]$Version
)

$ScriptVersion = "1.0.0"

$ErrorActionPreference = "Stop"

$PluginFiles = @(
    "check_services.ps1",
    "check_windows_time.bat",
    "CheckWindowsVolumeMountPointFreeSpace.ps1",
    "CheckWindowsVolumeMountPointFreeSpace_byVol.ps1",
    "check_openmanage.exe",
    "check_all_csv_frespace.ps1",
    "check_storage_pool.ps1",
    "upgrade-ncpa.ps1"
)

function Join-UriPath {
    param(
        [string]$BaseUri,
        [string]$ChildPath
    )

    return $BaseUri.TrimEnd("/") + "/" + $ChildPath.TrimStart("/").Replace("\", "/")
}

function Copy-RemoteFile {
    param(
        [string]$Uri,
        [string]$Destination,
        [string]$User,
        [string]$Password
    )

    $client = New-Object System.Net.WebClient
    try {
        if ($User) {
            $client.Credentials = New-Object System.Net.NetworkCredential($User, $Password)
        }

        $destinationDir = Split-Path -Parent $Destination
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        $client.DownloadFile($Uri, $Destination)
    }
    catch {
        throw "Failed to download $Uri to $Destination. $($_.Exception.Message)"
    }
    finally {
        $client.Dispose()
    }
}

function Exit-Nagios {
    param(
        [int]$Code,
        [string]$State,
        [string]$Message
    )

    Write-Output "$State - $Message"
    exit $Code
}

function Assert-InstallerSignature {
    param(
        [string]$Path,
        [string]$ExpectedSubject = "Nagios Enterprises, LLC",
        [string]$ExpectedSerial = "2265943-2"
    )

    $sig = Get-AuthenticodeSignature -LiteralPath $Path

    if ($sig.Status -ne "Valid") {
        Exit-Nagios 2 "CRITICAL" "Installer signature invalid or missing: $($sig.Status) - $Path"
    }

    $actualSubject = $sig.SignerCertificate.Subject
    if ($actualSubject -notlike "*$ExpectedSubject*") {
        Exit-Nagios 2 "CRITICAL" "Installer signed by unexpected publisher: $actualSubject"
    }

    $actualSerial = $sig.SignerCertificate.Subject -replace '.*SERIALNUMBER=([^,]+).*', '$1'
    if ($actualSerial -ne $ExpectedSerial) {
        Exit-Nagios 2 "CRITICAL" "Installer certificate serial mismatch: got $actualSerial"
    }
}

try {
    if ($Version) {
        Exit-Nagios 0 "OK" "upgrade-ncpa.ps1 version $ScriptVersion"
    }

    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    $lockFile = Join-Path $WorkDir "upgrade.lock"
    if ((Test-Path -LiteralPath $lockFile) -and -not $Force) {
        $ageMinutes = ((Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime).TotalMinutes
        if ($ageMinutes -lt $LockMinutes) {
            Exit-Nagios 1 "WARNING" "NCPA upgrade already appears to be running; lock age $([math]::Round($ageMinutes, 1)) minutes"
        }
    }

    Set-Content -Path $lockFile -Value "Started $(Get-Date -Format o)" -Encoding ASCII

    $stageDir = Join-Path $WorkDir "stage"
    $stageScriptDir = Join-Path $stageDir "scripts"
    New-Item -ItemType Directory -Path $stageScriptDir -Force | Out-Null

    $installerPath = Join-Path $stageDir $InstallerName
    $installerUri = Join-UriPath -BaseUri $SourceRoot -ChildPath $InstallerName
    Copy-RemoteFile -Uri $installerUri -Destination $installerPath -User $User -Password $Password

    Assert-InstallerSignature -Path $installerPath

    $downloadVersion = (Get-Item $installerPath).VersionInfo.FileVersion
    $ncpaExe = "C:\Program Files\Nagios\NCPA\ncpa.exe"
    $installedVersion = if (Test-Path $ncpaExe) {
        (Get-Item $ncpaExe).VersionInfo.FileVersion
    } else { $null }
    $skipInstall = $false

    if ($installedVersion) {
        if ([System.Version]$downloadVersion -le [System.Version]$installedVersion -and -not $Force) {
            $skipInstall = $true
        }
    }

    foreach ($pluginFile in $PluginFiles) {
        $sourceUri = Join-UriPath -BaseUri $SourceRoot -ChildPath "scripts/$pluginFile"
        $stagedFile = Join-Path $stageScriptDir $pluginFile
        Copy-RemoteFile -Uri $sourceUri -Destination $stagedFile -User $User -Password $Password
    }

    $scriptSourceDir = $stageScriptDir

    $workerPath = Join-Path $WorkDir "run-upgrade.ps1"
    $logPath = Join-Path $WorkDir "upgrade-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    $pluginList = ($PluginFiles | ForEach-Object { "        `"$_`"" }) -join ",`r`n"
    $skipInstallStr = if ($skipInstall) { '$true' } else { '$false' }

    $worker = @"
`$ErrorActionPreference = "Continue"
Start-Transcript -Path "$logPath" -Append
try {
    `$installerPath = "$installerPath"
    `$scriptSourceDir = "$scriptSourceDir"
    `$pluginDir = "$PluginDir"
    `$skipInstall = $skipInstallStr
    `$pluginFiles = @(
$pluginList
    )

    New-Item -ItemType Directory -Path `$pluginDir -Force | Out-Null

    if (-not `$skipInstall) {
        Write-Output "Starting NCPA installer: `$installerPath"
        `$arguments = "/S /TOKEN='$Token'"
        `$process = Start-Process -FilePath `$installerPath -ArgumentList `$arguments -Wait -PassThru
        Write-Output "Installer exit code: `$(`$process.ExitCode)"
    }
    else {
        Write-Output "Skipping installer: downloaded version ($downloadVersion) is not newer than installed ($installedVersion)"
    }

    Remove-Item -LiteralPath `$installerPath -Force -ErrorAction SilentlyContinue
    Write-Output "Removed installer: `$installerPath"

    foreach (`$pluginFile in `$pluginFiles) {
        `$sourceFile = Join-Path `$scriptSourceDir `$pluginFile
        `$destinationFile = Join-Path `$pluginDir `$pluginFile
        Copy-Item -LiteralPath `$sourceFile -Destination `$destinationFile -Force
        Write-Output "Copied `$pluginFile"
    }

    Start-Sleep -Seconds 5
    `$service = Get-Service -Name "ncpalistener" -ErrorAction SilentlyContinue
    if (`$service -and `$service.Status -ne "Running") {
        Start-Service -Name "ncpalistener"
        Write-Output "Started service ncpalistener"
    }
}
finally {
    Remove-Item -Path "$lockFile" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$workerPath" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$stageScriptDir" -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Transcript
}
"@

    Set-Content -Path $workerPath -Value $worker -Encoding ASCII

    Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$workerPath`"" `
        -WindowStyle Hidden

    if ($skipInstall) {
        Exit-Nagios 0 "OK" "NCPA up to date ($installedVersion); plugins updated; log: $logPath"
    }
    else {
        Exit-Nagios 0 "OK" "NCPA upgrade started ($installedVersion -> $downloadVersion); log: $logPath"
    }
}
catch {
    if ($lockFile) {
        Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
    }

    Exit-Nagios 3 "UNKNOWN" "Unable to stage NCPA upgrade: $($_.Exception.Message)"
}
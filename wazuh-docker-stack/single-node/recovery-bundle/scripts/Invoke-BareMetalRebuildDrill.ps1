[CmdletBinding()]
param(
    [string]$VaultPath = "",
    [string]$Passphrase = "",
    [string]$HostAddress = "",
    [string]$DrillRoot = "",
    [string]$BundleStamp = "",
    [switch]$RestoreVolumeBackups,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

$bundleRoot = Split-Path $PSScriptRoot -Parent
$canonicalProjectRoot = (Resolve-Path (Join-Path $bundleRoot "..\..\..")).Path
$backupRoot = Join-Path $bundleRoot "backups\monitoring-host"
$legacyProjectRoot = Join-Path $bundleRoot "blueprints\monitoring-host\monitoring-stack"

function Get-LatestBundleSnapshot {
    param([string]$BackupRoot)

    if (-not (Test-Path $BackupRoot)) {
        return $null
    }

    return Get-ChildItem -Path $BackupRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Test-ProjectRoot {
    param([string]$Path)

    return (Test-Path (Join-Path $Path "scripts\windows\Invoke-BareMetalRebuildDrill.ps1")) -and
        (Test-Path (Join-Path $Path "docker-compose.yml"))
}

function Resolve-ProjectRoot {
    param(
        [string]$CanonicalProjectRoot,
        [string]$BackupRoot,
        [string]$BundleStamp,
        [string]$LegacyProjectRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($BundleStamp)) {
        $snapshotProjectRoot = Join-Path (Join-Path $BackupRoot $BundleStamp) "monitoring-stack"
        if (-not (Test-ProjectRoot $snapshotProjectRoot)) {
            throw "Bundle stamp '$BundleStamp' does not contain a staged monitoring stack at '$snapshotProjectRoot'."
        }

        return $snapshotProjectRoot
    }

    if (Test-ProjectRoot $CanonicalProjectRoot) {
        return $CanonicalProjectRoot
    }

    $latestSnapshot = Get-LatestBundleSnapshot -BackupRoot $BackupRoot
    if ($latestSnapshot) {
        $snapshotProjectRoot = Join-Path $latestSnapshot.FullName "monitoring-stack"
        if (Test-ProjectRoot $snapshotProjectRoot) {
            return $snapshotProjectRoot
        }
    }

    if (Test-ProjectRoot $LegacyProjectRoot) {
        return $LegacyProjectRoot
    }

    throw "No monitoring-stack source was found for the rebuild drill. Use the live repository source or a recovery bundle with 'backups\\monitoring-host\\<stamp>'."
}

$projectRoot = Resolve-ProjectRoot -CanonicalProjectRoot $canonicalProjectRoot -BackupRoot $backupRoot -BundleStamp $BundleStamp -LegacyProjectRoot $legacyProjectRoot
$delegateScript = Join-Path $projectRoot "scripts\windows\Invoke-BareMetalRebuildDrill.ps1"

if (-not (Test-Path $delegateScript)) {
    throw "Bare-metal rebuild drill delegate not found at $delegateScript"
}

if (-not [string]::IsNullOrWhiteSpace($VaultPath) -and -not [System.IO.Path]::IsPathRooted($VaultPath)) {
    $VaultPath = Join-Path $bundleRoot $VaultPath
}

if ([string]::IsNullOrWhiteSpace($DrillRoot)) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $DrillRoot = Join-Path $bundleRoot "logs\rebuild-drills\bare-metal-$timestamp"
}
elseif (-not [System.IO.Path]::IsPathRooted($DrillRoot)) {
    $DrillRoot = Join-Path $bundleRoot $DrillRoot
}

$delegateArgs = @(
    "-ProjectRoot", $projectRoot,
    "-RecoveryBundleRoot", $bundleRoot,
    "-DrillRoot", $DrillRoot
)
if (-not [string]::IsNullOrWhiteSpace($VaultPath)) {
    $delegateArgs += @("-VaultPath", $VaultPath)
}
if (-not [string]::IsNullOrWhiteSpace($Passphrase)) {
    $delegateArgs += @("-Passphrase", $Passphrase)
}
if (-not [string]::IsNullOrWhiteSpace($HostAddress)) {
    $delegateArgs += @("-HostAddress", $HostAddress)
}
if (-not [string]::IsNullOrWhiteSpace($BundleStamp)) {
    $delegateArgs += @("-BundleStamp", $BundleStamp)
}
if ($RestoreVolumeBackups) {
    $delegateArgs += "-RestoreVolumeBackups"
}
if ($Apply) {
    $delegateArgs += "-Apply"
}

& powershell -ExecutionPolicy Bypass -File $delegateScript @delegateArgs

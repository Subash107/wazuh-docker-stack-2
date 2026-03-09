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
$projectRoot = Join-Path $bundleRoot "blueprints\monitoring-host\monitoring-stack"
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

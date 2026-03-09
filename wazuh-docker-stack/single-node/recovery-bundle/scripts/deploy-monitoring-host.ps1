param(
    [Parameter(Mandatory = $true)]
    [string]$HostAddress,
    [string]$TargetRoot = "D:\Monitoring",
    [string]$BundleStamp,
    [switch]$RestoreVolumeBackups,
    [switch]$SkipStart,
    [switch]$SkipLocalSeed,
    [switch]$SkipValidation
)

$ErrorActionPreference = "Stop"

if ($SkipValidation -and -not $SkipStart) {
    throw "-SkipValidation is only supported together with -SkipStart."
}

function Copy-Tree {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /NP /XD __pycache__ recovery-bundle | Out-Null
}

function Restore-DockerVolume {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeName,
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    $inUseContainers = docker ps -q --filter "volume=$VolumeName"
    if ($inUseContainers) {
        throw "Refusing to restore Docker volume '$VolumeName' because it is currently attached to running containers."
    }

    docker volume create $VolumeName | Out-Null
    $archiveRoot = Split-Path $ArchivePath -Parent
    $archiveName = Split-Path $ArchivePath -Leaf
    docker run --rm `
      -v "${VolumeName}:/to" `
      -v "${archiveRoot}:/backup:ro" `
      alpine:3.20 sh -lc "mkdir -p /to && tar -C /to -xzf /backup/$archiveName"
}

$bundleRoot = Split-Path $PSScriptRoot -Parent
$monitoringSource = Join-Path $bundleRoot "blueprints\monitoring-host\monitoring-stack"
$wazuhSource = Join-Path $bundleRoot "blueprints\monitoring-host\wazuh-single-node"
$sourceMonitoringRoot = (Resolve-Path (Join-Path $bundleRoot "..\..\..")).Path
$sourceMonitoringSecrets = Join-Path $sourceMonitoringRoot "secrets"
$sourceWazuhRoot = (Resolve-Path (Join-Path $bundleRoot "..\..")).Path
$sourceWazuhSecrets = Join-Path $sourceWazuhRoot "secrets"
$wazuhTarget = Join-Path $TargetRoot "wazuh-docker-stack\single-node"
$wazuhRootTarget = Join-Path $TargetRoot "wazuh-docker-stack"
$wazuhSecretsTarget = Join-Path $wazuhRootTarget "secrets"
$recoveryBundleTarget = Join-Path $wazuhTarget "recovery-bundle"
$backupRoot = Join-Path $bundleRoot "backups\monitoring-host"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required on the target host."
}

New-Item -ItemType Directory -Force -Path $TargetRoot, $wazuhRootTarget, $wazuhTarget, $wazuhSecretsTarget, $recoveryBundleTarget | Out-Null

foreach ($monitoringFile in @(
    ".env.example",
    "README.md",
    "docker-compose.yml",
    "alertmanager.yml",
    "prometheus.yml",
    "alert.rules.yml",
    "blackbox.yml"
)) {
    $sourcePath = Join-Path $monitoringSource $monitoringFile
    if (Test-Path $sourcePath) {
        Copy-Item $sourcePath -Destination $TargetRoot -Force
    }
}
Copy-Tree "$monitoringSource\scripts" (Join-Path $TargetRoot "scripts")
if (Test-Path (Join-Path $monitoringSource "docs")) {
    Copy-Tree (Join-Path $monitoringSource "docs") (Join-Path $TargetRoot "docs")
}
if (Test-Path (Join-Path $monitoringSource "gateway")) {
    Copy-Tree (Join-Path $monitoringSource "gateway") (Join-Path $TargetRoot "gateway")
}
Copy-Tree "$monitoringSource\secrets" (Join-Path $TargetRoot "secrets")
if ((-not $SkipLocalSeed) -and (Test-Path $sourceMonitoringSecrets)) {
    Copy-Tree $sourceMonitoringSecrets (Join-Path $TargetRoot "secrets")
}
Copy-Tree "$monitoringSource\targets" (Join-Path $TargetRoot "targets")

Copy-Item "$wazuhSource\docker-compose.yml", "$wazuhSource\generate-indexer-certs.yml", "$wazuhSource\README.md", "$wazuhSource\.env.example" -Destination $wazuhTarget -Force
Copy-Tree "$wazuhSource\config" (Join-Path $wazuhTarget "config")
Copy-Tree "$wazuhSource\secrets" $wazuhSecretsTarget
if ((-not $SkipLocalSeed) -and (Test-Path (Join-Path $sourceWazuhRoot ".env"))) {
    Copy-Item (Join-Path $sourceWazuhRoot ".env") -Destination (Join-Path $wazuhRootTarget ".env") -Force
}
elseif ((-not $SkipLocalSeed) -and (Test-Path (Join-Path $wazuhSource ".env.example"))) {
    Copy-Item (Join-Path $wazuhSource ".env.example") -Destination (Join-Path $wazuhRootTarget ".env") -Force
}
if ((-not $SkipLocalSeed) -and (Test-Path $sourceWazuhSecrets)) {
    Copy-Tree $sourceWazuhSecrets $wazuhSecretsTarget
}
Copy-Item (Join-Path $bundleRoot "README.md") -Destination $recoveryBundleTarget -Force
Copy-Tree (Join-Path $bundleRoot "scripts") (Join-Path $recoveryBundleTarget "scripts")
Copy-Tree (Join-Path $bundleRoot "blueprints\sensor-vm") (Join-Path $recoveryBundleTarget "blueprints\sensor-vm")

$recoveryConfigTarget = Join-Path $recoveryBundleTarget "config"
New-Item -ItemType Directory -Force -Path $recoveryConfigTarget | Out-Null
Copy-Item (Join-Path $bundleRoot "config\hyperv-provision.env.example"), (Join-Path $bundleRoot "config\offsite-backup.env.example") -Destination $recoveryConfigTarget -Force

$monitoringCompose = Join-Path $TargetRoot "docker-compose.yml"
$composeText = Get-Content $monitoringCompose -Raw
$composeText = [regex]::Replace($composeText, 'WAZUH_DASHBOARD_URL=http://[^:]+:5601', "WAZUH_DASHBOARD_URL=http://$HostAddress`:5601")
Set-Content -Path $monitoringCompose -Value $composeText -NoNewline

$selectedBackupDir = $null
if (-not $BundleStamp) {
    $latestBackup = Get-ChildItem $backupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestBackup) {
        $selectedBackupDir = $latestBackup.FullName
        $BundleStamp = $latestBackup.Name
    }
} else {
    $candidate = Join-Path $backupRoot $BundleStamp
    if (Test-Path $candidate) {
        $selectedBackupDir = $candidate
    }
}

$volumeBackupDir = if ($selectedBackupDir) { Join-Path $selectedBackupDir "docker-volumes" } else { $null }
if ($RestoreVolumeBackups -and $volumeBackupDir -and (Test-Path $volumeBackupDir)) {
    Get-ChildItem $volumeBackupDir -Filter "*.tgz" | Sort-Object Name | ForEach-Object {
        $volumeName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        Restore-DockerVolume -VolumeName $volumeName -ArchivePath $_.FullName
    }
}

$wazuhComposeWrapper = Join-Path $TargetRoot "scripts\windows\Invoke-WazuhSingleNodeCompose.ps1"
if (-not (Test-Path $wazuhComposeWrapper)) {
    throw "Secret-aware Wazuh compose wrapper not found at $wazuhComposeWrapper"
}

if (-not $SkipValidation) {
    powershell -ExecutionPolicy Bypass -File $wazuhComposeWrapper -ProjectRoot $TargetRoot config | Out-Null
    docker compose -f $monitoringCompose -p monitoring config | Out-Null
}

if (-not $SkipStart) {
    powershell -ExecutionPolicy Bypass -File $wazuhComposeWrapper -ProjectRoot $TargetRoot up -d | Out-Null
    docker compose -f $monitoringCompose -p monitoring up -d
}

Write-Host "Monitoring host deployed to $TargetRoot"
if ($RestoreVolumeBackups -and $BundleStamp) {
    Write-Host "Restored stateful Docker volumes from bundle stamp: $BundleStamp"
}
if ($SkipLocalSeed) {
    Write-Host "Local runtime secrets and .env files were not seeded into the target root."
}
if ($SkipValidation) {
    Write-Host "Config validation was skipped for staged rebuild use."
}
Write-Host "Next step for the Ubuntu sensor VM:"
Write-Host "  Clean bootstrap: powershell -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-SensorVmBootstrap.ps1 -VmAddress 192.168.1.6 -VmUser subash"
Write-Host "  Archive restore: sudo bash restore-sensor-vm.sh --archive /path/to/ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip $HostAddress"

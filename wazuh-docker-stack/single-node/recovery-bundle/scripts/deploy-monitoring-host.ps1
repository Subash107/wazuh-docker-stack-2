param(
    [Parameter(Mandatory = $true)]
    [string]$HostAddress,
    [string]$TargetRoot = "D:\Monitoring",
    [string]$BundleStamp,
    [switch]$RestoreVolumeBackups,
    [switch]$SkipStart
)

$ErrorActionPreference = "Stop"

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
$wazuhTarget = Join-Path $TargetRoot "wazuh-docker-stack\single-node"
$backupRoot = Join-Path $bundleRoot "backups\monitoring-host"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required on the target host."
}

New-Item -ItemType Directory -Force -Path $TargetRoot, $wazuhTarget | Out-Null

Copy-Item "$monitoringSource\docker-compose.yml", "$monitoringSource\alertmanager.yml", "$monitoringSource\prometheus.yml", "$monitoringSource\alert.rules.yml" -Destination $TargetRoot -Force
Copy-Tree "$monitoringSource\scripts" (Join-Path $TargetRoot "scripts")
Copy-Tree "$monitoringSource\secrets" (Join-Path $TargetRoot "secrets")

Copy-Item "$wazuhSource\docker-compose.yml", "$wazuhSource\generate-indexer-certs.yml", "$wazuhSource\README.md" -Destination $wazuhTarget -Force
Copy-Tree "$wazuhSource\config" (Join-Path $wazuhTarget "config")

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

docker compose -f (Join-Path $wazuhTarget "docker-compose.yml") -p single-node config | Out-Null
docker compose -f $monitoringCompose -p monitoring config | Out-Null

if (-not $SkipStart) {
    docker compose -f (Join-Path $wazuhTarget "docker-compose.yml") -p single-node up -d
    docker compose -f $monitoringCompose -p monitoring up -d
}

Write-Host "Monitoring host deployed to $TargetRoot"
if ($RestoreVolumeBackups -and $BundleStamp) {
    Write-Host "Restored stateful Docker volumes from bundle stamp: $BundleStamp"
}
Write-Host "Next step on the Ubuntu sensor VM:"
Write-Host "  sudo bash restore-sensor-vm.sh --archive /path/to/ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip $HostAddress"

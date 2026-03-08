param(
    [string]$VmAddress = "192.168.1.6",
    [string]$SshUser = "subash",
    [string]$SshPassword = $env:VM_SSH_PASSWORD,
    [string]$SudoPassword = $env:VM_SUDO_PASSWORD,
    [string]$Stamp = (Get-Date -Format "yyyyMMdd-HHmmss"),
    [string]$HostRoot
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SshPassword) -or [string]::IsNullOrWhiteSpace($SudoPassword)) {
    throw "Set VM_SSH_PASSWORD and VM_SUDO_PASSWORD in the environment, or pass -SshPassword and -SudoPassword."
}

function Copy-Tree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [string[]]$ExcludeDirs = @()
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $robocopyArgs = @(
        $Source,
        $Destination,
        "/E",
        "/NFL",
        "/NDL",
        "/NJH",
        "/NJS",
        "/NP"
    )

    if ($ExcludeDirs.Count -gt 0) {
        $robocopyArgs += "/XD"
        $robocopyArgs += $ExcludeDirs
    }

    & robocopy @robocopyArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed while copying '$Source' to '$Destination' (exit code $LASTEXITCODE)."
    }
}

function Export-DockerVolume {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeName,
        [Parameter(Mandatory = $true)]
        [string]$DestinationDir
    )

    $archiveName = "$VolumeName.tgz"
    $archivePath = Join-Path $DestinationDir $archiveName

    docker run --rm `
      -v "${VolumeName}:/from:ro" `
      -v "${DestinationDir}:/backup" `
      alpine:3.20 sh -lc "tar -C /from -czf /backup/$archiveName ."

    if (-not (Test-Path $archivePath)) {
        throw "Expected volume archive '$archivePath' was not created."
    }

    return $archivePath
}

$bundleRoot = Split-Path $PSScriptRoot -Parent
$backupRoot = Join-Path $bundleRoot "backups"
$monitoringBackup = Join-Path $backupRoot "monitoring-host\$Stamp"
$sensorBackup = Join-Path $backupRoot "sensor-vm"
$metadataDir = Join-Path $backupRoot "metadata\$Stamp"
$repoRoot = Split-Path $bundleRoot -Parent

if (-not $HostRoot) {
    $HostRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
}

New-Item -ItemType Directory -Force -Path $monitoringBackup, $sensorBackup, $metadataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $monitoringBackup "monitoring-stack"), (Join-Path $monitoringBackup "wazuh-single-node") | Out-Null
$dockerVolumeBackupDir = Join-Path $monitoringBackup "docker-volumes"
New-Item -ItemType Directory -Force -Path $dockerVolumeBackupDir | Out-Null

Copy-Item "$hostRoot\docker-compose.yml", "$hostRoot\alertmanager.yml", "$hostRoot\prometheus.yml", "$hostRoot\alert.rules.yml" -Destination (Join-Path $monitoringBackup "monitoring-stack") -Force
Copy-Tree -Source "$hostRoot\scripts" -Destination (Join-Path $monitoringBackup "monitoring-stack\scripts") -ExcludeDirs @("__pycache__")
Copy-Tree -Source "$hostRoot\secrets" -Destination (Join-Path $monitoringBackup "monitoring-stack\secrets")
Copy-Tree -Source $repoRoot -Destination (Join-Path $monitoringBackup "wazuh-single-node") -ExcludeDirs @("__pycache__", "recovery-bundle")

Copy-Item "$hostRoot\docker-compose.yml", "$hostRoot\alertmanager.yml", "$hostRoot\prometheus.yml", "$hostRoot\alert.rules.yml" -Destination (Join-Path $bundleRoot "blueprints\monitoring-host\monitoring-stack") -Force
Copy-Tree -Source "$hostRoot\scripts" -Destination (Join-Path $bundleRoot "blueprints\monitoring-host\monitoring-stack\scripts") -ExcludeDirs @("__pycache__")
Copy-Tree -Source "$hostRoot\secrets" -Destination (Join-Path $bundleRoot "blueprints\monitoring-host\monitoring-stack\secrets")
Copy-Item "$repoRoot\docker-compose.yml", "$repoRoot\generate-indexer-certs.yml", "$repoRoot\README.md" -Destination (Join-Path $bundleRoot "blueprints\monitoring-host\wazuh-single-node") -Force
Copy-Tree -Source "$repoRoot\config" -Destination (Join-Path $bundleRoot "blueprints\monitoring-host\wazuh-single-node\config")

$statefulVolumes = docker volume ls --format "{{.Name}}" | Where-Object { $_ -like "single-node_*" } | Sort-Object
$volumeManifest = @()

foreach ($volumeName in $statefulVolumes) {
    $archivePath = Export-DockerVolume -VolumeName $volumeName -DestinationDir $dockerVolumeBackupDir
    $volumeManifest += [pscustomobject]@{
        volume_name = $volumeName
        archive_path = $archivePath
    }
}

$volumeManifest |
    ConvertTo-Json -Depth 3 |
    Out-File -FilePath (Join-Path $metadataDir "docker-volume-manifest.json") -Encoding utf8

$archiveName = "ubuntu-subash-$VmAddress-$Stamp.tgz"
$containerScript = Join-Path $PSScriptRoot "backup-ubuntu-vm.container.sh"
Set-Content -Path (Join-Path $repoRoot ".bundle_stamp") -Value $Stamp

docker run --rm `
  --env "VM_ADDRESS=$VmAddress" `
  --env "SSH_USER=$SshUser" `
  --env "SSH_PASSWORD=$SshPassword" `
  --env "SUDO_PASSWORD=$SudoPassword" `
  --env "BACKUP_ARCHIVE_NAME=$archiveName" `
  -v "${sensorBackup}:/backup" `
  -v "${metadataDir}:/meta" `
  -v "${containerScript}:/backup.sh:ro" `
  alpine:3.20 sh -lc "tr -d '\r' < /backup.sh > /tmp/backup.sh && chmod +x /tmp/backup.sh && /tmp/backup.sh"

docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | Out-File -FilePath (Join-Path $metadataDir "windows-host-docker-ps.txt") -Encoding utf8
docker volume ls | Out-File -FilePath (Join-Path $metadataDir "windows-host-docker-volumes.txt") -Encoding utf8
docker compose -f "$hostRoot\docker-compose.yml" -p monitoring config | Out-File -FilePath (Join-Path $metadataDir "monitoring-compose-resolved.yml") -Encoding utf8
docker compose -f "$repoRoot\docker-compose.yml" -p single-node config | Out-File -FilePath (Join-Path $metadataDir "wazuh-single-node-compose-resolved.yml") -Encoding utf8

$hashInputs = @(
    (Join-Path $sensorBackup $archiveName)
)
$hashInputs += Get-ChildItem -File -Recurse $monitoringBackup | Select-Object -ExpandProperty FullName
$hashInputs += Get-ChildItem -File -Recurse $metadataDir | Where-Object { $_.Name -ne "sha256-manifest.csv" } | Select-Object -ExpandProperty FullName
$hashRows = foreach ($hashPath in ($hashInputs | Sort-Object -Unique)) {
    if (Test-Path $hashPath) {
        Get-FileHash -LiteralPath $hashPath -Algorithm SHA256
    }
}

$hashRows |
    Select-Object Path, Hash |
    ConvertTo-Csv -NoTypeInformation |
    Out-File -FilePath (Join-Path $metadataDir "sha256-manifest.csv") -Encoding utf8

Write-Host "Backup complete."
Write-Host "Monitoring host snapshot: $monitoringBackup"
Write-Host "Sensor VM archive: $(Join-Path $sensorBackup $archiveName)"
Write-Host "Metadata: $metadataDir"

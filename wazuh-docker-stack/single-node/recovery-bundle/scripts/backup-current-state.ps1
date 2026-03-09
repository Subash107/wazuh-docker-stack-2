param(
    [string]$VmAddress = "192.168.1.6",
    [string]$SshUser = "subash",
    [string]$SshPassword = "",
    [string]$SudoPassword = "",
    [string]$Stamp = (Get-Date -Format "yyyyMMdd-HHmmss"),
    [string]$HostRoot
)

$ErrorActionPreference = "Stop"

function Get-SecretValue {
    param(
        [string]$FilePath,
        [string]$EnvironmentName
    )

    if (Test-Path $FilePath) {
        return (Get-Content -Path $FilePath -Raw -Encoding UTF8).Trim()
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue.Trim()
    }

    return ""
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

if ([string]::IsNullOrWhiteSpace($SshPassword)) {
    $SshPassword = Get-SecretValue -FilePath (Join-Path $HostRoot "secrets\vm_ssh_password.txt") -EnvironmentName "VM_SSH_PASSWORD"
}
if ([string]::IsNullOrWhiteSpace($SudoPassword)) {
    $SudoPassword = Get-SecretValue -FilePath (Join-Path $HostRoot "secrets\vm_sudo_password.txt") -EnvironmentName "VM_SUDO_PASSWORD"
}
if ([string]::IsNullOrWhiteSpace($SshPassword) -or [string]::IsNullOrWhiteSpace($SudoPassword)) {
    throw "Populate $HostRoot\secrets\vm_ssh_password.txt and vm_sudo_password.txt, set the matching environment variables, or pass -SshPassword and -SudoPassword."
}

New-Item -ItemType Directory -Force -Path $monitoringBackup, $sensorBackup, $metadataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $monitoringBackup "monitoring-stack"), (Join-Path $monitoringBackup "wazuh-single-node") | Out-Null
$dockerVolumeBackupDir = Join-Path $monitoringBackup "docker-volumes"
New-Item -ItemType Directory -Force -Path $dockerVolumeBackupDir | Out-Null

Copy-Item "$hostRoot\.env.example", "$hostRoot\README.md", "$hostRoot\docker-compose.yml", "$hostRoot\alertmanager.yml", "$hostRoot\prometheus.yml", "$hostRoot\alert.rules.yml", "$hostRoot\blackbox.yml" -Destination (Join-Path $monitoringBackup "monitoring-stack") -Force
Copy-Tree -Source "$hostRoot\scripts" -Destination (Join-Path $monitoringBackup "monitoring-stack\scripts") -ExcludeDirs @("__pycache__")
Copy-Tree -Source "$hostRoot\docs" -Destination (Join-Path $monitoringBackup "monitoring-stack\docs") -ExcludeDirs @("__pycache__")
Copy-Tree -Source "$hostRoot\targets" -Destination (Join-Path $monitoringBackup "monitoring-stack\targets") -ExcludeDirs @("__pycache__")
Copy-Tree -Source "$hostRoot\secrets" -Destination (Join-Path $monitoringBackup "monitoring-stack\secrets")
if (Test-Path "$hostRoot\gateway") {
    Copy-Tree -Source "$hostRoot\gateway" -Destination (Join-Path $monitoringBackup "monitoring-stack\gateway")
}
Copy-Tree -Source $repoRoot -Destination (Join-Path $monitoringBackup "wazuh-single-node") -ExcludeDirs @("__pycache__", "recovery-bundle")

$legacyBlueprintRoot = Join-Path $bundleRoot "blueprints\monitoring-host"
if (Test-Path $legacyBlueprintRoot) {
    Remove-Item -Recurse -Force $legacyBlueprintRoot
}

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
$wazuhComposeWrapper = Join-Path $HostRoot "scripts\windows\Invoke-WazuhSingleNodeCompose.ps1"
if (-not (Test-Path $wazuhComposeWrapper)) {
    throw "Secret-aware Wazuh compose wrapper not found at $wazuhComposeWrapper"
}
powershell -ExecutionPolicy Bypass -File $wazuhComposeWrapper -ProjectRoot $HostRoot config | Out-File -FilePath (Join-Path $metadataDir "wazuh-single-node-compose-resolved.yml") -Encoding utf8

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

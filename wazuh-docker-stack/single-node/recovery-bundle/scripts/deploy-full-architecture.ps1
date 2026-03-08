param(
    [Parameter(Mandatory = $true)]
    [string]$HostAddress,
    [Parameter(Mandatory = $true)]
    [string]$VmAddress,
    [string]$VmUser = "subash",
    [string]$VmPassword = $env:VM_SSH_PASSWORD,
    [string]$SudoPassword = $env:VM_SUDO_PASSWORD,
    [string]$TargetRoot = "D:\Monitoring",
    [string]$BundleStamp,
    [string]$ArchivePath,
    [switch]$RestoreVolumeBackups
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($VmPassword) -or [string]::IsNullOrWhiteSpace($SudoPassword)) {
    throw "Set VM_SSH_PASSWORD and VM_SUDO_PASSWORD in the environment, or pass -VmPassword and -SudoPassword."
}

$scriptRoot = $PSScriptRoot
$bundleRoot = Split-Path $scriptRoot -Parent
$backupSensorRoot = Join-Path $bundleRoot "backups\sensor-vm"
$containerScript = Join-Path $scriptRoot "deploy-sensor-vm.container.sh"
$hostDeployScript = Join-Path $scriptRoot "deploy-monitoring-host.ps1"

if (-not $ArchivePath) {
    $latestArchive = Get-ChildItem $backupSensorRoot -Filter "*.tgz" |
        Where-Object { $_.Length -gt 0 } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestArchive) {
        throw "No VM archive was found under '$backupSensorRoot'."
    }

    $ArchivePath = $latestArchive.FullName
}

if (-not (Test-Path $ArchivePath)) {
    throw "VM archive '$ArchivePath' does not exist."
}

& $hostDeployScript -HostAddress $HostAddress -TargetRoot $TargetRoot -BundleStamp $BundleStamp -RestoreVolumeBackups:$RestoreVolumeBackups

$archiveLeaf = Split-Path $ArchivePath -Leaf
$restoreScript = Join-Path $scriptRoot "restore-sensor-vm.sh"

docker run --rm `
  --env "VM_ADDRESS=$VmAddress" `
  --env "SSH_USER=$VmUser" `
  --env "SSH_PASSWORD=$VmPassword" `
  --env "SUDO_PASSWORD=$SudoPassword" `
  --env "MANAGER_IP=$HostAddress" `
  --env "ARCHIVE_NAME=$archiveLeaf" `
  -v "${ArchivePath}:/payload/$archiveLeaf:ro" `
  -v "${restoreScript}:/payload/restore-sensor-vm.sh:ro" `
  -v "${containerScript}:/deploy-sensor-vm.sh:ro" `
  alpine:3.20 sh -lc "tr -d '\r' < /deploy-sensor-vm.sh > /tmp/deploy-sensor-vm.sh && chmod +x /tmp/deploy-sensor-vm.sh && /tmp/deploy-sensor-vm.sh"

Write-Host "Full architecture deployed."
Write-Host "Docker host address: $HostAddress"
Write-Host "Sensor VM restored on: $VmAddress"

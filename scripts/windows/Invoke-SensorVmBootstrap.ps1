[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VmAddress,
    [string]$VmUser = "subash",
    [string]$ManagerIp = "",
    [int]$ManagerPort = 1514,
    [string]$VmPassword = "",
    [string]$SudoPassword = "",
    [ValidateSet("full", "agent-only")]
    [string]$InstallProfile = "full",
    [string]$PiHoleWebPassword = "",
    [string]$PiHoleUpstreamDns = "192.168.1.1",
    [string]$LanCidr = "192.168.1.0/24",
    [string]$SensorIp = "",
    [string]$TimeZone = "UTC",
    [int]$PiHoleWebPort = 8080,
    [int]$MitmproxyProxyPort = 8082,
    [int]$MitmproxyWebPort = 8083,
    [string]$PiHoleImage = "pihole/pihole@sha256:ee348529cea9601df86ad94d62a39cad26117e1eac9e82d8876aa0ec7fe1ba27",
    [string]$MitmproxyImage = "mitmproxy/mitmproxy@sha256:743b6cdc817211d64bc269f5defacca8d14e76e647fc474e5c7244dbcb645141",
    [string]$ComposeProjectRoot = "/opt/monitoring-sensor",
    [string]$RemoteDir = "",
    [switch]$UseKeyAuth
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

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ([string]::IsNullOrWhiteSpace($VmPassword)) {
    $VmPassword = Get-SecretValue -FilePath (Join-Path $projectRoot "secrets\vm_ssh_password.txt") -EnvironmentName "VM_SSH_PASSWORD"
}
if ([string]::IsNullOrWhiteSpace($SudoPassword)) {
    $SudoPassword = Get-SecretValue -FilePath (Join-Path $projectRoot "secrets\vm_sudo_password.txt") -EnvironmentName "VM_SUDO_PASSWORD"
}
if ([string]::IsNullOrWhiteSpace($PiHoleWebPassword)) {
    $PiHoleWebPassword = Get-SecretValue -FilePath (Join-Path $projectRoot "secrets\pihole_web_password.txt") -EnvironmentName "PIHOLE_WEBPASSWORD"
}

$recoveryBundleRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "wazuh-docker-stack\single-node\recovery-bundle"
$deployScript = Join-Path $recoveryBundleRoot "scripts\deploy-sensor-vm.ps1"

if (-not (Test-Path $deployScript)) {
    throw "Canonical deployment entrypoint not found: $deployScript"
}

& $deployScript `
    -VmAddress $VmAddress `
    -VmUser $VmUser `
    -ManagerIp $ManagerIp `
    -ManagerPort $ManagerPort `
    -VmPassword $VmPassword `
    -SudoPassword $SudoPassword `
    -InstallProfile $InstallProfile `
    -PiHoleWebPassword $PiHoleWebPassword `
    -PiHoleUpstreamDns $PiHoleUpstreamDns `
    -LanCidr $LanCidr `
    -SensorIp $SensorIp `
    -TimeZone $TimeZone `
    -PiHoleWebPort $PiHoleWebPort `
    -MitmproxyProxyPort $MitmproxyProxyPort `
    -MitmproxyWebPort $MitmproxyWebPort `
    -PiHoleImage $PiHoleImage `
    -MitmproxyImage $MitmproxyImage `
    -ComposeProjectRoot $ComposeProjectRoot `
    -RemoteDir $RemoteDir `
    -UseKeyAuth:$UseKeyAuth

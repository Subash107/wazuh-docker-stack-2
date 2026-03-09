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

function Get-PreferredHostIPv4 {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) {
        throw "Could not determine the default IPv4 route."
    }

    $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1
    if (-not $address) {
        throw "Could not determine the local IPv4 address."
    }

    return $address.IPAddress
}

function Test-CommandAvailable {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

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

function ConvertTo-ShellLiteral {
    param([string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    $escaped = $Value.Replace("'", "'""'""'")
    return "'$escaped'"
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-Native {
    param(
        [string[]]$Command,
        [string]$FailureMessage
    )

    $exe = $Command[0]
    $args = @()
    if ($Command.Count -gt 1) {
        $args = $Command[1..($Command.Count - 1)]
    }

    & $exe @args
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

$scriptRoot = $PSScriptRoot
$bundleRoot = Split-Path $scriptRoot -Parent
$blueprintRoot = Join-Path $bundleRoot "blueprints\sensor-vm"
$containerScript = Join-Path $scriptRoot "bootstrap-sensor-vm.container.sh"
$monitoringRoot = (Resolve-Path (Join-Path $scriptRoot "..\..\..\..")).Path

if ([string]::IsNullOrWhiteSpace($VmPassword)) {
    $VmPassword = Get-SecretValue -FilePath (Join-Path $monitoringRoot "secrets\vm_ssh_password.txt") -EnvironmentName "VM_SSH_PASSWORD"
}
if ([string]::IsNullOrWhiteSpace($SudoPassword)) {
    $SudoPassword = Get-SecretValue -FilePath (Join-Path $monitoringRoot "secrets\vm_sudo_password.txt") -EnvironmentName "VM_SUDO_PASSWORD"
}
if ([string]::IsNullOrWhiteSpace($PiHoleWebPassword)) {
    $PiHoleWebPassword = Get-SecretValue -FilePath (Join-Path $monitoringRoot "secrets\pihole_web_password.txt") -EnvironmentName "PIHOLE_WEBPASSWORD"
}

if (-not (Test-Path $blueprintRoot)) {
    throw "Sensor blueprint directory was not found: $blueprintRoot"
}

if (-not (Test-Path (Join-Path $blueprintRoot "scripts\bootstrap-sensor-vm.sh"))) {
    throw "Canonical sensor bootstrap script is missing from the blueprint."
}

if (-not $ManagerIp) {
    $ManagerIp = Get-PreferredHostIPv4
}

if (-not $SensorIp) {
    $SensorIp = $VmAddress
}

if (-not $SudoPassword -and $VmPassword) {
    $SudoPassword = $VmPassword
}

if ($InstallProfile -eq "full" -and [string]::IsNullOrWhiteSpace($PiHoleWebPassword)) {
    throw "Pi-hole web password is required for the full sensor profile."
}

if ([string]::IsNullOrWhiteSpace($SudoPassword)) {
    throw "Set VM_SUDO_PASSWORD or pass -SudoPassword."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrWhiteSpace($RemoteDir)) {
    $RemoteDir = "/tmp/monitoring-sensor-bootstrap-$timestamp"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "monitoring-sensor-bootstrap-$timestamp"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$archivePath = Join-Path $tempRoot "sensor-blueprint.tgz"
$runtimeEnvPath = Join-Path $tempRoot "runtime.env"
$remoteBootstrapPath = Join-Path $tempRoot "bootstrap-remote.sh"

try {
    Invoke-Native -Command @(
        "tar",
        "-C", $blueprintRoot,
        "-czf", $archivePath,
        "."
    ) -FailureMessage "Failed to archive the sensor blueprint."

    $runtimeLines = @(
        "SUDO_PASSWORD=" + (ConvertTo-ShellLiteral $SudoPassword),
        "INSTALL_PROFILE=" + (ConvertTo-ShellLiteral $InstallProfile),
        "MANAGER_IP=" + (ConvertTo-ShellLiteral $ManagerIp),
        "MANAGER_PORT=" + (ConvertTo-ShellLiteral "$ManagerPort"),
        "SENSOR_IP=" + (ConvertTo-ShellLiteral $SensorIp),
        "LAN_CIDR=" + (ConvertTo-ShellLiteral $LanCidr),
        "TZ=" + (ConvertTo-ShellLiteral $TimeZone),
        "PIHOLE_WEBPASSWORD=" + (ConvertTo-ShellLiteral $PiHoleWebPassword),
        "PIHOLE_UPSTREAM_DNS=" + (ConvertTo-ShellLiteral $PiHoleUpstreamDns),
        "PIHOLE_WEB_PORT=" + (ConvertTo-ShellLiteral "$PiHoleWebPort"),
        "MITMPROXY_PROXY_PORT=" + (ConvertTo-ShellLiteral "$MitmproxyProxyPort"),
        "MITMPROXY_WEB_PORT=" + (ConvertTo-ShellLiteral "$MitmproxyWebPort"),
        "PIHOLE_IMAGE=" + (ConvertTo-ShellLiteral $PiHoleImage),
        "MITMPROXY_IMAGE=" + (ConvertTo-ShellLiteral $MitmproxyImage),
        "PIHOLE_LISTENING_MODE='all'",
        "COMPOSE_PROJECT_ROOT=" + (ConvertTo-ShellLiteral $ComposeProjectRoot)
    )
    Write-Utf8NoBom -Path $runtimeEnvPath -Content (($runtimeLines -join "`n") + "`n")

    $remoteBootstrapTemplate = @'
#!/bin/sh
set -eu

remote_root="${1:-__REMOTE_DIR__}"
mkdir -p "$remote_root/blueprint"
tar -xzf "$remote_root/sensor-blueprint.tgz" -C "$remote_root/blueprint"

. "$remote_root/runtime.env"

chmod +x "$remote_root/blueprint/scripts/bootstrap-sensor-vm.sh"
printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' env \
  INSTALL_PROFILE="$INSTALL_PROFILE" \
  MANAGER_IP="$MANAGER_IP" \
  MANAGER_PORT="$MANAGER_PORT" \
  SENSOR_IP="$SENSOR_IP" \
  LAN_CIDR="$LAN_CIDR" \
  TZ="$TZ" \
  PIHOLE_WEBPASSWORD="$PIHOLE_WEBPASSWORD" \
  PIHOLE_UPSTREAM_DNS="$PIHOLE_UPSTREAM_DNS" \
  PIHOLE_WEB_PORT="$PIHOLE_WEB_PORT" \
  MITMPROXY_PROXY_PORT="$MITMPROXY_PROXY_PORT" \
  MITMPROXY_WEB_PORT="$MITMPROXY_WEB_PORT" \
  PIHOLE_IMAGE="$PIHOLE_IMAGE" \
  MITMPROXY_IMAGE="$MITMPROXY_IMAGE" \
  PIHOLE_LISTENING_MODE="$PIHOLE_LISTENING_MODE" \
  COMPOSE_PROJECT_ROOT="$COMPOSE_PROJECT_ROOT" \
  "$remote_root/blueprint/scripts/bootstrap-sensor-vm.sh"
'@
    $remoteBootstrap = $remoteBootstrapTemplate.Replace("__REMOTE_DIR__", $RemoteDir)
    Write-Utf8NoBom -Path $remoteBootstrapPath -Content $remoteBootstrap

    if (-not $UseKeyAuth -and -not [string]::IsNullOrWhiteSpace($VmPassword)) {
        if (-not (Test-CommandAvailable "docker")) {
            throw "Password-based deployment needs Docker on the Windows host for the sshpass container helper."
        }

        Invoke-Native -Command @(
            "docker", "run", "--rm",
            "--env", "VM_ADDRESS=$VmAddress",
            "--env", "SSH_USER=$VmUser",
            "--env", "SSH_PASSWORD=$VmPassword",
            "--env", "REMOTE_DIR=$RemoteDir",
            "-v", "${archivePath}:/payload/sensor-blueprint.tgz:ro",
            "-v", "${runtimeEnvPath}:/payload/runtime.env:ro",
            "-v", "${remoteBootstrapPath}:/payload/bootstrap-remote.sh:ro",
            "-v", "${containerScript}:/deploy-sensor-vm.sh:ro",
            "alpine:3.20",
            "sh", "-lc",
            "tr -d '\r' < /deploy-sensor-vm.sh > /tmp/deploy-sensor-vm.sh && chmod +x /tmp/deploy-sensor-vm.sh && /tmp/deploy-sensor-vm.sh"
        ) -FailureMessage "Sensor deployment over password-based SSH failed."
    }
    else {
        if (-not (Test-CommandAvailable "ssh") -or -not (Test-CommandAvailable "scp")) {
            throw "Key-based deployment requires both ssh and scp on the Windows host."
        }

        Invoke-Native -Command @(
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "$VmUser@$VmAddress",
            "mkdir -p '$RemoteDir'"
        ) -FailureMessage "Failed to create the remote sensor bootstrap directory."

        Invoke-Native -Command @(
            "scp",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            $archivePath,
            $runtimeEnvPath,
            $remoteBootstrapPath,
            "${VmUser}@${VmAddress}:$RemoteDir/"
        ) -FailureMessage "Failed to upload the sensor bootstrap assets."

        Invoke-Native -Command @(
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "$VmUser@$VmAddress",
            "chmod +x '$RemoteDir/bootstrap-remote.sh' && sh '$RemoteDir/bootstrap-remote.sh' '$RemoteDir'"
        ) -FailureMessage "Sensor deployment over key-based SSH failed."
    }

    Write-Host "Sensor VM bootstrap completed."
    Write-Host "Manager IP: $ManagerIp"
    Write-Host "Sensor VM: $VmAddress"
    Write-Host "Profile: $InstallProfile"
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Recurse -Force $tempRoot
    }
}

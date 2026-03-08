param(
    [string]$HyperVConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "config\hyperv-provision.env"),
    [string]$BundleStamp,
    [string]$TargetRoot = "D:\Monitoring",
    [switch]$RestoreVolumeBackups,
    [switch]$ForceRecreateVm
)

$ErrorActionPreference = "Stop"

function Load-EnvConfig {
    param([string]$Path)
    $map = @{}
    foreach ($rawLine in Get-Content $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $map[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $map
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$Default
    )

    if ($Config.ContainsKey($Key) -and $Config[$Key]) {
        return $Config[$Key]
    }

    return $Default
}

function Get-PreferredHostIPv4 {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) {
        throw "Could not determine the default IPv4 route for the host."
    }

    $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1
    if (-not $address) {
        throw "Could not determine the host IPv4 address."
    }

    return $address.IPAddress
}

if (-not (Test-Path $HyperVConfigPath)) {
    throw "Hyper-V config file '$HyperVConfigPath' was not found."
}

$config = Load-EnvConfig -Path $HyperVConfigPath
$configuredManagerIp = Get-ConfigValue -Config $config -Key "MANAGER_IP" -Default $null
$managerIp = if ($configuredManagerIp) { $configuredManagerIp } else { Get-PreferredHostIPv4 }

& (Join-Path $PSScriptRoot "deploy-monitoring-host.ps1") `
    -HostAddress $managerIp `
    -TargetRoot $TargetRoot `
    -BundleStamp $BundleStamp `
    -RestoreVolumeBackups:$RestoreVolumeBackups

& (Join-Path $PSScriptRoot "new-hyperv-sensor-vm.ps1") `
    -ConfigPath $HyperVConfigPath `
    -BundleStamp $BundleStamp `
    -ManagerIp $managerIp `
    -ForceRecreate:$ForceRecreateVm

Write-Host "Full Hyper-V architecture deployment finished."
Write-Host "Manager host IP: $managerIp"

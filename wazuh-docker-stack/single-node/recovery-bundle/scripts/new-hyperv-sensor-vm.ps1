param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "config\hyperv-provision.env"),
    [string]$BundleStamp,
    [string]$ManagerIp,
    [switch]$ForceRecreate,
    [switch]$SkipRestore
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Load-EnvConfig {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Config file '$Path' was not found."
    }

    $map = @{}
    foreach ($rawLine in Get-Content $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            throw "Invalid config line '$rawLine' in '$Path'."
        }

        $map[$parts[0].Trim()] = $parts[1].Trim()
    }

    return $map
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$Default,
        [switch]$Required
    )

    if ($Config.ContainsKey($Key) -and $Config[$Key]) {
        return $Config[$Key]
    }
    if ($Required) {
        throw "Config key '$Key' is required."
    }

    return $Default
}

function Get-SecretValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [switch]$Required
    )

    if (-not $Config.ContainsKey($Key) -or -not $Config[$Key]) {
        if ($Required) {
            throw "Config key '$Key' is required."
        }
        return $null
    }

    $path = $Config[$Key]
    if (-not (Test-Path $path)) {
        throw "Secret file '$path' was not found."
    }

    return (Get-Content $path -Raw).Trim()
}

function Get-BundleRoot {
    return (Split-Path $PSScriptRoot -Parent)
}

function Get-RepoRoot {
    return (Split-Path (Get-BundleRoot) -Parent)
}

function Get-LatestBundleStamp {
    $stampPath = Join-Path (Get-RepoRoot) ".bundle_stamp"
    if (-not (Test-Path $stampPath)) {
        throw "Bundle stamp file '$stampPath' was not found."
    }

    return (Get-Content $stampPath -Raw).Trim()
}

function Get-SensorArchivePath {
    param([string]$Stamp)

    $sensorRoot = Join-Path (Get-BundleRoot) "backups\sensor-vm"
    $archive = Get-ChildItem $sensorRoot -Filter "*-$Stamp.tgz" | Select-Object -First 1
    if (-not $archive) {
        throw "No sensor VM archive was found for bundle stamp '$Stamp'."
    }

    return $archive.FullName
}

function Get-PreferredNetAdapter {
    param(
        [string]$AdapterName
    )

    if ($AdapterName) {
        $named = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
        if (-not $named) {
            throw "Network adapter '$AdapterName' was not found."
        }

        return $named
    }

    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if ($defaultRoute) {
        $candidate = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.Status -eq "Up") {
            return $candidate
        }
    }

    $physical = Get-NetAdapter -Physical | Where-Object Status -eq "Up" | Select-Object -First 1
    if ($physical) {
        return $physical
    }

    throw "Could not find an active physical network adapter."
}

function Get-OrCreateExternalSwitch {
    param(
        [string]$SwitchName,
        [bool]$AutoCreate,
        [string]$AdapterName
    )

    if ($SwitchName) {
        $named = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if (-not $named) {
            throw "Hyper-V switch '$SwitchName' was not found."
        }

        return $named
    }

    $existing = Get-VMSwitch | Where-Object SwitchType -eq "External" | Select-Object -First 1
    if ($existing) {
        return $existing
    }

    if (-not $AutoCreate) {
        throw "No external Hyper-V switch exists and AUTO_CREATE_EXTERNAL_SWITCH is disabled."
    }

    $adapter = Get-PreferredNetAdapter -AdapterName $AdapterName
    $newSwitchName = "External-" + (($adapter.Name -replace '[^A-Za-z0-9-]', '-') -replace '-+', '-').Trim('-')
    $created = New-VMSwitch -Name $newSwitchName -NetAdapterName $adapter.Name -AllowManagementOS $true
    return $created
}

function Get-AdapterForSwitch {
    param([Microsoft.HyperV.PowerShell.VMSwitch]$Switch)

    if ($Switch.NetAdapterInterfaceDescription) {
        $adapter = Get-NetAdapter | Where-Object InterfaceDescription -eq $Switch.NetAdapterInterfaceDescription | Select-Object -First 1
        if ($adapter) {
            return $adapter
        }
    }

    return Get-PreferredNetAdapter -AdapterName $null
}

function Get-HostIPv4 {
    param([Microsoft.Management.Infrastructure.CimInstance]$Adapter)

    $address = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Sort-Object SkipAsSource, PrefixLength -Descending |
        Select-Object -First 1

    if (-not $address) {
        throw "Could not determine an IPv4 address for adapter '$($Adapter.Name)'."
    }

    return $address.IPAddress
}

function Ensure-UbuntuBaseDisk {
    param(
        [string]$ImageUrl,
        [string]$CacheRoot
    )

    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null

    $imageName = Split-Path $ImageUrl -Leaf
    $downloadPath = Join-Path $CacheRoot $imageName
    $extractRoot = Join-Path $CacheRoot "extracted"
    $canonicalName = if ($imageName -match '\.tar\.gz$') { [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($imageName)) } else { [System.IO.Path]::GetFileNameWithoutExtension($imageName) }

    $existingDisk = Get-ChildItem $CacheRoot -Filter "$canonicalName*" | Where-Object { $_.Extension -in ".vhd", ".vhdx" } | Select-Object -First 1
    if ($existingDisk) {
        return $existingDisk.FullName
    }

    if (-not (Test-Path $downloadPath)) {
        Invoke-WebRequest -Uri $ImageUrl -OutFile $downloadPath
    }

    if (Test-Path $extractRoot) {
        Remove-Item -Recurse -Force $extractRoot
    }
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

    tar -xzf $downloadPath -C $extractRoot

    $vhd = Get-ChildItem $extractRoot -Recurse -Include *.vhd, *.vhdx | Select-Object -First 1
    if (-not $vhd) {
        throw "Downloaded Ubuntu image '$downloadPath' did not contain a VHD or VHDX."
    }

    $canonicalPath = Join-Path $CacheRoot $vhd.Name
    Copy-Item $vhd.FullName $canonicalPath -Force
    Remove-Item -Recurse -Force $extractRoot
    return $canonicalPath
}

function Wait-ForVmIPv4 {
    param(
        [string]$VmName,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ips = (Get-VMNetworkAdapter -VMName $VmName).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' }
        if ($ips) {
            return $ips[0]
        }

        Start-Sleep -Seconds 10
    }

    throw "Timed out waiting for VM '$VmName' to obtain an IPv4 address."
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script from an elevated PowerShell session."
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell cmdlets are not available on this host."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required for the cloud-init ISO build and remote restore steps."
}

$config = Load-EnvConfig -Path $ConfigPath
$bundleRoot = Get-BundleRoot
$vmName = Get-ConfigValue -Config $config -Key "VM_NAME" -Default "monitoring-sensor"
$vmHostName = Get-ConfigValue -Config $config -Key "VM_HOSTNAME" -Default $vmName
$vmRoot = Join-Path (Get-ConfigValue -Config $config -Key "VM_DATA_ROOT" -Default (Join-Path $bundleRoot "hyperv")) $vmName
$vmCpuCount = [int](Get-ConfigValue -Config $config -Key "VM_CPU_COUNT" -Default "2")
$vmMemoryStartupMb = [int](Get-ConfigValue -Config $config -Key "VM_MEMORY_STARTUP_MB" -Default "4096")
$vmGeneration = [int](Get-ConfigValue -Config $config -Key "VM_GENERATION" -Default "2")
$dhcpWaitSeconds = [int](Get-ConfigValue -Config $config -Key "DHCP_WAIT_SECONDS" -Default "900")
$switchName = Get-ConfigValue -Config $config -Key "VM_SWITCH_NAME" -Default $null
$autoCreateSwitch = [System.Convert]::ToBoolean((Get-ConfigValue -Config $config -Key "AUTO_CREATE_EXTERNAL_SWITCH" -Default "true"))
$switchAdapterName = Get-ConfigValue -Config $config -Key "SWITCH_ADAPTER_NAME" -Default $null
$imageUrl = Get-ConfigValue -Config $config -Key "UBUNTU_IMAGE_URL" -Required
$imageCacheRoot = Get-ConfigValue -Config $config -Key "IMAGE_CACHE_ROOT" -Default (Join-Path $bundleRoot "cache\ubuntu")
$vmAdminUser = Get-ConfigValue -Config $config -Key "VM_ADMIN_USER" -Default "subash"
$vmAdminPasswordFile = Get-ConfigValue -Config $config -Key "VM_ADMIN_PASSWORD_FILE" -Required
$vmAdminPassword = Get-SecretValue -Config $config -Key "VM_ADMIN_PASSWORD_FILE" -Required
$selectedStamp = if ($BundleStamp) { $BundleStamp } else { Get-LatestBundleStamp }
$sensorArchive = Get-SensorArchivePath -Stamp $selectedStamp

$switch = Get-OrCreateExternalSwitch -SwitchName $switchName -AutoCreate:$autoCreateSwitch -AdapterName $switchAdapterName
$switchAdapter = Get-AdapterForSwitch -Switch $switch
$resolvedManagerIp = if ($ManagerIp) { $ManagerIp } elseif (Get-ConfigValue -Config $config -Key "MANAGER_IP" -Default $null) { Get-ConfigValue -Config $config -Key "MANAGER_IP" -Default $null } else { Get-HostIPv4 -Adapter $switchAdapter }
$baseDiskPath = Ensure-UbuntuBaseDisk -ImageUrl $imageUrl -CacheRoot $imageCacheRoot

if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    if (-not $ForceRecreate) {
        throw "A VM named '$vmName' already exists. Re-run with -ForceRecreate to replace it."
    }

    Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-VM -Name $vmName -Force
    if (Test-Path $vmRoot) {
        Remove-Item -Recurse -Force $vmRoot
    }
}

New-Item -ItemType Directory -Force -Path $vmRoot | Out-Null
$osDiskPath = Join-Path $vmRoot ($vmName + "-os" + [System.IO.Path]::GetExtension($baseDiskPath))
Copy-Item $baseDiskPath $osDiskPath -Force

$seedIsoPath = Join-Path $vmRoot "$vmName-seed.iso"
& (Join-Path $PSScriptRoot "build-cloud-init-seed.ps1") `
    -OutputIsoPath $seedIsoPath `
    -HostName $vmHostName `
    -InstanceId ("$vmName-$selectedStamp") `
    -AdminUser $vmAdminUser `
    -PasswordFile $vmAdminPasswordFile

New-VM -Name $vmName -Generation $vmGeneration -MemoryStartupBytes ($vmMemoryStartupMb * 1MB) -SwitchName $switch.Name -VHDPath $osDiskPath -Path $vmRoot | Out-Null
Set-VMProcessor -VMName $vmName -Count $vmCpuCount
Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false
Set-VM -VMName $vmName -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
Add-VMDvdDrive -VMName $vmName -Path $seedIsoPath | Out-Null

Start-VM -Name $vmName | Out-Null
$vmIp = Wait-ForVmIPv4 -VmName $vmName -TimeoutSeconds $dhcpWaitSeconds

try {
    if (-not $SkipRestore) {
        $containerScript = Join-Path $PSScriptRoot "deploy-sensor-vm.container.sh"
        $restoreScript = Join-Path $PSScriptRoot "restore-sensor-vm.sh"
        $archiveLeaf = Split-Path $sensorArchive -Leaf

        docker run --rm `
          --env "VM_ADDRESS=$vmIp" `
          --env "SSH_USER=$vmAdminUser" `
          --env "SSH_PASSWORD=$vmAdminPassword" `
          --env "SUDO_PASSWORD=$vmAdminPassword" `
          --env "MANAGER_IP=$resolvedManagerIp" `
          --env "ARCHIVE_NAME=$archiveLeaf" `
          -v "${sensorArchive}:/payload/$archiveLeaf:ro" `
          -v "${restoreScript}:/payload/restore-sensor-vm.sh:ro" `
          -v "${containerScript}:/deploy-sensor-vm.sh:ro" `
          alpine:3.20 sh -lc "tr -d '\r' < /deploy-sensor-vm.sh > /tmp/deploy-sensor-vm.sh && chmod +x /tmp/deploy-sensor-vm.sh && /tmp/deploy-sensor-vm.sh"
    }
}
finally {
    Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue | Remove-VMDvdDrive -ErrorAction SilentlyContinue
    if (Test-Path $seedIsoPath) {
        Remove-Item -Force $seedIsoPath -ErrorAction SilentlyContinue
    }
}

Write-Host "Hyper-V sensor VM provisioned."
Write-Host "VM name: $vmName"
Write-Host "Switch: $($switch.Name)"
Write-Host "Manager IP: $resolvedManagerIp"
Write-Host "VM IPv4: $vmIp"
Write-Host "Bundle stamp: $selectedStamp"

[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$RecoveryBundleRoot = "",
    [string]$VaultPath = "",
    [string]$Passphrase = "",
    [string]$HostAddress = "",
    [string]$DrillRoot = "",
    [string]$BundleStamp = "",
    [switch]$RestoreVolumeBackups,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

if ($RestoreVolumeBackups -and -not $Apply) {
    throw "-RestoreVolumeBackups is only supported together with -Apply."
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-EnvMap {
    param([string]$Path)

    $values = @{}
    if (-not (Test-Path $Path)) {
        return $values
    }

    foreach ($line in Get-Content -Path $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }

        $name, $value = $line -split "=", 2
        if (-not $name) {
            continue
        }

        $values[$name.Trim()] = if ($null -ne $value) { $value.Trim() } else { "" }
    }

    return $values
}

function Invoke-CapturedCommand {
    param(
        [string]$Label,
        [string[]]$Command,
        [string]$OutputFile
    )

    $exe = $Command[0]
    $args = @()
    if ($Command.Count -gt 1) {
        $args = $Command[1..($Command.Count - 1)]
    }

    $previousNativePref = $null
    $nativePrefExists = $null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)
    $previousErrorActionPreference = $ErrorActionPreference

    if ($nativePrefExists) {
        $previousNativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $ErrorActionPreference = "Continue"
        $output = & $exe @args 2>&1
        $exitCode = $LASTEXITCODE
        $output | Set-Content -Path $OutputFile

        if ($exitCode -ne 0) {
            throw "$Label failed. Review $OutputFile"
        }

        return $output
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePrefExists) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePref
        }
    }
}

function Get-ContainerNetworkName {
    param([string]$ContainerName)

    $networkName = (& docker inspect $ContainerName --format "{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($networkName)) {
        throw "Could not determine the Docker network for '$ContainerName'."
    }

    return $networkName
}

function Get-LatestArtifactDirectory {
    param(
        [string]$DeploymentsRoot,
        [string]$Prefix
    )

    if (-not (Test-Path $DeploymentsRoot)) {
        return ""
    }

    $latest = Get-ChildItem -Path $DeploymentsRoot -Directory -Filter "$Prefix*" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latest) {
        return $latest.FullName
    }

    return ""
}

function Resolve-RootRelativePath {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $Root $Path
}

function Assert-CleanDockerHostForApply {
    $existingContainers = @{}
    foreach ($name in (& docker ps -a --format "{{.Names}}" 2>$null)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $existingContainers[$name.Trim()] = $true
        }
    }

    $conflictingContainers = @(
        "prometheus",
        "blackbox-exporter",
        "alertmanager",
        "wazuh-alert-forwarder",
        "monitoring-service-index",
        "monitoring-gateway",
        "single-node-wazuh-indexer-1",
        "single-node-wazuh-manager-1",
        "single-node-wazuh-dashboard-1"
    ) | Where-Object { $existingContainers.ContainsKey($_) }

    if ($conflictingContainers.Count -gt 0) {
        throw "Refusing -Apply because the Docker host is not clean. Existing containers: $($conflictingContainers -join ', ')"
    }

    $conflictingVolumes = @()
    foreach ($volumeName in (& docker volume ls --format "{{.Name}}" 2>$null)) {
        if ($volumeName -like "single-node_*" -or $volumeName -eq "single-node_wazuh_logs") {
            $conflictingVolumes += $volumeName
        }
    }

    if ($conflictingVolumes.Count -gt 0) {
        throw "Refusing -Apply because Wazuh recovery volumes already exist: $($conflictingVolumes -join ', ')"
    }

    $conflictingNetworks = @()
    foreach ($networkName in (& docker network ls --format "{{.Name}}" 2>$null)) {
        if ($networkName -in @("monitoring_default", "single-node_default")) {
            $conflictingNetworks += $networkName
        }
    }

    if ($conflictingNetworks.Count -gt 0) {
        throw "Refusing -Apply because recovery networks already exist: $($conflictingNetworks -join ', ')"
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$projectRootResolved = (Resolve-Path $ProjectRoot).Path
$RecoveryBundleRoot = Resolve-RootRelativePath -Path $RecoveryBundleRoot -Root $projectRootResolved
$VaultPath = Resolve-RootRelativePath -Path $VaultPath -Root $projectRootResolved
$DrillRoot = Resolve-RootRelativePath -Path $DrillRoot -Root $projectRootResolved

if ([string]::IsNullOrWhiteSpace($RecoveryBundleRoot)) {
    $RecoveryBundleRoot = Join-Path $projectRootResolved "wazuh-docker-stack\single-node\recovery-bundle"
}
if ([string]::IsNullOrWhiteSpace($VaultPath)) {
    $VaultPath = Join-Path $projectRootResolved "local\secret-vault\monitoring-secrets.enc.json"
}
if ([string]::IsNullOrWhiteSpace($HostAddress)) {
    $envPath = Join-Path $projectRootResolved ".env"
    $envExamplePath = Join-Path $projectRootResolved ".env.example"
    $envMap = if (Test-Path $envPath) { Read-EnvMap -Path $envPath } else { Read-EnvMap -Path $envExamplePath }
    if ($envMap.ContainsKey("MONITORING_GATEWAY_HOST") -and -not [string]::IsNullOrWhiteSpace($envMap["MONITORING_GATEWAY_HOST"])) {
        $HostAddress = $envMap["MONITORING_GATEWAY_HOST"]
    }
    else {
        $HostAddress = "192.168.1.3"
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrWhiteSpace($DrillRoot)) {
    $DrillRoot = Join-Path $projectRootResolved "logs\rebuild-drills\bare-metal-$timestamp"
}

$deployScript = Join-Path $RecoveryBundleRoot "scripts\deploy-monitoring-host.ps1"
$vaultImportScript = Join-Path $projectRootResolved "scripts\windows\Invoke-SecretVaultImport.ps1"
$workspaceRoot = Join-Path $DrillRoot "workspace"
$deploymentsRoot = Join-Path $workspaceRoot "logs\deployments"
$summaryPath = Join-Path $DrillRoot "summary.txt"
$curlHelperImage = "curlimages/curl@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69"

foreach ($requiredPath in @($RecoveryBundleRoot, $deployScript, $vaultImportScript)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required path not found: $requiredPath"
    }
}

if (-not (Test-Path $VaultPath)) {
    throw "Vault file not found at $VaultPath"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required for the bare-metal rebuild drill."
}

if ($Apply) {
    Assert-CleanDockerHostForApply
}

New-Item -ItemType Directory -Force -Path $DrillRoot | Out-Null

$deployCommand = @(
    "powershell", "-ExecutionPolicy", "Bypass",
    "-File", $deployScript,
    "-HostAddress", $HostAddress,
    "-TargetRoot", $workspaceRoot,
    "-SkipStart",
    "-SkipLocalSeed",
    "-SkipValidation"
)
if (-not [string]::IsNullOrWhiteSpace($BundleStamp)) {
    $deployCommand += @("-BundleStamp", $BundleStamp)
}
if ($RestoreVolumeBackups) {
    $deployCommand += "-RestoreVolumeBackups"
}

Invoke-CapturedCommand -Label "stage recovery bundle host" -Command $deployCommand -OutputFile (Join-Path $DrillRoot "stage-host.txt") | Out-Null

$importCommand = @(
    "powershell", "-ExecutionPolicy", "Bypass",
    "-File", $vaultImportScript,
    "-ProjectRoot", $workspaceRoot,
    "-VaultPath", $VaultPath
)
if (-not [string]::IsNullOrWhiteSpace($Passphrase)) {
    $importCommand += @("-Passphrase", $Passphrase)
}

Invoke-CapturedCommand -Label "import secret vault" -Command $importCommand -OutputFile (Join-Path $DrillRoot "secret-vault-import.txt") | Out-Null

$wazuhRolloutScript = Join-Path $workspaceRoot "scripts\windows\Invoke-WazuhSingleNodeRollout.ps1"
$monitoringRolloutScript = Join-Path $workspaceRoot "scripts\windows\Invoke-MonitoringPhase1Rollout.ps1"

foreach ($requiredPath in @($wazuhRolloutScript, $monitoringRolloutScript)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required staged script not found: $requiredPath"
    }
}

$wazuhCommand = @(
    "powershell", "-ExecutionPolicy", "Bypass",
    "-File", $wazuhRolloutScript,
    "-ProjectRoot", $workspaceRoot
)
if ($Apply) {
    $wazuhCommand += @("-Apply", "-SkipPreBackup")
}
Invoke-CapturedCommand -Label "Wazuh rebuild drill" -Command $wazuhCommand -OutputFile (Join-Path $DrillRoot "wazuh-rollout.txt") | Out-Null

$monitoringCommand = @(
    "powershell", "-ExecutionPolicy", "Bypass",
    "-File", $monitoringRolloutScript,
    "-ProjectRoot", $workspaceRoot
)
if ($Apply) {
    $monitoringCommand += "-Apply"
}
Invoke-CapturedCommand -Label "Monitoring rebuild drill" -Command $monitoringCommand -OutputFile (Join-Path $DrillRoot "monitoring-rollout.txt") | Out-Null

if ($Apply) {
    $gatewayUserPath = Join-Path $workspaceRoot "secrets\gateway_admin_username.txt"
    $gatewayPasswordPath = Join-Path $workspaceRoot "secrets\gateway_admin_password.txt"
    if (-not (Test-Path $gatewayUserPath) -or -not (Test-Path $gatewayPasswordPath)) {
        throw "Gateway admin username/password files are required for the post-apply gateway probe."
    }

    $gatewayUser = (Get-Content -Path $gatewayUserPath -Raw -Encoding UTF8).Trim()
    $gatewayPassword = (Get-Content -Path $gatewayPasswordPath -Raw -Encoding UTF8).Trim()
    $networkName = Get-ContainerNetworkName -ContainerName "monitoring-gateway"

    Invoke-CapturedCommand -Label "gateway healthz probe" -Command @(
        "docker", "exec",
        "monitoring-gateway",
        "/bin/sh", "-lc",
        "wget --no-check-certificate -q -O - https://127.0.0.1:9443/healthz"
    ) -OutputFile (Join-Path $DrillRoot "gateway-healthz.txt") | Out-Null

    Invoke-CapturedCommand -Label "gateway Prometheus auth probe" -Command @(
        "docker", "run", "--rm",
        "--network", $networkName,
        $curlHelperImage,
        "-ksS",
        "-u", "$gatewayUser`:$gatewayPassword",
        "https://monitoring-gateway:9443/prometheus/-/healthy"
    ) -OutputFile (Join-Path $DrillRoot "gateway-prometheus-probe.txt") | Out-Null

    Invoke-CapturedCommand -Label "service index health probe" -Command @(
        "docker", "run", "--rm",
        "--network", $networkName,
        $curlHelperImage,
        "-fsS",
        "http://monitoring-service-index:9088/healthz"
    ) -OutputFile (Join-Path $DrillRoot "service-index-healthz.txt") | Out-Null
}

$monitoringArtifact = Get-LatestArtifactDirectory -DeploymentsRoot $deploymentsRoot -Prefix "phase1-"
$wazuhArtifact = Get-LatestArtifactDirectory -DeploymentsRoot $deploymentsRoot -Prefix "wazuh-rollout-"
$sensorBackupRoot = Join-Path $RecoveryBundleRoot "backups\sensor-vm"
$latestSensorArchive = Get-ChildItem -Path $sensorBackupRoot -File -Filter "*.tgz" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$modeLabel = if ($Apply) { "apply" } else { "validation" }

$summaryLines = @(
    "Bare-metal rebuild drill summary",
    "mode=$modeLabel",
    "project_root=$projectRootResolved",
    "recovery_bundle_root=$RecoveryBundleRoot",
    "vault_path=$VaultPath",
    "workspace_root=$workspaceRoot",
    "host_address=$HostAddress",
    "monitoring_artifacts=$monitoringArtifact",
    "wazuh_artifacts=$wazuhArtifact",
    "latest_sensor_archive=$(if ($latestSensorArchive) { $latestSensorArchive.FullName } else { '' })",
    "next_sensor_bootstrap=powershell -ExecutionPolicy Bypass -File $workspaceRoot\\scripts\\windows\\Invoke-SensorVmBootstrap.ps1 -VmAddress 192.168.1.6 -VmUser subash",
    "next_sensor_restore=sudo bash restore-sensor-vm.sh --archive /path/to/ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip $HostAddress"
)
Write-Utf8NoBom -Path $summaryPath -Content (($summaryLines -join "`r`n") + "`r`n")

Write-Host "Bare-metal rebuild drill completed successfully."
Write-Host "Mode: $modeLabel"
Write-Host "Artifacts: $DrillRoot"
Write-Host "Staged workspace: $workspaceRoot"
if ($monitoringArtifact) {
    Write-Host "Monitoring rollout artifacts: $monitoringArtifact"
}
if ($wazuhArtifact) {
    Write-Host "Wazuh rollout artifacts: $wazuhArtifact"
}

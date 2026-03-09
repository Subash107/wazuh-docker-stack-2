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

function Assert-PathExists {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path $Path)) {
        throw "$Label not found: $Path"
    }
}

function Assert-ArchiveContainsEntries {
    param(
        [string]$ArchivePath,
        [string[]]$Entries,
        [string[]]$RequiredExact,
        [string[]]$RequiredPrefixes
    )

    foreach ($requiredEntry in $RequiredExact) {
        if ($requiredEntry -notin $Entries) {
            throw "Sensor archive '$ArchivePath' is missing required entry '$requiredEntry'. Refresh the sensor backup before rerunning the drill."
        }
    }

    foreach ($requiredPrefix in $RequiredPrefixes) {
        if (-not ($Entries | Where-Object { $_.StartsWith($requiredPrefix) })) {
            throw "Sensor archive '$ArchivePath' is missing required content under '$requiredPrefix'. Refresh the sensor backup before rerunning the drill."
        }
    }
}

function Invoke-SensorBootstrapValidation {
    param(
        [string]$WorkspaceRoot,
        [string]$DrillRoot,
        [string]$HostAddress
    )

    $bootstrapScript = Join-Path $WorkspaceRoot "scripts\windows\Invoke-SensorVmBootstrap.ps1"
    $deployScript = Join-Path $WorkspaceRoot "wazuh-docker-stack\single-node\recovery-bundle\scripts\deploy-sensor-vm.ps1"
    $containerScript = Join-Path $WorkspaceRoot "wazuh-docker-stack\single-node\recovery-bundle\scripts\bootstrap-sensor-vm.container.sh"
    $blueprintRoot = Join-Path $WorkspaceRoot "wazuh-docker-stack\single-node\recovery-bundle\blueprints\sensor-vm"
    $composeFile = Join-Path $blueprintRoot "compose\docker-compose.yml"
    $sensorEnvExamplePath = Join-Path $blueprintRoot "config\sensor.env.example"
    $ossecTemplatePath = Join-Path $blueprintRoot "config\ossec.conf.template"
    $bootstrapShellScript = Join-Path $blueprintRoot "scripts\bootstrap-sensor-vm.sh"
    $composeCtlScript = Join-Path $blueprintRoot "bin\composectl.sh"
    $firewallScript = Join-Path $blueprintRoot "bin\firewall.sh"
    $composeUnitPath = Join-Path $blueprintRoot "systemd\monitoring-sensor-compose.service"
    $firewallUnitPath = Join-Path $blueprintRoot "systemd\monitoring-sensor-firewall.service"
    $sensorEnvPath = Join-Path $DrillRoot "sensor-bootstrap.env"
    $sensorComposeOutputPath = Join-Path $DrillRoot "sensor-bootstrap-compose.txt"
    $sensorBlueprintArchivePath = Join-Path $DrillRoot "sensor-blueprint.tgz"
    $sensorBlueprintArchiveListingPath = Join-Path $DrillRoot "sensor-blueprint-archive.txt"
    $renderedOssecPath = Join-Path $DrillRoot "sensor-ossec-rendered.xml"

    foreach ($requiredPath in @(
        $bootstrapScript,
        $deployScript,
        $containerScript,
        $composeFile,
        $sensorEnvExamplePath,
        $ossecTemplatePath,
        $bootstrapShellScript,
        $composeCtlScript,
        $firewallScript,
        $composeUnitPath,
        $firewallUnitPath,
        (Join-Path $WorkspaceRoot "secrets\vm_ssh_password.txt"),
        (Join-Path $WorkspaceRoot "secrets\vm_sudo_password.txt"),
        (Join-Path $WorkspaceRoot "secrets\pihole_web_password.txt")
    )) {
        Assert-PathExists -Path $requiredPath -Label "Required staged sensor asset"
    }

    $sensorEnvMap = Read-EnvMap -Path $sensorEnvExamplePath
    $piholePassword = (Get-Content -Path (Join-Path $WorkspaceRoot "secrets\pihole_web_password.txt") -Raw -Encoding UTF8).Trim()

    $sensorRuntimeLines = @(
        "TZ=$(if ($sensorEnvMap.ContainsKey('TZ')) { $sensorEnvMap['TZ'] } else { 'UTC' })",
        "PIHOLE_WEBPASSWORD=$piholePassword",
        "PIHOLE_UPSTREAM_DNS=$(if ($sensorEnvMap.ContainsKey('PIHOLE_UPSTREAM_DNS')) { $sensorEnvMap['PIHOLE_UPSTREAM_DNS'] } else { '192.168.1.1' })",
        "PIHOLE_WEB_PORT=$(if ($sensorEnvMap.ContainsKey('PIHOLE_WEB_PORT')) { $sensorEnvMap['PIHOLE_WEB_PORT'] } else { '8080' })",
        "MITMPROXY_PROXY_PORT=$(if ($sensorEnvMap.ContainsKey('MITMPROXY_PROXY_PORT')) { $sensorEnvMap['MITMPROXY_PROXY_PORT'] } else { '8082' })",
        "MITMPROXY_WEB_PORT=$(if ($sensorEnvMap.ContainsKey('MITMPROXY_WEB_PORT')) { $sensorEnvMap['MITMPROXY_WEB_PORT'] } else { '8083' })",
        "PIHOLE_IMAGE=$(if ($sensorEnvMap.ContainsKey('PIHOLE_IMAGE')) { $sensorEnvMap['PIHOLE_IMAGE'] } else { 'pihole/pihole@sha256:ee348529cea9601df86ad94d62a39cad26117e1eac9e82d8876aa0ec7fe1ba27' })",
        "MITMPROXY_IMAGE=$(if ($sensorEnvMap.ContainsKey('MITMPROXY_IMAGE')) { $sensorEnvMap['MITMPROXY_IMAGE'] } else { 'mitmproxy/mitmproxy@sha256:743b6cdc817211d64bc269f5defacca8d14e76e647fc474e5c7244dbcb645141' })",
        "PIHOLE_LISTENING_MODE=$(if ($sensorEnvMap.ContainsKey('PIHOLE_LISTENING_MODE')) { $sensorEnvMap['PIHOLE_LISTENING_MODE'] } else { 'all' })"
    )
    Write-Utf8NoBom -Path $sensorEnvPath -Content (($sensorRuntimeLines -join "`n") + "`n")

    Invoke-CapturedCommand -Label "sensor bootstrap compose validation" -Command @(
        "docker", "compose",
        "-f", $composeFile,
        "--env-file", $sensorEnvPath,
        "config"
    ) -OutputFile $sensorComposeOutputPath | Out-Null

    Invoke-CapturedCommand -Label "archive staged sensor blueprint" -Command @(
        "tar",
        "-C", $blueprintRoot,
        "-czf", $sensorBlueprintArchivePath,
        "."
    ) -OutputFile (Join-Path $DrillRoot "sensor-blueprint-archive-create.txt") | Out-Null

    Assert-PathExists -Path $sensorBlueprintArchivePath -Label "Staged sensor blueprint archive"

    Invoke-CapturedCommand -Label "list staged sensor blueprint archive" -Command @(
        "tar",
        "-tzf", $sensorBlueprintArchivePath
    ) -OutputFile $sensorBlueprintArchiveListingPath | Out-Null

    $renderedOssec = (Get-Content -Path $ossecTemplatePath -Raw -Encoding UTF8).
        Replace("__MANAGER_IP__", $HostAddress).
        Replace("__MANAGER_PORT__", "1514")

    if ($renderedOssec -match "__MANAGER_") {
        throw "Rendered sensor ossec.conf still contains unresolved manager placeholders."
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Stop"
        [xml]$ossecXml = $renderedOssec
    }
    catch {
        throw "Rendered sensor ossec.conf template is not valid XML."
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($requiredXPath in @(
        "/ossec_config/client",
        "/ossec_config/client/server/address",
        "/ossec_config/client/server/port",
        "/ossec_config/client_buffer",
        "/ossec_config/syscheck",
        "/ossec_config/rootcheck"
    )) {
        if (-not $ossecXml.SelectSingleNode($requiredXPath)) {
            throw "Rendered sensor ossec.conf is missing required node '$requiredXPath'."
        }
    }

    foreach ($forbiddenXPath in @(
        "/ossec_config/client/client_buffer",
        "/ossec_config/integrity_monitoring",
        "/ossec_config/rootkit_detection"
    )) {
        if ($ossecXml.SelectSingleNode($forbiddenXPath)) {
            throw "Rendered sensor ossec.conf still contains forbidden node '$forbiddenXPath'."
        }
    }

    Write-Utf8NoBom -Path $renderedOssecPath -Content $renderedOssec
}

function Invoke-SensorRestoreValidation {
    param(
        [string]$StagedRecoveryBundleRoot,
        [string]$DrillRoot,
        [string]$HostAddress,
        [string]$ArchivePath
    )

    $restoreScript = Join-Path $StagedRecoveryBundleRoot "scripts\restore-sensor-vm.sh"
    Assert-PathExists -Path $restoreScript -Label "Sensor restore script"

    $restoreScriptText = Get-Content -Path $restoreScript -Raw -Encoding UTF8
    foreach ($requiredToken in @("--archive", "--manager-ip", "monitoring-sensor-compose", "monitoring-sensor-firewall", "suricata", "wazuh-agent")) {
        if ($restoreScriptText -notmatch [regex]::Escape($requiredToken)) {
            throw "Sensor restore script is missing required token '$requiredToken'."
        }
    }

    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        return "skipped"
    }

    Assert-PathExists -Path $ArchivePath -Label "Latest sensor archive"

    $archiveEntries = Invoke-CapturedCommand -Label "sensor archive listing" -Command @(
        "tar",
        "-tzf", $ArchivePath
    ) -OutputFile (Join-Path $DrillRoot "sensor-restore-archive.txt")

    $normalizedEntries = @(
        $archiveEntries |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    Assert-ArchiveContainsEntries -ArchivePath $ArchivePath -Entries $normalizedEntries -RequiredExact @(
        "etc/default/monitoring-sensor",
        "etc/systemd/system/monitoring-sensor-compose.service",
        "etc/systemd/system/monitoring-sensor-firewall.service",
        "usr/lib/systemd/system/suricata.service",
        "usr/lib/systemd/system/wazuh-agent.service"
    ) -RequiredPrefixes @(
        "opt/monitoring-sensor/",
        "etc/suricata/",
        "var/ossec/",
        "usr/local/lib/monitoring-sensor/"
    )

    Write-Utf8NoBom -Path (Join-Path $DrillRoot "sensor-restore-command.txt") -Content (
        "sudo bash restore-sensor-vm.sh --archive `"$ArchivePath`" --manager-ip $HostAddress`r`n"
    )

    return "validated"
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
$sensorBackupRoot = Join-Path $RecoveryBundleRoot "backups\sensor-vm"

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

$latestSensorArchive = Get-ChildItem -Path $sensorBackupRoot -File -Filter "*.tgz" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$latestSensorArchivePath = if ($latestSensorArchive) { $latestSensorArchive.FullName } else { "" }
$stagedRecoveryBundleRoot = Join-Path $workspaceRoot "wazuh-docker-stack\single-node\recovery-bundle"

Invoke-SensorBootstrapValidation -WorkspaceRoot $workspaceRoot -DrillRoot $DrillRoot -HostAddress $HostAddress
$sensorRestoreStatus = Invoke-SensorRestoreValidation -StagedRecoveryBundleRoot $stagedRecoveryBundleRoot -DrillRoot $DrillRoot -HostAddress $HostAddress -ArchivePath $latestSensorArchivePath

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
    "sensor_bootstrap_validation=validated",
    "sensor_bootstrap_compose_output=$(Join-Path $DrillRoot 'sensor-bootstrap-compose.txt')",
    "sensor_restore_validation=$sensorRestoreStatus",
    "latest_sensor_archive=$(if ($latestSensorArchive) { $latestSensorArchive.FullName } else { '' })",
    "next_sensor_bootstrap=powershell -ExecutionPolicy Bypass -File $workspaceRoot\\scripts\\windows\\Invoke-SensorVmBootstrap.ps1 -VmAddress 192.168.1.6 -VmUser subash",
    "next_sensor_restore=sudo bash restore-sensor-vm.sh --archive /path/to/ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip $HostAddress"
)
Write-Utf8NoBom -Path $summaryPath -Content (($summaryLines -join "`r`n") + "`r`n")

Write-Host "Bare-metal rebuild drill completed successfully."
Write-Host "Mode: $modeLabel"
Write-Host "Artifacts: $DrillRoot"
Write-Host "Staged workspace: $workspaceRoot"
Write-Host "Sensor bootstrap validation: validated"
Write-Host "Sensor restore validation: $sensorRestoreStatus"
if ($monitoringArtifact) {
    Write-Host "Monitoring rollout artifacts: $monitoringArtifact"
}
if ($wazuhArtifact) {
    Write-Host "Wazuh rollout artifacts: $wazuhArtifact"
}

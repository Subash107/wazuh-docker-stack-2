[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SkipPreBackup,
    [string]$ProjectRoot = "",
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

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

function Wait-ForContainerReady {
    param(
        [string]$ContainerName,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = (& docker inspect $ContainerName --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" 2>$null).Trim()
        if ($LASTEXITCODE -ne 0) {
            Start-Sleep -Seconds 3
            continue
        }

        if ($state -in @("healthy", "running")) {
            return
        }

        if ($state -in @("unhealthy", "exited", "dead")) {
            throw "Container '$ContainerName' reported state '$state'."
        }

        Start-Sleep -Seconds 3
    }

    throw "Timed out waiting for '$ContainerName' to become ready."
}

function Get-ContainerNetworkName {
    param([string]$ContainerName)

    $networkName = (& docker inspect $ContainerName --format "{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($networkName)) {
        throw "Could not determine the Docker network for '$ContainerName'."
    }

    return $networkName
}

function Wait-ForHttpStatus {
    param(
        [string]$NetworkName,
        [string]$Url,
        [string[]]$ExpectedStatusCodes,
        [string]$CurlImage,
        [int]$TimeoutSeconds,
        [string]$UserName = "",
        [string]$Password = ""
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $command = @(
            "docker", "run", "--rm",
            "--network", $NetworkName,
            $CurlImage,
            "-ksS",
            "-o", "/dev/null",
            "-w", "%{http_code}"
        )
        if (-not [string]::IsNullOrWhiteSpace($UserName)) {
            $command += @("-u", "$UserName`:$Password")
        }
        $command += $Url

        $status = (& $command[0] $command[1..($command.Count - 1)] 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and $status -in $ExpectedStatusCodes) {
            return
        }

        Start-Sleep -Seconds 5
    }

    throw "Timed out waiting for '$Url' to return one of: $($ExpectedStatusCodes -join ', ')"
}

function Save-WazuhSnapshot {
    param(
        [string]$DestinationRoot,
        [string]$ProjectRootPath
    )

    $snapshotRoot = Join-Path $DestinationRoot "config"
    New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null

    foreach ($relativePath in @(
        "wazuh-docker-stack\.env.example",
        "wazuh-docker-stack\single-node\docker-compose.yml",
        "wazuh-docker-stack\single-node\generate-indexer-certs.yml",
        "wazuh-docker-stack\single-node\README.md"
    )) {
        $sourcePath = Join-Path $ProjectRootPath $relativePath
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $snapshotRoot -Force
        }
    }

    foreach ($optionalPath in @(
        "wazuh-docker-stack\.env",
        "wazuh-docker-stack\secrets\README.md"
    )) {
        $sourcePath = Join-Path $ProjectRootPath $optionalPath
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $snapshotRoot -Force
        }
    }

    $configSource = Join-Path $ProjectRootPath "wazuh-docker-stack\single-node\config"
    if (Test-Path $configSource) {
        Copy-Item -Path $configSource -Destination $snapshotRoot -Recurse -Force
    }
}

function Read-Secret {
    param(
        [string]$Path,
        [string]$EnvironmentName,
        [switch]$Required
    )

    if (Test-Path $Path) {
        return (Get-Content -Path $Path -Raw -Encoding UTF8).Trim()
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue.Trim()
    }

    if ($Required) {
        throw "Missing secret value. Populate $Path or set $EnvironmentName."
    }

    return ""
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$projectRootResolved = (Resolve-Path $ProjectRoot).Path
$wazuhRoot = Join-Path $projectRootResolved "wazuh-docker-stack"
$singleNodeRoot = Join-Path $wazuhRoot "single-node"
$secretRoot = Join-Path $wazuhRoot "secrets"
$wazuhComposeWrapper = Join-Path $projectRootResolved "scripts\windows\Invoke-WazuhSingleNodeCompose.ps1"
$backupScript = Join-Path $singleNodeRoot "recovery-bundle\scripts\backup-current-state.ps1"
$curlHelperImage = "curlimages/curl@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path $projectRootResolved "logs\deployments\wazuh-rollout-$timestamp"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

if (-not (Test-Path $wazuhComposeWrapper)) {
    throw "Secret-aware Wazuh compose wrapper not found at $wazuhComposeWrapper"
}

if (-not (Test-Path $backupScript)) {
    throw "Recovery bundle backup script not found at $backupScript"
}

$apiPassword = Read-Secret -Path (Join-Path $secretRoot "api_password.txt") -EnvironmentName "API_PASSWORD" -Required
foreach ($requiredSecretPath in @(
    (Join-Path $secretRoot "indexer_password.txt"),
    (Join-Path $secretRoot "api_password.txt"),
    (Join-Path $secretRoot "dashboard_password.txt")
)) {
    if (-not (Test-Path $requiredSecretPath)) {
        throw "Missing required Wazuh secret file: $requiredSecretPath"
    }
}

foreach ($requiredConfigPath in @(
    (Join-Path $singleNodeRoot "config\wazuh_indexer_ssl_certs\root-ca.pem"),
    (Join-Path $singleNodeRoot "config\wazuh_indexer_ssl_certs\wazuh.manager.pem"),
    (Join-Path $singleNodeRoot "config\wazuh_indexer_ssl_certs\wazuh.manager-key.pem"),
    (Join-Path $singleNodeRoot "config\wazuh_indexer_ssl_certs\wazuh.indexer.pem"),
    (Join-Path $singleNodeRoot "config\wazuh_indexer_ssl_certs\wazuh.indexer-key.pem"),
    (Join-Path $singleNodeRoot "config\wazuh_indexer_ssl_certs\wazuh.dashboard.pem"),
    (Join-Path $singleNodeRoot "config\wazuh_indexer_ssl_certs\wazuh.dashboard-key.pem")
)) {
    if (-not (Test-Path $requiredConfigPath)) {
        throw "Missing required Wazuh config file: $requiredConfigPath"
    }
}

Push-Location $projectRootResolved
try {
    Save-WazuhSnapshot -DestinationRoot $runRoot -ProjectRootPath $projectRootResolved

    Invoke-CapturedCommand -Label "docker pull curl helper" -Command @(
        "docker", "pull", $curlHelperImage
    ) -OutputFile (Join-Path $runRoot "curl-helper-pull.txt") | Out-Null

    Invoke-CapturedCommand -Label "docker ps" -Command @(
        "docker", "ps", "--format", "table {{.Names}}`t{{.Status}}`t{{.Image}}"
    ) -OutputFile (Join-Path $runRoot "docker-ps.pre.txt") | Out-Null

    Invoke-CapturedCommand -Label "Wazuh single-node config" -Command @(
        "powershell", "-ExecutionPolicy", "Bypass",
        "-File", $wazuhComposeWrapper,
        "-ProjectRoot", $projectRootResolved,
        "config"
    ) -OutputFile (Join-Path $runRoot "wazuh-single-node-compose.resolved.yml") | Out-Null

    Invoke-CapturedCommand -Label "generate-indexer-certs config" -Command @(
        "docker", "compose",
        "-f", (Join-Path $singleNodeRoot "generate-indexer-certs.yml"),
        "config"
    ) -OutputFile (Join-Path $runRoot "generate-indexer-certs.resolved.yml") | Out-Null

    $dashboardConfigPath = Join-Path $singleNodeRoot "config\wazuh_dashboard\wazuh.yml"
    if (-not (Test-Path $dashboardConfigPath)) {
        throw "Expected rendered Wazuh dashboard config was not found at $dashboardConfigPath"
    }
    if ((Get-Content -Path $dashboardConfigPath -Raw -Encoding UTF8) -match "CHANGE_ME") {
        throw "Rendered Wazuh dashboard config still contains placeholder values at $dashboardConfigPath"
    }

    if (-not $Apply) {
        Write-Host "Validation completed. No Wazuh containers were recreated."
        Write-Host "Artifacts: $runRoot"
        return
    }

    if (-not $SkipPreBackup) {
        Invoke-CapturedCommand -Label "backup current state" -Command @(
            "powershell", "-ExecutionPolicy", "Bypass",
            "-File", $backupScript,
            "-HostRoot", $projectRootResolved,
            "-Stamp", $timestamp
        ) -OutputFile (Join-Path $runRoot "pre-backup.txt") | Out-Null
    }

    $rolloutGroups = @(
        @{
            Services = @("wazuh-indexer")
            Container = "single-node-wazuh-indexer-1"
            Url = "https://wazuh.indexer:9200"
            ExpectedStatusCodes = @("200", "401")
            UserName = ""
            Password = ""
        },
        @{
            Services = @("wazuh-manager")
            Container = "single-node-wazuh-manager-1"
            Url = "https://wazuh.manager:55000/security/user/authenticate?raw=true"
            ExpectedStatusCodes = @("200")
            UserName = "wazuh-wui"
            Password = $apiPassword
        },
        @{
            Services = @("wazuh-dashboard")
            Container = "single-node-wazuh-dashboard-1"
            Url = "https://wazuh-dashboard:5601/login"
            ExpectedStatusCodes = @("200", "302")
            UserName = ""
            Password = ""
        }
    )

    $stepIndex = 1
    foreach ($group in $rolloutGroups) {
        $services = [string[]]$group.Services
        $containerName = [string]$group.Container
        $stepName = "step-$stepIndex-" + ($services -join "-")

        Invoke-CapturedCommand -Label "docker compose up ($($services -join ', '))" -Command (
            @(
                "powershell", "-ExecutionPolicy", "Bypass",
                "-File", $wazuhComposeWrapper,
                "-ProjectRoot", $projectRootResolved,
                "up", "-d", "--force-recreate", "--no-deps"
            ) + $services
        ) -OutputFile (Join-Path $runRoot "$stepName.txt") | Out-Null

        Wait-ForContainerReady -ContainerName $containerName -TimeoutSeconds $TimeoutSeconds
        $networkName = Get-ContainerNetworkName -ContainerName $containerName
        Wait-ForHttpStatus `
            -NetworkName $networkName `
            -Url ([string]$group.Url) `
            -ExpectedStatusCodes ([string[]]$group.ExpectedStatusCodes) `
            -CurlImage $curlHelperImage `
            -TimeoutSeconds $TimeoutSeconds `
            -UserName ([string]$group.UserName) `
            -Password ([string]$group.Password)

        Invoke-CapturedCommand -Label "inspect $containerName" -Command @(
            "docker", "inspect", $containerName
        ) -OutputFile (Join-Path $runRoot "$containerName.inspect.json") | Out-Null

        $stepIndex++
    }

    Invoke-CapturedCommand -Label "docker ps post" -Command @(
        "docker", "ps", "--format", "table {{.Names}}`t{{.Status}}`t{{.Image}}"
    ) -OutputFile (Join-Path $runRoot "docker-ps.post.txt") | Out-Null

    Write-Host "Wazuh single-node rollout completed successfully."
    Write-Host "Artifacts: $runRoot"
}
finally {
    Pop-Location
}

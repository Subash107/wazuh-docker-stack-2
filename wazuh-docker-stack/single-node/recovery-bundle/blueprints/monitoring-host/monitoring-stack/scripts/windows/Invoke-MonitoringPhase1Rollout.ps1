[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

function Get-EnvMap {
    param([string]$Path)

    $values = @{}
    foreach ($line in Get-Content -Path $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }

        $name, $value = $line -split "=", 2
        if (-not $name) {
            continue
        }

        $cleanValue = ""
        if ($null -ne $value) {
            $cleanValue = $value.Trim()
        }

        $values[$name.Trim()] = $cleanValue
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

function Wait-ForContainerHealthy {
    param(
        [string]$ContainerName,
        [int]$TimeoutSeconds = 120
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

        if ($state -eq "unhealthy") {
            throw "Container '$ContainerName' reported unhealthy."
        }

        Start-Sleep -Seconds 3
    }

    throw "Timed out waiting for '$ContainerName' to become healthy."
}

function Save-ConfigSnapshot {
    param(
        [string]$DestinationRoot,
        [string]$ProjectRootPath
    )

    $snapshotRoot = Join-Path $DestinationRoot "config"
    New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null

    foreach ($path in @(
        ".env",
        ".env.example",
        "docker-compose.yml",
        "prometheus.yml",
        "blackbox.yml",
        "alertmanager.yml",
        "alert.rules.yml",
        "README.md"
    )) {
        Copy-Item -Path (Join-Path $ProjectRootPath $path) -Destination $snapshotRoot -Force
    }

    if (Test-Path (Join-Path $ProjectRootPath "gateway")) {
        Copy-Item -Path (Join-Path $ProjectRootPath "gateway") -Destination $snapshotRoot -Recurse -Force
    }
    Copy-Item -Path (Join-Path $ProjectRootPath "targets") -Destination $snapshotRoot -Recurse -Force
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$projectRootResolved = (Resolve-Path $ProjectRoot).Path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path $projectRootResolved "logs\deployments\phase1-$timestamp"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

Push-Location $projectRootResolved
try {
    $envMap = Get-EnvMap -Path (Join-Path $projectRootResolved ".env")
    $prometheusImage = $envMap["PROMETHEUS_IMAGE"]
    $alertmanagerImage = $envMap["ALERTMANAGER_IMAGE"]
    $blackboxImage = $envMap["BLACKBOX_EXPORTER_IMAGE"]
    $caddyImage = $envMap["CADDY_IMAGE"]

    if (-not $prometheusImage -or -not $alertmanagerImage -or -not $blackboxImage) {
        throw "PROMETHEUS_IMAGE, ALERTMANAGER_IMAGE, and BLACKBOX_EXPORTER_IMAGE must be set in .env"
    }
    if (-not $caddyImage) {
        $caddyImage = "caddy@sha256:af32e97399febea808609119bb21544d0265c58a02836576e32a2d082c262c17"
    }
    $monitoringGatewayHost = if ($envMap.ContainsKey("MONITORING_GATEWAY_HOST") -and -not [string]::IsNullOrWhiteSpace($envMap["MONITORING_GATEWAY_HOST"])) {
        $envMap["MONITORING_GATEWAY_HOST"]
    }
    else {
        "192.168.1.3"
    }

    foreach ($requiredSecret in @(
        "secrets\brevo_smtp_key.txt",
        "secrets\gateway_admin_username.txt",
        "secrets\gateway_admin_password_hash.txt"
    )) {
        $secretPath = Join-Path $projectRootResolved $requiredSecret
        if (-not (Test-Path $secretPath)) {
            throw "Missing required secret file: $secretPath"
        }
    }

    Save-ConfigSnapshot -DestinationRoot $runRoot -ProjectRootPath $projectRootResolved

    Invoke-CapturedCommand -Label "docker ps" -Command @(
        "docker", "ps", "--format", "table {{.Names}}`t{{.Status}}`t{{.Image}}"
    ) -OutputFile (Join-Path $runRoot "docker-ps.pre.txt") | Out-Null

    Invoke-CapturedCommand -Label "docker compose config" -Command @(
        "docker", "compose", "config"
    ) -OutputFile (Join-Path $runRoot "compose.resolved.yml") | Out-Null

    Invoke-CapturedCommand -Label "promtool check config" -Command @(
        "docker", "run", "--rm",
        "--entrypoint", "promtool",
        "-v", "${projectRootResolved}\prometheus.yml:/etc/prometheus/prometheus.yml",
        "-v", "${projectRootResolved}\alert.rules.yml:/etc/prometheus/alert.rules.yml",
        "-v", "${projectRootResolved}\targets:/etc/prometheus/targets:ro",
        $prometheusImage,
        "check", "config", "/etc/prometheus/prometheus.yml"
    ) -OutputFile (Join-Path $runRoot "promtool-check.txt") | Out-Null

    Invoke-CapturedCommand -Label "amtool check-config" -Command @(
        "docker", "run", "--rm",
        "--entrypoint", "amtool",
        "-v", "${projectRootResolved}\alertmanager.yml:/etc/alertmanager/alertmanager.yml",
        $alertmanagerImage,
        "check-config", "/etc/alertmanager/alertmanager.yml"
    ) -OutputFile (Join-Path $runRoot "amtool-check.txt") | Out-Null

    Invoke-CapturedCommand -Label "blackbox config check" -Command @(
        "docker", "run", "--rm",
        "-v", "${projectRootResolved}\blackbox.yml:/etc/blackbox_exporter/config.yml",
        $blackboxImage,
        "--config.file=/etc/blackbox_exporter/config.yml",
        "--config.check"
    ) -OutputFile (Join-Path $runRoot "blackbox-check.txt") | Out-Null

    Invoke-CapturedCommand -Label "caddy config validate" -Command @(
        "docker", "run", "--rm",
        "--entrypoint", "/bin/sh",
        "-e", "MONITORING_GATEWAY_HOST=$monitoringGatewayHost",
        "-v", "${projectRootResolved}\gateway\Caddyfile:/etc/caddy/Caddyfile:ro",
        "-v", "${projectRootResolved}\secrets\gateway_admin_username.txt:/run/secrets/gateway_admin_username.txt:ro",
        "-v", "${projectRootResolved}\secrets\gateway_admin_password_hash.txt:/run/secrets/gateway_admin_password_hash.txt:ro",
        $caddyImage,
        "-lc",
        'export GATEWAY_ADMIN_USERNAME=$(cat /run/secrets/gateway_admin_username.txt); export GATEWAY_ADMIN_PASSWORD_HASH=$(cat /run/secrets/gateway_admin_password_hash.txt); caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile'
    ) -OutputFile (Join-Path $runRoot "caddy-validate.txt") | Out-Null

    if (-not $Apply) {
        Write-Host "Validation completed. No containers were recreated."
        Write-Host "Artifacts: $runRoot"
        return
    }

    $rolloutGroups = @(
        @{ Services = @("alertmanager", "blackbox-exporter"); Containers = @("alertmanager", "blackbox-exporter") },
        @{ Services = @("prometheus"); Containers = @("prometheus") },
        @{ Services = @("monitoring-service-index"); Containers = @("monitoring-service-index") },
        @{ Services = @("monitoring-gateway"); Containers = @("monitoring-gateway") },
        @{ Services = @("wazuh-alert-forwarder"); Containers = @("wazuh-alert-forwarder") }
    )

    $stepIndex = 1
    foreach ($group in $rolloutGroups) {
        $services = [string[]]$group.Services
        $containers = [string[]]$group.Containers
        $stepName = "step-$stepIndex-" + ($services -join "-")

        Invoke-CapturedCommand -Label "docker compose up ($($services -join ', '))" -Command (
            @("docker", "compose", "up", "-d", "--force-recreate", "--no-deps") + $services
        ) -OutputFile (Join-Path $runRoot "$stepName.txt") | Out-Null

        foreach ($container in $containers) {
            Wait-ForContainerHealthy -ContainerName $container
            Invoke-CapturedCommand -Label "inspect $container" -Command @(
                "docker", "inspect", $container
            ) -OutputFile (Join-Path $runRoot "$container.inspect.json") | Out-Null
        }

        $stepIndex++
    }

    Invoke-CapturedCommand -Label "docker ps post" -Command @(
        "docker", "ps", "--format", "table {{.Names}}`t{{.Status}}`t{{.Image}}"
    ) -OutputFile (Join-Path $runRoot "docker-ps.post.txt") | Out-Null

    Write-Host "Phase 1 rollout completed successfully."
    Write-Host "Artifacts: $runRoot"
}
finally {
    Pop-Location
}

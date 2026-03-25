[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$EnsureStarted,
    [switch]$SkipRolloutValidation,
    [int]$StartupWaitSeconds = 10,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-EnvMap {
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

function Get-EnvValue {
    param(
        [hashtable]$Map,
        [string]$Name,
        [string]$DefaultValue
    )

    if ($Map.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($Map[$Name])) {
        return [string]$Map[$Name]
    }

    return $DefaultValue
}

function Read-SecretValue {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Missing secret file: $Path"
    }

    return (Get-Content -Path $Path -Raw -Encoding UTF8).Trim()
}

function Add-Result {
    param(
        [string]$Phase,
        [string]$Check,
        [ValidateSet("PASS", "WARN", "FAIL", "SKIP")]
        [string]$Status,
        [string]$Details
    )

    $item = [pscustomobject]@{
        Phase   = $Phase
        Check   = $Check
        Status  = $Status
        Details = $Details
    }
    $script:Results.Add($item) | Out-Null

    $color = switch ($Status) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
        default { "DarkGray" }
    }

    Write-Host ("[{0}] {1} :: {2} :: {3}" -f $Status, $Phase, $Check, $Details) -ForegroundColor $color
}

function Invoke-Check {
    param(
        [string]$Phase,
        [string]$Check,
        [scriptblock]$Script
    )

    try {
        $details = & $Script
        if ([string]::IsNullOrWhiteSpace([string]$details)) {
            $details = "ok"
        }

        Add-Result -Phase $Phase -Check $Check -Status "PASS" -Details ([string]$details)
        return $true
    }
    catch {
        Add-Result -Phase $Phase -Check $Check -Status "FAIL" -Details $_.Exception.Message
        return $false
    }
}

function Add-WarnResult {
    param(
        [string]$Phase,
        [string]$Check,
        [string]$Details
    )

    Add-Result -Phase $Phase -Check $Check -Status "WARN" -Details $Details
}

function Add-SkipResult {
    param(
        [string]$Phase,
        [string]$Check,
        [string]$Details
    )

    Add-Result -Phase $Phase -Check $Check -Status "SKIP" -Details $Details
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

        if ($null -eq $output) {
            Set-Content -Path $OutputFile -Value ""
        }
        else {
            $output | Set-Content -Path $OutputFile
        }

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

function Get-ContainerState {
    param([string]$ContainerName)

    $state = (& docker inspect $ContainerName --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($state)) {
        throw "Container '$ContainerName' was not found."
    }

    return $state
}

function Wait-ForContainerReady {
    param(
        [string]$ContainerName,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $state = Get-ContainerState -ContainerName $ContainerName
        }
        catch {
            Start-Sleep -Seconds 3
            continue
        }

        if ($state -in @("healthy", "running")) {
            return $state
        }

        if ($state -in @("unhealthy", "exited", "dead")) {
            throw "Container '$ContainerName' reported state '$state'."
        }

        Start-Sleep -Seconds 3
    }

    throw "Timed out waiting for '$ContainerName' to become ready."
}

function Invoke-CurlStatusCheck {
    param(
        [string]$Url,
        [string[]]$ExpectedStatusCodes,
        [switch]$SkipTlsVerify,
        [string]$UserName = "",
        [string]$Password = ""
    )

    $args = @()
    if ($SkipTlsVerify) {
        $args += "-k"
    }
    $args += @("-sS", "-o", "NUL", "-w", "%{http_code}")
    if (-not [string]::IsNullOrWhiteSpace($UserName)) {
        $args += @("-u", "$UserName`:$Password")
    }
    $args += $Url

    $statusCode = (& curl.exe @args 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed for $Url"
    }

    if ($statusCode -notin $ExpectedStatusCodes) {
        throw "Unexpected HTTP status $statusCode from $Url; expected $($ExpectedStatusCodes -join ', ')"
    }

    return "HTTP $statusCode from $Url"
}

function Get-TargetJobName {
    param($Target)

    if ($null -ne $Target.labels -and $Target.labels.PSObject.Properties.Name -contains "job") {
        return [string]$Target.labels.job
    }

    if ($Target.PSObject.Properties.Name -contains "scrapePool") {
        return [string]$Target.scrapePool
    }

    return "unknown"
}

function Save-SummaryArtifacts {
    param([string]$RunRoot)

    $resultItems = $script:Results.ToArray()
    $summary = [pscustomobject]@{
        generated_at_utc        = (Get-Date).ToUniversalTime().ToString("o")
        project_root            = $script:ProjectRootResolved
        ensure_started          = [bool]$EnsureStarted
        skip_rollout_validation = [bool]$SkipRolloutValidation
        results                 = $resultItems
    }

    Write-Utf8NoBom -Path (Join-Path $RunRoot "summary.json") -Content ($summary | ConvertTo-Json -Depth 8)
    Write-Utf8NoBom -Path (Join-Path $RunRoot "summary.txt") -Content (($resultItems | Format-Table -AutoSize | Out-String).TrimEnd() + "`r`n")
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$script:ProjectRootResolved = (Resolve-Path $ProjectRoot).Path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$runRoot = Join-Path $script:ProjectRootResolved "logs\day1-checks\day1-$timestamp"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

$rootEnvPath = Join-Path $script:ProjectRootResolved ".env"
$rootEnvExamplePath = Join-Path $script:ProjectRootResolved ".env.example"
$rootEnv = if (Test-Path $rootEnvPath) { Get-EnvMap -Path $rootEnvPath } else { Get-EnvMap -Path $rootEnvExamplePath }

$gatewayHost = Get-EnvValue -Map $rootEnv -Name "MONITORING_GATEWAY_HOST" -DefaultValue "192.168.1.3"
$serviceIndexPort = [int](Get-EnvValue -Map $rootEnv -Name "SERVICE_INDEX_PORT" -DefaultValue "9088")
$grafanaPort = [int](Get-EnvValue -Map $rootEnv -Name "GRAFANA_PORT" -DefaultValue "3001")
$gatewayServiceIndexPort = [int](Get-EnvValue -Map $rootEnv -Name "GATEWAY_SERVICE_INDEX_PORT" -DefaultValue "9443")
$gatewayPrometheusPort = [int](Get-EnvValue -Map $rootEnv -Name "GATEWAY_PROMETHEUS_PORT" -DefaultValue "9444")
$gatewayAlertmanagerPort = [int](Get-EnvValue -Map $rootEnv -Name "GATEWAY_ALERTMANAGER_PORT" -DefaultValue "9445")
$gatewayBlackboxPort = [int](Get-EnvValue -Map $rootEnv -Name "GATEWAY_BLACKBOX_PORT" -DefaultValue "9446")
$gatewayWazuhDashboardPort = [int](Get-EnvValue -Map $rootEnv -Name "GATEWAY_WAZUH_DASHBOARD_PORT" -DefaultValue "9447")

$requiredFiles = @(
    ".env",
    "secrets\brevo_smtp_key.txt",
    "secrets\grafana_admin_username.txt",
    "secrets\grafana_admin_password.txt",
    "secrets\gateway_admin_username.txt",
    "secrets\gateway_admin_password_hash.txt",
    "wazuh-docker-stack\secrets\indexer_password.txt",
    "wazuh-docker-stack\secrets\api_password.txt",
    "wazuh-docker-stack\secrets\dashboard_password.txt",
    "wazuh-docker-stack\single-node\config\wazuh_indexer_ssl_certs\root-ca.pem",
    "wazuh-docker-stack\single-node\config\wazuh_indexer_ssl_certs\wazuh.manager.pem",
    "wazuh-docker-stack\single-node\config\wazuh_indexer_ssl_certs\wazuh.manager-key.pem",
    "wazuh-docker-stack\single-node\config\wazuh_indexer_ssl_certs\wazuh.indexer.pem",
    "wazuh-docker-stack\single-node\config\wazuh_indexer_ssl_certs\wazuh.indexer-key.pem",
    "wazuh-docker-stack\single-node\config\wazuh_indexer_ssl_certs\wazuh.dashboard.pem",
    "wazuh-docker-stack\single-node\config\wazuh_indexer_ssl_certs\wazuh.dashboard-key.pem"
)
$recommendedFiles = @(
    "secrets\vm_ssh_password.txt",
    "secrets\vm_sudo_password.txt",
    "secrets\pihole_web_password.txt",
    "secrets\mitmproxy_web_password.txt"
)

$wazuhContainers = @(
    "single-node-wazuh-indexer-1",
    "single-node-wazuh-manager-1",
    "single-node-wazuh-dashboard-1"
)
$monitoringContainers = @(
    "prometheus",
    "grafana",
    "blackbox-exporter",
    "alertmanager",
    "wazuh-alert-forwarder",
    "monitoring-service-index",
    "monitoring-gateway"
)
$corePrometheusJobs = @(
    "prometheus",
    "alertmanager",
    "blackbox_exporter",
    "gateway_https_endpoints"
)
$sensorPrometheusJobs = @(
    "ping_servers",
    "sensor_http_endpoints",
    "sensor_tcp_endpoints",
    "sensor_dns_endpoints"
)

$requiredFilesPass = Invoke-Check -Phase "Prereqs" -Check "Required local files" -Script {
    $missing = foreach ($relativePath in $requiredFiles) {
        $fullPath = Join-Path $script:ProjectRootResolved $relativePath
        if (-not (Test-Path $fullPath)) {
            $relativePath
        }
    }

    if ($missing) {
        throw "Missing: $($missing -join ', ')"
    }

    return "$($requiredFiles.Count) required files present"
}

$recommendedMissing = foreach ($relativePath in $recommendedFiles) {
    $fullPath = Join-Path $script:ProjectRootResolved $relativePath
    if (-not (Test-Path $fullPath)) {
        $relativePath
    }
}
if ($recommendedMissing) {
    Add-WarnResult -Phase "Prereqs" -Check "Recommended sensor bootstrap files" -Details ("Missing: " + ($recommendedMissing -join ", "))
}
else {
    Add-Result -Phase "Prereqs" -Check "Recommended sensor bootstrap files" -Status "PASS" -Details "$($recommendedFiles.Count) recommended files present"
}

$dockerPass = Invoke-Check -Phase "Prereqs" -Check "Docker reachable" -Script {
    $version = (& docker info --format "{{.ServerVersion}}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
        throw "docker info failed"
    }

    return "Docker server $version"
}

if ($SkipRolloutValidation) {
    Add-SkipResult -Phase "Validate" -Check "Wazuh rollout helper" -Details "Skipped by -SkipRolloutValidation"
    Add-SkipResult -Phase "Validate" -Check "Monitoring rollout helper" -Details "Skipped by -SkipRolloutValidation"
    $wazuhPreflightPass = $true
    $monitoringPreflightPass = $true
}
else {
    $wazuhPreflightPass = Invoke-Check -Phase "Validate" -Check "Wazuh rollout helper" -Script {
        $output = Invoke-CapturedCommand -Label "Invoke-WazuhSingleNodeRollout" -Command @(
            "powershell", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $script:ProjectRootResolved "scripts\windows\Invoke-WazuhSingleNodeRollout.ps1"),
            "-ProjectRoot", $script:ProjectRootResolved
        ) -OutputFile (Join-Path $runRoot "wazuh-rollout-validation.txt")

        $lastLine = ($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace([string]$lastLine)) {
            return "Validation completed"
        }

        return [string]$lastLine
    }

    $monitoringPreflightPass = Invoke-Check -Phase "Validate" -Check "Monitoring rollout helper" -Script {
        $output = Invoke-CapturedCommand -Label "Invoke-MonitoringPhase1Rollout" -Command @(
            "powershell", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $script:ProjectRootResolved "scripts\windows\Invoke-MonitoringPhase1Rollout.ps1"),
            "-ProjectRoot", $script:ProjectRootResolved
        ) -OutputFile (Join-Path $runRoot "monitoring-rollout-validation.txt")

        $lastLine = ($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace([string]$lastLine)) {
            return "Validation completed"
        }

        return [string]$lastLine
    }
}

$canEnsureStarted = $EnsureStarted -and $requiredFilesPass -and $dockerPass

if (-not $EnsureStarted) {
    Add-SkipResult -Phase "Startup" -Check "Ensure Wazuh stack running" -Details "Run with -EnsureStarted to auto-start the stack"
    Add-SkipResult -Phase "Startup" -Check "Ensure monitoring stack running" -Details "Run with -EnsureStarted to auto-start the stack"
}
else {
    if (-not $canEnsureStarted) {
        Add-SkipResult -Phase "Startup" -Check "Ensure Wazuh stack running" -Details "Skipped because prerequisites failed"
        Add-SkipResult -Phase "Startup" -Check "Ensure monitoring stack running" -Details "Skipped because prerequisites failed"
    }
    else {
        if (-not $wazuhPreflightPass) {
            Add-SkipResult -Phase "Startup" -Check "Ensure Wazuh stack running" -Details "Skipped because Wazuh validation failed"
        }
        else {
            [void](Invoke-Check -Phase "Startup" -Check "Ensure Wazuh stack running" -Script {
                $output = Invoke-CapturedCommand -Label "Invoke-WazuhSingleNodeCompose up -d" -Command @(
                    "powershell", "-ExecutionPolicy", "Bypass",
                    "-File", (Join-Path $script:ProjectRootResolved "scripts\windows\Invoke-WazuhSingleNodeCompose.ps1"),
                    "-ProjectRoot", $script:ProjectRootResolved,
                    "up", "-d"
                ) -OutputFile (Join-Path $runRoot "wazuh-compose-up.txt")

                if ($StartupWaitSeconds -gt 0) {
                    Start-Sleep -Seconds $StartupWaitSeconds
                }

                foreach ($containerName in $wazuhContainers) {
                    Wait-ForContainerReady -ContainerName $containerName -TimeoutSeconds $TimeoutSeconds | Out-Null
                }

                return "Wazuh containers started or already running"
            })
        }

        if (-not $monitoringPreflightPass) {
            Add-SkipResult -Phase "Startup" -Check "Ensure monitoring stack running" -Details "Skipped because monitoring validation failed"
        }
        else {
            [void](Invoke-Check -Phase "Startup" -Check "Ensure monitoring stack running" -Script {
                $volumeName = (& docker volume inspect single-node_wazuh_logs --format "{{.Name}}" 2>$null).Trim()
                if ($LASTEXITCODE -ne 0 -or $volumeName -ne "single-node_wazuh_logs") {
                    throw "Required Docker volume 'single-node_wazuh_logs' was not found."
                }

                $output = Invoke-CapturedCommand -Label "docker compose up -d" -Command @(
                    "docker", "compose", "up", "-d"
                ) -OutputFile (Join-Path $runRoot "monitoring-compose-up.txt")

                if ($StartupWaitSeconds -gt 0) {
                    Start-Sleep -Seconds $StartupWaitSeconds
                }

                foreach ($containerName in $monitoringContainers) {
                    Wait-ForContainerReady -ContainerName $containerName -TimeoutSeconds $TimeoutSeconds | Out-Null
                }

                return "Monitoring containers started or already running"
            })
        }
    }
}

[void](Invoke-Check -Phase "Runtime" -Check "Wazuh log volume present" -Script {
    $volumeName = (& docker volume inspect single-node_wazuh_logs --format "{{.Name}}" 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $volumeName -ne "single-node_wazuh_logs") {
        throw "Required Docker volume 'single-node_wazuh_logs' was not found."
    }

    return "single-node_wazuh_logs exists"
})

[void](Invoke-Check -Phase "Runtime" -Check "Wazuh container states" -Script {
    $states = foreach ($containerName in $wazuhContainers) {
        "{0}={1}" -f $containerName, (Get-ContainerState -ContainerName $containerName)
    }

    return ($states -join "; ")
})

[void](Invoke-Check -Phase "Runtime" -Check "Monitoring container states" -Script {
    $states = foreach ($containerName in $monitoringContainers) {
        "{0}={1}" -f $containerName, (Get-ContainerState -ContainerName $containerName)
    }

    return ($states -join "; ")
})

[void](Invoke-Check -Phase "Endpoints" -Check "Wazuh indexer local HTTPS" -Script {
    Invoke-CurlStatusCheck -Url "https://127.0.0.1:9200" -ExpectedStatusCodes @("200", "401") -SkipTlsVerify
})

[void](Invoke-Check -Phase "Endpoints" -Check "Wazuh manager API local HTTPS" -Script {
    $apiPassword = Read-SecretValue -Path (Join-Path $script:ProjectRootResolved "wazuh-docker-stack\secrets\api_password.txt")
    Invoke-CurlStatusCheck -Url "https://127.0.0.1:55000/security/user/authenticate?raw=true" -ExpectedStatusCodes @("200") -SkipTlsVerify -UserName "wazuh-wui" -Password $apiPassword
})

[void](Invoke-Check -Phase "Endpoints" -Check "Wazuh dashboard local HTTPS" -Script {
    Invoke-CurlStatusCheck -Url "https://127.0.0.1:5601/login" -ExpectedStatusCodes @("200", "302") -SkipTlsVerify
})

[void](Invoke-Check -Phase "Endpoints" -Check "Service index local healthz" -Script {
    $body = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/healthz" -f $serviceIndexPort) -TimeoutSec 15
    if ([string]$body -ne "ok") {
        throw "Unexpected response body: $body"
    }

    return "ok from port $serviceIndexPort"
})

[void](Invoke-Check -Phase "Endpoints" -Check "Grafana local health" -Script {
    Invoke-CurlStatusCheck -Url ("http://127.0.0.1:{0}/api/health" -f $grafanaPort) -ExpectedStatusCodes @("200")
})

[void](Invoke-Check -Phase "Endpoints" -Check "Prometheus local health" -Script {
    Invoke-CurlStatusCheck -Url "http://127.0.0.1:9090/-/healthy" -ExpectedStatusCodes @("200")
})

[void](Invoke-Check -Phase "Endpoints" -Check "Alertmanager local health" -Script {
    Invoke-CurlStatusCheck -Url "http://127.0.0.1:9093/-/healthy" -ExpectedStatusCodes @("200")
})

[void](Invoke-Check -Phase "Endpoints" -Check "Blackbox local metrics" -Script {
    Invoke-CurlStatusCheck -Url "http://127.0.0.1:9115/metrics" -ExpectedStatusCodes @("200")
})

[void](Invoke-Check -Phase "Endpoints" -Check "Gateway service index health" -Script {
    Invoke-CurlStatusCheck -Url ("https://127.0.0.1:{0}/healthz" -f $gatewayServiceIndexPort) -ExpectedStatusCodes @("200") -SkipTlsVerify
})

[void](Invoke-Check -Phase "Endpoints" -Check "Gateway Prometheus health" -Script {
    Invoke-CurlStatusCheck -Url ("https://127.0.0.1:{0}/healthz" -f $gatewayPrometheusPort) -ExpectedStatusCodes @("200") -SkipTlsVerify
})

[void](Invoke-Check -Phase "Endpoints" -Check "Gateway Alertmanager health" -Script {
    Invoke-CurlStatusCheck -Url ("https://127.0.0.1:{0}/healthz" -f $gatewayAlertmanagerPort) -ExpectedStatusCodes @("200") -SkipTlsVerify
})

[void](Invoke-Check -Phase "Endpoints" -Check "Gateway Blackbox health" -Script {
    Invoke-CurlStatusCheck -Url ("https://127.0.0.1:{0}/healthz" -f $gatewayBlackboxPort) -ExpectedStatusCodes @("200") -SkipTlsVerify
})

[void](Invoke-Check -Phase "Endpoints" -Check "Gateway Wazuh dashboard health" -Script {
    Invoke-CurlStatusCheck -Url ("https://127.0.0.1:{0}/healthz" -f $gatewayWazuhDashboardPort) -ExpectedStatusCodes @("200") -SkipTlsVerify
})

[void](Invoke-Check -Phase "APIs" -Check "Service index summary" -Script {
    $payload = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/status" -f $serviceIndexPort) -TimeoutSec 15
    $payload | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $runRoot "service-index-status.json")

    if ($null -eq $payload.summary) {
        throw "Service index payload did not include a summary."
    }

    $total = [int]$payload.summary.total
    $healthy = [int]$payload.summary.healthy
    $critical = [int]$payload.summary.critical
    if ($critical -gt 0) {
        $criticalServices = @($payload.services | Where-Object { $_.status -ne "healthy" } | Select-Object -ExpandProperty name)
        Add-WarnResult -Phase "APIs" -Check "Service index service health" -Details ("{0}/{1} healthy; critical: {2}" -f $healthy, $total, ($criticalServices -join ", "))
    }
    else {
        Add-Result -Phase "APIs" -Check "Service index service health" -Status "PASS" -Details ("{0}/{1} healthy" -f $healthy, $total)
    }

    $alertCount = @($payload.alerts).Count
    return "$healthy/$total healthy; active Prometheus alerts: $alertCount"
})

[void](Invoke-Check -Phase "APIs" -Check "Prometheus target API" -Script {
    $targetsPayload = Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/v1/targets" -TimeoutSec 15
    $targetsPayload | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $runRoot "prometheus-targets.json")

    $activeTargets = @($targetsPayload.data.activeTargets)
    if (-not $activeTargets) {
        throw "Prometheus returned no active targets."
    }

    $jobSummaries = foreach ($target in $activeTargets) {
        [pscustomobject]@{
            Job    = Get-TargetJobName -Target $target
            Health = [string]$target.health
        }
    }

    $coreIssues = foreach ($jobName in $corePrometheusJobs) {
        $matching = @($jobSummaries | Where-Object { $_.Job -eq $jobName })
        if (-not $matching) {
            "$jobName=missing"
            continue
        }

        foreach ($entry in $matching | Where-Object { $_.Health -ne "up" }) {
            "$jobName=$($entry.Health)"
        }
    }

    if ($coreIssues) {
        throw "Core target issues: $($coreIssues -join ', ')"
    }

    $sensorIssues = foreach ($jobName in $sensorPrometheusJobs) {
        $matching = @($jobSummaries | Where-Object { $_.Job -eq $jobName })
        if (-not $matching) {
            "$jobName=missing"
            continue
        }

        foreach ($entry in $matching | Where-Object { $_.Health -ne "up" }) {
            "$jobName=$($entry.Health)"
        }
    }

    if ($sensorIssues) {
        Add-WarnResult -Phase "APIs" -Check "Prometheus sensor target health" -Details ("Issues: " + ($sensorIssues -join ", "))
    }
    else {
        Add-Result -Phase "APIs" -Check "Prometheus sensor target health" -Status "PASS" -Details "All sensor jobs are healthy"
    }

    return "Core monitoring jobs are healthy"
})

Save-SummaryArtifacts -RunRoot $runRoot

$statusCounts = @{
    PASS = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count
    WARN = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count
    FAIL = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
    SKIP = @($script:Results | Where-Object { $_.Status -eq "SKIP" }).Count
}

Write-Host ""
Write-Host "Summary: PASS=$($statusCounts.PASS) WARN=$($statusCounts.WARN) FAIL=$($statusCounts.FAIL) SKIP=$($statusCounts.SKIP)"
Write-Host "Artifacts: $runRoot"

if ($statusCounts.FAIL -gt 0) {
    exit 1
}

exit 0

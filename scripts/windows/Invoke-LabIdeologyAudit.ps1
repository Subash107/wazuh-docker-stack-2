[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$ProfilePath = ""
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

function Add-Result {
    param(
        [string]$Section,
        [string]$Check,
        [ValidateSet("PASS", "WARN", "FAIL", "SKIP")]
        [string]$Status,
        [string]$Details
    )

    $item = [pscustomobject]@{
        Section = $Section
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

    Write-Host ("[{0}] {1} :: {2} :: {3}" -f $Status, $Section, $Check, $Details) -ForegroundColor $color
}

function Invoke-Audit {
    param(
        [string]$Section,
        [string]$Check,
        [scriptblock]$Script
    )

    try {
        $details = & $Script
        if ([string]::IsNullOrWhiteSpace([string]$details)) {
            $details = "ok"
        }

        Add-Result -Section $Section -Check $Check -Status "PASS" -Details ([string]$details)
        return $true
    }
    catch {
        Add-Result -Section $Section -Check $Check -Status "FAIL" -Details $_.Exception.Message
        return $false
    }
}

function Add-WarnResult {
    param(
        [string]$Section,
        [string]$Check,
        [string]$Details
    )

    Add-Result -Section $Section -Check $Check -Status "WARN" -Details $Details
}

function Add-SkipResult {
    param(
        [string]$Section,
        [string]$Check,
        [string]$Details
    )

    Add-Result -Section $Section -Check $Check -Status "SKIP" -Details $Details
}

function Convert-IPv4ToUInt32 {
    param([string]$Address)

    $ip = [System.Net.IPAddress]::Parse($Address)
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "IPv6 is not supported for this audit: $Address"
    }

    $bytes = $ip.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-IpInCidr {
    param(
        [string]$IpAddress,
        [string]$Cidr
    )

    $parts = $Cidr -split "/", 2
    if ($parts.Count -ne 2) {
        return $false
    }

    $network = Convert-IPv4ToUInt32 -Address $parts[0]
    $ip = Convert-IPv4ToUInt32 -Address $IpAddress
    $prefixLength = [int]$parts[1]
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        return $false
    }

    if ($prefixLength -eq 0) {
        return $true
    }

    $mask = [uint32]::MaxValue -shl (32 - $prefixLength)
    return (($network -band $mask) -eq ($ip -band $mask))
}

function Test-IpInCidrs {
    param(
        [string]$IpAddress,
        [string[]]$Cidrs
    )

    foreach ($cidr in $Cidrs) {
        if (Test-IpInCidr -IpAddress $IpAddress -Cidr $cidr) {
            return $true
        }
    }

    return $false
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

function Get-ScalarList {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Get-InventoryEntries {
    param([string]$Path)

    $entries = @()
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -match "^-\s+(?<value>\S+)$") {
            $value = $matches["value"]
            if ($value.EndsWith(":")) {
                continue
            }

            $entries += $value
        }
    }

    return $entries
}

function Get-HostFromTargetValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $parsedUri = $null
    if ([System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$parsedUri)) {
        return $parsedUri.Host
    }

    if ($Value -match "^[A-Za-z0-9._-]+:\d+$") {
        return ($Value -split ":", 2)[0]
    }

    return $Value
}

function Test-LabHost {
    param(
        [string]$HostName,
        [string[]]$LabCidrs,
        [string[]]$AllowedPublicHosts
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $false
    }

    if ($HostName -in @("localhost", "127.0.0.1", "host.docker.internal")) {
        return $true
    }

    if ($HostName -in @(
        "prometheus",
        "alertmanager",
        "blackbox-exporter",
        "monitoring-gateway",
        "monitoring-service-index",
        "grafana",
        "wazuh-dashboard",
        "wazuh-manager",
        "wazuh-indexer"
    )) {
        return $true
    }

    $ipAddress = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$ipAddress)) {
        if ($ipAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return (Test-IpInCidrs -IpAddress $HostName -Cidrs $LabCidrs)
        }

        return $false
    }

    if ($HostName -in $AllowedPublicHosts) {
        return $true
    }

    if ($HostName -notmatch "\.") {
        return $true
    }

    return $false
}

function Save-SummaryArtifacts {
    param([string]$RunRoot)

    $resultItems = $script:Results.ToArray()
    $summary = [pscustomobject]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        profile_path     = $script:ResolvedProfilePath
        project_root     = $script:ProjectRootResolved
        results          = $resultItems
    }

    Write-Utf8NoBom -Path (Join-Path $RunRoot "summary.json") -Content ($summary | ConvertTo-Json -Depth 8)
    Write-Utf8NoBom -Path (Join-Path $RunRoot "summary.txt") -Content (($resultItems | Format-Table -AutoSize | Out-String).TrimEnd() + "`r`n")
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$script:ProjectRootResolved = (Resolve-Path $ProjectRoot).Path
if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path $script:ProjectRootResolved "docs\reference\lab-ideology-profile.json"
}
$script:ResolvedProfilePath = (Resolve-Path $ProfilePath).Path

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path $script:ProjectRootResolved "logs\lab-audits\lab-audit-$timestamp"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$script:Results = New-Object 'System.Collections.Generic.List[object]'

$profileLoaded = Invoke-Audit -Section "Profile" -Check "Tracked lab ideology profile" -Script {
    $script:Profile = Get-Content -Path $script:ResolvedProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    return "Loaded $($script:Profile.title)"
}

if (-not $profileLoaded) {
    Save-SummaryArtifacts -RunRoot $runRoot
    exit 1
}

$labCidrs = @(Get-ScalarList -Value $script:Profile.closed_network.lab_cidrs)
$allowedPublicEgress = @(Get-ScalarList -Value $script:Profile.closed_network.allowed_public_egress)
$practiceInventoryRelative = [string]$script:Profile.practice_targets.inventory_file
$practiceInventoryPath = Join-Path $script:ProjectRootResolved $practiceInventoryRelative

[void](Invoke-Audit -Section "Closed Network" -Check "Target inventories stay on private or internal hosts" -Script {
    $findings = @()
    foreach ($file in Get-ChildItem -Path (Join-Path $script:ProjectRootResolved "targets") -Filter "*.yml") {
        foreach ($entry in Get-InventoryEntries -Path $file.FullName) {
            if ($entry -eq "[]") {
                continue
            }

            $hostName = Get-HostFromTargetValue -Value $entry
            if (-not (Test-LabHost -HostName $hostName -LabCidrs $labCidrs -AllowedPublicHosts @())) {
                $findings += "$($file.Name):$entry"
            }
        }
    }

    if ($findings) {
        throw "Unexpected non-lab hosts: $($findings -join ', ')"
    }

    return "All tracked target inventories stay on private or internal hosts"
})

[void](Invoke-Audit -Section "Closed Network" -Check "Service catalog stays on lab or internal hosts" -Script {
    $catalogPath = Join-Path $script:ProjectRootResolved "scripts\python\service_index_assets\service_catalog.json"
    $catalog = Get-Content -Path $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $findings = @()

    foreach ($service in @($catalog.services)) {
        $url = [string]$service.url
        $hostName = ""
        $parsedUri = $null
        if ([System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$parsedUri)) {
            $hostName = $parsedUri.Host
        }
        elseif ($url -match "^ssh\s+\S+@(?<host>\S+)$") {
            $hostName = $matches["host"]
        }
        elseif ($url -match "^(?<host>[A-Za-z0-9._-]+):\d+$") {
            $hostName = $matches["host"]
        }
        else {
            continue
        }

        if (-not (Test-LabHost -HostName $hostName -LabCidrs $labCidrs -AllowedPublicHosts @())) {
            $findings += "$($service.name):$url"
        }
    }

    if ($findings) {
        throw "Unexpected catalog hosts: $($findings -join ', ')"
    }

    return "Operator-facing service links stay on lab or internal hosts"
})

[void](Invoke-Audit -Section "Closed Network" -Check "Gateway enforces authenticated ingress" -Script {
    $caddyfile = Get-Content -Path (Join-Path $script:ProjectRootResolved "gateway\Caddyfile") -Raw -Encoding UTF8
    if ($caddyfile -notmatch "basic_auth") {
        throw "gateway/Caddyfile does not contain basic_auth."
    }

    $portCount = @($script:Profile.closed_network.expected_gateway_ports).Count
    return "Gateway auth is configured and profile expects $portCount HTTPS gateway ports"
})

$envPath = Join-Path $script:ProjectRootResolved ".env"
$envExamplePath = Join-Path $script:ProjectRootResolved ".env.example"
$envMap = if (Test-Path $envPath) { Get-EnvMap -Path $envPath } else { Get-EnvMap -Path $envExamplePath }
$geoLookupEnabled = ($envMap["GEOLOOKUP_ENABLED"] -eq "true")
if ($geoLookupEnabled) {
    Add-WarnResult -Section "Closed Network" -Check "Explicit public geolocation egress" -Details ("Geo lookup is enabled; keep external access limited to " + ($allowedPublicEgress -join ", "))
}
else {
    Add-Result -Section "Closed Network" -Check "Explicit public geolocation egress" -Status "PASS" -Details "Geo lookup is disabled"
}

$smtpHost = ""
$alertmanagerText = Get-Content -Path (Join-Path $script:ProjectRootResolved "alertmanager.yml") -Raw -Encoding UTF8
if ($alertmanagerText -match 'smtp_smarthost:\s*"?(?<host>[^":\r\n]+)') {
    $smtpHost = $matches["host"]
}
if (-not [string]::IsNullOrWhiteSpace($smtpHost)) {
    Add-WarnResult -Section "Closed Network" -Check "Explicit SMTP egress" -Details "Alert delivery depends on public SMTP host $smtpHost"
}
else {
    Add-SkipResult -Section "Closed Network" -Check "Explicit SMTP egress" -Details "smtp_smarthost was not detected"
}

[void](Invoke-Audit -Section "Virtualization" -Check "Recovery bundle and blueprint exist" -Script {
    $paths = @(
        "wazuh-docker-stack\single-node\recovery-bundle",
        "wazuh-docker-stack\single-node\recovery-bundle\blueprints\sensor-vm",
        "wazuh-docker-stack\single-node\recovery-bundle\scripts\deploy-monitoring-host.ps1",
        "wazuh-docker-stack\single-node\recovery-bundle\scripts\restore-sensor-vm.sh",
        "wazuh-docker-stack\single-node\recovery-bundle\scripts\new-hyperv-sensor-vm.ps1"
    )
    $missing = foreach ($relativePath in $paths) {
        if (-not (Test-Path (Join-Path $script:ProjectRootResolved $relativePath))) {
            $relativePath
        }
    }

    if ($missing) {
        throw "Missing virtualization or recovery asset(s): $($missing -join ', ')"
    }

    return "Recovery bundle, sensor blueprint, and Hyper-V helper are present"
})

[void](Invoke-Audit -Section "Realistic Environment" -Check "Pinned images are used for deterministic rebuilds" -Script {
    $rootCompose = Get-Content -Path (Join-Path $script:ProjectRootResolved "docker-compose.yml") -Raw -Encoding UTF8
    $sensorEnv = Get-Content -Path (Join-Path $script:ProjectRootResolved "wazuh-docker-stack\single-node\recovery-bundle\blueprints\sensor-vm\config\sensor.env.example") -Raw -Encoding UTF8

    $rootDigestCount = ([regex]::Matches($rootCompose, "@sha256:[0-9a-f]{64}")).Count
    if ($rootDigestCount -lt 7) {
        throw "Root docker-compose.yml does not pin all expected images by digest."
    }
    if ($sensorEnv -notmatch "PIHOLE_IMAGE=.*@sha256:" -or $sensorEnv -notmatch "MITMPROXY_IMAGE=.*@sha256:") {
        throw "Sensor blueprint image digests are not pinned."
    }

    return "Pinned digests found in root compose and sensor blueprint"
})

[void](Invoke-Audit -Section "Realistic Environment" -Check "Tracked addresses match the current host and sensor layout" -Script {
    $monitoringHost = [string]$script:Profile.closed_network.monitoring_host
    $sensorVm = [string]$script:Profile.closed_network.sensor_vm
    $pingTargets = Get-Content -Path (Join-Path $script:ProjectRootResolved "targets\ping_servers.yml") -Raw -Encoding UTF8
    if ($pingTargets -notmatch [regex]::Escape($monitoringHost)) {
        throw "targets/ping_servers.yml is missing monitoring host $monitoringHost"
    }
    if ($pingTargets -notmatch [regex]::Escape($sensorVm)) {
        throw "targets/ping_servers.yml is missing sensor VM $sensorVm"
    }

    return "Lab profile addresses match the tracked monitoring host and sensor VM"
})

[void](Invoke-Audit -Section "Health Monitoring" -Check "Monitoring stack files and helpers exist" -Script {
    $paths = @(
        "prometheus.yml",
        "blackbox.yml",
        "alert.rules.yml",
        "scripts\windows\Invoke-Day1Check.ps1",
        "scripts\windows\Invoke-LabIdeologyAudit.ps1",
        "scripts\python\monitoring_service_index.py"
    )
    $missing = foreach ($relativePath in $paths) {
        if (-not (Test-Path (Join-Path $script:ProjectRootResolved $relativePath))) {
            $relativePath
        }
    }

    if ($missing) {
        throw "Missing health-monitoring asset(s): $($missing -join ', ')"
    }

    return "Prometheus, Blackbox, service index, and audit helpers are present"
})

[void](Invoke-Audit -Section "Health Monitoring" -Check "Prometheus covers sensor, gateway, and practice-target probes" -Script {
    $prometheusText = Get-Content -Path (Join-Path $script:ProjectRootResolved "prometheus.yml") -Raw -Encoding UTF8
    foreach ($jobName in @("ping_servers", "sensor_http_endpoints", "sensor_tcp_endpoints", "sensor_dns_endpoints", "gateway_https_endpoints", "practice_http_endpoints")) {
        if ($prometheusText -notmatch ('job_name:\s+"' + [regex]::Escape($jobName) + '"')) {
            throw "prometheus.yml is missing job $jobName"
        }
    }

    return "Prometheus scrape config includes sensor, gateway, and practice-target coverage"
})

[void](Invoke-Audit -Section "Hardware" -Check "Declared resource baseline exists" -Script {
    $monitoringHostBaseline = $script:Profile.resource_baseline.monitoring_host
    $sensorBaseline = $script:Profile.resource_baseline.sensor_vm
    if ($null -eq $monitoringHostBaseline -or $null -eq $sensorBaseline) {
        throw "Resource baseline is incomplete in the lab profile."
    }

    return ("Monitoring host baseline {0} CPU / {1} GB RAM; sensor baseline {2} CPU / {3} GB RAM" -f
        $monitoringHostBaseline.cpu_cores,
        $monitoringHostBaseline.memory_gb,
        $sensorBaseline.cpu_cores,
        $sensorBaseline.memory_gb)
})

[void](Invoke-Audit -Section "Hardware" -Check "Low-resource fallback profile exists" -Script {
    $path = Join-Path $script:ProjectRootResolved "projects\ubuntu-lightweight-soc\README.md"
    if (-not (Test-Path $path)) {
        throw "projects/ubuntu-lightweight-soc/README.md is missing."
    }

    return "Low-resource Ubuntu SOC profile is available for constrained sensors"
})

[void](Invoke-Audit -Section "Multiple OS" -Check "Windows and Linux operator paths are both present" -Script {
    $paths = @(
        "scripts\windows",
        "scripts\linux",
        "Sysmon",
        "wazuh-docker-stack\single-node\recovery-bundle\blueprints\sensor-vm"
    )
    $missing = foreach ($relativePath in $paths) {
        if (-not (Test-Path (Join-Path $script:ProjectRootResolved $relativePath))) {
            $relativePath
        }
    }

    if ($missing) {
        throw "Missing cross-platform asset(s): $($missing -join ', ')"
    }

    return "Windows, Ubuntu, and Windows telemetry assets are represented"
})

[void](Invoke-Audit -Section "Multiple OS" -Check "Tracked OS matrix is declared" -Script {
    $osMatrix = @(Get-ScalarList -Value $script:Profile.operating_system_matrix)
    if (@($osMatrix | Where-Object { $_ -match "Windows" }).Count -lt 1 -or @($osMatrix | Where-Object { $_ -match "Ubuntu|Linux" }).Count -lt 1) {
        throw "Lab profile does not declare mixed OS coverage."
    }

    return ("Declared OS coverage: " + ($osMatrix -join ", "))
})

[void](Invoke-Audit -Section "Duplicate Tools" -Check "Cross-check tooling exists in the repo" -Script {
    $toolEvidence = @{
        "Pi-hole" = "wazuh-docker-stack\single-node\recovery-bundle\blueprints\sensor-vm\compose\docker-compose.yml"
        "mitmproxy" = "wazuh-docker-stack\single-node\recovery-bundle\blueprints\sensor-vm\compose\docker-compose.yml"
        "Suricata" = "wazuh-docker-stack\single-node\recovery-bundle\blueprints\sensor-vm\config\ossec.conf.template"
        "Wazuh" = "wazuh-docker-stack\single-node\docker-compose.yml"
        "Prometheus" = "prometheus.yml"
        "Blackbox Exporter" = "blackbox.yml"
        "Monitoring Service Index" = "scripts\python\monitoring_service_index.py"
    }

    $missing = @()
    foreach ($row in @($script:Profile.duplicate_tool_matrix)) {
        $tools = @($row.primary) + @(Get-ScalarList -Value $row.secondary)
        foreach ($tool in $tools) {
            if (-not $toolEvidence.ContainsKey([string]$tool)) {
                $missing += "$($row.finding):$tool"
                continue
            }

            $relativePath = $toolEvidence[[string]$tool]
            if (-not (Test-Path (Join-Path $script:ProjectRootResolved $relativePath))) {
                $missing += "$($row.finding):$tool"
            }
        }
    }

    if ($missing) {
        throw "Missing duplicate-tool evidence for: $($missing -join ', ')"
    }

    return "Tracked duplicate-tool matrix maps to repo components"
})

[void](Invoke-Audit -Section "Practice Targets" -Check "Practice-target inventory and rules exist" -Script {
    $paths = @(
        $practiceInventoryRelative,
        "prometheus.yml",
        "alert.rules.yml"
    )
    $missing = foreach ($relativePath in $paths) {
        if (-not (Test-Path (Join-Path $script:ProjectRootResolved $relativePath))) {
            $relativePath
        }
    }

    if ($missing) {
        throw "Missing practice-target asset(s): $($missing -join ', ')"
    }

    $prometheusText = Get-Content -Path (Join-Path $script:ProjectRootResolved "prometheus.yml") -Raw -Encoding UTF8
    $alertRulesText = Get-Content -Path (Join-Path $script:ProjectRootResolved "alert.rules.yml") -Raw -Encoding UTF8
    if ($prometheusText -notmatch 'job_name:\s+"practice_http_endpoints"') {
        throw "prometheus.yml is missing practice_http_endpoints."
    }
    if ($alertRulesText -notmatch 'alert:\s+PracticeHttpEndpointDown') {
        throw "alert.rules.yml is missing PracticeHttpEndpointDown."
    }

    return "Practice-target inventory, scrape job, and alert rule are present"
})

$practiceEntries = @()
if (Test-Path $practiceInventoryPath) {
    $practiceEntries = @(Get-InventoryEntries -Path $practiceInventoryPath)
}
if (-not $practiceEntries -or ($practiceEntries.Count -eq 1 -and $practiceEntries[0] -eq "[]")) {
    Add-WarnResult -Section "Practice Targets" -Check "Practice-target inventory population" -Details "Inventory exists but no isolated practice targets are declared yet"
}
else {
    [void](Invoke-Audit -Section "Practice Targets" -Check "Practice targets stay on private lab hosts" -Script {
        $findings = @()
        foreach ($entry in $practiceEntries) {
            if ($entry -eq "[]") {
                continue
            }

            $hostName = Get-HostFromTargetValue -Value $entry
            if (-not (Test-LabHost -HostName $hostName -LabCidrs $labCidrs -AllowedPublicHosts @())) {
                $findings += $entry
            }
        }

        if ($findings) {
            throw "Practice targets are not confined to the lab network: $($findings -join ', ')"
        }

        return "$($practiceEntries.Count) practice targets stay on the lab network"
    })
}

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

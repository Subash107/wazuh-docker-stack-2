[CmdletBinding()]
param(
    [Parameter(Position = 1)]
    [string]$ProjectRoot = "",
    [switch]$ForceRenderDashboardConfig,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$ComposeArgs
)

$ErrorActionPreference = "Stop"

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

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Convert-ToYamlDoubleQuoted {
    param([string]$Value)

    return ($Value.Replace('\', '\\').Replace('"', '\"'))
}

function Sync-WazuhDashboardConfig {
    param(
        [string]$SingleNodeRoot,
        [string]$ApiPassword,
        [bool]$ForceRender
    )

    $targetPath = Join-Path $SingleNodeRoot "config\wazuh_dashboard\wazuh.yml"
    $examplePath = Join-Path $SingleNodeRoot "config\wazuh_dashboard\wazuh.yml.example"

    if (-not (Test-Path $examplePath)) {
        throw "Missing Wazuh dashboard config example: $examplePath"
    }

    if ((Test-Path $targetPath) -and -not $ForceRender) {
        $current = Get-Content -Path $targetPath -Raw -Encoding UTF8
        if ($current -notmatch "CHANGE_ME") {
            return
        }
    }

    $escapedPassword = Convert-ToYamlDoubleQuoted -Value $ApiPassword
    $rendered = (Get-Content -Path $examplePath -Raw -Encoding UTF8).Replace('password: "CHANGE_ME"', "password: `"$escapedPassword`"")
    Write-Utf8NoBom -Path $targetPath -Content $rendered
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
elseif (($ComposeArgs.Count -eq 0) -and -not (Test-Path $ProjectRoot)) {
    $ComposeArgs = @($ProjectRoot)
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

if (-not $ComposeArgs -or $ComposeArgs.Count -eq 0) {
    throw "Pass the docker compose arguments after the script name, for example: up -d or config"
}

$projectRootResolved = (Resolve-Path $ProjectRoot).Path
$wazuhRoot = Join-Path $projectRootResolved "wazuh-docker-stack"
$singleNodeRoot = Join-Path $wazuhRoot "single-node"
$envPath = Join-Path $wazuhRoot ".env"
$envExamplePath = Join-Path $wazuhRoot ".env.example"
$secretRoot = Join-Path $wazuhRoot "secrets"

$envMap = if (Test-Path $envPath) { Read-EnvMap -Path $envPath } else { Read-EnvMap -Path $envExamplePath }
$indexerPassword = Read-Secret -Path (Join-Path $secretRoot "indexer_password.txt") -EnvironmentName "INDEXER_PASSWORD" -Required
$apiPassword = Read-Secret -Path (Join-Path $secretRoot "api_password.txt") -EnvironmentName "API_PASSWORD" -Required
$dashboardPassword = Read-Secret -Path (Join-Path $secretRoot "dashboard_password.txt") -EnvironmentName "DASHBOARD_PASSWORD" -Required

Sync-WazuhDashboardConfig -SingleNodeRoot $singleNodeRoot -ApiPassword $apiPassword -ForceRender:$ForceRenderDashboardConfig

$variableMap = @{}
foreach ($key in $envMap.Keys) {
    $variableMap[$key] = $envMap[$key]
}
$variableMap["INDEXER_PASSWORD"] = $indexerPassword
$variableMap["API_PASSWORD"] = $apiPassword
$variableMap["DASHBOARD_PASSWORD"] = $dashboardPassword

$previousValues = @{}
foreach ($key in $variableMap.Keys) {
    $previousValues[$key] = [Environment]::GetEnvironmentVariable($key)
    [Environment]::SetEnvironmentVariable($key, $variableMap[$key])
}

Push-Location $singleNodeRoot
try {
    & docker compose @ComposeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose $($ComposeArgs -join ' ') failed."
    }
}
finally {
    Pop-Location
    foreach ($key in $previousValues.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previousValues[$key])
    }
}

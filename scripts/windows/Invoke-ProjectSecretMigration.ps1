[CmdletBinding()]
param(
    [string]$ProjectRoot = ""
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

function Read-JsonObject {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return @{}
    }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $parsed = ConvertFrom-Json -InputObject $raw
    $result = @{}
    if ($null -eq $parsed) {
        return $result
    }

    foreach ($property in $parsed.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }

    return $result
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-SecretFile {
    param(
        [string]$Path,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Write-Utf8NoBom -Path $Path -Content ($Value.Trim() + "`n")
    return $true
}

function Resolve-FirstValue {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return ""
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$projectRootResolved = (Resolve-Path $ProjectRoot).Path
$wazuhRoot = Join-Path $projectRootResolved "wazuh-docker-stack"
$envPath = Join-Path $wazuhRoot ".env"
$envExamplePath = Join-Path $wazuhRoot ".env.example"
$wazuhSecretRoot = Join-Path $wazuhRoot "secrets"
$hostSecretRoot = Join-Path $projectRootResolved "secrets"
$privateRoot = Join-Path $projectRootResolved "local\operator-private"
$overridePath = Join-Path $privateRoot "credentials.override.json"

$envMap = Read-EnvMap -Path $envPath
$overrideMap = Read-JsonObject -Path $overridePath

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $privateRoot "secret-migration-backup\$timestamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

if (Test-Path $envPath) {
    Copy-Item -Path $envPath -Destination (Join-Path $backupRoot ".env.bak") -Force
}
if (Test-Path $overridePath) {
    Copy-Item -Path $overridePath -Destination (Join-Path $backupRoot "credentials.override.json.bak") -Force
}

$writtenSecrets = @()

if (Write-SecretFile -Path (Join-Path $wazuhSecretRoot "indexer_password.txt") -Value (Resolve-FirstValue @($envMap["INDEXER_PASSWORD"]))) {
    $writtenSecrets += "wazuh-docker-stack/secrets/indexer_password.txt"
}
if (Write-SecretFile -Path (Join-Path $wazuhSecretRoot "api_password.txt") -Value (Resolve-FirstValue @($envMap["API_PASSWORD"]))) {
    $writtenSecrets += "wazuh-docker-stack/secrets/api_password.txt"
}
if (Write-SecretFile -Path (Join-Path $wazuhSecretRoot "dashboard_password.txt") -Value (Resolve-FirstValue @($envMap["DASHBOARD_PASSWORD"]))) {
    $writtenSecrets += "wazuh-docker-stack/secrets/dashboard_password.txt"
}

if (Write-SecretFile -Path (Join-Path $hostSecretRoot "vm_ssh_password.txt") -Value (Resolve-FirstValue @($overrideMap["sensor_ssh_password"], $env:VM_SSH_PASSWORD))) {
    $writtenSecrets += "secrets/vm_ssh_password.txt"
}
if (Write-SecretFile -Path (Join-Path $hostSecretRoot "vm_sudo_password.txt") -Value (Resolve-FirstValue @($overrideMap["sensor_sudo_password"], $env:VM_SUDO_PASSWORD))) {
    $writtenSecrets += "secrets/vm_sudo_password.txt"
}
if (Write-SecretFile -Path (Join-Path $hostSecretRoot "pihole_web_password.txt") -Value (Resolve-FirstValue @($overrideMap["pihole_password"], $env:PIHOLE_WEBPASSWORD))) {
    $writtenSecrets += "secrets/pihole_web_password.txt"
}

$envLines = @()
if (Test-Path $envPath) {
    foreach ($line in Get-Content -Path $envPath) {
        if ($line -match '^\s*(INDEXER_PASSWORD|API_PASSWORD|DASHBOARD_PASSWORD)\s*=') {
            continue
        }
        $envLines += $line
    }
}
elseif (Test-Path $envExamplePath) {
    $envLines = Get-Content -Path $envExamplePath
}

if ($envLines.Count -gt 0) {
    Write-Utf8NoBom -Path $envPath -Content (($envLines -join "`n").TrimEnd() + "`n")
}

$scrubbedOverride = @{}
foreach ($entry in $overrideMap.GetEnumerator()) {
    if ($entry.Key -in @(
        "pihole_password",
        "sensor_ssh_password",
        "sensor_sudo_password",
        "wazuh_dashboard_password",
        "wazuh_api_password",
        "wazuh_indexer_password"
    )) {
        continue
    }
    $scrubbedOverride[$entry.Key] = $entry.Value
}

if ($scrubbedOverride.Count -gt 0) {
    $overrideJson = $scrubbedOverride | ConvertTo-Json -Depth 5
    Write-Utf8NoBom -Path $overridePath -Content ($overrideJson + "`n")
}
elseif (Test-Path $overridePath) {
    Remove-Item -Path $overridePath -Force
}

Write-Host "Local secret migration completed."
Write-Host "Backup folder: $backupRoot"
if ($writtenSecrets.Count -gt 0) {
    Write-Host "Secret files written:"
    foreach ($path in $writtenSecrets) {
        Write-Host "  $path"
    }
}
else {
    Write-Host "No secret files were written because no source values were found."
}

[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$VaultPath = "",
    [string]$Passphrase = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "SecretVault.Common.ps1")

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$projectRootResolved = (Resolve-Path $ProjectRoot).Path
if ([string]::IsNullOrWhiteSpace($VaultPath)) {
    $VaultPath = Join-Path $projectRootResolved "local\secret-vault\monitoring-secrets.enc.json"
}

$passphraseValue = Get-SecretVaultPassphrase -Passphrase $Passphrase
$vaultDirectory = Split-Path $VaultPath -Parent
New-Item -ItemType Directory -Force -Path $vaultDirectory | Out-Null

$candidateFiles = @(
    ".env",
    "wazuh-docker-stack\.env",
    "secrets\brevo_smtp_key.txt",
    "secrets\gateway_admin_username.txt",
    "secrets\gateway_admin_password.txt",
    "secrets\gateway_admin_password_hash.txt",
    "secrets\vm_ssh_password.txt",
    "secrets\vm_sudo_password.txt",
    "secrets\pihole_web_password.txt",
    "wazuh-docker-stack\secrets\indexer_password.txt",
    "wazuh-docker-stack\secrets\api_password.txt",
    "wazuh-docker-stack\secrets\dashboard_password.txt",
    "local\operator-private\credentials.override.json"
)

$files = [ordered]@{}
foreach ($relativePath in $candidateFiles) {
    $fullPath = Join-Path $projectRootResolved $relativePath
    if (Test-Path $fullPath) {
        $files[$relativePath] = Get-Content -Path $fullPath -Raw -Encoding UTF8
    }
}

if ($files.Count -eq 0) {
    throw "No local secret-bearing files were found to export."
}

$payload = [ordered]@{
    format = "monitoring-secret-vault-content/v1"
    created_at = (Get-Date).ToString("o")
    machine = $env:COMPUTERNAME
    files = $files
}
$plaintext = ($payload | ConvertTo-Json -Depth 6)
$vaultRecord = Protect-SecretVaultPayload -Plaintext $plaintext -Passphrase $passphraseValue
Write-Utf8NoBom -Path $VaultPath -Content (($vaultRecord | ConvertTo-Json -Depth 6) + "`n")

Write-Host "Encrypted secret vault written to $VaultPath"
Write-Host "Files captured:"
foreach ($relativePath in $files.Keys) {
    Write-Host "  $relativePath"
}

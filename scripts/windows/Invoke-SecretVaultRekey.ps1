[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$VaultPath = "",
    [string]$CurrentPassphrase = "",
    [string]$NewPassphrase = ""
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
elseif (-not [System.IO.Path]::IsPathRooted($VaultPath)) {
    $VaultPath = Join-Path $projectRootResolved $VaultPath
}
if (-not (Test-Path $VaultPath)) {
    throw "Vault file not found at $VaultPath"
}

$currentPassphraseValue = Get-SecretVaultPassphrase -Passphrase $CurrentPassphrase
$newPassphraseValue = Get-SecretVaultPassphrase -Passphrase $NewPassphrase -EnvironmentName "MONITORING_SECRET_VAULT_NEW_PASSPHRASE"

$vaultRecord = ConvertFrom-Json -InputObject (Get-Content -Path $VaultPath -Raw -Encoding UTF8)
$plaintext = Unprotect-SecretVaultPayload -VaultRecord $vaultRecord -Passphrase $currentPassphraseValue
$payload = ConvertFrom-Json -InputObject $plaintext
$normalizedPayload = [ordered]@{
    format = [string]$payload.format
    created_at = [string]$payload.created_at
    machine = [string]$payload.machine
    files = ConvertTo-SecretVaultFilesMap -Files $payload.files
}
$normalizedPlaintext = ($normalizedPayload | ConvertTo-Json -Depth 6)
$rotatedRecord = Protect-SecretVaultPayload -Plaintext $normalizedPlaintext -Passphrase $newPassphraseValue

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = "$VaultPath.$timestamp.bak"
Copy-Item -Path $VaultPath -Destination $backupPath -Force
Write-Utf8NoBom -Path $VaultPath -Content (($rotatedRecord | ConvertTo-Json -Depth 6) + "`n")

Write-Host "Secret vault rekeyed at $VaultPath"
Write-Host "Previous vault backup: $backupPath"

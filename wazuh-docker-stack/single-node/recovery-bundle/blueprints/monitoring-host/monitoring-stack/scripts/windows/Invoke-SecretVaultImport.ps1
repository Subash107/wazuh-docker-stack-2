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
if (-not (Test-Path $VaultPath)) {
    throw "Vault file not found at $VaultPath"
}

$passphraseValue = Get-SecretVaultPassphrase -Passphrase $Passphrase
$vaultRecord = ConvertFrom-Json -InputObject (Get-Content -Path $VaultPath -Raw -Encoding UTF8)
$plaintext = Unprotect-SecretVaultPayload -VaultRecord $vaultRecord -Passphrase $passphraseValue
$payload = ConvertFrom-Json -InputObject $plaintext

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $projectRootResolved "local\secret-vault\import-backup\$timestamp"
$restored = @()
$backedUp = $false

foreach ($property in $payload.files.PSObject.Properties) {
    $relativePath = $property.Name
    $destinationPath = Join-Path $projectRootResolved $relativePath
    $destinationDirectory = Split-Path $destinationPath -Parent
    $backupPath = Join-Path $backupRoot $relativePath

    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null

    if (Test-Path $destinationPath) {
        $backupDirectory = Split-Path $backupPath -Parent
        New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
        Copy-Item -Path $destinationPath -Destination $backupPath -Force
        $backedUp = $true
    }

    Write-Utf8NoBom -Path $destinationPath -Content ([string]$property.Value)
    $restored += $relativePath
}

Write-Host "Secret vault imported into $projectRootResolved"
if ($backedUp) {
    Write-Host "Existing files were backed up to $backupRoot"
}
Write-Host "Files restored:"
foreach ($relativePath in $restored) {
    Write-Host "  $relativePath"
}

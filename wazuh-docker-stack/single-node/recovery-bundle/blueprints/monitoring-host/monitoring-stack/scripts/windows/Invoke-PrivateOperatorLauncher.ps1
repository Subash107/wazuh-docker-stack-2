param()

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "Invoke-PrivateCredentialExport.ps1"
if (-not (Test-Path $scriptPath)) {
    throw "Unable to locate Invoke-PrivateCredentialExport.ps1 in $PSScriptRoot"
}

& $scriptPath -Open:$false
if ($LASTEXITCODE -ne 0) {
    throw "Private credential export generation failed with exit code $LASTEXITCODE."
}

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$launcherPath = Join-Path $repoRoot "local\operator-private\launcher.html"
if (-not (Test-Path $launcherPath)) {
    throw "Expected launcher page was not generated at $launcherPath"
}

Write-Host "Private operator launcher written to $launcherPath"
Start-Process $launcherPath

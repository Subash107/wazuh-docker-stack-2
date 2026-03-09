param(
    [switch]$Open = $true
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$privateRoot = Join-Path $repoRoot "local\operator-private"
$outputHtml = Join-Path $privateRoot "credential-export.html"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required to generate the private credential export on this host."
}

New-Item -ItemType Directory -Force -Path $privateRoot | Out-Null

$dockerArgs = @(
    "run",
    "--rm",
    "-v", "${repoRoot}:/repo",
    "-e", "MONITORING_REPO_ROOT=/repo",
    "-e", "OPERATOR_MACHINE_NAME=$env:COMPUTERNAME"
)

$dockerArgs += @(
    "python:3.12-slim",
    "python",
    "/repo/scripts/python/generate_private_credentials_page.py"
)

docker @dockerArgs
if ($LASTEXITCODE -ne 0) {
    throw "Docker-based private credential export failed with exit code $LASTEXITCODE."
}

Write-Host "Private credential export written to $outputHtml"
if ($Open -and (Test-Path $outputHtml)) {
    Start-Process $outputHtml
}

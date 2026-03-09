[CmdletBinding()]
param(
    [string]$SSHUser = "subash",
    [string]$SSHHost = "192.168.1.6",
    [string]$ScriptPath = ""
)

$ErrorActionPreference = "Stop"

if ($ScriptPath) {
    Write-Warning "ScriptPath is ignored. This wrapper now delegates to the canonical sensor bootstrap."
}

$canonicalScript = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "scripts\windows\Invoke-SensorVmBootstrap.ps1"
& $canonicalScript -VmAddress $SSHHost -VmUser $SSHUser

[CmdletBinding()]
param(
    [string]$SSHUser = "subash",
    [string]$SSHHost = "192.168.1.6",
    [string]$PiHoleWebPassword = ""
)

$ErrorActionPreference = "Stop"

$canonicalScript = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "scripts\windows\Invoke-SensorVmBootstrap.ps1"
& $canonicalScript -VmAddress $SSHHost -VmUser $SSHUser -PiHoleWebPassword $PiHoleWebPassword

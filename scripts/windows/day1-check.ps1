[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$ScriptArguments
)

$ErrorActionPreference = "Stop"

$canonicalScript = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "scripts\windows\Invoke-Day1Check.ps1"
& $canonicalScript @ScriptArguments

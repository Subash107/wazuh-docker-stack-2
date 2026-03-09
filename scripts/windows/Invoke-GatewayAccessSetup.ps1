[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$UserName = "",
    [string]$Password = "",
    [switch]$RotatePassword
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function New-RandomPassword {
    param([int]$Length = 24)

    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*_-"
    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        [void]$builder.Append($alphabet[(Get-Random -Minimum 0 -Maximum $alphabet.Length)])
    }

    return $builder.ToString()
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$projectRootResolved = (Resolve-Path $ProjectRoot).Path
$secretRoot = Join-Path $projectRootResolved "secrets"
$envPath = Join-Path $projectRootResolved ".env"
$envExamplePath = Join-Path $projectRootResolved ".env.example"
$userPath = Join-Path $secretRoot "gateway_admin_username.txt"
$passwordPath = Join-Path $secretRoot "gateway_admin_password.txt"
$hashPath = Join-Path $secretRoot "gateway_admin_password_hash.txt"

New-Item -ItemType Directory -Force -Path $secretRoot | Out-Null

$envMap = @{}
if (Test-Path $envPath) {
    foreach ($line in Get-Content -Path $envPath) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#") -or -not $line.Contains("=")) {
            continue
        }

        $name, $value = $line -split "=", 2
        $envMap[$name.Trim()] = $value.Trim()
    }
}
elseif (Test-Path $envExamplePath) {
    foreach ($line in Get-Content -Path $envExamplePath) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#") -or -not $line.Contains("=")) {
            continue
        }

        $name, $value = $line -split "=", 2
        $envMap[$name.Trim()] = $value.Trim()
    }
}

$caddyImage = if ($envMap.ContainsKey("CADDY_IMAGE") -and -not [string]::IsNullOrWhiteSpace($envMap["CADDY_IMAGE"])) {
    $envMap["CADDY_IMAGE"]
}
else {
    "caddy@sha256:af32e97399febea808609119bb21544d0265c58a02836576e32a2d082c262c17"
}

if ([string]::IsNullOrWhiteSpace($UserName)) {
    if (Test-Path $userPath) {
        $UserName = (Get-Content -Path $userPath -Raw -Encoding UTF8).Trim()
    }
    else {
        $UserName = "operator"
    }
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    if ((-not $RotatePassword) -and (Test-Path $passwordPath)) {
        $Password = (Get-Content -Path $passwordPath -Raw -Encoding UTF8).Trim()
    }
    else {
        $Password = New-RandomPassword
    }
}

$hash = (& docker run --rm --entrypoint caddy $caddyImage hash-password --plaintext $Password 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hash)) {
    throw "Failed to generate the gateway password hash with image '$caddyImage'."
}

Write-Utf8NoBom -Path $userPath -Content ($UserName + "`n")
Write-Utf8NoBom -Path $passwordPath -Content ($Password + "`n")
Write-Utf8NoBom -Path $hashPath -Content ($hash + "`n")

Write-Host "Gateway access secrets written:"
Write-Host "  $userPath"
Write-Host "  $passwordPath"
Write-Host "  $hashPath"
Write-Host "Gateway username: $UserName"
Write-Host "Gateway password updated locally. Use the private credential export to view it later."

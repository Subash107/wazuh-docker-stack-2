param(
    [Parameter(Mandatory = $true)]
    [string]$OutputIsoPath,
    [Parameter(Mandatory = $true)]
    [string]$HostName,
    [Parameter(Mandatory = $true)]
    [string]$InstanceId,
    [Parameter(Mandatory = $true)]
    [string]$AdminUser,
    [Parameter(Mandatory = $true)]
    [string]$PasswordFile
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PasswordFile)) {
    throw "Password file '$PasswordFile' was not found."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is required to build the cloud-init seed ISO."
}

$adminPassword = (Get-Content $PasswordFile -Raw).Trim()
$seedRoot = Join-Path ([System.IO.Path]::GetDirectoryName($OutputIsoPath)) "seed-$InstanceId"
if (Test-Path $seedRoot) {
    Remove-Item -Recurse -Force $seedRoot
}
New-Item -ItemType Directory -Force -Path $seedRoot | Out-Null

$metaData = @"
instance-id: $InstanceId
local-hostname: $HostName
"@

$userData = @"
#cloud-config
hostname: $HostName
preserve_hostname: false
manage_etc_hosts: true
ssh_pwauth: true
disable_root: true
users:
  - default
  - name: $AdminUser
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    sudo: ALL=(ALL:ALL) ALL
chpasswd:
  expire: false
  users:
    - name: $AdminUser
      password: $adminPassword
package_update: false
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent || true
  - systemctl start qemu-guest-agent || true
"@

Set-Content -Path (Join-Path $seedRoot "meta-data") -Value $metaData -Encoding ascii -NoNewline
Set-Content -Path (Join-Path $seedRoot "user-data") -Value $userData -Encoding ascii

$isoDir = Split-Path $OutputIsoPath -Parent
$isoName = Split-Path $OutputIsoPath -Leaf
New-Item -ItemType Directory -Force -Path $isoDir | Out-Null

if (Test-Path $OutputIsoPath) {
    Remove-Item -Force $OutputIsoPath
}

docker run --rm `
  -v "${seedRoot}:/seed:ro" `
  -v "${isoDir}:/out" `
  alpine:3.20 sh -lc "apk add --no-cache xorriso >/dev/null && xorriso -as mkisofs -volid CIDATA -joliet -rock -output /out/$isoName /seed/user-data /seed/meta-data" | Out-Null

if (-not (Test-Path $OutputIsoPath)) {
    throw "Failed to build cloud-init ISO '$OutputIsoPath'."
}

Remove-Item -Recurse -Force $seedRoot
Write-Host "Cloud-init seed created: $OutputIsoPath"

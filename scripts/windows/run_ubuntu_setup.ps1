# Execute Ubuntu installation over SSH
param(
    [string]$SSHUser = "subash",
    [string]$SSHHost = "192.168.1.6",
    [string]$ScriptPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "scripts\linux\install_ubuntu_complete.sh")
)

Write-Host "=========================================="
Write-Host "Executing Wazuh Setup on Ubuntu"
Write-Host "=========================================="
Write-Host "Host: $SSHUser@$SSHHost"
Write-Host ""

$InstallScript = Get-Content -Path $ScriptPath -Raw

# Method 1: Try using ssh -tt with StrictHostKeyChecking disabled
try {
    Write-Host "[*] Connecting via SSH and executing installation..."
    Write-Host ""
    
    # Use ssh-keyscan to add host key
    $null = ssh-keyscan -t ed25519 $SSHHost 2>$null | Add-Content ~/.ssh/known_hosts 2>$null || $true
    
    # Execute via SSH - send script through stdin
    $InstallScript | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -l $SSHUser $SSHHost "bash -s" 2>&1
    
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Setup Execution Completed!"
    Write-Host "=========================================="
}
catch {
    Write-Host "Error during SSH execution: $_"
}

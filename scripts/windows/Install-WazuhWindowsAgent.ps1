# Windows Wazuh Agent Installation Script

$WAZUH_MANAGER_IP = "192.168.1.7"
$WAZUH_MANAGER_PORT = 1514
$WAZUH_AGENT_NAME = "Windows-Monitoring"
$WAZUH_VERSION = "4.14.3"
$WAZUH_AGENT_INSTALLER = "wazuh-agent-$WAZUH_VERSION-1.msi"
$DOWNLOAD_URL = "https://packages.wazuh.com/4.x/windows/$WAZUH_AGENT_INSTALLER"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Windows Wazuh Agent Installation" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Set error action
$ErrorActionPreference = "Stop"

# Create temp directory
$TempDir = "$env:TEMP\Wazuh"
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir | Out-Null
}

$InstallerPath = Join-Path $TempDir $WAZUH_AGENT_INSTALLER

# Download the agent
Write-Host "[*] Downloading Wazuh Agent v$WAZUH_VERSION..." -ForegroundColor Yellow
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile $InstallerPath -UseBasicParsing
    Write-Host "[+] Downloaded to: $InstallerPath" -ForegroundColor Green
} catch {
    Write-Host "[-] Failed to download. Error: $_" -ForegroundColor Red
    Write-Host "Manual download: $DOWNLOAD_URL" -ForegroundColor Yellow
    exit 1
}

# Close any existing Wazuh services
Write-Host "[*] Stopping any existing Wazuh services..." -ForegroundColor Yellow
$services = @("WazuhSvc", "Wazuh")
foreach ($service in $services) {
    try {
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
            Write-Host "[+] Stopped service: $service" -ForegroundColor Green
        }
    } catch {}
}

# Uninstall if already exists
Write-Host "[*] Removing previous Wazuh installation if it exists..." -ForegroundColor Yellow
$wazuhPath = "C:\Program Files (x86)\ossec-agent"
if (Test-Path $wazuhPath) {
    Remove-Item -Path $wazuhPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[+] Removed old installation" -ForegroundColor Green
}

# Install the agent
Write-Host "[*] Installing Wazuh Agent..." -ForegroundColor Yellow
$installArgs = @(
    "/i", "`"$InstallerPath`"",
    "/quiet",
    "WAZUH_MANAGER=$WAZUH_MANAGER_IP",
    "WAZUH_MANAGER_PORT=$WAZUH_MANAGER_PORT",
    "WAZUH_AGENT_NAME=$WAZUH_AGENT_NAME",
    "WAZUH_AGENT_GROUP=default"
)

try {
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru
    if ($process.ExitCode -eq 0) {
        Write-Host "[+] Agent installed successfully" -ForegroundColor Green
    } else {
        Write-Host "[-] Installation returned exit code: $($process.ExitCode)" -ForegroundColor Red
    }
} catch {
    Write-Host "[-] Installation failed: $_" -ForegroundColor Red
    exit 1
}

# Wait for service to be registered
Start-Sleep -Seconds 5

# Start the service
Write-Host "[*] Starting Wazuh Agent service..." -ForegroundColor Yellow
try {
    Start-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
    Write-Host "[+] Service started" -ForegroundColor Green
} catch {
    Write-Host "[-] Failed to start service: $_" -ForegroundColor Red
}

# Verify installation
Write-Host "[*] Verifying installation..." -ForegroundColor Yellow
$agentPath = "C:\Program Files (x86)\ossec-agent"
if (Test-Path $agentPath) {
    Write-Host "[+] Agent directory exists: $agentPath" -ForegroundColor Green
    
    # Check service status
    $service = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
    if ($service) {
        Write-Host "[+] Service status: $($service.Status)" -ForegroundColor Green
    }
} else {
    Write-Host "[-] Agent directory not found" -ForegroundColor Red
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Installation Complete!" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Agent Details:" -ForegroundColor Cyan
Write-Host "  Name: $WAZUH_AGENT_NAME"
Write-Host "  Manager: ${WAZUH_MANAGER_IP}:${WAZUH_MANAGER_PORT}"
Write-Host "  Path: $agentPath"
Write-Host "  Service: WazuhSvc"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Check Wazuh Dashboard at http://192.168.1.7:5601"
Write-Host "2. Go to Agents section to authorize the Windows agent"
Write-Host "3. Verify connection in Dashboard"
Write-Host ""
Write-Host "Agent Logs:" -ForegroundColor Yellow
$logPath = "$agentPath\ossec.log"
if (Test-Path $logPath) {
    Get-Content $logPath -Tail 10 | Write-Host
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Cleanup temp files
Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue

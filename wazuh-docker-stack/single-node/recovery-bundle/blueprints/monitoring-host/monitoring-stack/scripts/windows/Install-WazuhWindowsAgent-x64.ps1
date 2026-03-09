param(
    [string]$Architecture = "64-bit"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "Wazuh Windows Agent Installer (x64)" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

# Configuration
$MANAGER_IP = "192.168.1.7"
$MANAGER_PORT = "1514"
$AGENT_NAME = "Windows-Monitoring"
$WAZUH_VERSION = "4.14.3"
$INSTALL_DIR = "C:\Program Files\ossec-agent"

# Create temp directory
$tempDir = "$env:TEMP\Wazuh"
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

Write-Host "[*] Configuration:" -ForegroundColor Cyan
Write-Host "    Manager: $MANAGER_IP"
Write-Host "    Port: $MANAGER_PORT"
Write-Host "    Agent Name: $AGENT_NAME"
Write-Host "    Installation Path: $INSTALL_DIR"
Write-Host ""

# Download 64-bit MSI
Write-Host "[*] Downloading Wazuh Agent x64 ($WAZUH_VERSION)..."
$msiPath = "$tempDir\wazuh-agent-$WAZUH_VERSION-1.msi"
$downloadUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WAZUH_VERSION-1.msi"

try {
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($downloadUrl, $msiPath)
    Write-Host "[+] Downloaded: $msiPath" -ForegroundColor Green
    Write-Host "    Size: $((Get-Item $msiPath).Length / 1MB -as [int])MB" -ForegroundColor Green
} catch {
    Write-Host "[-] Download failed: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Installation options
$msiArgs = @(
    "/i `"$msiPath`""
    "/quiet"
    "/norestart"
    "WAZUH_MANAGER=$MANAGER_IP"
    "WAZUH_MANAGER_PORT=$MANAGER_PORT"
    "WAZUH_AGENT_NAME=`"$AGENT_NAME`""
    "WAZUH_AGENT_GROUP=default"
)

Write-Host "[*] Installing Wazuh Agent..."
Write-Host "    Command: msiexec.exe $($msiArgs -join ' ')"
Write-Host ""

# Execute installation with detailed error tracking
try {
    $process = Start-Process "msiexec.exe" `
        -ArgumentList ($msiArgs -join " ") `
        -Wait `
        -PassThru `
        -NoNewWindow

    $exitCode = $process.ExitCode
    Write-Host "[*] Installation completed with exit code: $exitCode" -ForegroundColor Yellow
    
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        Write-Host "[+] Installation successful!" -ForegroundColor Green
        Write-Host ""
        
        # Verify installation
        Write-Host "[*] Verifying installation..."
        Start-Sleep -Seconds 3
        
        if (Test-Path "$INSTALL_DIR\ossec.conf") {
            Write-Host "[+] Agent configuration found" -ForegroundColor Green
            
            # Check ossec.conf
            $confContent = Get-Content "$INSTALL_DIR\ossec.conf" -Raw
            if ($confContent -match $MANAGER_IP) {
                Write-Host "[+] Manager IP configured correctly" -ForegroundColor Green
            }
        }
        
        # Check Windows service
        $service = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
        if ($service) {
            Write-Host "[+] WazuhSvc service found" -ForegroundColor Green
            
            if ($service.Status -eq "Running") {
                Write-Host "[+] WazuhSvc is RUNNING" -ForegroundColor Green
            } else {
                Write-Host "[*] WazuhSvc status: $($service.Status)" -ForegroundColor Yellow
                Write-Host "[*] Attempting to start service..."
                Start-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
                Write-Host "[+] Service start command issued" -ForegroundColor Green
            }
        } else {
            Write-Host "[-] WazuhSvc service not found" -ForegroundColor Red
        }
        
    } else {
        Write-Host "[-] Installation failed with exit code: $exitCode" -ForegroundColor Red
        
        # Common MSI error codes
        $errorCodes = @{
            1603 = "General error (often indicates prerequisite missing or permission issue)"
            1619 = "Installation package not found"
            1637 = "This installation package is not supported on this platform"
            1638 = "Another version of this product is already installed"
            1645 = "Windows Installer does not permit installation from a Remote Desktop Connection"
        }
        
        if ($errorCodes.ContainsKey($exitCode)) {
            Write-Host "    Possible cause: $($errorCodes[$exitCode])" -ForegroundColor Yellow
        }
    }
    
} catch {
    Write-Host "[-] Installation process failed: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "Installation Summary" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Check Windows Services: WazuhSvc status"
Write-Host "2. Verify logs: dir $INSTALL_DIR\logs\"
Write-Host "3. Check configuration: type $INSTALL_DIR\ossec.conf"
Write-Host "4. Monitor Wazuh Dashboard at: http://192.168.1.7:5601"
Write-Host ""

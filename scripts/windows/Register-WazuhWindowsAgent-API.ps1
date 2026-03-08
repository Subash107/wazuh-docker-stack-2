# Alternative approach - Register agent via Wazuh API then configure manually

param(
    [string]$WazuhApiUrl = "https://192.168.1.7:55000",
    [string]$WazuhApiUser = "wazuh-wui",
    [string]$WazuhApiPass = $env:WAZUH_API_PASS,
    [string]$AgentName = "Windows-Monitoring",
    [string]$ManagerIp = "192.168.1.7"
)

if ([string]::IsNullOrWhiteSpace($WazuhApiPass)) {
    throw "Set -WazuhApiPass or the WAZUH_API_PASS environment variable before running this script."
}

Write-Host "==========================================" -ForegroundColor Yellow
Write-Host "Wazuh Agent Registration via API" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow
Write-Host ""

# Disable certificate validation for demo purposes
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# Get auth token
Write-Host "[*] Authenticating to Wazuh API..."
try {
    $auth = @{
        user = $WazuhApiUser
        password = $WazuhApiPass
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri "$WazuhApiUrl/security/user/authenticate" `
        -Method POST `
        -Body $auth `
        -ContentType "application/json" `
        -SkipCertificateCheck
    
    $token = $response.data.token
    Write-Host "[+] Authentication successful" -ForegroundColor Green
    Write-Host "Token: $($token.Substring(0, 20))..." -ForegroundColor Green

} catch {
    Write-Host "[-] Authentication failed: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Wazuh API Details:" -ForegroundColor Yellow
    Write-Host "  URL: $WazuhApiUrl"
    Write-Host "  User: $WazuhApiUser"
    Write-Host ""
    Write-Host "Attempting direct Windows installation instead..." -ForegroundColor Yellow
    exit 0
}

# Add agent
Write-Host "[*] Adding Windows agent to Wazuh..."
try {  
    $agentData = @{
        name = $AgentName
        ip = "any"
    } | ConvertTo-Json

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $response = Invoke-RestMethod -Uri "$WazuhApiUrl/agents" `
        -Method POST `
        -Body $agentData `
        -Headers $headers `
        -SkipCertificateCheck

    Write-Host "[+] Agent added successfully" -ForegroundColor Green
    $agentId = $response.data.id
    Write-Host "Agent ID: $agentId" -ForegroundColor Green
    Write-Host ""
    Write-Host "To complete the agent setup:" -ForegroundColor Yellow
    Write-Host "1. Download Wazuh Agent for Windows from:"
    Write-Host "   https://packages.wazuh.com/4.x/windows/"
    Write-Host ""
    Write-Host "2. Install with the following parameters:"
    Write-Host "   - Manager IP: $ManagerIp"
    Write-Host "   - Manager Port: 1514"
    Write-Host "   - Agent Name: $AgentName"
    Write-Host "   - Agent ID: $agentId"
    Write-Host ""

} catch {
    Write-Host "[-] Failed to add agent: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Yellow

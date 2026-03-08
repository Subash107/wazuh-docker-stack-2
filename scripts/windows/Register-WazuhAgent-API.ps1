param(
    [string]$AgentName = "Windows-Monitoring",
    [string]$AgentIP = "192.168.1.7",
    [string]$WazuhApiUrl = "https://192.168.1.7:55000",
    [string]$WazuhUser = "admin",
    [string]$WazuhPass = $env:WAZUH_API_PASS
)

# Configure TLS and disable certificate validation for self-signed certs
[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
[System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($WazuhPass)) {
    throw "Set -WazuhPass or the WAZUH_API_PASS environment variable before running this script."
}

Write-Host "Wazuh Windows Agent Registration via API" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Agent Name: $AgentName" -ForegroundColor Yellow
Write-Host "Agent IP: $AgentIP" -ForegroundColor Yellow
Write-Host ""

try {
    # Step 1: Authenticate
    Write-Host "[*] Authenticating to Wazuh API..." -ForegroundColor Yellow
    $authBody = @{
        user = $WazuhUser
        password = $WazuhPass
    } | ConvertTo-Json
    
    $authResponse = Invoke-RestMethod -Uri "$WazuhApiUrl/security/user/authenticate" `
        -Method POST `
        -Body $authBody `
        -ContentType "application/json" `
        -ErrorAction Stop
    
    $token = $authResponse.data.token
    Write-Host "[+] Authentication successful" -ForegroundColor Green
    
    # Step 2: Check for existing agent
    Write-Host "[*] Checking for existing agent '$AgentName'..." -ForegroundColor Yellow
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    $agentsResponse = Invoke-RestMethod -Uri "$WazuhApiUrl/agents?pretty=true&select=id,name" `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop
    
    $existingAgent = $agentsResponse.data.affected_items | Where-Object {$_.name -eq $AgentName}
    if ($existingAgent) {
        Write-Host "[!] Agent already registered" -ForegroundColor Yellow
        Write-Host "    Agent ID: $($existingAgent.id)" -ForegroundColor Green
        Write-Host "    Agent Name: $($existingAgent.name)" -ForegroundColor Green
        $agentId = $existingAgent.id
    } else {
        # Step 3: Add new agent
        Write-Host "[*] Registering new agent..." -ForegroundColor Yellow
        $addAgentBody = @{
            name = $AgentName
            ip = $AgentIP
        } | ConvertTo-Json
        
        $addResponse = Invoke-RestMethod -Uri "$WazuhApiUrl/agents" `
            -Method POST `
            -Headers $headers `
            -Body $addAgentBody `
            -ErrorAction Stop
        
        $agent = $addResponse.data
        $agentId = $agent.id
        Write-Host "[+] Agent registered successfully!" -ForegroundColor Green
        Write-Host "    Agent ID: $agentId" -ForegroundColor Green
        Write-Host "    Agent Name: $($agent.name)" -ForegroundColor Green
        Write-Host "    Agent IP: $($agent.ip)" -ForegroundColor Green
    }
    
    # Step 4: Get agent key
    Write-Host ""
    Write-Host "[*] Retrieving agent key from manager..." -ForegroundColor Yellow
    
    # Export agent key as file (extracts from manager's internal database)
    $exportResponse = Invoke-RestMethod -Uri "$WazuhApiUrl/agents/$agentId/key/export" `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop
    
    $agentKey = $exportResponse.data.key
    
    if ($agentKey) {
        Write-Host "[+] Agent key retrieved!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Agent Key:" -ForegroundColor Cyan
        Write-Host "$agentKey" -ForegroundColor Green
        
        Write-Host ""
        Write-Host "Saving key to file for Windows agent..." -ForegroundColor Yellow
        $agentKey | Out-File -FilePath "C:\Windows\Temp\wazuh-agent-key.txt" -Encoding ASCII
        Write-Host "[+] Saved to: C:\Windows\Temp\wazuh-agent-key.txt" -ForegroundColor Green
    } else {
        Write-Host "[!] Could not retrieve agent key from manager" -ForegroundColor Yellow
        Write-Host "    Agent may need to contact manager first to generate key" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "1. The Windows agent should now auto-enroll with the manager"
    Write-Host "2. Start the WazuhSvc service: Start-Service WazuhSvc"
    Write-Host "3. Check Wazuh Dashboard for agent status"
    
} catch {
    Write-Host "[-] Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Details:" -ForegroundColor Yellow
    Write-Host $_ 
    exit 1
}

Write-Host ""

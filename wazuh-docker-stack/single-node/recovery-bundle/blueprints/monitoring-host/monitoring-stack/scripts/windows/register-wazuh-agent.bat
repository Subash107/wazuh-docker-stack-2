@echo off
REM Wazuh Agent Registration Script
REM This script registers the Windows Wazuh agent with the manager

echo.
echo ========================================
echo Wazuh Agent Registration
echo ========================================
echo.

set AGENT_DIR=C:\Program Files (x86)\ossec-agent
set AUTH_TOOL=%AGENT_DIR%\agent-auth.exe
set MANAGER_IP=192.168.1.7
set MANAGER_PORT=1515
set AGENT_NAME=Windows-Monitoring

if not exist "%AUTH_TOOL%" (
    echo Error: agent-auth.exe not found at %AUTH_TOOL%
    exit /b 1
)

echo Running agent registration...
echo Command: "%AUTH_TOOL%" -m %MANAGER_IP% -p %MANAGER_PORT% -A %AGENT_NAME%
echo.

"%AUTH_TOOL%" -m %MANAGER_IP% -p %MANAGER_PORT% -A %AGENT_NAME%

echo.
echo Registration complete.
echo Checking client.keys file...
dir "%AGENT_DIR%\client.keys"

echo.
echo Starting WazuhSvc service...
net start WazuhSvc

echo.
echo Service status:
sc query WazuhSvc

echo.
echo ========================================
echo Registration finished
echo ========================================

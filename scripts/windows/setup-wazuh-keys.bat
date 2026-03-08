@echo off
REM Write Wazuh agent key file with admin privileges

echo Setting up Wazuh agent key...

setlocal enabledelayedexpansion

set agentdir=C:\Program Files (x86)\ossec-agent
set keyfile=%agentdir%\client.keys
set agentkey=MDAxIFdpbmRvd3MtTW9uaXRvcmluZyAxOTIuMTY4LjEuNyA0NjBiZjIxNDEyNGJlODQ5MjExODNkNDkwMzVlZmUxYmYyZTExYWI2MTNlOGY2NGMxMjJlNmYxMzA0MjNhMmZi

REM Delete existing file
if exist "%keyfile%" (
    echo Removing old client.keys...
    del /F /Q "%keyfile%"
    timeout /T 1 /NOBREAK > nul
)

REM Create new file with key
echo Creating new client.keys file...
(
    echo !agentkey!
) > "%keyfile%"

if exist "%keyfile%" (
    echo.
    echo [SUCCESS] client.keys created
    dir "%keyfile%"
) else (
    echo [ERROR] Failed to create client.keys
)

echo.
echo Starting WazuhSvc service...
net start WazuhSvc

echo.
echo Service status:
sc query WazuhSvc

echo.
echo Done!

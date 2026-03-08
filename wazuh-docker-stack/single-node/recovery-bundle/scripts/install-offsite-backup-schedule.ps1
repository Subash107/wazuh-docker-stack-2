param(
    [string]$TaskName = "Monitoring-Offsite-Backup",
    [string]$DailyAt = "02:30",
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "config\offsite-backup.env"),
    [switch]$RunWhenLoggedOut,
    [string]$UserName = "$env:USERDOMAIN\$env:USERNAME",
    [string]$PasswordFile,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$runnerScript = Join-Path $PSScriptRoot "run-offsite-backup.ps1"
if (-not (Test-Path $runnerScript)) {
    throw "Runner script '$runnerScript' was not found."
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config file '$ConfigPath' was not found."
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask -and -not $Force) {
    throw "Task '$TaskName' already exists. Re-run with -Force to replace it."
}
if ($existingTask -and $Force) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -ConfigPath `"$ConfigPath`""
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($DailyAt, "HH:mm", $null))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$description = "Runs the portable monitoring recovery bundle backup and off-host upload job."

if ($RunWhenLoggedOut) {
    if (-not $PasswordFile) {
        throw "PasswordFile is required with -RunWhenLoggedOut."
    }
    if (-not (Test-Path $PasswordFile)) {
        throw "Password file '$PasswordFile' was not found."
    }

    $password = (Get-Content $PasswordFile -Raw).Trim()
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description $description -User $UserName -Password $password | Out-Null
    Write-Host "Scheduled task '$TaskName' installed for user '$UserName'. It will run even when the user is logged out."
}
else {
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description $description -Principal $principal | Out-Null
    Write-Host "Scheduled task '$TaskName' installed for interactive runs as '$UserName'."
    Write-Host "This mode requires the user session to be logged in at the scheduled time."
}

Write-Host "Runner: $runnerScript"
Write-Host "Config: $ConfigPath"
Write-Host "Time: $DailyAt"

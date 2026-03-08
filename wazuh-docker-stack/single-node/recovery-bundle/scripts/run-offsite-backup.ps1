param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "config\offsite-backup.env"),
    [switch]$SkipLocalBackup,
    [switch]$SkipOffsiteUpload,
    [switch]$SkipRetention
)

$ErrorActionPreference = "Stop"

$bundleRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $bundleRoot -Parent
$backupRoot = Join-Path $bundleRoot "backups"
$logRoot = Join-Path $bundleRoot "logs\offsite-backup"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $logRoot "offsite-backup-$runId.log"

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

function Write-RunLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -Path $script:logPath -Value $line
}

function Load-EnvConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Config file '$Path' was not found."
    }

    $map = @{}
    foreach ($rawLine in Get-Content $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            throw "Invalid config line '$rawLine' in '$Path'."
        }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if ($value.Length -ge 2) {
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $map[$key] = $value
    }

    return $map
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [string]$Default,
        [switch]$Required
    )

    if ($Config.ContainsKey($Key) -and $Config[$Key]) {
        return $Config[$Key]
    }

    if ($Required) {
        throw "Config key '$Key' is required."
    }

    return $Default
}

function Get-SecretValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [switch]$Required
    )

    $fileKey = "${Name}_FILE"
    if ($Config.ContainsKey($fileKey) -and $Config[$fileKey]) {
        $secretPath = $Config[$fileKey]
        if (-not (Test-Path $secretPath)) {
            throw "Secret file '$secretPath' for '$Name' does not exist."
        }

        return (Get-Content $secretPath -Raw).Trim()
    }

    if ($Config.ContainsKey($Name) -and $Config[$Name]) {
        return $Config[$Name]
    }

    if ($Required) {
        throw "Secret '$Name' is required."
    }

    return $null
}

function Invoke-RobocopySafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [switch]$Mirror
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $args = @(
        $Source,
        $Destination
    )
    if ($Mirror) {
        $args += "/MIR"
    } else {
        $args += "/E"
    }

    $args += @("/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    & robocopy @args | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed while copying '$Source' to '$Destination' (exit code $LASTEXITCODE)."
    }
}

function Join-RemotePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base,
        [Parameter(Mandatory = $true)]
        [string]$Child
    )

    return ($Base.TrimEnd("/") + "/" + $Child.TrimStart("/"))
}

function Get-LatestLocalStamp {
    $stampFile = Join-Path $repoRoot ".bundle_stamp"
    if (-not (Test-Path $stampFile)) {
        throw "Bundle stamp file '$stampFile' does not exist."
    }

    return (Get-Content $stampFile -Raw).Trim()
}

function Get-LocalSnapshotPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stamp
    )

    $monitoringPath = Join-Path $backupRoot "monitoring-host\$Stamp"
    $metadataPath = Join-Path $backupRoot "metadata\$Stamp"
    $sensorArchive = Get-ChildItem (Join-Path $backupRoot "sensor-vm") -Filter "*-$Stamp.tgz" | Select-Object -First 1

    if (-not (Test-Path $monitoringPath)) {
        throw "Local monitoring snapshot '$monitoringPath' does not exist."
    }
    if (-not (Test-Path $metadataPath)) {
        throw "Local metadata snapshot '$metadataPath' does not exist."
    }
    if (-not $sensorArchive) {
        throw "Local sensor VM archive for stamp '$Stamp' was not found."
    }

    return [pscustomobject]@{
        Stamp = $Stamp
        MonitoringPath = $monitoringPath
        MetadataPath = $metadataPath
        SensorArchivePath = $sensorArchive.FullName
        SensorArchiveName = $sensorArchive.Name
    }
}

function Get-LocalStamps {
    $stamps = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($root in @("monitoring-host", "metadata")) {
        $path = Join-Path $backupRoot $root
        if (Test-Path $path) {
            foreach ($dir in Get-ChildItem $path -Directory) {
                [void]$stamps.Add($dir.Name)
            }
        }
    }

    $sensorRoot = Join-Path $backupRoot "sensor-vm"
    if (Test-Path $sensorRoot) {
        foreach ($file in Get-ChildItem $sensorRoot -Filter "*.tgz") {
            if ($file.BaseName -match '(\d{8}-\d{6})$') {
                [void]$stamps.Add($matches[1])
            }
        }
    }

    return @($stamps) | Sort-Object -Descending
}

function Remove-LocalSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stamp
    )

    foreach ($path in @(
        (Join-Path $backupRoot "monitoring-host\$Stamp"),
        (Join-Path $backupRoot "metadata\$Stamp")
    )) {
        if (Test-Path $path) {
            Remove-Item -Recurse -Force $path
        }
    }

    $sensorRoot = Join-Path $backupRoot "sensor-vm"
    if (Test-Path $sensorRoot) {
        Get-ChildItem $sensorRoot -Filter "*-$Stamp.tgz" | Remove-Item -Force
    }
}

function Enforce-LocalRetention {
    param(
        [Parameter(Mandatory = $true)]
        [int]$KeepCount,
        [string]$ProtectStamp
    )

    if ($KeepCount -lt 1) {
        return
    }

    $ordered = Get-LocalStamps | Where-Object { $_ -ne $ProtectStamp }
    $toDelete = $ordered | Select-Object -Skip ($KeepCount - 1)
    foreach ($stamp in $toDelete) {
        Write-RunLog "Pruning local snapshot stamp $stamp"
        Remove-LocalSnapshot -Stamp $stamp
    }
}

function Enforce-LogRetention {
    param(
        [Parameter(Mandatory = $true)]
        [int]$KeepCount
    )

    if ($KeepCount -lt 1) {
        return
    }

    Get-ChildItem $logRoot -Filter "*.log" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepCount |
        Remove-Item -Force
}

function Ensure-RcloneExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $systemRclone = Get-Command rclone -ErrorAction SilentlyContinue
    if ($systemRclone) {
        return $systemRclone.Source
    }

    $toolRoot = Join-Path $bundleRoot "tools\rclone"
    $portableExe = Join-Path $toolRoot "rclone.exe"
    if (Test-Path $portableExe) {
        return $portableExe
    }

    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
    $downloadUrl = Get-ConfigValue -Config $Config -Key "RCLONE_DOWNLOAD_URL" -Default "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
    $zipPath = Join-Path $toolRoot "rclone.zip"
    $extractPath = Join-Path $toolRoot "extract"

    Write-RunLog "Downloading portable rclone from $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
    if (Test-Path $extractPath) {
        Remove-Item -Recurse -Force $extractPath
    }

    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    $downloadedExe = Get-ChildItem $extractPath -Recurse -Filter "rclone.exe" | Select-Object -First 1
    if (-not $downloadedExe) {
        throw "Portable rclone download completed but rclone.exe was not found."
    }

    Copy-Item $downloadedExe.FullName $portableExe -Force
    Remove-Item -Force $zipPath
    Remove-Item -Recurse -Force $extractPath
    return $portableExe
}

function Invoke-Rclone {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$ConfigPathOverride
    )

    $exe = $script:rcloneExe
    $finalArgs = @()
    if ($ConfigPathOverride) {
        $finalArgs += "--config"
        $finalArgs += $ConfigPathOverride
    }
    $finalArgs += $Arguments

    Write-RunLog ("rclone " + ($finalArgs -join " "))
    & $exe @finalArgs
    if ($LASTEXITCODE -ne 0) {
        throw "rclone failed with exit code $LASTEXITCODE."
    }
}

function Publish-BlueprintsFilesystem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )

    New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
    Copy-Item (Join-Path $bundleRoot "README.md") (Join-Path $TargetRoot "README.md") -Force
    Invoke-RobocopySafe -Source (Join-Path $bundleRoot "blueprints") -Destination (Join-Path $TargetRoot "blueprints") -Mirror
    Invoke-RobocopySafe -Source (Join-Path $bundleRoot "scripts") -Destination (Join-Path $TargetRoot "scripts") -Mirror
}

function Publish-SnapshotFilesystem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $snapshotRoot = Join-Path $TargetRoot "snapshots\$($Snapshot.Stamp)"
    $summary = [ordered]@{
        bundle_stamp = $Snapshot.Stamp
        published_at = (Get-Date).ToString("o")
        sensor_archive = $Snapshot.SensorArchiveName
        monitoring_snapshot = "snapshots/$($Snapshot.Stamp)/monitoring-host"
        metadata_snapshot = "snapshots/$($Snapshot.Stamp)/metadata"
    }
    $summaryPath = Join-Path $env:TEMP "snapshot-$($Snapshot.Stamp)-summary.json"
    $summary | ConvertTo-Json -Depth 4 | Out-File -FilePath $summaryPath -Encoding utf8

    New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
    Invoke-RobocopySafe -Source $Snapshot.MonitoringPath -Destination (Join-Path $snapshotRoot "monitoring-host") -Mirror
    Invoke-RobocopySafe -Source $Snapshot.MetadataPath -Destination (Join-Path $snapshotRoot "metadata") -Mirror
    Copy-Item $Snapshot.SensorArchivePath (Join-Path $snapshotRoot $Snapshot.SensorArchiveName) -Force
    Copy-Item $summaryPath (Join-Path $snapshotRoot "summary.json") -Force
    Set-Content -Path (Join-Path $TargetRoot "latest.txt") -Value $Snapshot.Stamp
    Copy-Item $logPath (Join-Path $TargetRoot ("offsite-run-" + $runId + ".log")) -Force
    Remove-Item -Force $summaryPath
}

function Publish-BlueprintsRclone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [string]$RcloneConfigPath
    )

    Invoke-Rclone -Arguments @("copyto", (Join-Path $bundleRoot "README.md"), (Join-RemotePath $TargetRoot "README.md")) -ConfigPathOverride $RcloneConfigPath
    Invoke-Rclone -Arguments @("sync", (Join-Path $bundleRoot "blueprints"), (Join-RemotePath $TargetRoot "blueprints")) -ConfigPathOverride $RcloneConfigPath
    Invoke-Rclone -Arguments @("sync", (Join-Path $bundleRoot "scripts"), (Join-RemotePath $TargetRoot "scripts")) -ConfigPathOverride $RcloneConfigPath
}

function Publish-SnapshotRclone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [Parameter(Mandatory = $true)]
        $Snapshot,
        [string]$RcloneConfigPath
    )

    $snapshotRoot = Join-RemotePath $TargetRoot ("snapshots/" + $Snapshot.Stamp)
    $summary = [ordered]@{
        bundle_stamp = $Snapshot.Stamp
        published_at = (Get-Date).ToString("o")
        sensor_archive = $Snapshot.SensorArchiveName
        monitoring_snapshot = "snapshots/$($Snapshot.Stamp)/monitoring-host"
        metadata_snapshot = "snapshots/$($Snapshot.Stamp)/metadata"
    }
    $summaryPath = Join-Path $env:TEMP "snapshot-$($Snapshot.Stamp)-summary.json"
    $latestPath = Join-Path $env:TEMP "snapshot-$($Snapshot.Stamp)-latest.txt"

    $summary | ConvertTo-Json -Depth 4 | Out-File -FilePath $summaryPath -Encoding utf8
    Set-Content -Path $latestPath -Value $Snapshot.Stamp

    Invoke-Rclone -Arguments @("copy", $Snapshot.MonitoringPath, (Join-RemotePath $snapshotRoot "monitoring-host")) -ConfigPathOverride $RcloneConfigPath
    Invoke-Rclone -Arguments @("copy", $Snapshot.MetadataPath, (Join-RemotePath $snapshotRoot "metadata")) -ConfigPathOverride $RcloneConfigPath
    Invoke-Rclone -Arguments @("copyto", $Snapshot.SensorArchivePath, (Join-RemotePath $snapshotRoot $Snapshot.SensorArchiveName)) -ConfigPathOverride $RcloneConfigPath
    Invoke-Rclone -Arguments @("copyto", $summaryPath, (Join-RemotePath $snapshotRoot "summary.json")) -ConfigPathOverride $RcloneConfigPath
    Invoke-Rclone -Arguments @("copyto", $latestPath, (Join-RemotePath $TargetRoot "latest.txt")) -ConfigPathOverride $RcloneConfigPath
    Invoke-Rclone -Arguments @("copyto", $logPath, (Join-RemotePath $TargetRoot ("offsite-run-" + $runId + ".log"))) -ConfigPathOverride $RcloneConfigPath

    Remove-Item -Force $summaryPath, $latestPath
}

function Enforce-RemoteRetentionFilesystem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [Parameter(Mandatory = $true)]
        [int]$KeepCount,
        [string]$ProtectStamp
    )

    if ($KeepCount -lt 1) {
        return
    }

    $snapshotRoot = Join-Path $TargetRoot "snapshots"
    if (-not (Test-Path $snapshotRoot)) {
        return
    }

    $ordered = Get-ChildItem $snapshotRoot -Directory | Sort-Object Name -Descending | Select-Object -ExpandProperty Name | Where-Object { $_ -ne $ProtectStamp }
    $toDelete = $ordered | Select-Object -Skip ($KeepCount - 1)
    foreach ($stamp in $toDelete) {
        Write-RunLog "Pruning remote filesystem snapshot stamp $stamp"
        Remove-Item -Recurse -Force (Join-Path $snapshotRoot $stamp)
    }
}

function Enforce-RemoteRetentionRclone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [Parameter(Mandatory = $true)]
        [int]$KeepCount,
        [string]$ProtectStamp,
        [string]$RcloneConfigPath
    )

    if ($KeepCount -lt 1) {
        return
    }

    $snapshotRoot = Join-RemotePath $TargetRoot "snapshots"
    $lsfArgs = @()
    if ($RcloneConfigPath) {
        $lsfArgs += "--config"
        $lsfArgs += $RcloneConfigPath
    }
    $lsfArgs += @("lsf", $snapshotRoot, "--dirs-only")
    $listing = & $script:rcloneExe @lsfArgs
    if ($LASTEXITCODE -ne 0) {
        throw "rclone lsf failed with exit code $LASTEXITCODE."
    }

    $ordered = $listing |
        ForEach-Object { $_.TrimEnd("/") } |
        Where-Object { $_ } |
        Sort-Object -Descending |
        Where-Object { $_ -ne $ProtectStamp }

    $toDelete = $ordered | Select-Object -Skip ($KeepCount - 1)
    foreach ($stamp in $toDelete) {
        Write-RunLog "Pruning remote rclone snapshot stamp $stamp"
        Invoke-Rclone -Arguments @("purge", (Join-RemotePath $snapshotRoot $stamp)) -ConfigPathOverride $RcloneConfigPath
    }
}

try {
    Write-RunLog "Starting off-host backup run"
    $config = Load-EnvConfig -Path $ConfigPath
    $jobName = Get-ConfigValue -Config $config -Key "JOB_NAME" -Default "Monitoring Offsite Backup"
    $targetType = (Get-ConfigValue -Config $config -Key "TARGET_TYPE" -Default "filesystem").ToLowerInvariant()
    $targetRoot = Get-ConfigValue -Config $config -Key "TARGET_ROOT" -Required
    $localKeepCount = [int](Get-ConfigValue -Config $config -Key "LOCAL_KEEP_COUNT" -Default "7")
    $remoteKeepCount = [int](Get-ConfigValue -Config $config -Key "REMOTE_KEEP_COUNT" -Default "30")
    $logKeepCount = [int](Get-ConfigValue -Config $config -Key "LOG_KEEP_COUNT" -Default "30")
    $hostRoot = Get-ConfigValue -Config $config -Key "HOST_ROOT" -Default "D:\Monitoring"
    $vmAddress = Get-ConfigValue -Config $config -Key "VM_ADDRESS" -Default "192.168.1.6"
    $vmUser = Get-ConfigValue -Config $config -Key "VM_SSH_USER" -Default "subash"
    $vmSshPassword = Get-SecretValue -Config $config -Name "VM_SSH_PASSWORD" -Required
    $vmSudoPassword = Get-SecretValue -Config $config -Name "VM_SUDO_PASSWORD" -Required

    Write-RunLog "Job name: $jobName"
    Write-RunLog "Target type: $targetType"

    if (-not $SkipLocalBackup) {
        Write-RunLog "Running local recovery bundle backup"
        & (Join-Path $PSScriptRoot "backup-current-state.ps1") `
            -VmAddress $vmAddress `
            -SshUser $vmUser `
            -SshPassword $vmSshPassword `
            -SudoPassword $vmSudoPassword `
            -HostRoot $hostRoot
    } else {
        Write-RunLog "Skipping local recovery bundle backup by request" "WARN"
    }

    $snapshot = Get-LocalSnapshotPaths -Stamp (Get-LatestLocalStamp)
    Write-RunLog "Using bundle snapshot stamp $($snapshot.Stamp)"

    if (-not $SkipOffsiteUpload) {
        switch ($targetType) {
            "filesystem" {
                Write-RunLog "Publishing bundle snapshot to filesystem target '$targetRoot'"
                Publish-BlueprintsFilesystem -TargetRoot $targetRoot
                Publish-SnapshotFilesystem -TargetRoot $targetRoot -Snapshot $snapshot
            }
            "rclone" {
                $script:rcloneExe = Ensure-RcloneExecutable -Config $config
                $rcloneConfigPath = Get-ConfigValue -Config $config -Key "RCLONE_CONFIG_PATH" -Default $null
                if ($rcloneConfigPath -and -not (Test-Path $rcloneConfigPath)) {
                    throw "Configured rclone config file '$rcloneConfigPath' does not exist."
                }

                Write-RunLog "Publishing bundle snapshot to rclone target '$targetRoot' using '$script:rcloneExe'"
                Publish-BlueprintsRclone -TargetRoot $targetRoot -RcloneConfigPath $rcloneConfigPath
                Publish-SnapshotRclone -TargetRoot $targetRoot -Snapshot $snapshot -RcloneConfigPath $rcloneConfigPath
            }
            default {
                throw "Unsupported TARGET_TYPE '$targetType'. Use 'filesystem' or 'rclone'."
            }
        }
    } else {
        Write-RunLog "Skipping off-host upload by request" "WARN"
    }

    if (-not $SkipRetention) {
        Enforce-LocalRetention -KeepCount $localKeepCount -ProtectStamp $snapshot.Stamp
        switch ($targetType) {
            "filesystem" {
                if (-not $SkipOffsiteUpload) {
                    Enforce-RemoteRetentionFilesystem -TargetRoot $targetRoot -KeepCount $remoteKeepCount -ProtectStamp $snapshot.Stamp
                }
            }
            "rclone" {
                if (-not $SkipOffsiteUpload) {
                    $rcloneConfigPath = Get-ConfigValue -Config $config -Key "RCLONE_CONFIG_PATH" -Default $null
                    Enforce-RemoteRetentionRclone -TargetRoot $targetRoot -KeepCount $remoteKeepCount -ProtectStamp $snapshot.Stamp -RcloneConfigPath $rcloneConfigPath
                }
            }
        }
        Enforce-LogRetention -KeepCount $logKeepCount
    } else {
        Write-RunLog "Skipping retention by request" "WARN"
    }

    Write-RunLog "Off-host backup run finished successfully"
}
catch {
    Write-RunLog $_.Exception.Message "ERROR"
    throw
}

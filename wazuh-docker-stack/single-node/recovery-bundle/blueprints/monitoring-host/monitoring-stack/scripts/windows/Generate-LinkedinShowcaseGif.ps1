param(
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$assetsDir = Join-Path $repoRoot "media\assets\linkedin"
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot "media\assets\monitoring-stack-linkedin-showcase.gif"
}

$inputs = @(
    (Join-Path $assetsDir "linkedin-square-project-card-1080x1080.png"),
    (Join-Path $assetsDir "linkedin-carousel-01-architecture-1080x1350.png"),
    (Join-Path $assetsDir "linkedin-carousel-02-upgrade-highlights-1080x1350.png"),
    (Join-Path $assetsDir "linkedin-carousel-03-delivery-recovery-1080x1350.png")
)

foreach ($input in $inputs) {
    if (-not (Test-Path $input)) {
        throw "Missing slide '$input'. Run Generate-LinkedinMediaAssets.ps1 first."
    }
}

function Get-FfmpegPath {
    $command = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $toolRoot = Join-Path $env:TEMP "monitoring-ffmpeg"
    $archiveName = "ffmpeg-8.0.1-essentials_build.zip"
    $zipPath = Join-Path $toolRoot $archiveName
    $extractRoot = Join-Path $toolRoot "extract"
    $ffmpegExe = Get-ChildItem -Path $extractRoot -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($ffmpegExe) {
        return $ffmpegExe.FullName
    }

    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
    $url = "https://github.com/GyanD/codexffmpeg/releases/download/8.0.1/$archiveName"
    $needsDownload = -not (Test-Path $zipPath)
    if (-not $needsDownload) {
        $existingArchive = Get-Item $zipPath
        $needsDownload = $existingArchive.Length -lt 1MB
    }

    if ($needsDownload) {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri $url -OutFile $zipPath
    }

    if (Test-Path $extractRoot) {
        Remove-Item -Recurse -Force $extractRoot
    }

    Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force
    $ffmpegExe = Get-ChildItem -Path $extractRoot -Filter ffmpeg.exe -Recurse | Select-Object -First 1

    if (-not $ffmpegExe) {
        throw "ffmpeg.exe was not found after extracting '$zipPath'."
    }

    return $ffmpegExe.FullName
}

$ffmpegPath = Get-FfmpegPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$filter = @"
[0:v]fps=12,scale=1080:1080:flags=lanczos,pad=1080:1350:0:135:#F7EFE4,setsar=1[v0];
[1:v]fps=12,scale=1080:1350:flags=lanczos,setsar=1[v1];
[2:v]fps=12,scale=1080:1350:flags=lanczos,setsar=1[v2];
[3:v]fps=12,scale=1080:1350:flags=lanczos,setsar=1[v3];
[v0][v1]xfade=transition=fade:duration=0.45:offset=1.75[x1];
[x1][v2]xfade=transition=fade:duration=0.45:offset=3.50[x2];
[x2][v3]xfade=transition=fade:duration=0.45:offset=5.25[anim];
[anim]split[gifsrc][palsrc];
[palsrc]palettegen=stats_mode=single[pal];
[gifsrc][pal]paletteuse=dither=bayer:bayer_scale=3
"@

$args = @(
    "-y",
    "-loop", "1", "-t", "2.2", "-i", $inputs[0],
    "-loop", "1", "-t", "2.2", "-i", $inputs[1],
    "-loop", "1", "-t", "2.2", "-i", $inputs[2],
    "-loop", "1", "-t", "2.2", "-i", $inputs[3],
    "-filter_complex", $filter,
    "-loop", "0",
    $OutputPath
)

& $ffmpegPath @args

if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg exited with code $LASTEXITCODE."
}

Get-Item $OutputPath | Format-List Name, Length, FullName

param(
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot "media\assets\linkedin"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$Palette = @{
    Cream = "#F7EFE4"
    Sand = "#E8D3BC"
    Peach = "#FFD3B6"
    Ink = "#0A1620"
    Navy = "#102736"
    NavySoft = "#17384A"
    Slate = "#587484"
    Line = "#D6C2AE"
    Teal = "#23A89E"
    Mint = "#8CE0D0"
    Coral = "#F26A4B"
    Orange = "#FF9B54"
    Gold = "#F1C75B"
    White = "#FFFDFC"
    Panel = "#0F2230"
    PanelAlt = "#153142"
    MutedText = "#6D7F89"
}

function New-Point($X, $Y) {
    return New-Object System.Windows.Point($X, $Y)
}

function New-Rect($X, $Y, $Width, $Height) {
    return New-Object System.Windows.Rect($X, $Y, $Width, $Height)
}

function Get-Color([string]$Hex) {
    return [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
}

function New-SolidBrush([string]$Hex, [double]$Opacity = 1.0) {
    $brush = New-Object System.Windows.Media.SolidColorBrush (Get-Color $Hex)
    $brush.Opacity = $Opacity
    return $brush
}

function New-LinearBrush([string]$FromHex, [string]$ToHex, [double]$Opacity = 1.0) {
    $brush = New-Object System.Windows.Media.LinearGradientBrush
    $brush.StartPoint = New-Point 0 0
    $brush.EndPoint = New-Point 1 1
    $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Get-Color $FromHex), 0.0)))
    $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Get-Color $ToHex), 1.0)))
    $brush.Opacity = $Opacity
    return $brush
}

function New-RadialBrush([string]$CenterHex, [string]$OuterHex, [double]$Opacity = 1.0) {
    $brush = New-Object System.Windows.Media.RadialGradientBrush
    $brush.Center = New-Point 0.5 0.5
    $brush.GradientOrigin = New-Point 0.5 0.5
    $brush.RadiusX = 0.5
    $brush.RadiusY = 0.5
    $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Get-Color $CenterHex), 0.0)))
    $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Get-Color $OuterHex), 1.0)))
    $brush.Opacity = $Opacity
    return $brush
}

function New-Pen([string]$Hex, [double]$Thickness, [double]$Opacity = 1.0) {
    $pen = New-Object System.Windows.Media.Pen((New-SolidBrush $Hex $Opacity), $Thickness)
    $pen.StartLineCap = [System.Windows.Media.PenLineCap]::Round
    $pen.EndLineCap = [System.Windows.Media.PenLineCap]::Round
    $pen.LineJoin = [System.Windows.Media.PenLineJoin]::Round
    return $pen
}

function New-Typeface([string]$Family, [System.Windows.FontWeight]$Weight) {
    return New-Object System.Windows.Media.Typeface(
        (New-Object System.Windows.Media.FontFamily($Family)),
        [System.Windows.FontStyles]::Normal,
        $Weight,
        [System.Windows.FontStretches]::Normal
    )
}

function New-TextLayout(
    [string]$Text,
    [string]$Family,
    [double]$Size,
    [string]$Hex,
    [System.Windows.FontWeight]$Weight,
    [double]$MaxWidth = 0
) {
    $layout = New-Object System.Windows.Media.FormattedText(
        $Text,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Windows.FlowDirection]::LeftToRight,
        (New-Typeface $Family $Weight),
        $Size,
        (New-SolidBrush $Hex)
    )

    if ($MaxWidth -gt 0) {
        $layout.MaxTextWidth = $MaxWidth
    }

    return $layout
}

function Draw-Text(
    $Dc,
    [string]$Text,
    [double]$X,
    [double]$Y,
    [double]$Size,
    [string]$Hex,
    [string]$Family = "Segoe UI",
    [System.Windows.FontWeight]$Weight = [System.Windows.FontWeights]::Normal,
    [double]$MaxWidth = 0,
    [string]$Align = "Left"
) {
    $layout = New-TextLayout -Text $Text -Family $Family -Size $Size -Hex $Hex -Weight $Weight -MaxWidth $MaxWidth
    if ($Align -eq "Center") {
        $X = $X - ($layout.Width / 2.0)
    }
    elseif ($Align -eq "Right") {
        $X = $X - $layout.Width
    }

    [void]$Dc.DrawText($layout, (New-Point $X $Y))
}

function Draw-RoundedRect(
    $Dc,
    [double]$X,
    [double]$Y,
    [double]$Width,
    [double]$Height,
    [double]$Radius,
    $FillBrush,
    $Pen = $null
) {
    $Dc.DrawRoundedRectangle($FillBrush, $Pen, (New-Rect $X $Y $Width $Height), $Radius, $Radius)
}

function Draw-Grid($Dc, [double]$Width, [double]$Height, [double]$Step, [string]$Hex, [double]$Opacity) {
    $pen = New-Pen $Hex 1 $Opacity
    for ($x = 0; $x -le $Width; $x += $Step) {
        $Dc.DrawLine($pen, (New-Point $x 0), (New-Point $x $Height))
    }
    for ($y = 0; $y -le $Height; $y += $Step) {
        $Dc.DrawLine($pen, (New-Point 0 $y), (New-Point $Width $y))
    }
}

function Draw-Orb($Dc, [double]$X, [double]$Y, [double]$RadiusX, [double]$RadiusY, [string]$CenterHex, [string]$OuterHex, [double]$Opacity) {
    $Dc.DrawEllipse((New-RadialBrush $CenterHex $OuterHex $Opacity), $null, (New-Point $X $Y), $RadiusX, $RadiusY)
}

function Draw-Pill($Dc, [string]$Text, [double]$X, [double]$Y, [string]$FillHex, [string]$TextHex) {
    $layout = New-TextLayout -Text $Text -Family "Segoe UI" -Size 18 -Hex $TextHex -Weight ([System.Windows.FontWeights]::SemiBold)
    $width = [Math]::Ceiling($layout.Width) + 28
    Draw-RoundedRect $Dc $X $Y $width 36 18 (New-SolidBrush $FillHex) $null
    [void]$Dc.DrawText($layout, (New-Point ($X + 14) ($Y + 7)))
    return $width
}

function Draw-Arrow($Dc, [double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [string]$Hex, [double]$Thickness = 4) {
    $pen = New-Pen $Hex $Thickness 1.0
    $Dc.DrawLine($pen, (New-Point $X1 $Y1), (New-Point $X2 $Y2))

    $angle = [Math]::Atan2(($Y2 - $Y1), ($X2 - $X1))
    $size = 12
    $left = New-Point ($X2 - $size * [Math]::Cos($angle - 0.45)) ($Y2 - $size * [Math]::Sin($angle - 0.45))
    $right = New-Point ($X2 - $size * [Math]::Cos($angle + 0.45)) ($Y2 - $size * [Math]::Sin($angle + 0.45))

    $geometry = New-Object System.Windows.Media.StreamGeometry
    $context = $geometry.Open()
    $context.BeginFigure((New-Point $X2 $Y2), $true, $true)
    $context.LineTo($left, $true, $false)
    $context.LineTo($right, $true, $false)
    $context.Close()
    $Dc.DrawGeometry((New-SolidBrush $Hex), $null, $geometry)
}

function Draw-ComponentCard(
    $Dc,
    [string]$Title,
    [string]$Subtitle,
    [double]$X,
    [double]$Y,
    [double]$Width,
    [double]$Height,
    [string]$AccentHex,
    [string]$StateText = "healthy"
) {
    Draw-RoundedRect $Dc $X $Y $Width $Height 22 (New-SolidBrush $Palette.Panel) (New-Pen $Palette.NavySoft 1.4 1.0)
    Draw-RoundedRect $Dc ($X + 18) ($Y + 18) 12 ($Height - 36) 6 (New-SolidBrush $AccentHex) $null
    $dotX = $X + $Width - 28
    $dotY = $Y + 26
    $Dc.DrawEllipse((New-SolidBrush $AccentHex), $null, (New-Point $dotX $dotY), 5, 5)
    Draw-Text $Dc $StateText ($dotX - 10) ($Y + 13) 12 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::SemiBold) 0 "Right"
    Draw-Text $Dc $Title ($X + 44) ($Y + 18) 18 $Palette.White "Georgia" ([System.Windows.FontWeights]::Bold) ($Width - 92)
    Draw-Text $Dc $Subtitle ($X + 44) ($Y + 48) 12.5 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) ($Width - 92)
}

function Draw-HighlightCard(
    $Dc,
    [double]$X,
    [double]$Y,
    [double]$Width,
    [double]$Height,
    [string]$Number,
    [string]$Title,
    [string]$Body,
    [string]$AccentHex
) {
    Draw-RoundedRect $Dc $X $Y $Width $Height 28 (New-SolidBrush $Palette.White) (New-Pen $Palette.Line 1.0 0.9)
    Draw-RoundedRect $Dc ($X + 22) ($Y + 22) 52 52 18 (New-SolidBrush $AccentHex) $null
    Draw-Text $Dc $Number ($X + 48) ($Y + 30) 22 $Palette.White "Segoe UI" ([System.Windows.FontWeights]::Bold) 0 "Center"
    Draw-Text $Dc $Title ($X + 96) ($Y + 22) 22 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold) ($Width - 120)
    Draw-Text $Dc $Body ($X + 96) ($Y + 58) 15 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) ($Width - 120)
}

function Draw-StatTile(
    $Dc,
    [double]$X,
    [double]$Y,
    [double]$Width,
    [double]$Height,
    [string]$Title,
    [string]$Body,
    [string]$AccentHex
) {
    Draw-RoundedRect $Dc $X $Y $Width $Height 22 (New-SolidBrush $Palette.White 0.95) (New-Pen $AccentHex 1.2 0.8)
    Draw-RoundedRect $Dc ($X + 18) ($Y + 18) 40 8 4 (New-SolidBrush $AccentHex) $null
    Draw-Text $Dc $Title ($X + 18) ($Y + 40) 22 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold) ($Width - 36)
    Draw-Text $Dc $Body ($X + 18) ($Y + 72) 13.5 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) ($Width - 36)
}

function Save-Canvas([string]$Path, [int]$Width, [int]$Height, [scriptblock]$Painter) {
    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    & $Painter $dc $Width $Height
    $dc.Close()

    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        $Width,
        $Height,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($visual)

    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    try {
        $encoder.Save($stream)
    }
    finally {
        $stream.Dispose()
    }
}

function Draw-Cover($Dc, [int]$Width, [int]$Height) {
    $Dc.DrawRectangle((New-LinearBrush $Palette.Cream $Palette.Peach), $null, (New-Rect 0 0 $Width $Height))
    Draw-Grid $Dc $Width $Height 72 $Palette.Navy 0.05
    Draw-Orb $Dc 1370 30 260 200 $Palette.Orange "#00000000" 0.28
    Draw-Orb $Dc 1160 320 320 180 $Palette.Mint "#00000000" 0.20

    Draw-Text $Dc "LINKEDIN ASSET PACK" 94 48 16 $Palette.Coral "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Security Monitoring Stack" 94 76 52 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold) 620
    Draw-Text $Dc "Wazuh + Prometheus + Alertmanager + Blackbox Exporter" 98 196 22 $Palette.Slate "Segoe UI" ([System.Windows.FontWeights]::SemiBold) 620
    Draw-Text $Dc "Docker-based SOC monitoring with routed alerts, health checks, and a safer deployment story." 98 256 18 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) 620

    $pillX = 98
    foreach ($pill in @(
        @{ Text = "Docker"; Fill = $Palette.Navy; TextHex = $Palette.White },
        @{ Text = "Health Checks"; Fill = $Palette.Teal; TextHex = $Palette.White },
        @{ Text = "Alert Routing"; Fill = $Palette.Coral; TextHex = $Palette.White },
        @{ Text = "GitHub Safe"; Fill = $Palette.Gold; TextHex = $Palette.Ink }
    )) {
        $pillX += Draw-Pill $Dc $pill.Text $pillX 316 $pill.Fill $pill.TextHex
        $pillX += 12
    }

    Draw-RoundedRect $Dc 970 34 560 328 30 (New-SolidBrush $Palette.Panel) (New-Pen $Palette.NavySoft 1.4 1.0)
    Draw-Text $Dc "Runtime flow" 1010 62 18 $Palette.Mint "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Observed services and alert handoff" 1010 88 14 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal)

    Draw-ComponentCard $Dc "Wazuh Logs" "single-node alerts volume" 1010 118 220 84 $Palette.Coral
    Draw-ComponentCard $Dc "Forwarder" "dedup + routing bridge" 1270 118 220 84 $Palette.Teal
    Draw-ComponentCard $Dc "Alerts" "notification policy" 1010 232 220 84 $Palette.Orange
    Draw-ComponentCard $Dc "Metrics" "health + latency rules" 1270 232 220 84 $Palette.Gold

    Draw-Arrow $Dc 1236 160 1262 160 $Palette.Mint 4
    Draw-Arrow $Dc 1120 205 1120 224 $Palette.Orange 4
    Draw-Arrow $Dc 1382 205 1382 224 $Palette.Gold 4

    Draw-Text $Dc "ICMP via file_sd" 1298 330 14 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::SemiBold)
    Draw-Text $Dc "Pinned images | rollout script | safe repo" 1010 330 14 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::SemiBold)
}

function Draw-OverviewPost($Dc, [int]$Width, [int]$Height) {
    $Dc.DrawRectangle((New-LinearBrush $Palette.Navy $Palette.NavySoft), $null, (New-Rect 0 0 $Width $Height))
    Draw-Orb $Dc 1050 70 220 180 $Palette.Teal "#00000000" 0.20
    Draw-Orb $Dc 120 560 180 120 $Palette.Coral "#00000000" 0.18

    Draw-RoundedRect $Dc 54 52 360 523 28 (New-SolidBrush $Palette.White 0.06) (New-Pen $Palette.White 1 0.10)
    Draw-Text $Dc "PROJECT OVERVIEW" 84 82 16 $Palette.Mint "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Wazuh logs`ninto actionable`nalerts" 84 118 38 $Palette.White "Georgia" ([System.Windows.FontWeights]::Bold) 280
    Draw-Text $Dc "Monitoring stays modular while alerts move through one clean path." 84 314 17 $Palette.Sand "Segoe UI" ([System.Windows.FontWeights]::Normal) 286

    Draw-StatTile $Dc 84 368 300 96 "Pinned images" "Digest pins keep upgrades reproducible." $Palette.Coral
    Draw-StatTile $Dc 84 478 300 96 "Health checks" "Core services now report readiness." $Palette.Teal

    Draw-RoundedRect $Dc 454 52 692 523 28 (New-SolidBrush $Palette.Cream) $null
    Draw-Text $Dc "Observed data path" 500 86 22 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Clear handoff between detection, enrichment, and notification." 500 120 16 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal)

    Draw-ComponentCard $Dc "Endpoints" "ICMP targets and hosts" 506 176 270 92 $Palette.Orange
    Draw-ComponentCard $Dc "Wazuh stack" "manager, dashboard, indexer" 848 176 250 92 $Palette.Coral
    Draw-ComponentCard $Dc "Forwarder" "filters, enriches, correlates" 675 316 296 96 $Palette.Teal
    Draw-ComponentCard $Dc "Alerts" "routes notifications" 506 462 244 78 $Palette.Gold
    Draw-ComponentCard $Dc "Health probes" "health and reachability" 792 448 306 92 $Palette.Mint

    Draw-Arrow $Dc 780 222 840 222 $Palette.Cream 5
    Draw-Arrow $Dc 810 268 810 306 $Palette.Cream 5
    Draw-Arrow $Dc 820 414 690 454 $Palette.Coral 5
    Draw-Arrow $Dc 860 414 940 448 $Palette.Teal 5
}

function Draw-ArchitectureSlide($Dc, [int]$Width, [int]$Height) {
    $Dc.DrawRectangle((New-LinearBrush $Palette.Cream $Palette.Sand), $null, (New-Rect 0 0 $Width $Height))
    Draw-Grid $Dc $Width $Height 90 $Palette.Navy 0.04
    Draw-Orb $Dc 980 140 180 180 $Palette.Mint "#00000000" 0.22

    Draw-Text $Dc "01 / Architecture" 88 78 20 $Palette.Coral "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Signal flow, cleanly split" 88 110 44 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold) 720
    Draw-Text $Dc "Monitoring runs at the repo root. Wazuh stays in the bundled stack. A shared Docker volume carries alert logs between them." 92 176 18 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) 860

    Draw-RoundedRect $Dc 86 292 908 700 34 (New-SolidBrush $Palette.Panel) (New-Pen $Palette.NavySoft 1.5 1.0)
    Draw-Text $Dc "Core runtime" 130 330 20 $Palette.Mint "Segoe UI" ([System.Windows.FontWeights]::Bold)

    Draw-ComponentCard $Dc "ICMP targets" "inventory from ping_servers.yml" 130 386 250 96 $Palette.Gold
    Draw-ComponentCard $Dc "Wazuh stack" "manager, dashboard, indexer, logs" 420 386 270 96 $Palette.Coral
    Draw-ComponentCard $Dc "Forwarder" "dedup, correlation, delivery" 724 386 230 96 $Palette.Teal

    Draw-ComponentCard $Dc "Prometheus" "health checks + rule evaluation" 130 582 244 92 $Palette.Mint
    Draw-ComponentCard $Dc "Blackbox" "ICMP probe executor" 410 582 280 92 $Palette.Gold
    Draw-ComponentCard $Dc "Alertmanager" "notification backend" 724 582 230 92 $Palette.Orange

    Draw-ComponentCard $Dc "Runbook + rollout" "validation-first path" 130 782 324 96 $Palette.Coral
    Draw-ComponentCard $Dc "Public-safe repo" "secret files swapped for examples" 490 782 464 96 $Palette.Teal

    Draw-Arrow $Dc 382 432 414 432 $Palette.Mint 5
    Draw-Arrow $Dc 692 432 718 432 $Palette.Mint 5
    Draw-Arrow $Dc 246 484 246 570 $Palette.Gold 5
    Draw-Arrow $Dc 550 484 550 570 $Palette.Cream 5
    Draw-Arrow $Dc 838 484 838 570 $Palette.Orange 5

    Draw-Text $Dc "Key idea" 92 1044 18 $Palette.Coral "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Wazuh detects, the forwarder normalizes, Prometheus watches health, and Alertmanager handles outbound notification flow." 92 1074 18 $Palette.Ink "Segoe UI" ([System.Windows.FontWeights]::SemiBold) 890
}

function Draw-UpgradeSlide($Dc, [int]$Width, [int]$Height) {
    $Dc.DrawRectangle((New-LinearBrush $Palette.White $Palette.Cream), $null, (New-Rect 0 0 $Width $Height))
    Draw-Orb $Dc 160 134 140 120 $Palette.Orange "#00000000" 0.15
    Draw-Orb $Dc 930 1220 180 140 $Palette.Mint "#00000000" 0.20

    Draw-Text $Dc "02 / Upgrade Highlights" 88 78 20 $Palette.Teal "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Phase 1 hardening, safely rolled out" 88 110 46 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold) 850
    Draw-Text $Dc "The stack was upgraded with operational guardrails: no surprise path changes, clearer runtime inputs, and better observability before rollout." 92 182 18 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) 880

    $cards = @(
        @{ N = "01"; T = "Image digests"; B = "Pinned images make upgrades deterministic."; X = 88; Y = 286; A = $Palette.Coral },
        @{ N = "02"; T = "Health checks"; B = "Core services now expose readiness clearly."; X = 548; Y = 286; A = $Palette.Teal },
        @{ N = "03"; T = ".env template"; B = "Runtime values moved into templates."; X = 88; Y = 506; A = $Palette.Gold },
        @{ N = "04"; T = "File-based targets"; B = "Ping targets now live in their own inventory."; X = 548; Y = 506; A = $Palette.Orange },
        @{ N = "05"; T = "Rollout runbook"; B = "Validation-first rollout plus rollback notes."; X = 88; Y = 726; A = $Palette.Teal },
        @{ N = "06"; T = "Repo-safe publish"; B = "Live secrets were replaced by tracked examples."; X = 548; Y = 726; A = $Palette.Coral }
    )

    foreach ($card in $cards) {
        Draw-HighlightCard $Dc $card.X $card.Y 404 172 $card.N $card.T $card.B $card.A
    }

    Draw-RoundedRect $Dc 88 964 864 234 32 (New-SolidBrush $Palette.Panel) $null
    Draw-Text $Dc "Outcome" 126 1002 18 $Palette.Mint "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "The project now upgrades more predictably, explains itself better, and can be shared publicly without leaking live runtime data." 126 1036 22 $Palette.White "Georgia" ([System.Windows.FontWeights]::Bold) 782
    Draw-Text $Dc "That is both an ops win and a better story for a public portfolio." 126 1120 18 $Palette.Sand "Segoe UI" ([System.Windows.FontWeights]::Normal) 782
}

function Draw-DeliverySlide($Dc, [int]$Width, [int]$Height) {
    $Dc.DrawRectangle((New-LinearBrush $Palette.NavySoft $Palette.Panel), $null, (New-Rect 0 0 $Width $Height))
    Draw-Orb $Dc 920 200 220 220 $Palette.Coral "#00000000" 0.16
    Draw-Orb $Dc 120 1180 180 120 $Palette.Gold "#00000000" 0.14

    Draw-Text $Dc "03 / Delivery & Recovery" 88 78 20 $Palette.Gold "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Built for rollout, handoff, and rebuild" 88 110 44 $Palette.White "Georgia" ([System.Windows.FontWeights]::Bold) 820
    Draw-Text $Dc "The project now includes the pieces needed to validate, deploy, explain, recover, and present it." 92 208 18 $Palette.Sand "Segoe UI" ([System.Windows.FontWeights]::Normal) 860

    Draw-RoundedRect $Dc 88 296 410 834 34 (New-SolidBrush $Palette.White 0.06) (New-Pen $Palette.White 1 0.10)
    Draw-Text $Dc "Operational path" 124 334 22 $Palette.Mint "Georgia" ([System.Windows.FontWeights]::Bold)

    $steps = @(
        @{ Y = 412; T = "Validate config"; B = "Compose, Prometheus, Alertmanager"; A = $Palette.Teal },
        @{ Y = 566; T = "Roll out in order"; B = "Blackbox, Alertmanager, Prometheus, forwarder"; A = $Palette.Orange },
        @{ Y = 720; T = "Check health"; B = "Container status and readiness checks"; A = $Palette.Gold },
        @{ Y = 874; T = "Publish safely"; B = "Sanitize secrets and push a shareable repo"; A = $Palette.Coral }
    )

    foreach ($step in $steps) {
        Draw-RoundedRect $Dc 124 $step.Y 338 110 26 (New-SolidBrush $Palette.PanelAlt) $null
        $Dc.DrawEllipse((New-SolidBrush $step.A), $null, (New-Point 162 ($step.Y + 54)), 18, 18)
        Draw-Text $Dc $step.T 196 ($step.Y + 22) 22 $Palette.White "Georgia" ([System.Windows.FontWeights]::Bold) 236
        Draw-Text $Dc $step.B 196 ($step.Y + 58) 15 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) 236
    }

    for ($i = 0; $i -lt ($steps.Count - 1); $i++) {
        $startY = $steps[$i].Y + 110
        $endY = $steps[$i + 1].Y
        Draw-Arrow $Dc 162 $startY 162 ($endY - 16) $Palette.Mint 4
    }

    Draw-RoundedRect $Dc 544 296 448 386 34 (New-SolidBrush $Palette.Cream) $null
    Draw-Text $Dc "Support assets" 584 332 22 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold)
    Draw-StatTile $Dc 584 386 170 118 "Windows" "Rollout and registration helpers." $Palette.Coral
    Draw-StatTile $Dc 782 386 170 118 "Linux" "Ubuntu-side install helpers." $Palette.Teal
    Draw-StatTile $Dc 584 530 170 118 "Docs" "Runbooks and references bundled." $Palette.Gold
    Draw-StatTile $Dc 782 530 170 118 "Recovery" "Backup and redeploy scripts included." $Palette.Orange

    Draw-RoundedRect $Dc 544 726 448 404 34 (New-SolidBrush $Palette.White 0.08) (New-Pen $Palette.White 1 0.10)
    Draw-Text $Dc "LinkedIn angle" 584 764 20 $Palette.Gold "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Architecture + upgrades + rollout discipline = strong portfolio signal." 584 804 20 $Palette.White "Georgia" ([System.Windows.FontWeights]::Bold) 368
    Draw-Text $Dc "Use the carousel to show the system design, what changed, and how you shipped it safely." 584 900 17 $Palette.Sand "Segoe UI" ([System.Windows.FontWeights]::Normal) 368
}

function Draw-SquareCard($Dc, [int]$Width, [int]$Height) {
    $Dc.DrawRectangle((New-LinearBrush $Palette.Cream $Palette.Peach), $null, (New-Rect 0 0 $Width $Height))
    Draw-Orb $Dc 880 170 220 180 $Palette.Coral "#00000000" 0.16
    Draw-Orb $Dc 120 930 180 110 $Palette.Mint "#00000000" 0.18
    Draw-Grid $Dc $Width $Height 96 $Palette.Navy 0.04

    Draw-Text $Dc "MONITORING STACK" 82 82 18 $Palette.Teal "Segoe UI" ([System.Windows.FontWeights]::Bold)
    Draw-Text $Dc "Wazuh-driven alerting`nwith a cleaner ops story" 82 124 50 $Palette.Ink "Georgia" ([System.Windows.FontWeights]::Bold) 760
    Draw-Text $Dc "Built to monitor the stack itself, route alerts cleanly, and publish safely." 86 272 21 $Palette.MutedText "Segoe UI" ([System.Windows.FontWeights]::Normal) 760

    Draw-RoundedRect $Dc 82 360 916 568 36 (New-SolidBrush $Palette.Panel) $null
    Draw-ComponentCard $Dc "Wazuh" "single-node telemetry" 124 420 250 92 $Palette.Coral
    Draw-ComponentCard $Dc "Forwarder" "filters, enriches, correlates" 410 420 310 92 $Palette.Teal
    Draw-ComponentCard $Dc "Alerts" "notification delivery" 756 420 196 92 $Palette.Gold
    Draw-ComponentCard $Dc "Prometheus" "rules and health status" 124 582 250 92 $Palette.Mint
    Draw-ComponentCard $Dc "Blackbox" "ICMP availability probes" 410 582 310 92 $Palette.Orange
    Draw-ComponentCard $Dc "GitHub-ready repo" "safe examples instead of live secrets" 124 742 828 118 $Palette.Coral

    Draw-Arrow $Dc 378 466 404 466 $Palette.Mint 5
    Draw-Arrow $Dc 724 466 748 466 $Palette.Mint 5
    Draw-Arrow $Dc 250 516 250 570 $Palette.Gold 5
    Draw-Arrow $Dc 566 516 566 570 $Palette.Orange 5
}

$assets = @(
    @{
        Name = "linkedin-cover-monitoring-stack-1584x396.png"
        Width = 1584
        Height = 396
        Painter = { param($dc, $w, $h) Draw-Cover $dc $w $h }
    },
    @{
        Name = "linkedin-post-alert-flow-1200x627.png"
        Width = 1200
        Height = 627
        Painter = { param($dc, $w, $h) Draw-OverviewPost $dc $w $h }
    },
    @{
        Name = "linkedin-carousel-01-architecture-1080x1350.png"
        Width = 1080
        Height = 1350
        Painter = { param($dc, $w, $h) Draw-ArchitectureSlide $dc $w $h }
    },
    @{
        Name = "linkedin-carousel-02-upgrade-highlights-1080x1350.png"
        Width = 1080
        Height = 1350
        Painter = { param($dc, $w, $h) Draw-UpgradeSlide $dc $w $h }
    },
    @{
        Name = "linkedin-carousel-03-delivery-recovery-1080x1350.png"
        Width = 1080
        Height = 1350
        Painter = { param($dc, $w, $h) Draw-DeliverySlide $dc $w $h }
    },
    @{
        Name = "linkedin-square-project-card-1080x1080.png"
        Width = 1080
        Height = 1080
        Painter = { param($dc, $w, $h) Draw-SquareCard $dc $w $h }
    }
)

foreach ($asset in $assets) {
    $path = Join-Path $OutputDir $asset.Name
    Save-Canvas -Path $path -Width $asset.Width -Height $asset.Height -Painter $asset.Painter
}

$guide = @"
LinkedIn asset pack
===================

Generated files:
- linkedin-cover-monitoring-stack-1584x396.png
- linkedin-post-alert-flow-1200x627.png
- linkedin-carousel-01-architecture-1080x1350.png
- linkedin-carousel-02-upgrade-highlights-1080x1350.png
- linkedin-carousel-03-delivery-recovery-1080x1350.png
- linkedin-square-project-card-1080x1080.png

Suggested use:
- Cover: profile banner crop, featured media, or GitHub social preview.
- Post image: single-image LinkedIn post.
- Carousel slides: use in order 01 -> 03 for a project breakdown.
- Square card: project thumbnail or portfolio image.

Suggested caption angle:
- Show the original monitoring problem.
- Explain the split between Wazuh runtime and root monitoring services.
- Mention the upgrade work: pinned images, health checks, rollout runbook, and secret-safe publishing.
"@

Set-Content -Path (Join-Path $OutputDir "asset-guide.txt") -Value $guide

Write-Host "Created LinkedIn assets in $OutputDir"
Get-ChildItem -File $OutputDir | Sort-Object Name | Select-Object Name, Length

<#
  install.ps1 — 安装百炼模型消耗小组件
  用法：
    powershell -ExecutionPolicy Bypass -File install.ps1            # 装桌面快捷方式
    powershell -ExecutionPolicy Bypass -File install.ps1 -AutoStart  # 同时设置开机自启
    powershell -ExecutionPolicy Bypass -File install.ps1 -Run        # 装完立即启动
#>
[CmdletBinding()]
param(
    [switch]$AutoStart,
    [switch]$Run
)

$ErrorActionPreference = 'Stop'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IconPath = Join-Path $AppDir 'icon.ico'
$Launcher = Join-Path $AppDir 'start-widget.vbs'
$Desktop = [Environment]::GetFolderPath('Desktop')
$StartupDir = [Environment]::GetFolderPath('Startup')
$DesktopLnk = Join-Path $Desktop '百炼模型消耗.lnk'
$StartupLnk = Join-Path $StartupDir 'ModelUsageWidget.lnk'

function Write-Step([string]$text) { Write-Host ('  ' + $text) }

Write-Host ''
Write-Host '  百炼模型消耗小组件 — 安装' -ForegroundColor Cyan
Write-Host '  --------------------------------'

# 1) 检查文件
foreach ($f in @('ModelUsageWidget.ps1', 'start-widget.vbs', 'config.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $AppDir $f))) {
        throw ('缺少文件：' + $f + '，请在完整目录中运行 install.ps1')
    }
}
Write-Step '✔ 程序文件齐全'

# 2) 检查 bl CLI
$bl = Join-Path $env:APPDATA 'npm\bl.cmd'
if (Test-Path -LiteralPath $bl) {
    Write-Step '✔ 已检测到百炼 CLI（bl）'
} else {
    Write-Step '⚠ 未检测到 bl 命令，小组件会提示安装百炼 CLI'
}

# 3) 生成图标
try {
    Add-Type -AssemblyName System.Drawing
    $size = 256
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    function New-Rounded($x, $y, $w, $h, $r) {
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $r * 2
        $p.AddArc($x, $y, $d, $d, 180, 90)
        $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
        $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
        $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
        $p.CloseFigure()
        return $p
    }

    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#171A21'))
    $bgPath = New-Rounded 8 8 240 240 48
    $g.FillPath($bgBrush, $bgPath)

    $bars = @(
        @{ x = 62;  h = 78;  color = '#3DDC97' },
        @{ x = 112; h = 128; color = '#F5C451' },
        @{ x = 162; h = 52;  color = '#FF6B6B' }
    )
    foreach ($b in $bars) {
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($b.color))
        $baseY = 196
        $barPath = New-Rounded $b.x ($baseY - $b.h) 32 $b.h 10
        $g.FillPath($brush, $barPath)
        $brush.Dispose(); $barPath.Dispose()
    }
    $g.Dispose(); $bgBrush.Dispose(); $bgPath.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $bmp.Dispose(); $ms.Dispose()

    $ico = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ico)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
    $bw.Write([byte]0); $bw.Write([byte]0)          # 256 x 256
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png); $bw.Flush()
    [System.IO.File]::WriteAllBytes($IconPath, $ico.ToArray())
    $bw.Dispose(); $ico.Dispose()
    Write-Step '✔ 已生成图标 icon.ico'
} catch {
    Write-Step ('⚠ 图标生成失败（不影响使用）：' + $_.Exception.Message)
}

# 4) 桌面快捷方式
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($DesktopLnk)
$sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$sc.Arguments = '"' + $Launcher + '"'
$sc.WorkingDirectory = $AppDir
if (Test-Path -LiteralPath $IconPath) { $sc.IconLocation = $IconPath }
$sc.Description = '百炼模型消耗小组件'
$sc.Save()
Write-Step ('✔ 桌面快捷方式：' + $DesktopLnk)

# 5) 可选开机自启
if ($AutoStart) {
    $sc2 = $ws.CreateShortcut($StartupLnk)
    $sc2.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc2.Arguments = '"' + $Launcher + '"'
    $sc2.WorkingDirectory = $AppDir
    if (Test-Path -LiteralPath $IconPath) { $sc2.IconLocation = $IconPath }
    $sc2.Description = '百炼模型消耗小组件（开机自启）'
    $sc2.Save()
    Write-Step ('✔ 已设置开机自启：' + $StartupLnk)
} else {
    Write-Step '· 未设置开机自启（可加 -AutoStart，或在托盘右键菜单勾选）'
}

# 6) 启动
if ($Run) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $Launcher + '"')
    Write-Step '✔ 已启动小组件'
}

Write-Host ''
Write-Host '  安装完成。双击桌面「百炼模型消耗」即可打开。' -ForegroundColor Green
Write-Host '  托盘右键可刷新 / 重新登录 / 开机自启 / 退出。' -ForegroundColor DarkGray
Write-Host ''

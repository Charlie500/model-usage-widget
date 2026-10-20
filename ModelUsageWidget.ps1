<#
  ModelUsageWidget.ps1
  百炼免费额度桌面小组件（Windows，PowerShell 5.1 / WinForms，无第三方依赖）

  数据来源：bl usage summary --output json（阿里云百炼 CLI，需已登录 console）
  功能：
    - 置顶小窗，8 行虚拟列表 + 滚轮 / 自绘滚动条翻看全部模型（按剩余额度升序）
    - 顶部供应商筛选 chips（全部 / 通义 / DeepSeek / 智谱 / 月之暗面 / 百度 / MiniMax / 其他）
    - 低于告警阈值弹 Windows 通知（托盘气泡），冷却与恢复重置
    - 拖动用 12ms 定时器跟随 + 双缓冲，避免跨子控件卡顿
    - 托盘常驻，双击显示/隐藏；右键刷新 / 重新登录 / 开机自启 / 退出
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:AppDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:StatePath  = Join-Path $script:AppDir 'state.json'
$script:LogPath    = Join-Path $script:AppDir 'widget.log'
$script:IconPath   = Join-Path $script:AppDir 'icon.ico'
$script:StartupDir = [Environment]::GetFolderPath('Startup')
$script:Shortcut   = Join-Path $script:StartupDir 'ModelUsageWidget.lnk'
$script:Launcher   = Join-Path $script:AppDir 'start-widget.vbs'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 双缓冲控件，降低拖动 / 滚动时的闪烁与卡顿
$script:BufferedOk = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
public class MuwForm : Form {
    public MuwForm() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
    }
}
public class MuwPanel : Panel {
    public MuwPanel() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
    }
}
public class MuwFlow : FlowLayoutPanel {
    public MuwFlow() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing
    $script:BufferedOk = $true
} catch {
    $script:BufferedOk = $false
}

# 单实例
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ModelUsageWidget_SingleInstance', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

# 高 DPI 感知（必须在创建窗口前）
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MuwDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
    [void][MuwDpi]::SetProcessDPIAware()
} catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$env:NO_COLOR = '1'

# ---------------------------------------------------------------- 主题
$Theme = @{
    Bg      = '#14161B'
    Card    = '#1B1E26'
    CardAlt = '#20242E'
    Track   = '#262B36'
    Text    = '#EDF0F6'
    Sub     = '#98A1B3'
    Dim     = '#5F6779'
    Green   = '#3DDC97'
    Amber   = '#F5C451'
    Orange  = '#FF9F45'
    Red     = '#FF6B6B'
    Border  = '#2A2F3A'
    ChipOn  = '#2C3A55'
    Scroll  = '#3A4252'
}
function Clr([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }

function Write-Log([string]$msg) {
    try {
        Add-Content -LiteralPath $script:LogPath -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg) -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Get-RoundedPath([System.Drawing.Rectangle]$rect, [int]$radius) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    if ($d -le 0) { $p.AddRectangle($rect); return $p }
    $p.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $p.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $p.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}
function Format-Num($n) { return ([double]$n).ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture) }
function Format-Wan($n) {
    if ($null -eq $n) { return '-' }
    if ([double]$n -ge 10000) {
        return ([math]::Round([double]$n / 10000.0, 1)).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture) + ' 万'
    }
    return (Format-Num $n)
}
function Get-Severity([double]$pct) {
    if ($pct -le 8)  { return $Theme.Red }
    if ($pct -le 20) { return $Theme.Orange }
    if ($pct -le 50) { return $Theme.Amber }
    return $Theme.Green
}
function Get-Vendor([string]$model) {
    $m = $model.ToLowerInvariant()
    if ($m -match '^(qwen|sambert|paraformer|cosyvoice|wan|wanx|bge|tongyi)') { return '通义' }
    if ($m -match '^(deepseek|siliconflow|vanchin)') { return 'DeepSeek' }
    if ($m -match '^(glm|zhipu)') { return '智谱' }
    if ($m -match '^(kimi|moonshot)') { return '月之暗面' }
    if ($m -match '^(ernie|paddle|pp-|internvl)') { return '百度' }
    if ($m -match '^minimax') { return 'MiniMax' }
    return '其他'
}

# ---------------------------------------------------------------- 配置 / 状态
function Get-DefaultConfig {
    return [pscustomobject]@{
        refreshMinutes      = 10
        types               = @('Text')
        warnPercent         = 20
        criticalPercent     = 8
        notifyCooldownHours = 12
        showRecentUsage     = $true
        recentDays          = 7
        autoRelogin         = $true
        reloginCooldownMinutes = 15
        showCodex           = $true
    }
}
function Load-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        $cfg = Get-DefaultConfig
        ($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
        return $cfg
    }
    try {
        $cfg = (Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json
        foreach ($p in (Get-DefaultConfig).PSObject.Properties) {
            if ($null -eq $cfg.PSObject.Properties[$p.Name]) {
                $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
            }
        }
        if (-not ($cfg.types -is [array])) { $cfg.types = @($cfg.types) }
        return $cfg
    } catch {
        Write-Log ('config.json 解析失败，使用默认配置: ' + $_.Exception.Message)
        return (Get-DefaultConfig)
    }
}
function Load-State {
    $state = @{ windowX = $null; windowY = $null; notified = @{}; vendor = '全部' }
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $s = (Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($null -ne $s.windowX) { $state.windowX = [int]$s.windowX }
            if ($null -ne $s.windowY) { $state.windowY = [int]$s.windowY }
            if ($null -ne $s.vendor -and -not [string]::IsNullOrWhiteSpace([string]$s.vendor)) { $state.vendor = [string]$s.vendor }
            if ($null -ne $s.notified) {
                foreach ($p in $s.notified.PSObject.Properties) { $state.notified[$p.Name] = [int64]$p.Value }
            }
        } catch { Write-Log ('state.json 解析失败，忽略: ' + $_.Exception.Message) }
    }
    return $state
}
function Save-State {
    try {
        $obj = @{
            windowX  = if ($null -ne $script:State.windowX) { [int]$script:State.windowX } else { $null }
            windowY  = if ($null -ne $script:State.windowY) { [int]$script:State.windowY } else { $null }
            vendor   = [string]$script:State.vendor
            notified = $script:State.notified
        }
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
    } catch { Write-Log ('保存 state 失败: ' + $_.Exception.Message) }
}

$script:Config = Load-Config
$script:State = Load-State
$script:Data = $null
$script:BlPath = $null
$script:BlQuoted = $null
$script:Fetch = @{ Running = $false; Proc = $null; Out = ''; Err = ''; Started = $null }
$script:Relogin = @{ Active = $false; Proc = $null; Started = $null; LastAttempt = $null; ConfigStamp = $null; Out = ''; Err = '' }
$script:Drag = @{ On = $false; DX = 0; DY = 0 }
$script:List = @()
$script:Offset = 0
$script:VendorFilter = [string]$script:State.vendor
$script:Scrolling = $false
$script:Slots = @()
$script:CodexQuota = $null

function Resolve-BlPath {
    $candidates = @()
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'npm\bl.cmd') }
    $cmd = Get-Command bl -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c) -and ($c -match '\.cmd$')) { return $c } }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}
function Initialize-Bl {
    $script:BlPath = Resolve-BlPath
    if ($script:BlPath) {
        if ($script:BlPath -match '\s') { $script:BlQuoted = '"' + $script:BlPath + '"' } else { $script:BlQuoted = $script:BlPath }
        Write-Log ('bl 路径: ' + $script:BlPath)
    } else { Write-Log '未找到 bl 命令' }
}

# ---------------------------------------------------------------- 布局
$W = 368
$PAGE = 8
$ROW_H = 56
$LIST_X = 18; $LIST_W = 320; $LIST_H = $PAGE * $ROW_H
$CHIP_H = 56
$CODEX_Y = 88
$script:ShowCodex = [bool]$script:Config.showCodex
if ($script:ShowCodex) {
    $CODEX_H = 54
    $CHIP_Y = $CODEX_Y + $CODEX_H + 6      # 148
} else {
    $CODEX_H = 0
    $CHIP_Y = 90
}
$LIST_Y = $CHIP_Y + $CHIP_H + 4            # 208 / 150
$FOOT_Y = $LIST_Y + $LIST_H + 8            # 664 / 606
$H = $FOOT_Y + 26                          # 690 / 632

# ---------------------------------------------------------------- 窗体
if ($script:BufferedOk) { $script:Form = New-Object MuwForm } else { $script:Form = New-Object System.Windows.Forms.Form }
$script:Form.Text = '模型消耗小组件'
$script:Form.FormBorderStyle = 'None'
$script:Form.StartPosition = 'Manual'
$script:Form.TopMost = $true
$script:Form.ShowInTaskbar = $false
$script:Form.BackColor = Clr $Theme.Bg
$script:Form.AutoScaleMode = 'Dpi'
$script:Form.ClientSize = New-Object System.Drawing.Size($W, $H)

$script:Form.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $pen = New-Object System.Drawing.Pen((Clr $Theme.Border), 1)
    try { $e.Graphics.DrawPath($pen, (Get-RoundedPath (New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))) 14)) }
    finally { $pen.Dispose() }
})
$script:Form.Add_Shown({
    if ($script:Form.Region) { $script:Form.Region.Dispose() }
    $path = Get-RoundedPath (New-Object System.Drawing.Rectangle(0, 0, $script:Form.Width, $script:Form.Height)) 14
    $script:Form.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
})

# ---- 平滑拖动：12ms 定时器跟随，不依赖子控件 MouseMove
$script:DragTimer = New-Object System.Windows.Forms.Timer
$script:DragTimer.Interval = 12
$script:DragTimer.Add_Tick({
    if (-not $script:Drag.On) { $script:DragTimer.Stop(); return }
    $leftDown = ([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left)
    if (-not $leftDown) {
        $script:Drag.On = $false
        $script:DragTimer.Stop()
        $script:State.windowX = $script:Form.Left
        $script:State.windowY = $script:Form.Top
        Save-State
        return
    }
    $p = [System.Windows.Forms.Cursor]::Position
    $script:Form.Location = New-Object System.Drawing.Point(($p.X - $script:Drag.DX), ($p.Y - $script:Drag.DY))
})
$script:StartDrag = {
    param($s, $e)
    if ($e.Button -eq 'Left') {
        $p = [System.Windows.Forms.Cursor]::Position
        $script:Drag.On = $true
        $script:Drag.DX = $p.X - $script:Form.Left
        $script:Drag.DY = $p.Y - $script:Form.Top
        $script:DragTimer.Start()
    }
}
$script:EndDrag = {
    $script:Drag.On = $false
    $script:DragTimer.Stop()
    $script:State.windowX = $script:Form.Left
    $script:State.windowY = $script:Form.Top
    Save-State
}

# ---- 顶部
$header = New-Object System.Windows.Forms.Panel
$header.SetBounds(0, 0, $W, 52)
$header.BackColor = Clr $Theme.Bg
$header.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$script:Form.Controls.Add($header)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '模型消耗'
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12.5, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = Clr $Theme.Text
$lblTitle.BackColor = 'Transparent'
$lblTitle.SetBounds(18, 10, 200, 24)
$lblTitle.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$header.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = '阿里云百炼 · 免费额度'
$lblSub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblSub.ForeColor = Clr $Theme.Dim
$lblSub.BackColor = 'Transparent'
$lblSub.SetBounds(19, 32, 220, 15)
$lblSub.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$header.Controls.Add($lblSub)

$btnClose = New-Object System.Windows.Forms.Label
$btnClose.Text = [char]0x00D7
$btnClose.Font = New-Object System.Drawing.Font('Segoe UI', 13)
$btnClose.ForeColor = Clr $Theme.Dim
$btnClose.BackColor = 'Transparent'
$btnClose.TextAlign = 'MiddleCenter'
$btnClose.SetBounds(($W - 34), 12, 22, 22)
$btnClose.Cursor = 'Hand'
$header.Controls.Add($btnClose)

$btnRefresh = New-Object System.Windows.Forms.Label
$btnRefresh.Text = [char]0x21BB
$btnRefresh.Font = New-Object System.Drawing.Font('Segoe UI', 13)
$btnRefresh.ForeColor = Clr $Theme.Dim
$btnRefresh.BackColor = 'Transparent'
$btnRefresh.TextAlign = 'MiddleCenter'
$btnRefresh.SetBounds(($W - 64), 12, 22, 22)
$btnRefresh.Cursor = 'Hand'
$header.Controls.Add($btnRefresh)

foreach ($ctrl in @($script:Form, $header, $lblTitle, $lblSub)) { $ctrl.Add_MouseDown($script:StartDrag) }
foreach ($ctrl in @($script:Form, $header, $lblTitle, $lblSub)) { $ctrl.Add_MouseUp($script:EndDrag) }
foreach ($ctrl in @($header, $lblTitle, $lblSub)) { $ctrl.Add_DoubleClick({ Start-Fetch }) }
$btnClose.Add_MouseEnter({ $btnClose.ForeColor = Clr $Theme.Text })
$btnClose.Add_MouseLeave({ $btnClose.ForeColor = Clr $Theme.Dim })
$btnClose.Add_Click({ Hide-ToTray })
$btnRefresh.Add_MouseEnter({ $btnRefresh.ForeColor = Clr $Theme.Text })
$btnRefresh.Add_MouseLeave({ $btnRefresh.ForeColor = Clr $Theme.Dim })
$btnRefresh.Add_Click({ Start-Fetch })

# ---- 近 7 天摘要
$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Text = '正在加载…'
$lblSummary.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$lblSummary.ForeColor = Clr $Theme.Sub
$lblSummary.BackColor = Clr $Theme.Card
$lblSummary.TextAlign = 'MiddleLeft'
$lblSummary.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$lblSummary.SetBounds(18, 54, ($W - 36), 30)
$script:Form.Controls.Add($lblSummary)

# ---- Codex 额度卡片
if ($script:ShowCodex) {
    if ($script:BufferedOk) { $codexCard = New-Object MuwPanel } else { $codexCard = New-Object System.Windows.Forms.Panel }
    $codexCard.BackColor = Clr $Theme.Card
    $codexCard.SetBounds(18, $CODEX_Y, ($W - 36), $CODEX_H)
    $script:Form.Controls.Add($codexCard)

    $lblCodexTitle = New-Object System.Windows.Forms.Label
    $lblCodexTitle.Text = 'Codex 额度'
    $lblCodexTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $lblCodexTitle.ForeColor = Clr $Theme.Sub
    $lblCodexTitle.BackColor = 'Transparent'
    $lblCodexTitle.SetBounds(10, 3, 170, 16)
    $codexCard.Controls.Add($lblCodexTitle)

    $lblCodexPct = New-Object System.Windows.Forms.Label
    $lblCodexPct.Text = '--'
    $lblCodexPct.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $lblCodexPct.ForeColor = Clr $Theme.Dim
    $lblCodexPct.BackColor = 'Transparent'
    $lblCodexPct.TextAlign = 'MiddleRight'
    $lblCodexPct.SetBounds(($W - 36 - 110), 2, 100, 18)
    $codexCard.Controls.Add($lblCodexPct)

    if ($script:BufferedOk) { $codexBar = New-Object MuwPanel } else { $codexBar = New-Object System.Windows.Forms.Panel }
    $codexBar.SetBounds(10, 24, ($W - 36 - 20), 6)
    $codexBar.BackColor = Clr $Theme.Track
    $codexBar.Tag = @{ Percent = 0; Color = $Theme.Dim }
    $codexBar.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $d = $s.Tag
        $w = $s.Width; $h = $s.Height
        $g.Clear((Clr $Theme.Track))
        $pctVal = [double]$d.Percent
        if ($pctVal -gt 0) {
            $fw = [int][math]::Max(3, [math]::Round($w * ($pctVal / 100.0)))
            if ($fw -gt $w) { $fw = $w }
            $brush = New-Object System.Drawing.SolidBrush((Clr $d.Color))
            try {
                if ($fw -ge 8) {
                    $path = Get-RoundedPath (New-Object System.Drawing.Rectangle(0, 0, $fw, $h)) 3
                    $g.FillPath($brush, $path); $path.Dispose()
                } else { $g.FillRectangle($brush, 0, 0, $fw, $h) }
            } finally { $brush.Dispose() }
        }
    })
    $codexCard.Controls.Add($codexBar)

    $lblCodexMeta = New-Object System.Windows.Forms.Label
    $lblCodexMeta.Text = '读取 Codex 额度…'
    $lblCodexMeta.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    $lblCodexMeta.ForeColor = Clr $Theme.Dim
    $lblCodexMeta.BackColor = 'Transparent'
    $lblCodexMeta.AutoEllipsis = $true
    $lblCodexMeta.SetBounds(10, 33, ($W - 36 - 20), 15)
    $codexCard.Controls.Add($lblCodexMeta)

    foreach ($ctrl in @($codexCard, $lblCodexTitle, $lblCodexPct, $codexBar, $lblCodexMeta)) { $ctrl.Add_MouseWheel($script:WheelHandler) }
}

# ---- 供应商筛选 chips
if ($script:BufferedOk) { $chipPanel = New-Object MuwFlow } else { $chipPanel = New-Object System.Windows.Forms.FlowLayoutPanel }
$chipPanel.FlowDirection = 'LeftToRight'
$chipPanel.WrapContents = $true
$chipPanel.BackColor = Clr $Theme.Bg
$chipPanel.SetBounds(18, $CHIP_Y, $LIST_W, $CHIP_H)
$script:Form.Controls.Add($chipPanel)

# ---- 列表（8 个复用行）
$listPanel = New-Object System.Windows.Forms.Panel
$listPanel.BackColor = Clr $Theme.Bg
$listPanel.SetBounds($LIST_X, $LIST_Y, $LIST_W, $LIST_H)
$script:Form.Controls.Add($listPanel)

# ---- 自绘滚动条
if ($script:BufferedOk) { $scrollBar = New-Object MuwPanel } else { $scrollBar = New-Object System.Windows.Forms.Panel }
$scrollBar.BackColor = Clr $Theme.Bg
$scrollBar.SetBounds(($LIST_X + $LIST_W + 8), ($LIST_Y + 2), 8, ($LIST_H - 4))
$scrollBar.Cursor = 'Hand'
$script:Form.Controls.Add($scrollBar)

# ---- 底部
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '准备中…'
$lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblStatus.ForeColor = Clr $Theme.Dim
$lblStatus.BackColor = 'Transparent'
$lblStatus.SetBounds(18, $FOOT_Y, 130, 18)
$script:Form.Controls.Add($lblStatus)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = ''
$lblHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblHint.ForeColor = Clr $Theme.Dim
$lblHint.BackColor = 'Transparent'
$lblHint.TextAlign = 'MiddleRight'
$lblHint.SetBounds(148, $FOOT_Y, ($W - 166), 18)
$script:Form.Controls.Add($lblHint)

$script:Tooltip = New-Object System.Windows.Forms.ToolTip
$script:Tooltip.InitialDelay = 350
$script:Tooltip.AutoPopDelay = 12000

function Set-Status([string]$text, [string]$colorKey) {
    $lblStatus.Text = $text
    $lblStatus.ForeColor = Clr $Theme[$colorKey]
}

# ---------------------------------------------------------------- 滚动 / 筛选
function Get-MaxOffset { return [math]::Max(0, $script:List.Count - $PAGE) }

function Update-Footer {
    $total = $script:List.Count
    if ($total -eq 0) { $lblHint.Text = '无匹配模型'; return }
    $start = $script:Offset + 1
    $end = [math]::Min($script:Offset + $PAGE, $total)
    $lblHint.Text = ('第 {0}-{1} / {2} 个 · 滚轮翻看' -f $start, $end, $total)
}

$script:WheelHandler = {
    param($s, $e)
    if ($e.Delta -ne 0) { Scroll-By (-1 * [int]($e.Delta / 120)) }
}

function Scroll-By([int]$delta) {
    $max = Get-MaxOffset
    if ($max -le 0) { return }
    $next = $script:Offset + $delta
    if ($next -lt 0) { $next = 0 }
    if ($next -gt $max) { $next = $max }
    if ($next -eq $script:Offset) { return }
    $script:Offset = $next
    Render-Rows
    Update-Footer
    $scrollBar.Invalidate()
}

function Scroll-ToRatio([double]$ratio) {
    $max = Get-MaxOffset
    if ($max -le 0) { return }
    if ($ratio -lt 0) { $ratio = 0 }
    if ($ratio -gt 1) { $ratio = 1 }
    $target = [int][math]::Round($ratio * $max)
    if ($target -ne $script:Offset) {
        $script:Offset = $target
        Render-Rows
        Update-Footer
        $scrollBar.Invalidate()
    }
}

function New-Chip([string]$text, [bool]$active) {
    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($text, $font)
    $w = $measured.Width + 18
    if ($script:BufferedOk) { $chip = New-Object MuwPanel } else { $chip = New-Object System.Windows.Forms.Panel }
    $chip.SetBounds(0, 0, $w, 21)
    $chip.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 5)
    $chip.BackColor = Clr $Theme.Bg
    $chip.Cursor = 'Hand'
    $chip.Tag = @{ Text = $text; Active = $active; Font = $font }
    $chip.Add_Paint({
        param($s, $e)
        $d = $s.Tag
        $e.Graphics.SmoothingMode = 'AntiAlias'
        if ($d.Active) { $fillHex = $Theme.ChipOn; $textHex = $Theme.Text } else { $fillHex = $Theme.CardAlt; $textHex = $Theme.Sub }
        $brush = New-Object System.Drawing.SolidBrush((Clr $fillHex))
        $path = Get-RoundedPath (New-Object System.Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))) 8
        $e.Graphics.FillPath($brush, $path)
        $brush.Dispose(); $path.Dispose()
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'
        $fmt.LineAlignment = 'Center'
        $brush2 = New-Object System.Drawing.SolidBrush((Clr $textHex))
        $rectF = New-Object System.Drawing.RectangleF(0, 0, $s.Width, $s.Height)
        $e.Graphics.DrawString([string]$d.Text, $d.Font, $brush2, $rectF, $fmt)
        $brush2.Dispose(); $fmt.Dispose()
    })
    $chip.Add_Click({
        param($s, $e)
        $v = [string]$s.Tag.Text
        if ($script:VendorFilter -ne $v) {
            $script:VendorFilter = $v
            $script:State.vendor = $v
            Save-State
            Apply-Filter
            Sync-Chips
            $chipPanel.Invalidate()
        }
    })
    return $chip
}

function Build-Chips {
    $chipPanel.SuspendLayout()
    foreach ($c in @($chipPanel.Controls)) { $chipPanel.Controls.Remove($c); $c.Dispose() }
    $vendors = @('全部')
    if ($null -ne $script:Data) {
        $types = @($script:Config.types)
        $seen = @{}
        foreach ($m in @($script:Data.freeTier)) {
            if ($types -notcontains $m.type) { continue }
            $v = Get-Vendor ([string]$m.model)
            if (-not $seen.ContainsKey($v)) { $seen[$v] = 0 }
            $seen[$v] = $seen[$v] + 1
        }
        $ordered = @($seen.Keys | Sort-Object { -1 * $seen[$_] }, { $_ })
        $vendors += $ordered
    }
    $reset = $false
    if ($null -ne $script:Data -and $vendors -notcontains $script:VendorFilter) {
        $script:VendorFilter = '全部'
        $script:State.vendor = '全部'
        $reset = $true
    }
    foreach ($v in $vendors) { $chipPanel.Controls.Add((New-Chip $v ($v -eq $script:VendorFilter))) }
    $chipPanel.ResumeLayout()
    if ($reset -and $null -ne $script:Data) { Apply-Filter }
    Sync-Chips
}

function Sync-Chips {
    foreach ($c in @($chipPanel.Controls)) {
        if ($null -eq $c.Tag) { continue }
        $active = ([string]$c.Tag.Text -eq $script:VendorFilter)
        if ($c.Tag.Active -ne $active) { $c.Tag.Active = $active; $c.Invalidate() }
    }
}

function Apply-Filter {
    if ($null -eq $script:Data) { return }
    $types = @($script:Config.types)
    $rows = @()
    foreach ($m in @($script:Data.freeTier)) {
        if ($types -notcontains $m.type) { continue }
        if ($script:VendorFilter -ne '全部' -and (Get-Vendor ([string]$m.model)) -ne $script:VendorFilter) { continue }
        $rows += $m
    }
    $script:List = @($rows | Sort-Object { [double]$_.remainingPercent })
    if ($script:Offset -gt (Get-MaxOffset)) { $script:Offset = Get-MaxOffset }
    if ($script:Offset -lt 0) { $script:Offset = 0 }
    Render-Rows
    Update-Footer
    $scrollBar.Invalidate()
}

# ---------------------------------------------------------------- 列表行（8 个复用）
function Create-RowSlot([int]$index) {
    if ($script:BufferedOk) { $row = New-Object MuwPanel } else { $row = New-Object System.Windows.Forms.Panel }
    $row.BackColor = Clr $Theme.Bg
    $row.SetBounds(0, ($index * $ROW_H), $LIST_W, $ROW_H)
    $row.Cursor = 'Hand'

    $name = New-Object System.Windows.Forms.Label
    $name.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $name.ForeColor = Clr $Theme.Text
    $name.BackColor = 'Transparent'
    $name.AutoEllipsis = $true
    $name.SetBounds(0, 0, 240, 18)
    $name.Cursor = 'Hand'
    $row.Controls.Add($name)

    $pct = New-Object System.Windows.Forms.Label
    $pct.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $pct.BackColor = 'Transparent'
    $pct.TextAlign = 'MiddleRight'
    $pct.SetBounds(240, 0, 80, 18)
    $pct.Cursor = 'Hand'
    $row.Controls.Add($pct)

    if ($script:BufferedOk) { $bar = New-Object MuwPanel } else { $bar = New-Object System.Windows.Forms.Panel }
    $bar.SetBounds(0, 21, $LIST_W, 7)
    $bar.BackColor = Clr $Theme.Track
    $bar.Tag = @{ Percent = 0; Color = $Theme.Green }
    $bar.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $d = $s.Tag
        $w = $s.Width; $h = $s.Height
        $g.Clear((Clr $Theme.Track))
        $pctVal = [double]$d.Percent
        if ($pctVal -gt 0) {
            $fw = [int][math]::Max(3, [math]::Round($w * ($pctVal / 100.0)))
            if ($fw -gt $w) { $fw = $w }
            $brush = New-Object System.Drawing.SolidBrush((Clr $d.Color))
            try {
                if ($fw -ge 8) {
                    $path = Get-RoundedPath (New-Object System.Drawing.Rectangle(0, 0, $fw, $h)) 3
                    $g.FillPath($brush, $path); $path.Dispose()
                } else { $g.FillRectangle($brush, 0, 0, $fw, $h) }
            } finally { $brush.Dispose() }
        }
    })
    $row.Controls.Add($bar)

    $meta = New-Object System.Windows.Forms.Label
    $meta.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    $meta.ForeColor = Clr $Theme.Dim
    $meta.BackColor = 'Transparent'
    $meta.AutoEllipsis = $true
    $meta.SetBounds(0, 32, $LIST_W, 15)
    $meta.Cursor = 'Hand'
    $row.Controls.Add($meta)

    $clickHandler = { param($s, $e) try { Start-Process 'https://bailian.console.aliyun.com/efm/usage' } catch { } }
    foreach ($ctrl in @($row, $name, $pct, $bar, $meta)) {
        $ctrl.Add_Click($clickHandler)
        $ctrl.Add_MouseWheel($script:WheelHandler)
    }
    return @{ Row = $row; Name = $name; Pct = $pct; Bar = $bar; Meta = $meta }
}

for ($i = 0; $i -lt $PAGE; $i++) {
    $slot = Create-RowSlot $i
    $listPanel.Controls.Add($slot.Row)
    $script:Slots += $slot
}

function Render-Rows {
    for ($i = 0; $i -lt $PAGE; $i++) {
        $slot = $script:Slots[$i]
        $idx = $script:Offset + $i
        if ($idx -ge $script:List.Count) { $slot.Row.Visible = $false; continue }
        $slot.Row.Visible = $true
        $m = $script:List[$idx]
        $pctVal = [double]$m.remainingPercent
        $sev = Get-Severity $pctVal

        $slot.Name.Text = [string]$m.model
        $slot.Pct.Text = (([math]::Round($pctVal, 1)).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture)) + '%'
        $slot.Pct.ForeColor = Clr $sev
        $slot.Bar.Tag = @{ Percent = $pctVal; Color = $sev }
        $slot.Bar.Invalidate()

        $remainText = '剩 ' + (Format-Wan $m.remaining) + ' / ' + (Format-Wan $m.total)
        $expireText = [string]$m.expires
        if ($expireText -eq '2099-01-01' -or [string]::IsNullOrWhiteSpace($expireText)) { $expireText = '不限时' }
        else { $expireText = $expireText.Substring(5) + ' 到期' }
        $autoText = '自动停用'
        if (-not $m.autoStop) { $autoText = '不自动停用' }
        $slot.Meta.Text = $remainText + ' · ' + $expireText + ' · ' + $autoText

        $tip = ('{0}（{1}）' -f $m.model, (Get-Vendor ([string]$m.model))) + [Environment]::NewLine +
               ('剩余 {0} / {1} tokens（{2}%）' -f (Format-Num $m.remaining), (Format-Num $m.total), ([math]::Round($pctVal, 1))) + [Environment]::NewLine +
               ('有效期至 {0}' -f $m.expires)
        $script:Tooltip.SetToolTip($slot.Row, $tip)
        $script:Tooltip.SetToolTip($slot.Name, $tip)
        $slot.Row.Tag = $m
        $slot.Name.Tag = $m
        $slot.Pct.Tag = $m
        $slot.Meta.Tag = $m
    }
    $scrollBar.Invalidate()
}

# ---------------------------------------------------------------- 滚动条交互
$scrollBar.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $g = $e.Graphics
    $g.Clear((Clr $Theme.Bg))
    $trackRect = New-Object System.Drawing.Rectangle(2, 0, 4, $s.Height)
    $trackBrush = New-Object System.Drawing.SolidBrush((Clr $Theme.Track))
    $trackPath = Get-RoundedPath $trackRect 2
    $g.FillPath($trackBrush, $trackPath)
    $trackBrush.Dispose(); $trackPath.Dispose()
    $total = $script:List.Count
    if ($total -gt $PAGE) {
        $thumbH = [int][math]::Max(26, [math]::Round($s.Height * ($PAGE / [double]$total)))
        $maxOff = [math]::Max(1, (Get-MaxOffset))
        $thumbY = [int][math]::Round(($s.Height - $thumbH) * ($script:Offset / [double]$maxOff))
        $thumbRect = New-Object System.Drawing.Rectangle(1, $thumbY, 6, $thumbH)
        $sb = New-Object System.Drawing.SolidBrush((Clr $Theme.Scroll))
        $sp = Get-RoundedPath $thumbRect 3
        $g.FillPath($sb, $sp)
        $sb.Dispose(); $sp.Dispose()
    }
})
$scrollBar.Add_MouseWheel($script:WheelHandler)
$scrollBar.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq 'Left' -and $script:List.Count -gt $PAGE) {
        $script:Scrolling = $true
        Scroll-ToRatio ($e.Y / [double][math]::Max(1, $s.Height))
        $s.Capture = $true
    }
})
$scrollBar.Add_MouseMove({
    param($s, $e)
    if ($script:Scrolling) { Scroll-ToRatio ($e.Y / [double][math]::Max(1, $s.Height)) }
})
$scrollBar.Add_MouseUp({
    param($s, $e)
    $script:Scrolling = $false
    $s.Capture = $false
})

# 在标题 / 摘要 / 空白处滚轮也能翻列表
foreach ($ctrl in @($script:Form, $header, $lblSummary, $lblStatus, $lblHint)) { $ctrl.Add_MouseWheel($script:WheelHandler) }

# ---------------------------------------------------------------- Codex 额度（本地会话日志）
function Read-FileTail([string]$Path, [int]$Bytes) {
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            $take = [int64][math]::Min([int64]$Bytes, $len)
            if ($take -le 0) { return '' }
            $fs.Seek(($len - $take), [System.IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $enc = New-Object System.Text.UTF8Encoding($false)
            return $enc.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Read-CodexQuota {
    try {
        $roots = @(
            (Join-Path $env:USERPROFILE '.codex\sessions'),
            (Join-Path $env:USERPROFILE '.codex\archived_sessions')
        )
        $files = @()
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            $files += @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 2)
        }
        $files = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
        foreach ($f in $files) {
            $chunk = Read-FileTail -Path $f.FullName -Bytes 4194304
            if ([string]::IsNullOrEmpty($chunk)) { continue }
            $idx = $chunk.LastIndexOf('"rate_limits":')
            if ($idx -lt 0) { continue }
            $start = $idx + '"rate_limits":'.Length
            if ($start -ge $chunk.Length) { continue }
            # 从 start 开始做花括号配对，跳过字符串内的括号
            $depth = 0; $inStr = $false; $esc = $false; $end = -1
            for ($i = $start; $i -lt $chunk.Length; $i++) {
                $ch = $chunk[$i]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($ch -eq '\') { $esc = $true }
                    elseif ($ch -eq '"') { $inStr = $false }
                    continue
                }
                if ($ch -eq '"') { $inStr = $true; continue }
                if ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') {
                    $depth--
                    if ($depth -eq 0) { $end = $i; break }
                }
            }
            if ($end -lt 0) { continue }
            $jsonText = $chunk.Substring($start, $end - $start + 1)
            try { $rl = $jsonText | ConvertFrom-Json } catch { continue }
            if ($null -eq $rl -or $null -eq $rl.primary) { continue }
            if ($null -eq $rl.primary.used_percent) { continue }

            $used = [double]$rl.primary.used_percent
            $windowMin = 0
            if ($null -ne $rl.primary.window_minutes) { $windowMin = [int]$rl.primary.window_minutes }
            $resetsLocal = $null
            if ($null -ne $rl.primary.resets_at) {
                try { $resetsLocal = [DateTimeOffset]::FromUnixTimeSeconds([int64]$rl.primary.resets_at).ToLocalTime().DateTime }
                catch { $resetsLocal = $null }
            }
            $label = '额度'
            if ($windowMin -ge 10000) { $label = '周额度' }
            elseif ($windowMin -eq 300) { $label = '5 小时额度' }
            elseif ($windowMin -ge 60) { $label = (([math]::Round($windowMin / 60.0, 1)).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture)) + ' 小时额度' }

            $creditBalance = ''
            $creditUnlimited = $false
            if ($null -ne $rl.credits) {
                if ($null -ne $rl.credits.balance) { $creditBalance = [string]$rl.credits.balance }
                if ($null -ne $rl.credits.unlimited) { $creditUnlimited = [bool]$rl.credits.unlimited }
            }
            return [pscustomobject]@{
                usedPercent      = $used
                remainingPercent = [math]::Max(0, [math]::Min(100, 100 - $used))
                windowMinutes    = $windowMin
                windowLabel      = $label
                resetsLocal      = $resetsLocal
                planType         = [string]$rl.plan_type
                creditsBalance   = $creditBalance
                creditsUnlimited = $creditUnlimited
                sourceFile       = $f.Name
            }
        }
        return $null
    } catch {
        Write-Log ('读取 Codex 额度失败: ' + $_.Exception.Message)
        return $null
    }
}

function Invoke-CodexNotifications($q) {
    if ($null -eq $q) { return }
    $remain = [double]$q.remainingPercent
    $level = $null
    if ($remain -le [double]$script:Config.criticalPercent) { $level = 'critical' }
    elseif ($remain -le [double]$script:Config.warnPercent) { $level = 'warn' }
    if (-not $level) { return }
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $key = 'codex|' + $level
    $last = 0
    if ($script:State.notified.ContainsKey($key)) { $last = [int64]$script:State.notified[$key] }
    $cooldown = [int64]$script:Config.notifyCooldownHours * 3600
    if (($nowSec - $last) -lt $cooldown) { return }
    $title = 'Codex 额度提醒'
    $icon = [System.Windows.Forms.ToolTipIcon]::Warning
    if ($level -eq 'critical') { $title = 'Codex 额度告急'; $icon = [System.Windows.Forms.ToolTipIcon]::Error }
    $resetText = '即将重置'
    if ($null -ne $q.resetsLocal) { $resetText = $q.resetsLocal.ToString('MM-dd HH:mm') + ' 重置' }
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $body = ('{0} 已用 {1}%，仅剩 {2}%，{3}。' -f $q.windowLabel, ([math]::Round($q.usedPercent, 1).ToString('0.#', $ci)), ([math]::Round($remain, 1).ToString('0.#', $ci)), $resetText) + [Environment]::NewLine + '请控制 Codex 使用或等待额度重置。'
    Show-Toast $title $body $icon
    $script:State.notified[$key] = $nowSec
    Save-State
    Write-Log ('通知: ' + $title + ' - ' + $key)
}

function Update-CodexUi {
    if (-not $script:ShowCodex) { return }
    $q = Read-CodexQuota
    $script:CodexQuota = $q
    if ($null -eq $q) {
        $lblCodexTitle.Text = 'Codex 额度'
        $lblCodexPct.Text = '--'
        $lblCodexPct.ForeColor = Clr $Theme.Dim
        $codexBar.Tag = @{ Percent = 0; Color = $Theme.Dim }
        $codexBar.Invalidate()
        $lblCodexMeta.Text = '未找到 Codex 会话数据（使用过 Codex 后自动出现）'
        return
    }
    $remain = [double]$q.remainingPercent
    $sev = Get-Severity $remain
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $lblCodexTitle.Text = ('Codex {0}' -f $q.windowLabel)
    $lblCodexPct.Text = ('剩 ' + ([math]::Round($remain, 1)).ToString('0.#', $ci) + '%')
    $lblCodexPct.ForeColor = Clr $sev
    $codexBar.Tag = @{ Percent = $remain; Color = $sev }
    $codexBar.Invalidate()
    $resetText = '重置时间未知'
    if ($null -ne $q.resetsLocal) { $resetText = $q.resetsLocal.ToString('MM-dd HH:mm') + ' 重置' }
    $metaParts = @(('已用 {0}%' -f ([math]::Round($q.usedPercent, 1)).ToString('0.#', $ci)), $resetText)
    if (-not [string]::IsNullOrWhiteSpace($q.planType)) { $metaParts += [string]$q.planType }
    if ($q.creditsUnlimited) { $metaParts += '额度无限' }
    elseif (-not [string]::IsNullOrWhiteSpace($q.creditsBalance) -and $q.creditsBalance -ne '0') { $metaParts += ('余额 ' + $q.creditsBalance) }
    $lblCodexMeta.Text = ($metaParts -join ' · ')
    Invoke-CodexNotifications $q
}

# ---------------------------------------------------------------- 数据刷新
function Start-Fetch {
    if ($script:Fetch.Running) { return }
    if (-not $script:BlPath) {
        Initialize-Bl
        if (-not $script:BlPath) { Set-Status '未找到 bl 命令：请先安装并登录百炼 CLI' 'Red'; return }
    }
    $script:Fetch.Running = $true
    $script:Fetch.Started = Get-Date
    $script:Fetch.Out = Join-Path $env:TEMP ('modelwidget-' + $PID + '-out.json')
    $script:Fetch.Err = Join-Path $env:TEMP ('modelwidget-' + $PID + '-err.txt')
    Remove-Item -LiteralPath $script:Fetch.Out -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Fetch.Err -Force -ErrorAction SilentlyContinue
    Set-Status '正在刷新…' 'Sub'
    try {
        $arg = '/c ' + $script:BlQuoted + ' usage summary --output json'
        $script:Fetch.Proc = Start-Process -FilePath $env:ComSpec -ArgumentList $arg `
            -RedirectStandardOutput $script:Fetch.Out -RedirectStandardError $script:Fetch.Err `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:PollTimer.Start()
    } catch {
        $script:Fetch.Running = $false
        Set-Status ('刷新失败：' + $_.Exception.Message) 'Red'
        Write-Log ('启动 bl 失败: ' + $_.Exception.Message)
    }
}

function Complete-Fetch {
    $script:PollTimer.Stop()
    $script:Fetch.Running = $false
    $p = $script:Fetch.Proc
    $out = ''
    $err = ''
    $code = 'n/a'
    if ($p) {
        try { $p.Refresh(); if ($p.HasExited) { $code = $p.ExitCode } } catch { $code = 'n/a' }
        if (Test-Path -LiteralPath $script:Fetch.Out) { $out = [System.IO.File]::ReadAllText($script:Fetch.Out, [System.Text.Encoding]::UTF8) }
        if (Test-Path -LiteralPath $script:Fetch.Err) { $err = [System.IO.File]::ReadAllText($script:Fetch.Err, [System.Text.Encoding]::UTF8) }
    }
    Write-Log ('poll finished code=' + $code + ' outLen=' + $out.Length + ' errLen=' + $err.Length)
    Update-CodexUi
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($out)) { try { $data = $out | ConvertFrom-Json } catch { $data = $null } }
    if ($null -eq $data) {
        $msg = (@($err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ').Trim()
        if (-not $msg) { $msg = '无有效输出（退出码 ' + $code + '）' }
        if ($msg -match 'auth|login|credential|401|token|session|登录') {
            Write-Log ('刷新失败（鉴权）: ' + $msg)
            Handle-AuthExpired
            return
        }
        Set-Status ('刷新失败：' + $msg) 'Red'
        Write-Log ('刷新失败: ' + $msg)
        return
    }
    $script:Data = $data
    Build-Chips
    Apply-Filter
    Update-Summary
    Invoke-Notifications
    Set-Status ('更新于 ' + (Get-Date -Format 'HH:mm:ss')) 'Sub'
    Write-Log ('刷新成功: ' + @($data.freeTier).Count + ' 个模型')
}

function Update-Summary {
    if ($null -eq $script:Data) { return }
    if ($script:Config.showRecentUsage -and $null -ne $script:Data.usage) {
        $u = $script:Data.usage
        $totalTok = 0
        foreach ($it in @($u.usages)) { if ($it.key -eq 'total_token') { $totalTok = [int64]$it.value } }
        $days = 7
        if ($null -ne $script:Data.period -and $null -ne $script:Data.period.days) { $days = [int]$script:Data.period.days }
        $lblSummary.Text = ('近 {0} 天 {1} 次调用 · {2} tokens' -f $days, (Format-Num $u.successfulCalls), (Format-Num $totalTok))
    } else {
        $lblSummary.Text = ('共 {0} 个模型的免费额度' -f @($script:Data.freeTier).Count)
    }
}

# ---------------------------------------------------------------- 登录过期自愈
function Handle-AuthExpired {
    if ([bool]$script:Config.autoRelogin) {
        Set-Status '登录已过期，正在自动重新登录…' 'Red'
        Write-Log '检测到 console 会话过期，尝试自动重新登录'
        Start-Relogin
    } else {
        Set-Status '登录已过期，请右键托盘 →「重新登录百炼」' 'Red'
        Show-AuthToast
    }
}

function Show-AuthToast([string]$text) {
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $key = 'auth|expired'
    $last = 0
    if ($script:State.notified.ContainsKey($key)) { $last = [int64]$script:State.notified[$key] }
    if (($nowSec - $last) -lt 10800) { return }
    $script:State.notified[$key] = $nowSec
    Save-State
    Show-Toast '百炼登录已过期' $text ([System.Windows.Forms.ToolTipIcon]::Warning)
}

function Start-Relogin {
    if ($script:Relogin.Active) { return }
    $now = Get-Date
    if ($null -ne $script:Relogin.LastAttempt -and ($now - $script:Relogin.LastAttempt).TotalMinutes -lt ([double]$script:Config.reloginCooldownMinutes)) { return }
    if (-not $script:BlPath) {
        Initialize-Bl
        if (-not $script:BlPath) { Set-Status '未找到 bl 命令' 'Red'; return }
    }
    $script:Relogin.Active = $true
    $script:Relogin.LastAttempt = $now
    $script:Relogin.Started = $now
    $script:Relogin.ConfigStamp = $null
    try { $script:Relogin.ConfigStamp = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc } catch { }
    $script:Relogin.Out = Join-Path $env:TEMP ('modelwidget-' + $PID + '-login-out.txt')
    $script:Relogin.Err = Join-Path $env:TEMP ('modelwidget-' + $PID + '-login-err.txt')
    Remove-Item $script:Relogin.Out, $script:Relogin.Err -Force -ErrorAction SilentlyContinue
    try {
        $arg = '/c ' + $script:BlQuoted + ' auth login --console'
        $script:Relogin.Proc = Start-Process -FilePath $env:ComSpec -ArgumentList $arg `
            -RedirectStandardOutput $script:Relogin.Out -RedirectStandardError $script:Relogin.Err `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:ReloginTimer.Start()
        Write-Log '启动自动重新登录进程'
    } catch {
        $script:Relogin.Active = $false
        Set-Status ('自动登录启动失败：' + $_.Exception.Message) 'Red'
        Write-Log ('自动登录启动失败: ' + $_.Exception.Message)
    }
}

function Invoke-ReloginPoll {
    if (-not $script:Relogin.Active) { $script:ReloginTimer.Stop(); return }
    try {
        $elapsed = ((Get-Date) - $script:Relogin.Started).TotalSeconds
        $changed = $false
        try {
            $stamp = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc
            if ($null -ne $script:Relogin.ConfigStamp -and $stamp -gt $script:Relogin.ConfigStamp) { $changed = $true }
        } catch { }
        $procDone = $true
        if ($script:Relogin.Proc) { try { $procDone = $script:Relogin.Proc.HasExited } catch { $procDone = $true } }

        if ($changed) {
            if (-not $procDone) { try { $script:Relogin.Proc.Kill() } catch { } }
            $script:ReloginTimer.Stop()
            $script:Relogin.Active = $false
            Set-Status '登录已恢复，正在刷新…' 'Sub'
            Write-Log '自动重新登录成功'
            Start-Fetch
            return
        }
        if ($procDone) {
            $script:ReloginTimer.Stop()
            $script:Relogin.Active = $false
            $errText = ''
            if (Test-Path -LiteralPath $script:Relogin.Err) { $errText = [System.IO.File]::ReadAllText($script:Relogin.Err, [System.Text.Encoding]::UTF8) }
            Set-Status '自动登录未完成，请右键托盘 →「重新登录百炼」' 'Red'
            Write-Log ('自动登录失败: ' + $errText.Trim())
            Show-AuthToast '自动登录未完成。请在浏览器完成授权，或右键托盘 →「重新登录百炼」。'
            return
        }
        if ($elapsed -gt 90) {
            try { $script:Relogin.Proc.Kill() } catch { }
            $script:ReloginTimer.Stop()
            $script:Relogin.Active = $false
            Set-Status '自动登录超时，请右键托盘 →「重新登录百炼」' 'Red'
            Write-Log '自动登录超时'
            Show-AuthToast '自动登录超时。请在浏览器完成授权，或右键托盘 →「重新登录百炼」。'
        }
    } catch {
        Write-Log ('自动登录轮询异常: ' + $_.Exception.Message)
        try { $script:ReloginTimer.Stop() } catch { }
        $script:Relogin.Active = $false
    }
}

function Invoke-Poll {
    if (-not $script:Fetch.Running) { $script:PollTimer.Stop(); return }
    try {
        $p = $script:Fetch.Proc
        if ($p -and -not $p.HasExited) {
            if ($null -ne $script:Fetch.Started -and ((Get-Date) - $script:Fetch.Started).TotalSeconds -gt 60) {
                try { $p.Kill() } catch { }
                $script:PollTimer.Stop(); $script:Fetch.Running = $false
                Set-Status '刷新超时（bl 无响应）' 'Red'
                Write-Log '刷新超时'
            }
            return
        }
        Complete-Fetch
    } catch {
        Write-Log ('poll 异常: ' + $_.Exception.Message)
        try { $script:PollTimer.Stop() } catch { }
        $script:Fetch.Running = $false
    }
}

# ---------------------------------------------------------------- 通知
function Invoke-Notifications {
    if ($null -eq $script:Data) { return }
    $types = @($script:Config.types)
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cooldown = [int64]$script:Config.notifyCooldownHours * 3600
    $fired = $false
    foreach ($m in @($script:Data.freeTier)) {
        if ($types -notcontains $m.type) { continue }
        $pctVal = [double]$m.remainingPercent
        $level = $null
        if ([double]$m.remaining -le 0) { $level = 'exhausted' }
        elseif ($pctVal -le [double]$script:Config.criticalPercent) { $level = 'critical' }
        elseif ($pctVal -le [double]$script:Config.warnPercent) { $level = 'warn' }
        if (-not $level) { continue }
        $key = [string]$m.model + '|' + $level
        $last = 0
        if ($script:State.notified.ContainsKey($key)) { $last = [int64]$script:State.notified[$key] }
        if (($nowSec - $last) -lt $cooldown) { continue }
        $title = '模型额度提醒'
        $icon = [System.Windows.Forms.ToolTipIcon]::Warning
        if ($level -eq 'critical') { $title = '模型额度告急'; $icon = [System.Windows.Forms.ToolTipIcon]::Error }
        if ($level -eq 'exhausted') { $title = '模型额度已耗尽'; $icon = [System.Windows.Forms.ToolTipIcon]::Error }
        if ($level -eq 'exhausted') {
            $body = ('{0} 免费额度已用完，auto-stop 已生效。' -f $m.model) + [Environment]::NewLine + '点击托盘图标查看其它模型额度。'
        } else {
            $body = ('{0} 免费额度仅剩 {1}%（{2} tokens），{3} 到期。' -f $m.model, ([math]::Round($pctVal, 1)), (Format-Num $m.remaining), $m.expires) + [Environment]::NewLine + '请及时调整默认模型或补充额度。'
        }
        Show-Toast $title $body $icon
        $script:State.notified[$key] = $nowSec
        $fired = $true
        Write-Log ('通知: ' + $title + ' - ' + $key)
    }
    foreach ($k in @($script:State.notified.Keys)) {
        $parts = $k -split '\|'
        if ($parts.Count -ne 2) { continue }
        $hit = $script:Data.freeTier | Where-Object { $_.model -eq $parts[0] } | Select-Object -First 1
        if ($null -eq $hit) { continue }
        $pctVal = [double]$hit.remainingPercent
        $recovered = $false
        if ($parts[1] -eq 'warn' -and $pctVal -gt ([double]$script:Config.warnPercent + 5)) { $recovered = $true }
        if ($parts[1] -eq 'critical' -and $pctVal -gt ([double]$script:Config.criticalPercent + 3)) { $recovered = $true }
        if ($parts[1] -eq 'exhausted' -and [double]$hit.remaining -gt 0) { $recovered = $true }
        if ($recovered) { $script:State.notified.Remove($k) }
    }
    if ($fired) { Save-State }
}

function Show-Toast([string]$title, [string]$text, $icon) {
    try {
        $script:Tray.BalloonTipTitle = $title
        $script:Tray.BalloonTipText = $text
        $script:Tray.BalloonTipIcon = $icon
        $script:Tray.ShowBalloonTip(10000)
    } catch { Write-Log ('通知失败: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- 托盘
$trayIcon = $null
if (Test-Path -LiteralPath $script:IconPath) { try { $trayIcon = New-Object System.Drawing.Icon($script:IconPath) } catch { $trayIcon = $null } }
if ($null -eq $trayIcon) { $trayIcon = [System.Drawing.SystemIcons]::Application }
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $trayIcon
$script:Tray.Text = '模型消耗小组件'
$script:Tray.Visible = $true
$script:Tray.Add_DoubleClick({ Show-Widget })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $menu.Items.Add('显示小组件'); $miShow.Add_Click({ Show-Widget })
$miRefresh = $menu.Items.Add('立即刷新'); $miRefresh.Add_Click({ Start-Fetch })
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miLogin = $menu.Items.Add('重新登录百炼')
$miLogin.Add_Click({
    if (-not $script:BlPath) { Initialize-Bl }
    if (-not $script:BlPath) {
        [System.Windows.Forms.MessageBox]::Show('未找到 bl 命令，请先安装百炼 CLI。', '模型消耗小组件', 'OK', 'Warning') | Out-Null
        return
    }
    try { Start-Process -FilePath $env:ComSpec -ArgumentList ('/c ' + $script:BlQuoted + ' auth login --console') -WindowStyle Normal } catch { }
})
$miAuto = $menu.Items.Add('开机自启')
$miAuto.CheckOnClick = $true
$miAuto.Checked = (Test-Path -LiteralPath $script:Shortcut)
$miAuto.Add_Click({
    try { if ($miAuto.Checked) { New-AutostartShortcut } else { Remove-AutostartShortcut } }
    catch { [System.Windows.Forms.MessageBox]::Show(('设置开机自启失败：' + $_.Exception.Message), '模型消耗小组件', 'OK', 'Warning') | Out-Null }
    $miAuto.Checked = (Test-Path -LiteralPath $script:Shortcut)
})
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit = $menu.Items.Add('退出'); $miExit.Add_Click({ Exit-App })
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_BalloonTipClicked({ Show-Widget })

function New-AutostartShortcut {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($script:Shortcut)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments = '"' + $script:Launcher + '"'
    $sc.WorkingDirectory = $script:AppDir
    if (Test-Path -LiteralPath $script:IconPath) { $sc.IconLocation = $script:IconPath }
    $sc.Description = '百炼模型消耗小组件'
    $sc.Save()
    Write-Log '已创建开机自启快捷方式'
}
function Remove-AutostartShortcut {
    if (Test-Path -LiteralPath $script:Shortcut) { Remove-Item -LiteralPath $script:Shortcut -Force }
    Write-Log '已移除开机自启快捷方式'
}
function Show-Widget {
    $script:Form.Show()
    $script:Form.WindowState = 'Normal'
    $script:Form.Activate()
    $script:Form.TopMost = $true
}
function Hide-ToTray {
    $script:Form.Hide()
    if (-not $script:WarnedTray) {
        $script:WarnedTray = $true
        Show-Toast '仍在后台运行' '小组件已最小化到托盘，双击托盘图标可重新显示。' ([System.Windows.Forms.ToolTipIcon]::Info)
    }
}
function Exit-App {
    try {
        $script:State.windowX = $script:Form.Left
        $script:State.windowY = $script:Form.Top
        Save-State
    } catch { }
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }
    try { $script:Form.Close(); [System.Windows.Forms.Application]::Exit() } catch { }
    Write-Log '退出'
    [System.Environment]::Exit(0)
}

# ---------------------------------------------------------------- 启动
$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = 300
$script:PollTimer.Add_Tick({ Invoke-Poll })

$script:RefreshTimer = New-Object System.Windows.Forms.Timer
$script:RefreshTimer.Interval = [int]([math]::Max(1, [int]$script:Config.refreshMinutes)) * 60000
$script:RefreshTimer.Add_Tick({ Start-Fetch })

$script:ReloginTimer = New-Object System.Windows.Forms.Timer
$script:ReloginTimer.Interval = 1200
$script:ReloginTimer.Add_Tick({ Invoke-ReloginPoll })

$script:Form.Add_Shown({
    $script:RefreshTimer.Start()
    Update-CodexUi
    Start-Fetch
})

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$defaultX = $screen.Right - $W - 40
$defaultY = $screen.Bottom - $H - 80
$posX = $defaultX; $posY = $defaultY
if ($null -ne $script:State.windowX -and $null -ne $script:State.windowY) {
    $x = [int]$script:State.windowX
    $y = [int]$script:State.windowY
    if ($x -gt ($screen.X - 100) -and $x -lt ($screen.Right - 100) -and $y -gt ($screen.Y - 50) -and $y -lt ($screen.Bottom - 100)) { $posX = $x; $posY = $y }
}
if ($posY + $H -gt $screen.Bottom - 40) { $posY = [math]::Max($screen.Top, ($screen.Bottom - $H - 60)) }
$script:Form.Location = New-Object System.Drawing.Point($posX, $posY)

Build-Chips
Update-Footer
Write-Log '小组件启动'
try {
    Initialize-Bl
    [System.Windows.Forms.Application]::Run($script:Form)
} catch {
    Write-Log ('未捕获异常: ' + $_.Exception.ToString())
    try { [System.Windows.Forms.MessageBox]::Show(('小组件异常：' + $_.Exception.Message), '模型消耗小组件', 'OK', 'Error') | Out-Null } catch { }
} finally {
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
}

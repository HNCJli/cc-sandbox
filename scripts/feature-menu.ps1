# 可选特性交互菜单:方向键 TUI 多选 + 编号输入降级。由 launch.ps1 dot-source。
# 与 progress.ps1 同模式:函数在调用时才读 launch.ps1 作用域里的 $optionalFeatures /
# $StateDir / Write-Step / Write-Warn(动态作用域),本文件不定义这些。
# 内容:Test-InteractiveConsole / Test-TuiConsole / ConvertTo-FeatureSelection /
#       Get-DisplayWidth / Wrap-FeatureText / Show-FeatureMenuTui / Select-OptionalFeatures

# stdin 是真人终端才弹菜单:Claude 后台跑/管道/重定向 stdin 时自动跳过,避免无人应答卡死
function Test-InteractiveConsole {
    return (-not [Console]::IsInputRedirected) -and ($Host.Name -eq 'ConsoleHost') -and [Environment]::UserInteractive
}

# 方向键 TUI 依赖 [Console]::ReadKey/KeyAvailable:非 console 宿主(ISE、重定向 stdin)会抛异常
# 探测失败返回 $false,调用方降级为编号输入(Select-OptionalFeatures)
function Test-TuiConsole {
    try { $null = [Console]::KeyAvailable; return $true } catch { return $false }
}

# 解析菜单输入:编号(逗号/空格分隔);a=全选,n=全不选;空=保持当前;非法输入返回 $null(调用方重问)
# 返回一律用 , 包一层:PS 函数返回空数组会坍缩成"无输出",调用方就没法和 $null(非法)区分了
function ConvertTo-FeatureSelection {
    # AllowEmptyString:回车=保持当前 是核心交互,Mandatory string 默认拒空串
    # (实测 2026-08-17:按回车 Read-Host 返回 "" → 参数绑定报错 → 被误判"输入无法识别"死循环)
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Answer,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Current
    )
    $t = $Answer.Trim()
    if ($t -eq "") { return ,@($Current) }
    if ($t -match '^(a|all|全选)$')     { return ,@($optionalFeatures | ForEach-Object { $_.Id }) }
    if ($t -match '^(n|none|0|全不选|-)$') { return ,@() }
    $picked = @()
    foreach ($tok in ($t -split '[,\s、;]+')) {
        if ($tok -eq "") { continue }
        if ($tok -notmatch '^\d+$') { return $null }
        $i = [int]$tok
        if ($i -lt 1 -or $i -gt $optionalFeatures.Count) { return $null }
        $id = $optionalFeatures[$i - 1].Id
        if ($picked -notcontains $id) { $picked += $id }
    }
    return ,$picked
}

# ====== 方向键 TUI 多选(↑↓/空格/回车)======
# PS 5.1 无现成多选组件,这里手写 ReadKey 循环 + 整块重绘。两个纯函数离线可单测。

# 控制台显示宽度:CJK 按宽 2,其余 1。TUI 的换行与补空格清残影都按显示宽度算,
# 不能用 .Length(中文 1 字符占 2 列,算错会导致残影清不干净/提前换行)
function Get-DisplayWidth {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Text)
    $w = 0
    foreach ($c in $Text.ToCharArray()) {
        $code = [int]$c
        if (($code -ge 0x1100 -and $code -le 0x115F) -or   # Hangul Jamo
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or   # CJK 部首/康熙/统一表意/注音/Yi
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or   # Hangul 音节
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or   # CJK 兼容表意
            ($code -ge 0xFE30 -and $code -le 0xFE4F) -or   # CJK 兼容形式
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or   # 全角形式
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $w += 2
        } else {
            $w += 1
        }
    }
    return $w
}

# 按显示宽度软换行(逐字符切,不猜词边界);长文案(如 tailscale 的审计警告)必须完整可见,不截断
function Wrap-FeatureText {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text,
        [Parameter(Mandatory)] [ValidateRange(4, 4096)] [int]$Width
    )
    $lines = @()
    $cur = ''; $curW = 0
    foreach ($c in $Text.ToCharArray()) {
        $cw = Get-DisplayWidth -Text ([string]$c)
        if ($curW + $cw -gt $Width -and $cur -ne '') {
            $lines += $cur; $cur = ''; $curW = 0
        }
        $cur += $c; $curW += $cw
    }
    if ($cur -ne '') { $lines += $cur }
    if ($lines.Count -eq 0) { $lines += '' }
    return ,@($lines)
}

# 方向键多选菜单。按键:↑↓ 移动高亮、空格 勾选/取消、回车 提交、数字键 直接切换第 N 项、
# a/n 全选/全不选;Ctrl+C 走 PowerShell 默认行为(中断整个 start,选择不落盘)。
# 返回:选中 id 数组(逗号包裹防空数组坍缩);$null = 无法渲染(窗口太小),调用方降级编号输入。
# 已知限制:菜单期间手动改窗口大小,换行不会重排(按键仍有效),下一次 start 恢复。
function Show-FeatureMenuTui {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Current)

    $n = $optionalFeatures.Count
    # 勾选状态与高亮游标(初始态 = 上次保存的选择,所以"直接回车"≡保持当前)
    $checked = @{}
    for ($i = 0; $i -lt $n; $i++) { $checked[$i] = ($Current -contains $optionalFeatures[$i].Id) }
    $cursor = 0

    # 布局:换行只算一次(9 = "  [x] 1. " 前缀的显示宽度,续行同样缩进对齐)
    $width = [Math]::Max(20, [Console]::WindowWidth - 12)
    $items = @(); $blockH = 3   # 标题 1 行 + 两行提示
    foreach ($f in $optionalFeatures) {
        $text = [string]$f.Description
        if ($f.RebuildOnly) { $text = "$text (改动需重建 VM 才生效)" }
        $chunks = Wrap-FeatureText -Text $text -Width ($width - 9)
        $items += ,@([string[]]$chunks)
        $blockH += $chunks.Count
    }
    # 窗口放不下整个菜单块:一个字都不打,直接让调用方走编号输入
    if ([Console]::WindowHeight - $blockH -lt 2) { return $null }

    $title = "可选特性(勾选后预装进 VM)"
    $hint1 = "↑↓ 移动   空格 勾选/取消   回车 确认   a=全选   n=全不选"
    $hint2 = "选择保存到 $StateDir\features.txt,下次 start 自动沿用"
    $menuTop = [Console]::CursorTop

    # 整块重绘:光标回到块首逐行重写,行尾补空格到窗口宽清残影(嵌套函数按动态作用域读外层变量)
    function Draw-FeatureMenu {
        [Console]::SetCursorPosition(0, $menuTop)
        $w = [Console]::WindowWidth
        $t = "==> $title"
        Write-Host ($t + (' ' * [Math]::Max(0, $w - 1 - (Get-DisplayWidth $t)))) -ForegroundColor Cyan
        for ($i = 0; $i -lt $items.Count; $i++) {
            $chunks = $items[$i]
            for ($j = 0; $j -lt $chunks.Count; $j++) {
                if ($j -eq 0) {
                    $mark = if ($checked[$i]) { '[x]' } else { '[ ]' }
                    $pre  = if ($i -eq $cursor) { '> ' } else { '  ' }
                    $line = "$pre$mark $($i + 1). $($chunks[0])"
                } else {
                    $line = (' ' * 9) + $chunks[$j]
                }
                $line = $line + (' ' * [Math]::Max(0, $w - 1 - (Get-DisplayWidth $line)))
                if ($i -eq $cursor) { Write-Host $line -ForegroundColor Yellow }
                else { Write-Host $line }
            }
        }
        foreach ($h in @("  $hint1", "  $hint2")) {
            Write-Host ($h + (' ' * [Math]::Max(0, $w - 1 - (Get-DisplayWidth $h)))) -ForegroundColor DarkGray
        }
    }

    $done = $false
    try {
        try { [Console]::CursorVisible = $false } catch {}
        Draw-FeatureMenu
        while (-not $done) {
            $k = [Console]::ReadKey($true)
            $dirty = $false
            switch ($k.Key) {
                'UpArrow'   { $cursor = ($cursor - 1 + $n) % $n; $dirty = $true }
                'DownArrow' { $cursor = ($cursor + 1) % $n; $dirty = $true }
                'Spacebar'  { $checked[$cursor] = -not $checked[$cursor]; $dirty = $true }
                'Enter'     { $done = $true }
                default {
                    $c = $k.KeyChar
                    if ($c -ge [char]'1' -and $c -le [char]'9') {
                        $idx = [int]$c - [int][char]'1'
                        if ($idx -lt $n) { $checked[$idx] = -not $checked[$idx]; $cursor = $idx; $dirty = $true }
                    } elseif ($c -eq 'a' -or $c -eq 'A') {
                        for ($i = 0; $i -lt $n; $i++) { $checked[$i] = $true }
                        $dirty = $true
                    } elseif ($c -eq 'n' -or $c -eq 'N') {
                        for ($i = 0; $i -lt $n; $i++) { $checked[$i] = $false }
                        $dirty = $true
                    }
                }
            }
            if ($dirty) { Draw-FeatureMenu }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }

    # 光标移出菜单块再返回,别让后续输出覆写在菜单上
    [Console]::SetCursorPosition(0, $menuTop + $blockH)
    Write-Host ""
    $picked = @()
    for ($i = 0; $i -lt $n; $i++) { if ($checked[$i]) { $picked += $optionalFeatures[$i].Id } }
    return ,@($picked)
}

# 多选菜单入口:优先方向键 TUI;ReadKey 不可用 / 窗口放不下时降级为编号输入(原交互保留)。
# 返回选中的 id 列表(不落盘,由 Resolve-OptionalFeatures 统一写)
function Select-OptionalFeatures {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Current)
    if ($optionalFeatures.Count -eq 0) { return ,@() }
    if (Test-TuiConsole) {
        $tui = Show-FeatureMenuTui -Current $Current
        if ($null -ne $tui) { return @($tui) }
        Write-Host "    (当前终端放不下按键式菜单,改为编号输入)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Step "可选特性(勾选后预装进 VM;选择会保存到 $StateDir\features.txt,下次 start 自动沿用)"
    for ($i = 0; $i -lt $optionalFeatures.Count; $i++) {
        $f = $optionalFeatures[$i]
        $mark   = if ($Current -contains $f.Id) { "[x]" } else { "[ ]" }
        $suffix = if ($f.RebuildOnly) { "(改动需重建 VM 才生效)" } else { "" }
        Write-Host ("  {0} {1}. {2} {3}" -f $mark, ($i + 1), $f.Description, $suffix)
    }
    Write-Host "  输入要启用的编号:如 1;多个逗号分隔;a=全选 n=全不选;直接回车=保持当前"
    while ($true) {
        $picked = ConvertTo-FeatureSelection -Answer (Read-Host "选择") -Current $Current
        if ($null -ne $picked) { return @($picked) }
        Write-Warn "输入无法识别。示例: 1 / 1,2 / a / n / 回车保持当前"
    }
}

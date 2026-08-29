# 可选特性交互菜单:方向键 TUI 多选 + 编号输入降级。由 launch.ps1 dot-source。
# 与 progress.ps1 同模式:函数在调用时才读调用方作用域里的 $optionalFeatures /
# $StateDir / Write-Step / Write-Warn(动态作用域),本文件不定义这些。
# 内容:Test-InteractiveConsole / Test-TuiConsole / ConvertTo-FeatureSelection /
#       Get-DisplayWidth / Wrap-FeatureText / Show-FeatureMenuTui / Select-OptionalFeatures /
#       Show-SingleChoiceMenuTui / Select-SingleChoice(单选,prepare-bundle 版本选择用)

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

    $title = "可选特性(空格勾选;重建型特性需 delete + start 才生效)"
    $hint1 = "↑↓ 移动   空格 勾选/取消   回车 确认   a=全选   n=全不选"
    $hint2 = "选择保存到 $vmStateDir\features.txt,下次 start 自动沿用"
    # 预留整块高度:光标离缓冲区底不足时先滚出空间。否则 Draw 逐行写会触发滚动,
    # menuTop 随之失效 → 重绘错位/字符重叠(2026-08-29 Warp 实测),菜单越画越乱
    if ([Console]::BufferHeight - [Console]::CursorTop - 1 -lt $blockH) {
        [Console]::Write(("`n" * ($blockH - ([Console]::BufferHeight - [Console]::CursorTop - 1))))
        $menuTop = [Console]::CursorTop - $blockH + 1
    } else {
        $menuTop = [Console]::CursorTop
    }

    # 整块重绘:光标回到块首逐行重写,行尾补空格到窗口宽清残影(嵌套函数按动态作用域读外层变量)
    # 钳到缓冲区末行:Warp 无回滚缓冲(BufferHeight==WindowHeight),长输出后 menuTop 可能越界
    function Draw-FeatureMenu {
        [Console]::SetCursorPosition(0, [Math]::Min($menuTop, [Console]::BufferHeight - 1))
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
    # 钳到缓冲区末行:长输出把光标钉在缓冲区底行时 menuTop+blockH 必然越界,
    # 直接 Set 会抛 ArgumentOutOfRange(短缓冲终端实测),钳位后靠换行自然滚出新行
    [Console]::SetCursorPosition(0, [Math]::Min($menuTop + $blockH, [Console]::BufferHeight - 1))
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
        # 渲染抛异常也降级编号输入,别让整个 start 崩;Ctrl+C 的 PipelineStoppedException 原样上抛
        try { $tui = Show-FeatureMenuTui -Current $Current }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { $tui = $null }
        if ($null -ne $tui) { return @($tui) }
        Write-Host "    (当前终端放不下按键式菜单,改为编号输入)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Step "可选特性(勾选后生效;选择会保存到 $vmStateDir\features.txt,下次 start 自动沿用)"
    for ($i = 0; $i -lt $optionalFeatures.Count; $i++) {
        $f = $optionalFeatures[$i]
        $mark   = if ($Current -contains $f.Id) { "[x]" } else { "[ ]" }
        $suffix = if ($f.RebuildOnly) { "(改动需重建 VM 才生效)" } else { "" }
        Write-Host ("  {0} {1}. {2} {3}" -f $mark, ($i + 1), $f.Description, $suffix)
    }
    Write-Host "  输入要启用的编号:如 1;多个逗号分隔;a=全选 n=全不选;直接回车=保持当前"
    while ($true) {
        # Read-Host 异常兜底(EOF/终端抖动会抛绑定错,2026-08-29 实测):按空输入 → 保持当前选择
        try { $ans = Read-Host "选择" } catch { $ans = '' }
        $picked = ConvertTo-FeatureSelection -Answer "$ans" -Current $Current
        if ($null -ne $picked) { return @($picked) }
        Write-Warn "输入无法识别。示例: 1 / 1,2 / a / n / 回车保持当前"
    }
}

# ====== 单选菜单(版本选择等场景)======
# 与多选同一套交互语言:↑↓ 移动、回车 确认、数字键直接选;TUI 放不下降级编号输入。

# 方向键单选 TUI。返回选中下标(int);无法渲染返回 $null(调用方降级编号输入)。
function Show-SingleChoiceMenuTui {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Options,
        [int]$DefaultIndex = 0,
        [string]$Title = '选择'
    )
    $n = $Options.Count
    if ($n -eq 0) { return $null }
    if ($DefaultIndex -lt 0 -or $DefaultIndex -ge $n) { $DefaultIndex = 0 }

    $width = [Math]::Max(20, [Console]::WindowWidth - 12)
    $items = @(); $blockH = 3   # 标题 1 行 + 两行提示
    foreach ($o in $Options) {
        $chunks = Wrap-FeatureText -Text ([string]$o) -Width ($width - 4)
        $items += ,@([string[]]$chunks)
        $blockH += $chunks.Count
    }
    if ([Console]::WindowHeight - $blockH -lt 2) { return $null }

    $hint1 = '↑↓ 移动   回车 确认(> 为默认项)   数字键直接选择'
    # 预留整块高度(同 Show-FeatureMenuTui):防 Draw 滚动导致 menuTop 失效、重绘错位
    if ([Console]::BufferHeight - [Console]::CursorTop - 1 -lt $blockH) {
        [Console]::Write(("`n" * ($blockH - ([Console]::BufferHeight - [Console]::CursorTop - 1))))
        $menuTop = [Console]::CursorTop - $blockH + 1
    } else {
        $menuTop = [Console]::CursorTop
    }
    $cursor = $DefaultIndex

    function Draw-SingleChoice {
        [Console]::SetCursorPosition(0, [Math]::Min($menuTop, [Console]::BufferHeight - 1))
        $w = [Console]::WindowWidth
        $t = "==> $Title"
        Write-Host ($t + (' ' * [Math]::Max(0, $w - 1 - (Get-DisplayWidth $t)))) -ForegroundColor Cyan
        for ($i = 0; $i -lt $items.Count; $i++) {
            $chunks = $items[$i]
            for ($j = 0; $j -lt $chunks.Count; $j++) {
                if ($j -eq 0) {
                    $pre = if ($i -eq $cursor) { '> ' } else { '  ' }
                    $line = "$pre$($i + 1). $($chunks[0])"
                } else {
                    $line = (' ' * 4) + $chunks[$j]
                }
                $line = $line + (' ' * [Math]::Max(0, $w - 1 - (Get-DisplayWidth $line)))
                if ($i -eq $cursor) { Write-Host $line -ForegroundColor Yellow }
                else { Write-Host $line }
            }
        }
        $h = "  $hint1"
        Write-Host ($h + (' ' * [Math]::Max(0, $w - 1 - (Get-DisplayWidth $h)))) -ForegroundColor DarkGray
    }

    $done = $false
    try {
        try { [Console]::CursorVisible = $false } catch {}
        Draw-SingleChoice
        while (-not $done) {
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'   { $cursor = ($cursor - 1 + $n) % $n; Draw-SingleChoice }
                'DownArrow' { $cursor = ($cursor + 1) % $n; Draw-SingleChoice }
                'Enter'     { $done = $true }
                default {
                    $c = $k.KeyChar
                    if ($c -ge [char]'1' -and $c -le [char]'9') {
                        $idx = [int]$c - [int][char]'1'
                        if ($idx -lt $n) { $cursor = $idx; $done = $true }
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }

    # 光标移出菜单块再返回,别让后续输出覆写在菜单上(钳位原因见 Show-FeatureMenuTui 末尾)
    [Console]::SetCursorPosition(0, [Math]::Min($menuTop + $blockH, [Console]::BufferHeight - 1))
    Write-Host ""
    return $cursor
}

# 单选入口:TUI 优先,放不下/非 console 降级编号输入;回车=默认项。
# 返回选中下标(int)。调用方负责非交互场景直接用默认值(不调本函数)。
function Select-SingleChoice {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Options,
        [int]$DefaultIndex = 0,
        [string]$Prompt = '选择'
    )
    if ($Options.Count -eq 0) { throw "Select-SingleChoice 收到空选项列表" }
    if ($DefaultIndex -lt 0 -or $DefaultIndex -ge $Options.Count) { $DefaultIndex = 0 }
    if (Test-TuiConsole) {
        # 渲染抛异常也降级编号输入,别让整个 prepare-bundle 崩;Ctrl+C 的 PipelineStoppedException 原样上抛
        try { $tui = Show-SingleChoiceMenuTui -Options $Options -DefaultIndex $DefaultIndex -Title $Prompt }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { $tui = $null }
        if ($null -ne $tui) { return $tui }
        Write-Host "    (当前终端放不下按键式菜单,改为编号输入)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Step $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $mark = if ($i -eq $DefaultIndex) { '*' } else { ' ' }
        Write-Host ("  {0} {1}. {2}" -f $mark, ($i + 1), $Options[$i])
    }
    Write-Host "  回车=默认项(带 * 的)"
    while ($true) {
        # Read-Host 在输入流异常(EOF/Warp pty 抖动)时会抛错或返回 $null(2026-08-29 实测崩掉整个脚本);
        # 兜底:任何异常按空输入处理 → 返回默认项
        try { $ansRaw = Read-Host "输入编号" } catch { $ansRaw = $null }
        $ans = if ($null -ne $ansRaw) { "$ansRaw".Trim() } else { '' }
        if ($ans -eq '') { return $DefaultIndex }
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $Options.Count) { return [int]$ans - 1 }
        Write-Warn "输入无法识别。示例: 1 / 回车=默认"
    }
}

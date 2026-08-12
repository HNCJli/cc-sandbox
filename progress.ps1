function Initialize-ProgressState {
    if (-not $script:progressState) {
        $script:progressState = @{}
    }
}

function Show-ProgressStage {
    param(
        [Parameter(Mandatory)] [int]$Number,
        [Parameter(Mandatory)] [string]$Title
    )
    Initialize-ProgressState
    $key = "stage:$Number"
    if (-not $script:progressState[$key]) {
        $script:progressState[$key] = $true
        Write-Host ("[{0}/6] {1}" -f $Number, $Title) -ForegroundColor Cyan
    }
}

function Render-ProgressSnapshot {
    param([hashtable]$Progress)
    if (-not $Progress) { return }
    Initialize-ProgressState

    Show-ProgressStage -Number 1 -Title '基础包安装'
    $packageNames = @('git','curl','wget','vim','less','jq','ripgrep','fd-find','tmux','fish','fzf','zoxide','openssh-server','sudo','locales','ca-certificates')
    foreach ($installed in @($Progress['packages'])) {
        $index = [array]::IndexOf($packageNames, [string]$installed)
        if ($index -ge 0) {
            $number = $index + 1
            $key = "package:$number"
            if (-not $script:progressState[$key]) {
                $script:progressState[$key] = $true
                Write-Host ("    [{0}/16] {1} 安装完成" -f $number, $installed) -ForegroundColor DarkGray
            }
        }
    }
    if (@($Progress['packages']).Count -eq 16 -and -not $script:progressState['package:complete']) {
        $script:progressState['package:complete'] = $true
        Write-Host '    OK  基础包安装完成（16 个）' -ForegroundColor Green
    }
}

function Complete-CloudInitProgress {
    param([hashtable]$Progress)
    if (-not $Progress) { return }
    Render-ProgressSnapshot -Progress $Progress
    Show-ProgressStage -Number 2 -Title '配置 VM 交互环境'
    foreach ($event in @($Progress['events'])) {
        if ($event -match '^(Fish 配置完成|tmux 配置完成|SSH 配置完成|Claude 配置同步逻辑完成)$') {
            $key = "event:$event"
            if (-not $script:progressState[$key]) {
                $script:progressState[$key] = $true
                Write-Host ("    {0}" -f $event) -ForegroundColor DarkGray
            }
        }
    }
}

function Complete-BundleProgress {
    param([hashtable]$Progress)
    if (-not $Progress) { return }
    $events = @($Progress['events'])
    if ($events -match 'stage:3\|') { Show-ProgressStage -Number 3 -Title '安装 Node.js' }
    if ($events -match 'stage:4\|') { Show-ProgressStage -Number 4 -Title '安装 Claude Code' }
}

function Complete-StartupProgress {
    Show-ProgressStage -Number 5 -Title '处理可选组件'
    if (-not $script:progressState['tailscale:skip']) {
        $script:progressState['tailscale:skip'] = $true
        Write-Host '    SKIP 未启用 Tailscale' -ForegroundColor DarkGray
    }
    Show-ProgressStage -Number 6 -Title '初始化完成'
}


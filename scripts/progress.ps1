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
        Write-Host ("[{0}/7] {1}" -f $Number, $Title) -ForegroundColor Cyan
    }
}

function Render-ProgressSnapshot {
    param([hashtable]$Progress)
    if (-not $Progress) { return }
    Initialize-ProgressState

    Show-ProgressStage -Number 1 -Title '基础包安装'
    # 包清单读 launch.ps1 的 $basePackages(动态作用域,同 $optionalFeatures 模式)——
    # 与渲染进 cloud-init 的安装清单同源,增减基础包只改 launch.ps1 一处
    $packages = @($Progress['packages'])
    for ($i = 0; $i -lt $packages.Count; $i++) {
        $key = "package:$($packages[$i])"
        if (-not $script:progressState[$key]) {
            $script:progressState[$key] = $true
            Write-Host ("    [{0}/{1}] {2} 安装完成" -f ($i + 1), $basePackages.Count, $packages[$i]) -ForegroundColor DarkGray
        }
    }
    if ($Progress['package_name'] -eq 'done' -and -not $script:progressState['package:complete']) {
        $script:progressState['package:complete'] = $true
        Write-Host ("    OK  基础包安装完成（{0} 个）" -f $basePackages.Count) -ForegroundColor Green
    }
}

function Complete-CloudInitProgress {
    param([hashtable]$Progress)
    if (-not $Progress) { return }
    Render-ProgressSnapshot -Progress $Progress
    Show-ProgressStage -Number 2 -Title '配置 VM 交互环境'
    # events 全量显示(cloud-init printf 的都是给人看的中文消息),去重;stage:N| 是
    # 内部阶段标记(Complete-BundleProgress 用),不显示
    foreach ($event in @($Progress['events'])) {
        if ($event -match '^stage:') { continue }
        $key = "event:$event"
        if (-not $script:progressState[$key]) {
            $script:progressState[$key] = $true
            Write-Host ("    {0}" -f $event) -ForegroundColor DarkGray
        }
    }
}

function Complete-BundleProgress {
    param([hashtable]$Progress)
    if (-not $Progress) { return }
    $events = @($Progress['events'])
    if ($events -match 'stage:3\|') { Show-ProgressStage -Number 3 -Title '安装 Claude Code' }
    if ($events -match 'stage:4\|') { Show-ProgressStage -Number 4 -Title '安装 opencode' }
    if ($events -match 'stage:5\|') { Show-ProgressStage -Number 5 -Title '安装 cc-pocket' }
}

function Complete-StartupProgress {
    # EnabledFeatures:本次生效的可选特性 id 列表(launch.ps1 的 $optionalFeatures 目录驱动)
    param([string[]]$EnabledFeatures = @())
    Show-ProgressStage -Number 6 -Title '处理可选组件'
    foreach ($f in $optionalFeatures) {
        if ($EnabledFeatures -contains $f.Id) {
            # 与收尾的 FinishHint(如"已预装,未配对")对齐,别在同一输出里既 SKIP 又已启用
            Write-Host ("    OK  {0} 已启用" -f $f.Name) -ForegroundColor Green
        } elseif (-not $script:progressState["feature:skip:$($f.Id)"]) {
            $script:progressState["feature:skip:$($f.Id)"] = $true
            Write-Host ("    SKIP 未启用 {0}" -f $f.Name) -ForegroundColor DarkGray
        }
    }
    Show-ProgressStage -Number 7 -Title '初始化完成'
}


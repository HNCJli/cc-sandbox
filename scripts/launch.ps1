#Requires -Version 5.0
<#
    claude-dev VM lifecycle manager.
    Usage:
        .\scripts\launch.ps1 start      # 创建/启动 VM + 挂载 + SSH 反向隧道
                                       # (真人终端裸跑会弹"可选特性"多选菜单,回车=保持上次选择;
                                       #  管道/后台/重定向 stdin 时自动跳过菜单,读 features.txt)
        .\scripts\launch.ps1 stop       # 停隧道 + 停 VM
        .\scripts\launch.ps1 status     # 看 VM 状态、隧道状态和已启用的可选特性
        .\scripts\launch.ps1 delete     # 删 VM + 清理(不会删状态目录里的 workspace/ 和 .ssh-key)

    可写状态(bundle/workspace/mounts.txt/features.txt/.ssh-key/.tunnel.pid)在 $StateDir,默认
    %USERPROFILE%\.cc-sandbox(可用参数 -StateDir 或环境变量 CC_SANDBOX_HOME 覆盖);
    仓库根若有旧布局状态文件,首次运行自动拷入 $StateDir(原文件保留)。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "delete")]
    [string]$Action = "start",

    # 宿主机要挂进 VM ~/workspace 的目录;空 = 用项目下 ./workspace(默认,向后兼容)
    # 仅用于传统单根模式(无 -NoRootWorkspace)
    [Parameter()]
    [string]$WorkspaceHost = "",

    # 可调配置(默认值就在此 param() 块)
    [string]$Image     = "noble",       # Ubuntu 24.04 LTS
    [int]$Cpus         = 4,
    [int]$MemoryGB     = 8,
    [int]$DiskGB       = 30,
    [int]$CcSwitchPort = 15721,         # cc-switch 在宿主机监听的端口

    [string]$AptMirror = "mirrors.aliyun.com", # VM 初始化时使用的 Ubuntu APT 镜像
    # 可选特性(tailscale 等)没有命令行开关:真人终端交互菜单选择,结果持久化到 features.txt

    # 额外挂载列表,每项 "HostPath" 或 "HostPath=vmSubdir",挂到 ~/workspace/<vmSubdir>
    # 简写时子目录名取宿主目录最后一级。传了此参数则不读 mounts.txt(参数优先)
    # 必须配合 -NoRootWorkspace 使用(多目录模式:~/workspace 是 VM 本地目录)
    [Parameter()]
    [string[]]$ExtraMounts = @(),

    # 跳过根 workspace 挂载(并卸掉已有根挂载)。开了它,~/workspace 就是 VM 本地目录,
    # ExtraMounts/mounts.txt 的子目录挂载便不再"嵌套在另一个挂载里"
    [Parameter()]
    [switch]$NoRootWorkspace,

    # 可写状态目录(bundle/workspace/mounts.txt/.ssh-key/.tunnel.pid/rendered yaml)
    # 默认 %USERPROFILE%\.cc-sandbox;环境变量 CC_SANDBOX_HOME 可覆盖,显式传参优先
    [Parameter()]
    [string]$StateDir = ""
)

# PS 5.1 把 native 命令的 stderr 当 terminating error,会让 multipass info(VM 不存在时)直接挂掉
# 改成 Continue,通过 $LASTEXITCODE + 显式 throw 来管理错误
$ErrorActionPreference = "Continue"
$scriptDir = $PSScriptRoot
Set-Location $scriptDir
. (Join-Path $scriptDir 'progress.ps1')
. (Join-Path $scriptDir 'feature-menu.ps1')

# ====== 目录布局 ======
# 只读资产(VM 模板):scripts/ 旁的 assets/(skill 包内,升级可整目录覆盖)
$assetsDir = (Get-Item (Join-Path $scriptDir '..\assets')).FullName
if (-not (Test-Path (Join-Path $assetsDir 'cloud-init.yaml'))) { throw "assets 目录不完整: $assetsDir(skill 包损坏?)" }

# 可写状态目录:skill 包外,重装/升级 skill 不影响用户数据
if (-not $StateDir) {
    $StateDir = if ($env:CC_SANDBOX_HOME) { $env:CC_SANDBOX_HOME } else { Join-Path $env:USERPROFILE '.cc-sandbox' }
}
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# 一次性迁移:老布局把可写状态放在仓库根(scripts/ 的上级),检测到就拷入 $StateDir(不动原文件)
$legacyRoot = Split-Path $scriptDir -Parent
foreach ($name in @('bundle', 'workspace', 'mounts.txt', '.ssh-key', '.ssh-key.pub', '.tunnel.pid', '.cloud-init.rendered.yaml')) {
    $old = Join-Path $legacyRoot $name
    $new = Join-Path $StateDir $name
    if ((Test-Path $old) -and -not (Test-Path $new)) {
        Copy-Item -Path $old -Destination $new -Recurse -Force
        Write-Host "    迁移旧布局状态: $name → $new(原文件保留,可手动清理)" -ForegroundColor DarkGray
    }
}

# 状态目录常备 mounts.txt 模板(用户复制/改名为 mounts.txt 后填自己的路径;幂等,已存在不覆盖)
$mountsExampleSrc = Join-Path $assetsDir 'mounts.example.txt'
$mountsExampleDst = Join-Path $StateDir 'mounts.example.txt'
if ((Test-Path $mountsExampleSrc) -and -not (Test-Path $mountsExampleDst)) {
    Copy-Item $mountsExampleSrc $mountsExampleDst
}

# -CcSwitchPort 是否被用户显式传入(未显式传时,允许从 base_url 里自动采信端口)
$ccSwitchPortExplicit = $PSBoundParameters.ContainsKey('CcSwitchPort')

# ====== 常量(不变项) ======
$vmName         = "claude-dev"
$mountClaudeHost = "/home/ubuntu/.claude-host"          # 宿主机 ~/.claude 挂到 VM 哪里
$mountWorkspace = "/home/ubuntu/workspace"              # ./workspace 挂到 VM 哪里(放在 ~/ 下)
# 可调项见 param() 块:$Image / $Cpus / $MemoryGB / $DiskGB / $CcSwitchPort / $AptMirror

# ====== 可选特性目录 ======
# 交互菜单 / features.txt 持久化 / 收尾提示 / 重建确认全部由此驱动;
# 新增可选特性 = 在此加一项;重建型的再在 Render-CloudInit 里接注入块(参考 {{TAILSCALE_BLOCK}} 的接法),
# 非重建型的在 Start-ClaudeDev 里按 Id 接执行段(参考 path-map 的接法)
#   Id          features.txt 里持久化的标识(改名等于换特性,别动)
#   RebuildOnly 仅重建 VM 时生效(cloud-init 只在 multipass launch 时跑);false = 每次 start 直接执行
#   Probe       VM 内探测该特性是否已生效的 bash 片段(约定 exit 0=已生效、1=未生效、其他=无法判定;
#               仅 RebuildOnly 特性会被重建确认用到)
#   FinishHint  start 收尾打印的一行提示(如配对指引),不需要则留空
$optionalFeatures = @(
    @{
        Id          = 'tailscale'
        Name        = 'Tailscale'
        RebuildOnly = $true
        Description = '跨网络直连 VM 上的服务(外出/手机 4G 时 SSH、访问 VM 里起的 web);公司机器别开,会被软件审计识别'
        Probe       = 'type -P tailscaled >/dev/null 2>&1'
        FinishHint  = "Tailscale:  VM 里跑 'sudo tailscale up' 配对(已预装,未配对)"
    }
    @{
        Id          = 'path-map'
        Name        = '路径映射记忆'
        RebuildOnly = $false   # 非 cloud-init 特性:Start-ClaudeDev 挂载后直接写,现有 VM 立即生效
        Description = '往 VM 内 Claude Code 全局记忆写宿主机↔VM 路径映射,对话里贴 Windows 路径自动换算成挂载点路径'
        Probe       = '[ -f ~/.claude/CLAUDE.md ] && grep -q "cc-sandbox:begin" ~/.claude/CLAUDE.md'
        FinishHint  = ''
    }
)

# ====== 日志 helpers ======
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }

# ====== cloud-init 安全进度 ======
# 只读取 cloud-init 写入的固定进度文件,不转发原始日志,避免泄露 token/环境变量
function Show-CloudInitProgress {
    param([Parameter(Mandatory)] [string]$VmName)
    $command = 'cat /run/claude-dev/progress 2>/dev/null; echo __PACKAGES__; cat /run/claude-dev/packages 2>/dev/null; echo __EVENTS__; cat /run/claude-dev/events 2>/dev/null'
    $r = Invoke-Multipass -ArgumentList @('exec', $VmName, '--', 'bash', '-lc', $command) -TimeoutSec 8
    if ($r.ExitCode -ne 0 -or $r.TimedOut -or -not $r.Stdout) { return $null }
    $values = @{}
    $packages = @()
    $events = @()
    $section = 'progress'
    foreach ($line in ($r.Stdout -split "`r?`n")) {
        if ($line -eq '__PACKAGES__') { $section = 'packages'; continue }
        if ($line -eq '__EVENTS__') { $section = 'events'; continue }
        if ($section -eq 'packages') {
            if ($line -match '^[a-z0-9][a-z0-9+.-]*$') { $packages += $line }
        } elseif ($section -eq 'events') {
            if ($line -match '^event=(.+)$') { $events += $Matches[1] }
            elseif ($line -match '^id=([^|]+)\|(.+)$') { $events += ($Matches[1] + '|' + $Matches[2]) }
        } elseif ($line -match '^(stage|package|package_name)=(.+)$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    $values['packages'] = $packages
    $values['events'] = $events
    return $values
}

function Show-LaunchRuntimeProgress {
    param([Parameter(Mandatory)] [string]$VmName)
    $r = Invoke-Multipass -ArgumentList @('info', $VmName) -TimeoutSec 8
    if ($r.ExitCode -ne 0 -or $r.TimedOut -or -not $r.Stdout) { return }
    $state = if ($r.Stdout -match 'State:\s+(\w+)') { $Matches[1] } else { '' }
    $ip = if ($r.Stdout -match 'IPv4:\s+([^\s]+)') { $Matches[1] } else { '' }
    if (-not $script:launchProgressShown) { $script:launchProgressShown = @{} }
    if (-not $script:launchProgressShown['vm-create']) {
        $script:launchProgressShown['vm-create'] = $true
        Write-Host '[VM 1/4] 准备 Ubuntu 镜像并创建 VM' -ForegroundColor Cyan
    }
    if ($state -eq 'Running' -and -not $script:launchProgressShown['vm-running']) {
        $script:launchProgressShown['vm-running'] = $true
        Write-Host '    VM 状态：Running' -ForegroundColor DarkGray
    }
    if (-not $script:launchProgressShown['network']) {
        $script:launchProgressShown['network'] = $true
        Write-Host '[VM 2/4] VM 网络已就绪' -ForegroundColor Cyan
        Write-Host '    等待 SSH 和 cloud-init...' -ForegroundColor DarkGray
    }
    if (-not $script:launchProgressShown['ssh']) {
        $ssh = Invoke-Multipass -ArgumentList @('exec', $VmName, '--', 'true') -TimeoutSec 8
        if ($ssh.ExitCode -eq 0 -and -not $ssh.TimedOut) {
            $script:launchProgressShown['ssh'] = $true
            Write-Host '[VM 3/4] SSH 服务已就绪' -ForegroundColor Cyan
        }
    }
    if ($script:launchProgressShown['ssh'] -and -not $script:launchProgressShown['cloud-init']) {
        $script:launchProgressShown['cloud-init'] = $true
        Write-Host '[VM 4/4] 开始 cloud-init 初始化' -ForegroundColor Cyan
    }
}

function Show-EarlyCloudInitLogProgress {
    param([Parameter(Mandatory)] [string]$VmName)
    $r = Invoke-Multipass -ArgumentList @('exec', $VmName, '--', 'bash', '-lc', "grep -E '^Get:[0-9]+ ' /var/log/cloud-init-output.log 2>/dev/null | tail -n 1") -TimeoutSec 8
    if ($r.ExitCode -ne 0 -or $r.TimedOut -or -not $r.Stdout) { return }
    if ($r.Stdout -match '^Get:([0-9]+)\s+(.+)$') {
        $key = "apt:$($Matches[1])"
        if (-not $script:cloudInitShown[$key]) {
            $script:cloudInitShown[$key] = $true
            Write-Host ("    APT 索引：已下载第 {0} 项" -f $Matches[1]) -ForegroundColor DarkGray
        }
    }
}

function Write-CloudInitProgress {
    param([hashtable]$Progress)
    if (-not $Progress) { return }
    Render-ProgressSnapshot -Progress $Progress
}

function Wait-CloudInitWithProgress {
    param([Parameter(Mandatory)] [string]$VmName)
    Write-Step "等 VM 初始化完成（进度实时显示）..."
    $deadline = (Get-Date).AddSeconds(1200)
    $last = ''
    try {
        while ((Get-Date) -lt $deadline) {
            $progress = Show-CloudInitProgress -VmName $VmName
            Show-EarlyCloudInitLogProgress -VmName $VmName
            Write-CloudInitProgress -Progress $progress

            $status = Invoke-Multipass -ArgumentList @('exec', $VmName, '--', 'cloud-init', 'status') -TimeoutSec 15
            if ($status.Stdout -match 'status:\s+(done|error|running|未运行)') {
                if ($Matches[1] -eq 'done' -or $Matches[1] -eq 'error') { return $Matches[1] }
            }
            Start-Sleep -Seconds 2
        }
        Write-Warn "cloud-init status 等待超时(20 分钟),继续后续步骤验证"
        return 'timeout'
    } finally {
        Write-Host "    cloud-init 进度监视已结束" -ForegroundColor DarkGray
    }
}
function Invoke-MultipassLaunchWithProgress {
    param(
        [Parameter(Mandatory)] [string[]]$ArgumentList,
        [int]$TimeoutSec = 1300
    )
    if (-not $script:multipassExe) { $script:multipassExe = (Get-Command multipass -ErrorAction Stop).Source }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:multipassExe
    $psi.Arguments = ($ArgumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $started = Get-Date
    $last = ''
    $script:progressState = @{}
    $script:cloudInitShown = $script:progressState
    $script:launchProgressShown = @{}
    while (-not $proc.HasExited -and ((Get-Date) - $started).TotalSeconds -lt $TimeoutSec) {
        $progress = Show-CloudInitProgress -VmName $vmName
        Show-EarlyCloudInitLogProgress -VmName $vmName
        Show-LaunchRuntimeProgress -VmName $vmName
        Write-CloudInitProgress -Progress $progress
        Start-Sleep -Seconds 2
    }
    $timedOut = -not $proc.HasExited
    if ($timedOut) { try { $proc.Kill() } catch {}; try { $proc.WaitForExit(2000) | Out-Null } catch {} }
    return @{
        ExitCode = if ($timedOut) { -1 } else { $proc.ExitCode }
        TimedOut = $timedOut
        Stdout = $outTask.GetAwaiter().GetResult()
        Stderr = $errTask.GetAwaiter().GetResult()
    }
}


# 项目锁定 Multipass 1.14.1(1.16.x 的 daemon 在 Windows 不稳,勿升级)。
# 所有调用仍走硬超时包装,防任何原因命令永不返回(daemon/网络/VM 卡死)

# 调一次 multipass 命令,带硬超时,绝不抛异常,返回 hashtable 让调用方决定
# 用 [System.Diagnostics.Process] 而非 Start-Process:PS 5.x 的 Start-Process + 重定向组合下 ExitCode 永远 null
function Invoke-Multipass {
    param(
        [Parameter(Mandatory)] [string[]]$ArgumentList,
        [int]$TimeoutSec = 60
    )
    # 缓存 multipass.exe 全路径(每次 Get-Command 太慢)
    if (-not $script:multipassExe) {
        $script:multipassExe = (Get-Command multipass -ErrorAction Stop).Source
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:multipassExe
    # 拼接 args,含空格/引号的加引号转义(multipass 参数多为简单 token,workspace 路径可能含空格)
    $psi.Arguments = ($ArgumentList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # UTF-8 输出(避免中文/非 ASCII 路径乱码)
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    [void]$proc.Start()
    # 异步读 stdout/stderr 防止管道死锁(同步 ReadToEnd 会卡死,标准输出写满 buffer 时)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $exited = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        try { $proc.Kill() } catch {}
        try { $proc.WaitForExit(2000) | Out-Null } catch {}
        return @{
            ExitCode = -1
            TimedOut = $true
            Stdout   = ''
            Stderr   = "multipass $($ArgumentList -join ' ') 超时(${TimeoutSec}s)"
        }
    }

    # 等 async 读取完成(进程已退出,任务也会很快完成)
    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.Result } catch {}
    try { $stderr = $errTask.Result } catch {}

    return @{
        ExitCode = $proc.ExitCode
        TimedOut = $false
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

# 等待 VM 内 multipass-sshfs snap 装好。
# 首次 multipass mount 会 lazy-install 这个 snap;snapd change 异步进行,紧接着的第二个 mount
# 会撞 "install-snap change in progress" 必失败。snap list multipass-sshfs exit 0 = 装好,普通用户可读。
# 选 snap list 而非解析 snap changes:输出稳定、不依赖 changes 表列布局。
function Wait-SshfsSnapReady {
    param([int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'snap', 'list', 'multipass-sshfs') -TimeoutSec 15
        if ($r.ExitCode -eq 0 -and -not $r.TimedOut) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

# mount 专用 wrapper:成功/已挂载/失败重试,失败时只警告不抛错(保持原版"继续"语义)
# "already mounted" 视为幂等成功 —— 但需 $VmTarget 配合 findmnt 二次验证
#   (multipassd 重启后可能内部去重表残留:VM 内核 mount 已清但 daemon 仍认为已挂,
#    mount 命令报 already-mounted 实际未挂。此时强制 umount 清表后重 mount)
# snap-install-in-progress 自救:stderr 匹配 snap 冲突时轮询 snap list 等装完再重试 mount
function Try-Mount {
    param(
        [Parameter(Mandatory)] [string[]]$MountArgs,
        [Parameter(Mandatory)] [string]$Description,
        [string]$FailureHint = "",
        [string]$VmTarget = ""    # 可选:VM 内挂载点路径,用于 already-mounted 的 findmnt 二次验证
    )
    # 最多 4 轮:第 1 轮正常 mount;后续轮可能是 snap 装完或状态错乱清理后的重试
    $snapProgressPattern = "install-snap.*in progress|Failed to install 'multipass-sshfs'|enabling mount support"
    $lastStderr = ""
    foreach ($attempt in 1..4) {
        # 120s:慢网络 + cloud-init 在跑时,multipass 跟 VM 的 SSH 通道会慢;60s 实测不够
        $r = Invoke-Multipass -ArgumentList $MountArgs -TimeoutSec 120
        if ($r.ExitCode -eq 0 -or $r.Stderr -match 'already mounted|already.*mount') {
            # 防御 multipassd 状态错乱:只在 already-mounted 分支验证(exit 0 通常真挂上)
            # findmnt 短轮询 10s 同时兜 sshfs mountinfo 同步延迟窗口
            if ($VmTarget -and $r.Stderr -match 'already mounted|already.*mount') {
                if (-not (Wait-VMTargetMounted -Target $VmTarget -TimeoutSec 10)) {
                    # daemon 报已挂但 VM 内核无挂载点 → 强制 umount 清 daemon 残留表,下一轮重 mount
                    Write-Warn "$Description daemon 报已挂但 VM 内未检测到,清理残留重挂..."
                    $null = Invoke-Multipass -ArgumentList @('umount', "${vmName}:${VmTarget}") -TimeoutSec 30
                    if ($attempt -lt 4) { Start-Sleep -Seconds 2; continue }
                    # 第 4 轮还撞状态错乱,落到失败提示
                    $lastStderr = "daemon 状态错乱:umount+mount 重试仍报 already-mounted 但 VM 内无挂载"
                    break
                }
            }
            Write-Ok "$Description 完成"
            return $true
        }
        $lastStderr = if ($r.Stderr) { $r.Stderr.Trim() } else { "" }
        # snap install 进行中:轮询 snap list 等装完,然后下一轮重试 mount
        if ($lastStderr -match $snapProgressPattern) {
            Write-Warn "$Description 等待 multipass-sshfs snap 安装完成..."
            if (Wait-SshfsSnapReady -TimeoutSec 180) {
                continue   # snap 装好了,回去再 mount 一次
            }
            # snap 等待超时,落到下面失败提示
            break
        }
        # 普通瞬态失败:短暂等待后下一轮重试(不自动重置 daemon,1.14.1 稳定;真卡死走 troubleshooting.md §F)
        if ($attempt -lt 4) { Start-Sleep -Seconds 5 }
    }
    $err = if ($lastStderr) { $lastStderr } else { "(超时或无错误输出)" }
    Write-Warn "$Description 失败:$err $FailureHint"
    return $false
}

# ====== 前置检查 ======
function Assert-Prerequisites {
    if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
        throw "multipass 未安装。从 https://multipass.run/install 下载 Windows installer 装好后重试。"
    }
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "ssh 客户端未找到。Windows 10+ 自带 OpenSSH(设置→应用→可选功能→添加 OpenSSH 客户端)。"
    }
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        throw "ssh-keygen 未找到。同上,装 OpenSSH。"
    }
    # Windows 上 Multipass 默认可能禁用 privileged-mounts,需开启才能挂宿主机目录
    # 注意:set 会重启 multipassd(所有版本都是这么生效的,不是 1.16 特有 bug),所以只在值未设时执行
    $cur = Invoke-Multipass -ArgumentList @('get', 'local.privileged-mounts') -TimeoutSec 15
    $needsSet = $cur.ExitCode -ne 0 -or (-not $cur.Stdout) -or $cur.Stdout.Trim() -ne "true"
    if ($needsSet) {
        Write-Step "开启 Multipass privileged-mounts (会重启 multipassd)..."
        $setR = Invoke-Multipass -ArgumentList @('set', 'local.privileged-mounts=true') -TimeoutSec 30
        if ($setR.ExitCode -ne 0 -and -not $setR.TimedOut) {
            # set 失败但不是超时(超时说明 daemon 重启中,正常)
            $err = if ($setR.Stderr) { $setR.Stderr.Trim() } else { "(无 stderr)" }
            Write-Warn "set 失败: $err (挂载可能不可用)"
        }
        # set 触发 multipassd 重启,固定等 10s 恢复,不做轮询(1.14.1 稳定)
        # 若 10s 不够,下一个 list(Test-VmExists)会 fail-fast 报 §F,不会误判成 VM 不存在
        Start-Sleep -Seconds 10
        Write-Ok "privileged-mounts 已开启(daemon 已重启)"
    }
}

# 一次 list 调用拿 VM 的 Name/State/IPv4,找不到返回 $null
# Get-VmState / Get-VmIp 共用此处(容错:list 失败返 $null)
# Test-VmExists 故意不走这里:list 失败必须 throw(fail-fast),不能与"VM 不存在"混淆
function Get-VmRecord {
    $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 15
    if ($r.ExitCode -ne 0) { return $null }
    $line = ($r.Stdout -split "`r?`n" | Where-Object { $_ -like "$vmName,*" } | Select-Object -First 1)
    if (-not $line) { return $null }
    $cols = $line -split ','
    return @{ Name = $cols[0]; State = $cols[1]; IPv4 = $cols[2] }
}

# VM 是否存在(二态):list 失败直接 throw(fail-fast),绝不在不确定时猜 absent
# 猜 absent → 上层会跑去 launch 新 VM 把现有 VM 搞乱;故宁可 throw 让用户查 §F
function Test-VmExists {
    $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 10
    if ($r.ExitCode -ne 0) {
        $err = if ($r.Stderr) { $r.Stderr.Trim() } else { "(无 stderr)" }
        throw "无法确认 VM 是否存在(multipass list 失败: $err)。见 troubleshooting.md §F:管理员重启 Multipass 服务。"
    }
    if ($r.Stdout -split "`r?`n" | Where-Object { $_ -like "$vmName,*" }) { return $true }
    return $false
}

# stop / delete 共用:直接跑 multipass 命令,不做 Test-VmExists 预检
# 停/删 VM 没必要预先知道状态——multipass 自己会告诉我们 VM 在不在
# daemon 卡死时不在这里自动重置(那是 §F 用户主动操作,需要 admin)
function Invoke-VmActionGraceful {
    param(
        [Parameter(Mandatory)] [string[]]$MultipassArgs,
        [string]$AbsentMsg = "VM 不存在,跳过",
        [string]$DoneMsg,
        [int]$TimeoutSec = 60
    )
    $r = Invoke-Multipass -ArgumentList $MultipassArgs -TimeoutSec $TimeoutSec
    if ($r.ExitCode -eq 0) {
        if ($DoneMsg) { Write-Ok $DoneMsg }
        return
    }
    $err = if ($r.Stderr) { $r.Stderr.Trim() } else { "" }
    # "VM 不存在/已停" 类错误:幂等视为已删/已停(实测字面量随版本/multipass 子命令有差异)
    # is not running / not running / already stopped:stop 一个已停实例时 multipass 返回这类错误,同样视为成功
    if ($err -match '(?:does not exist|not found|cannot be found|unknown instance|name.*not known|is not running|not running|already stopped)') {
        Write-Warn $AbsentMsg
        return
    }
    if ($r.TimedOut) {
        Write-Warn "multipass $($MultipassArgs -join ' ') 超时(${TimeoutSec}s)。daemon 可能卡死,见 troubleshooting.md §F(管理员重启 Multipass 服务)"
    } else {
        Write-Warn "multipass $($MultipassArgs -join ' ') 失败 ExitCode=$($r.ExitCode)。stderr: $err"
    }
}

# VM 当前状态(Running / Stopped / ...),失败返 $null
function Get-VmState { (Get-VmRecord).State }

# VM IP,失败返 $null
function Get-VmIp { (Get-VmRecord).IPv4 }

# ====== Bundle 检测 ======
# 检测 bundle/ 是否齐全(Node tarball + Claude wrapper + Claude Linux 二进制 + cc-pocket)
# 项目只走离线 bundle 安装,不齐 → start 直接报错(不做在线降级)
function Test-BundleReady {
    $bundleDir = Join-Path $StateDir 'bundle'
    if (-not (Test-Path $bundleDir)) { return $false }
    $hasNode  = Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue |
                Select-Object -First 1
    $hasWrap  = Get-ChildItem $bundleDir -Filter 'anthropic-ai-claude-code-*.tgz' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'linux-x64' } | Select-Object -First 1
    $hasLinux = Get-ChildItem $bundleDir -Filter 'anthropic-ai-claude-code-linux-x64-*.tgz' -ErrorAction SilentlyContinue |
                Select-Object -First 1
    $hasCc    = Get-ChildItem (Join-Path $bundleDir 'cc-pocket') -Filter 'cc-pocket-daemon-*-linux-x86_64.tar.gz' -ErrorAction SilentlyContinue |
                Select-Object -First 1
    return -not (-not $hasNode -or -not $hasWrap -or -not $hasLinux -or -not $hasCc)
}

# ====== 渲染 cloud-init ======
function Render-CloudInit {
    param(
        # 生效的可选特性 id 列表(来自 Resolve-OptionalFeatures)
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$EnabledFeatures,
        [Parameter(Mandatory)] [string]$AptMirror
    )
    Write-Step "渲染 cloud-init.yaml..."

    $templatePath = Join-Path $assetsDir "cloud-init.yaml"
    $tmuxPath     = Join-Path $assetsDir "tmux.conf"
    $statuslinePath = Join-Path $assetsDir "statusline.sh"
    foreach ($p in @($templatePath, $tmuxPath, $statuslinePath)) {
        if (-not (Test-Path $p)) { throw "缺文件: $p" }
    }

    $template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
    $tmuxRaw  = [System.IO.File]::ReadAllText($tmuxPath, [System.Text.Encoding]::UTF8)
    $statuslineRaw = [System.IO.File]::ReadAllText($statuslinePath, [System.Text.Encoding]::UTF8)

    # YAML block scalar 缩进:cloud-init.yaml 占位符所在 content: | 块是 6 空格缩进
    $tmuxIndented = (($tmuxRaw -split "`r?`n") | ForEach-Object { "      " + $_ }) -join "`n"
    # 去掉末尾多余空行,避免 YAML 末尾混乱
    $tmuxIndented = $tmuxIndented.TrimEnd("`n")
    $statuslineIndented = (($statuslineRaw -split "`r?\n") | ForEach-Object { "      " + $_ }) -join "`n"
    $statuslineIndented = $statuslineIndented.TrimEnd("`n")

    $pubKeyPath = Join-Path $StateDir ".ssh-key.pub"
    if (-not (Test-Path $pubKeyPath)) { throw ".ssh-key.pub 不存在,Start 流程漏了 keygen 步?" }
    $pubKey = ([System.IO.File]::ReadAllText($pubKeyPath, [System.Text.Encoding]::UTF8)).Trim()

    $rendered = $template.Replace('{{TMUX_CONF_PLACEHOLDER}}', $tmuxIndented)
    $rendered = $rendered.Replace('{{STATUSLINE_PLACEHOLDER}}', $statuslineIndented)
    # SSH_PUBKEY 现在在 runcmd 的 echo "..." 里,不需要缩进
    $rendered = $rendered.Replace('{{SSH_PUBKEY_PLACEHOLDER}}', $pubKey)

    # 各可选特性的注入块:按 Id 判断,块内容替换 cloud-init.yaml 里的 {{XXX_BLOCK}} 占位符(2 空格缩进
    # 对齐 runcmd 列表项),未启用替换成空字符串(留空行不影响 YAML 解析)
    # 新增特性:assets/cloud-init.yaml 加占位符(注意缩进注释)+ 这里加一段 $xxxBlock
    if ($EnabledFeatures -contains 'tailscale') {
        $tailscaleBlock = @"
  # tailscale(家里跨网络用;VM 拿 100.x.x.x tailnet IP,配对后手机 4G 能通过 cc-pocket 遥控)
  # 注:仅安装未运行 'tailscale up' 时无出站流量,但软件审计能看到包已装
  - printf '%s\n' 'stage=5' 'package=5' 'package_name=安装 Tailscale' > /run/claude-dev/progress
  - curl -fsSL https://tailscale.com/install.sh | sh
  - printf '%s\n' 'stage=5' 'package=6' 'package_name=Tailscale 处理完成' > /run/claude-dev/progress
"@
    } else {
        $tailscaleBlock = ""
    }
    $rendered = $rendered.Replace('{{TAILSCALE_BLOCK}}', $tailscaleBlock)
    if ($AptMirror -notmatch '^[a-zA-Z0-9.-]+(:[0-9]+)?$') { throw "-AptMirror 只能是合法 hostname,当前值: $AptMirror" }
    $rendered = $rendered.Replace('{{APT_MIRROR_PLACEHOLDER}}', $AptMirror)

    $renderedPath = Join-Path $StateDir ".cloud-init.rendered.yaml"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($renderedPath, $rendered, $utf8NoBom)
    Write-Ok "渲染完成: $renderedPath"
    return $renderedPath
}

# ====== 隧道模式判定 ======
# 读宿主机 ~/.claude/settings.json 的 env.ANTHROPIC_BASE_URL:
#   本地(127.0.0.1/localhost/[::1]) → tunnel:起 SSH 反向隧道回连本地代理(典型:cc-switch)
#   公网 URL                        → direct:VM 直连,跳过隧道
# 读不到/解析失败 → 保守按 tunnel(与历史行为一致,隧道留着无害)
function Get-TunnelDecision {
    param(
        [int]$ConfiguredPort,
        [switch]$ExplicitPort
    )
    $port = $ConfiguredPort
    $baseUrl = $null
    try {
        $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
        if (Test-Path $settingsPath) {
            $baseUrl = (Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).env.ANTHROPIC_BASE_URL
        }
    } catch { $baseUrl = $null }

    if (-not $baseUrl) {
        return @{ Mode = 'tunnel'; Port = $port; BaseUrl = $null; Reason = '未读到 ANTHROPIC_BASE_URL,按本地代理处理(保守)' }
    }
    $u = $null
    try { $u = [uri]$baseUrl } catch { }
    if ($u -and @('127.0.0.1', 'localhost', '::1') -contains $u.Host) {
        # URL 带非默认端口且用户没显式传 -CcSwitchPort → 采信 URL 里的端口
        if (-not $ExplicitPort -and $u.Port -gt 0 -and $u.Port -ne 80 -and $u.Port -ne 443) { $port = $u.Port }
        return @{ Mode = 'tunnel'; Port = $port; BaseUrl = $baseUrl; Reason = "ANTHROPIC_BASE_URL 指向本地 $($u.Host):$($u.Port)" }
    }
    if ($u) {
        return @{ Mode = 'direct'; Port = $port; BaseUrl = $baseUrl; Reason = "ANTHROPIC_BASE_URL 是公网地址($($u.Host)),VM 直连即可" }
    }
    return @{ Mode = 'tunnel'; Port = $port; BaseUrl = $baseUrl; Reason = 'ANTHROPIC_BASE_URL 无法解析为 URL,按本地代理处理(保守)' }
}

# ====== 杀隧道 ======
function Stop-Tunnel {
    $pidFile = Join-Path $StateDir ".tunnel.pid"
    if (-not (Test-Path $pidFile)) { return }
    $tpid = (Get-Content $pidFile -First 1).Trim()
    if ($tpid -and (Get-Process -Id $tpid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $tpid -Force
        Write-Ok "隧道 PID $tpid 已停"
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# ====== ExtraMounts 辅助:findmnt 验证挂载点真挂上了 ======
# multipass mount 输出不可靠(already mounted 误报等),用 VM 内 findmnt 才是真相
function Test-VMTargetMounted {
    param([Parameter(Mandatory)] [string]$Target)
    $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'findmnt', '-n', $Target) -TimeoutSec 15
    return $r.ExitCode -eq 0 -and $r.Stdout -match [regex]::Escape($Target)
}

# 带短轮询的 Test-VMTargetMounted:堵 sshfs 挂载点 mountinfo 同步延迟窗口
# (Try-Mount 报 OK 后,VM 内核更新 mountinfo 可能有秒级延迟,findmnt 立即查会落空)
# 稳定时立即返回,只在延迟窗口轮询,默认 10s
function Wait-VMTargetMounted {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [int]$TimeoutSec = 10,
        [int]$IntervalSec = 2
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-VMTargetMounted -Target $Target) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

# ====== .claude-host 硬 RO:bind + remount ro (内核层,不污染宿主) ======
# 背景:multipass mount 不支持原生 RO(issue #4601),chmod 又会经 SFTP 传回宿主
# 污染 ~/.claude。bind+remount ro 在 VM VFS 层做 RO,挡住包括 FUSE owner 在内的
# 所有写(EROFS),且完全不外泄到宿主机。
# 幂等:findmnt 检测 topmost mount 的 ro 选项;失败只警告不 throw(对齐 Try-Mount 语义)
function Set-HostMountReadOnly {
    param([Parameter(Mandatory)] [string]$Target)
    # 1) 先确认 FUSE 挂载真活(短轮询,堵 sshfs mountinfo 同步延迟)
    if (-not (Wait-VMTargetMounted -Target $Target -TimeoutSec 10)) {
        Write-Warn "RO 设置跳过:$Target 未挂载(findmnt 10s 内无记录)"
        return $false
    }
    # 2) 幂等检查:topmost mount 的 OPTIONS 已含 ro 就直接 OK
    $ro = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc',
        "findmnt -n -o OPTIONS -T '$Target' 2>/dev/null | tr ',' '\n' | grep -qx ro") -TimeoutSec 15
    if ($ro.ExitCode -eq 0) { Write-Ok "$Target 已是 RO"; return $true }
    # 3) bind + remount,ro,bind:同路径 bind 是 stacked mount,kernel 看 topmost 的 flags
    $script = "sudo mount --bind '$Target' '$Target' 2>/dev/null || true; sudo mount -o remount,ro,bind '$Target'"
    $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc', $script) -TimeoutSec 30
    if ($r.ExitCode -ne 0 -or $r.TimedOut) {
        Write-Warn "$Target RO 设置失败:$($r.Stderr) (RW 仍可用,继续)"
        return $false
    }
    Write-Ok "$Target 已设为 RO"
    return $true
}

# ====== VM 内 Claude Code 全局记忆:宿主机 ↔ VM 路径映射(可选特性 path-map) ======
# 往 VM 本地 ~/.claude/CLAUDE.md 写 managed block(<!-- cc-sandbox:begin/end --> 标记之间,
# 每次 start 按当前挂载整块刷新,块外用户自己写的内容保留)。
# 目的:用户在对话里贴宿主机(Windows)路径时,VM 里的 Claude Code 按表换算成挂载点路径。
# -Mappings 传映射写块;-Remove 删块(取消勾选时用,幂等,无块时无操作)。
# 失败只警告不 throw(CLAUDE.md 写不进不影响 VM 可用性,对齐 Try-Mount 语义)
function Set-VMClaudeMemory {
    param(
        # 每项 @{ HostPrefix=<宿主机绝对路径>; VmPath=<VM 内绝对路径> }
        [AllowEmptyCollection()] [array]$Mappings = @(),
        [switch]$Remove
    )

    if ($Remove) {
        # 删旧块 + 剥尾部空行;文件不存在直接成功(幂等)
        $script = 'f=/home/ubuntu/.claude/CLAUDE.md; [ -f "$f" ] || exit 0; sed -i "/^<!-- cc-sandbox:begin/,/^<!-- cc-sandbox:end -->/d" "$f"; while [ -s "$f" ] && [ -z "$(tail -n 1 "$f")" ]; do sed -i "\$d" "$f"; done; exit 0'
        $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c', $script) -TimeoutSec 30
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            Write-Warn "移除 VM 内路径映射块失败:$($r.Stderr)(不影响其他功能)"
        } else {
            Write-Ok "已移除 VM 内路径映射块(~/.claude/CLAUDE.md)"
        }
        return
    }

    # 宿主侧拼好整块 markdown,VM 端只做整块替换(避免多行/引号穿透 exec 传参)
    $rows = ($Mappings | ForEach-Object {
        "| ``$($_.HostPrefix)`` | ``$($_.VmPath)`` |"
    }) -join "`n"
    $exampleHost = "$($Mappings[0].HostPrefix)\test-project\.gitignore"
    $exampleVm   = "$($Mappings[0].VmPath)/test-project/.gitignore"

    $block = @'
<!-- cc-sandbox:begin -->
## 沙箱环境(cc-sandbox 自动生成,勿手改本区块)

你在 Multipass Ubuntu VM(claude-dev)里运行,不是在用户的 Windows 宿主机上。
workspace 由宿主机挂载进来,同一文件两边路径不同;用户消息里的 Windows 路径,按表换算后再操作。

### 宿主机路径 ↔ VM 路径映射

| 宿主机路径前缀 | VM 内路径 |
| --- | --- |
{{MAPPING_ROWS}}

换算规则:

- 命中判断忽略大小写:用户路径等于某前缀,或以"前缀 + `\`"开头,即命中该行。
- 命中后把前缀部分替换为对应 VM 路径,余下路径的 `\` 换成 `/`。例:`{{EXAMPLE_HOST}}` → `{{EXAMPLE_VM}}`。
- 反向同理:给用户展示文件位置时换算回宿主机路径,方便其在 Windows 侧定位。
- 前缀不在表中的宿主机路径未挂载进 VM,无法访问,应明确告知用户。
<!-- cc-sandbox:end -->
'@
    $block = $block.Replace('{{MAPPING_ROWS}}', $rows).Replace('{{EXAMPLE_HOST}}', $exampleHost).Replace('{{EXAMPLE_VM}}', $exampleVm)

    # 块文件经 transfer 传入(避免引号/换行穿透 exec 参数),UTF-8 无 BOM
    $blockHost = Join-Path $env:TEMP "cc-sandbox-claude-block.md"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($blockHost, $block + "`n", $utf8NoBom)

    $transfer = Invoke-Multipass -ArgumentList @('transfer', $blockHost, "${vmName}:/tmp/cc-sandbox-claude-block.md") -TimeoutSec 30
    if ($transfer.TimedOut -or $transfer.ExitCode -ne 0) {
        $err = if ($transfer.TimedOut) { "超时" } elseif ($transfer.Stderr) { $transfer.Stderr.Trim() } else { "(无 stderr)" }
        Write-Warn "路径映射块传入 VM 失败:$err(VM 里 Claude Code 不会自动换算宿主机路径,其余不受影响)"
        return
    }
    # 幂等整块替换:删旧块(若有)→ 剥尾部空行 → 非空文件补一个分隔空行 → 追加新块
    $merge = 'mkdir -p /home/ubuntu/.claude && touch /home/ubuntu/.claude/CLAUDE.md && sed -i "/^<!-- cc-sandbox:begin/,/^<!-- cc-sandbox:end -->/d" /home/ubuntu/.claude/CLAUDE.md && f=/home/ubuntu/.claude/CLAUDE.md; while [ -s "$f" ] && [ -z "$(tail -n 1 "$f")" ]; do sed -i "\$d" "$f"; done; [ -s "$f" ] && printf "\n" >> "$f"; cat /tmp/cc-sandbox-claude-block.md >> "$f" && rm -f /tmp/cc-sandbox-claude-block.md'
    $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c', $merge) -TimeoutSec 30
    if ($r.TimedOut -or $r.ExitCode -ne 0) {
        $err = if ($r.TimedOut) { "超时" } elseif ($r.Stderr) { $r.Stderr.Trim() } else { "(无 stderr)" }
        Write-Warn "路径映射块写入 ~/.claude/CLAUDE.md 失败:$err"
        return
    }
    Write-Ok "已写入宿主机↔VM 路径映射到 VM ~/.claude/CLAUDE.md($($Mappings.Count) 条)"
}

# ====== ExtraMounts:来源(参数优先,否则读 mounts.txt) ======
# 返回 string[];无参数且配置文件不存在/为空 → 返回空数组(调用方跳过)
function Get-ExtraMountsSource {
    if ($ExtraMounts -and $ExtraMounts.Count -gt 0) { return @($ExtraMounts) }
    $cfg = Join-Path $StateDir "mounts.txt"
    if (-not (Test-Path $cfg)) { return @() }
    if (-not (Test-Path $cfg -PathType Leaf)) { throw "mounts.txt 不是普通文件: $cfg" }
    try {
        $lines = Get-Content $cfg -Encoding UTF8 -ErrorAction Stop | ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -ne "" -and -not $_.StartsWith("#") }
    } catch {
        throw "无法读取 mounts.txt: $($_.Exception.Message)"
    }
    return @($lines)
}

# ====== ExtraMounts:解析 + 校验 ======
# 输入:[string[]] 每项 "HostPath" 或 "HostPath=vmSubdir"
# 输出:hashtable 数组,每项 @{ HostPath=<绝对路径>; VmSubdir=<相对路径>; Target=<VM 内绝对路径> }
# 解析/校验失败直接 throw(参数错误 fail fast)
function Resolve-ExtraMounts {
    param([Parameter(Mandatory)] [string[]]$Items)

    $result = @()
    $seenSubdirs = @{}
    foreach ($item in $Items) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            throw "-ExtraMounts 含空项。每项格式: HostPath 或 HostPath=vmSubdir"
        }

        # 按第一个 '=' 切;无 '=' 时整项为 HostPath,子目录名取宿主目录最后一级
        $idx = $item.IndexOf('=')
        if ($idx -ge 0) {
            $hostRaw  = $item.Substring(0, $idx).Trim()
            $vmSubdir = $item.Substring($idx + 1).Trim()
        } else {
            $hostRaw  = $item.Trim()
            $vmSubdir = ""
        }
        if ([string]::IsNullOrWhiteSpace($hostRaw)) {
            throw "-ExtraMounts 项 '$item' 宿主机路径为空。格式: HostPath 或 HostPath=vmSubdir"
        }

        # 校验宿主源目录必须存在(先校验,简写取目录名也依赖它)
        if (-not (Test-Path $hostRaw -PathType Container)) {
            throw "-ExtraMounts 项 '$item' 的宿主机目录不存在或不是目录: $hostRaw"
        }
        $hostPath = (Resolve-Path $hostRaw).Path

        # 简写:子目录名 = 宿主目录最后一级名(先去尾部 \ /)
        if ($vmSubdir -eq "") {
            $vmSubdir = Split-Path -Leaf ($hostPath.TrimEnd('\', '/'))
        }

        # 校验 vmSubdir(必须是 workspace 下的相对路径,禁逃逸)
        $vmSubdir = $vmSubdir.Replace([char]92, [char]47)
        $vmSubdir = $vmSubdir.Trim('/')
        if ([string]::IsNullOrWhiteSpace($vmSubdir) -or $vmSubdir -eq '.') {
            throw "-ExtraMounts 项 '$item' 的 vmSubdir 不能为空或 '.'(不能覆盖 workspace 根目录)"
        }
        $segments = $vmSubdir -split '/'
        if ($segments -contains '.') {
            throw "-ExtraMounts 项 '$item' 的 vmSubdir 不允许含 '.'(必须是 workspace 下的真实子目录): $vmSubdir"
        }
        if ($vmSubdir -match '(^|/)\.\.(/|$)') {
            throw "-ExtraMounts 项 '$item' 的 vmSubdir 不允许含 '..'(防逃逸出 workspace): $vmSubdir"
        }

        # 子目录名冲突(两项映射到同一子目录)
        if ($seenSubdirs.ContainsKey($vmSubdir)) {
            throw "-ExtraMounts 子目录名重复: '$vmSubdir' 同时被 '$($seenSubdirs[$vmSubdir])' 和 '$hostPath' 使用"
        }
        $seenSubdirs[$vmSubdir] = $hostPath

        $result += @{
            HostPath = $hostPath
            VmSubdir = $vmSubdir
            Target   = "$mountWorkspace/$vmSubdir"
        }
    }
    return $result
}

# ====== ExtraMounts:实际挂载 ======
# 仅在 ~/workspace 是 VM 本地目录时调用(即 -NoRootWorkspace),避免嵌套挂载
function Mount-ExtraMounts {
    param([Parameter(Mandatory)] [array]$Mounts)

    if ($Mounts.Count -eq 0) { return $true }

    $allMounted = $true
    Write-Step "挂载额外目录($($Mounts.Count) 个)到 $mountWorkspace 子目录..."
    foreach ($m in $Mounts) {
        $target = $m.Target     # VM 内绝对路径,如 /home/ubuntu/workspace/repo1
        $src    = $m.HostPath

        # 1) VM 内先 mkdir -p,否则 multipass mount 目标不存在会失败
        $mk = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'mkdir', '-p', $target) -TimeoutSec 30
        if ($mk.TimedOut -or $mk.ExitCode -ne 0) {
            $err = if ($mk.TimedOut) { "超时" } elseif ($mk.Stderr) { $mk.Stderr.Trim() } else { "(无 stderr)" }
            Write-Warn "mkdir -p $target 失败:$err(跳过 $src)"
            $allMounted = $false
            continue
        }

        # 2) 每次先卸载目标的旧映射再重挂:findmnt 只能证明目标被挂载,不能证明
        #    它仍对应当前 mounts.txt/-ExtraMounts 声明的宿主源目录
        $null = Invoke-Multipass -ArgumentList @('umount', "${vmName}:${target}") -TimeoutSec 30

        # 3) 走 Try-Mount:自带 snap-install-progress 自救(首个 mount 触发 lazy install
        #    multipass-sshfs snap,后续 mount 撞 change in progress 时轮询等装完再重试)
        #    + already-mounted 幂等 + 失败重试
        $mounted = Try-Mount -MountArgs @('mount', $src, "${vmName}:${target}") `
                             -Description "挂载 $src → $target" `
                             -FailureHint "(重新运行 .\launch.ps1 start -NoRootWorkspace 会再次尝试清理并挂载)" `
                             -VmTarget $target

        # 4) findmnt 双重确认:Try-Mount 报 OK 不代表真挂上(Multipass 偶尔报告 OK 但 findmnt 无)
        #    sshfs 挂载点 mountinfo 同步有秒级延迟,这里短轮询 10s
        if ($mounted -and (Wait-VMTargetMounted -Target $target -TimeoutSec 10)) {
            # Try-Mount 已打过 Write-Ok,不重复
        } else {
            if ($mounted) {
                Write-Warn "挂载 $src → $target 异常:Try-Mount 返成功但 findmnt 10s 内未检测到挂载"
            }
            # Try-Mount 失败时已 Write-Warn 过,这里不重复
            $allMounted = $false
        }
    }
    return $allMounted
}

# ====== 可选特性:持久化(features.txt)/ 探测 / 重建确认 ======
# 交互菜单(方向键 TUI + 编号降级)在 feature-menu.ps1;持久化文件在 $StateDir\features.txt,
# 风格同 mounts.txt:每行一个特性 id,# 注释,空行忽略

# 读 features.txt(无文件/空 → 空列表);未知 id 忽略并提示(版本升降级/手误的向前兼容)
function Get-SavedFeatureIds {
    $cfg = Join-Path $StateDir "features.txt"
    if (-not (Test-Path $cfg -PathType Leaf)) { return @() }
    $known = @($optionalFeatures | ForEach-Object { $_.Id })
    $ids = @()
    foreach ($line in (Get-Content $cfg -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        if ($known -contains $t) {
            $ids += $t
        } else {
            Write-Host "    忽略 features.txt 里的未知特性: $t(可能是新旧版本 skill 的标识)" -ForegroundColor DarkGray
        }
    }
    return @($ids)
}

function Set-SavedFeatureIds {
    # AllowEmptyCollection:全不选(菜单 n)时写回空列表,Mandatory 默认会拒空数组(实测 2026-08-17)
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Ids)
    $cfg = Join-Path $StateDir "features.txt"
    $lines = @(
        "# 可选特性选择:launch.ps1 start 交互菜单会自动改写此文件"
        "# 每行一个特性 id;删掉某行即关闭该特性(重建型特性需 delete + start 重建才生效)"
    ) + @($Ids)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cfg, ($lines -join "`n") + "`n", $utf8NoBom)
}

# 汇总本次生效的可选特性 id:交互菜单(真人终端)> features.txt > 全关
# 结果统一写回 features.txt:delete + start 重建、日常 start 都不用再记参数
function Resolve-OptionalFeatures {
    $saved = @(Get-SavedFeatureIds)
    if (Test-InteractiveConsole) {
        $picked = @(Select-OptionalFeatures -Current $saved)
    } else {
        $picked = $saved
    }
    # 与文件不一致才写,避免每次 start 都碰文件
    $differs = (@($picked).Count -ne @($saved).Count) -or (@($picked | Where-Object { $saved -notcontains $_ }).Count -gt 0)
    if ($differs) { Set-SavedFeatureIds -Ids @($picked) }
    # 空选择也要以"空数组"传给调用方:不加逗号包裹,空数组会坍缩成无输出,
    # 调用方拿到 $null → Render-CloudInit/Confirm-RebuildForFeatures 参数绑定报错(实测 2026-08-17)
    return ,@($picked)
}

# VM 内探测某特性是否已生效:Probe 片段约定 exit 0 = 已生效、exit 1 = 未生效;
# 其他退出码/超时 = 无法判定(重试后仍失败返回 $null,调用方按未知处理,不据此触发重建询问,
# 防止 SSH 偶发抖动被误读成"特性没装"而怂恿用户重建)
function Test-FeatureInVm {
    param([Parameter(Mandatory)] [string]$Probe)
    foreach ($try in 1..3) {
        $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc', $Probe) -TimeoutSec 15
        if (-not $r.TimedOut -and $r.ExitCode -eq 0) { return $true }
        # exit 1 且 stderr 干净才是"探测跑了、确实没装"(probe 自身重定向了 stderr);
        # 带 stderr 的 exit 1 更可能是 SSH/daemon 抖动,不当作未生效
        if (-not $r.TimedOut -and $r.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($r.Stderr)) { return $false }
        Start-Sleep -Seconds 3   # 刚唤醒时 SSH 可能没就绪,稍等重试
    }
    return $null
}

# 已有 VM 上新启用、尚未生效的重建型特性:交互询问是否立即删除重建(替代手动 delete + start 两条命令)
# 返回 $true = VM 仍在(走重挂/重起隧道),$false = 已删除(走重新 launch)
function Confirm-RebuildForFeatures {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$EnabledFeatures)
    $pending = @(); $unknown = @()
    foreach ($f in $optionalFeatures) {
        if (-not $f.RebuildOnly -or $EnabledFeatures -notcontains $f.Id) { continue }
        $inVm = Test-FeatureInVm -Probe $f.Probe
        if ($inVm -eq $true) { continue }
        if ($null -eq $inVm) { $unknown += $f.Name } else { $pending += $f }
    }
    if ($unknown.Count -gt 0) {
        Write-Warn "无法确认 VM 是否已装: $($unknown -join ', ')(探测超时)。若属新启用,需 delete + start 重建才生效"
    }
    if ($pending.Count -eq 0) { return $true }
    $names = ($pending | ForEach-Object { $_.Name }) -join ', '
    if (-not (Test-InteractiveConsole)) {
        Write-Warn "新启用的 $names 需重建 VM 才生效,本次 start 不动现有 VM。交互终端裸跑 start 可选立即重建"
        $script:skippedRebuildIds = @($script:skippedRebuildIds) + @($pending | ForEach-Object { $_.Id })
        return $true
    }
    Write-Warn "新启用的 $names 需要重建 VM(cloud-init 只在创建 VM 时跑;状态目录的 workspace/SSH key 等保留)"
    while ($true) {
        $ans = (Read-Host "现在删除并重建 VM?(y=重建, N=跳过)").Trim()
        if ($ans -match '^[Yy]') {
            Write-Step "删除旧 VM 以应用新特性..."
            Invoke-VmActionGraceful -MultipassArgs @('delete', '--purge', $vmName) -DoneMsg "旧 VM 已删除(状态目录数据保留)" -AbsentMsg "VM 不存在,跳过删除"
            return $false
        }
        if ($ans -eq "" -or $ans -match '^[Nn]') {
            Write-Warn "跳过重建,$names 将在下次 delete + start 时生效"
            # 记下跳过的特性,收尾提示不能再说"已预装,可配对"——包根本还没进 VM
            $script:skippedRebuildIds = @($script:skippedRebuildIds) + @($pending | ForEach-Object { $_.Id })
            return $true
        }
    }
}

# ====== start ======
function Start-ClaudeDev {
    Assert-Prerequisites

    # 多目录挂载参数校验 + 解析(在动 VM 前先 fail fast,避免无效参数触发 daemon 重启等副作用)
    $extraItems = Get-ExtraMountsSource
    if ($NoRootWorkspace -and $WorkspaceHost) {
        throw "-NoRootWorkspace 与 -WorkspaceHost 不能同时使用。前者用 -ExtraMounts/mounts.txt 挂子目录,后者只用于传统单根 workspace 挂载"
    }
    if (-not $NoRootWorkspace -and $extraItems.Count -gt 0) {
        throw "检测到 mounts.txt 或 -ExtraMounts,但普通 start 会产生嵌套挂载。请加 -NoRootWorkspace,或移除额外挂载后再用普通 start"
    }
    # -WorkspaceHost 校验也属 fail-fast:若放在挂载段(Stop-Tunnel 之后)才 throw,
    # 参数错误会先杀掉活隧道再退出,留下"隧道已死"的状态
    if ($WorkspaceHost -and -not (Test-Path $WorkspaceHost -PathType Container)) {
        throw "-WorkspaceHost 必须是已存在的目录: $WorkspaceHost"
    }
    $resolvedExtraMounts = if ($extraItems.Count -gt 0) { Resolve-ExtraMounts -Items $extraItems } else { @() }
    # 零挂载的 -NoRootWorkspace 属配置不完整:VM workspace 会是本地空目录,
    # path-map 也无映射可写(勾选了却不生效)。与上面两条校验同风格,启动前拦下
    if ($NoRootWorkspace -and $resolvedExtraMounts.Count -eq 0) {
        throw "-NoRootWorkspace 需要至少一个挂载:$StateDir\mounts.txt 不存在或为空,且未传 -ExtraMounts。把 $StateDir\mounts.example.txt 复制为 mounts.txt,填入宿主目录(每行一个)后重跑;或直接传 -ExtraMounts"
    }

    # 可选特性:交互菜单(真人终端)> features.txt;选择统一写回 features.txt(重建后不丢)
    $enabledFeatures = Resolve-OptionalFeatures
    if (@($enabledFeatures).Count -eq 0) {
        Write-Host "    可选特性: 无(想启用:交互终端裸跑 start 弹菜单,或编辑 $StateDir\features.txt)" -ForegroundColor DarkGray
    } else {
        $featureNames = ($optionalFeatures | Where-Object { $enabledFeatures -contains $_.Id } | ForEach-Object { $_.Name }) -join ', '
        Write-Ok "可选特性: $featureNames"
    }

    # 隧道复用/清理:start 幂等可反复跑。停旧隧道(后面会重起)
    Stop-Tunnel
    $pidFile = Join-Path $StateDir ".tunnel.pid"

    # SSH keypair
    $keyPath = Join-Path $StateDir ".ssh-key"
    if (-not (Test-Path $keyPath)) {
        Write-Step "生成 SSH keypair..."
        # PowerShell 处理空 passphrase 的坑:-N "" 会被 PS 吞成空,用 '""' 包一层
        & ssh-keygen -t ed25519 -f $keyPath -N '""' -C "claude-dev-tunnel" -q
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen 失败" }
        Write-Ok ".ssh-key 生成"
    }

    # bundle 检测:项目只走离线 bundle 安装(不齐直接报错,不做在线降级)
    $bundleReady = Test-BundleReady
    if (-not $bundleReady) {
        throw "bundle 不完整,停止启动。项目不支持在线安装降级——请先跑 .\scripts\prepare-bundle.ps1 补齐 Node + Claude Code + cc-pocket 离线包后重试。"
    }
    Write-Ok "检测到 bundle,安装模式: Node/Claude Code/cc-pocket 使用本地 bundle"
    $renderedPath = Render-CloudInit -EnabledFeatures $enabledFeatures -AptMirror $AptMirror

    $script:progressState = @{}
    $script:cloudInitShown = $script:progressState
    $script:launchProgressShown = @{}
    Write-Step "启动 VM(若新建:基础 cloud-init + 离线 bundle 装 Node/Claude Code;已存在则只重挂/重起隧道)..."
    # 二态判断:list 失败已在 Test-VmExists 里 throw(fail-fast),绝不猜 absent 跑去 launch 新的
    $vmExists = Test-VmExists
    if ($vmExists) {
        $state = Get-VmState
        if ($state -ne "Running") {
            # 先唤醒再探测:新启用的重建型特性要看 VM 里实际装没装,VM 停着探不了
            Write-Step "唤醒 VM..."
            $r = Invoke-Multipass -ArgumentList @('start', $vmName) -TimeoutSec 90
            if ($r.TimedOut -or $r.ExitCode -ne 0) {
                throw "multipass start 失败(daemon 可能卡死)。见 troubleshooting.md §F:管理员重启 Multipass 服务。"
            }
            Write-Ok "VM 从 $state 唤醒"
        }
        # 新启用的重建型特性(cloud-init 只在创建 VM 时跑)在现有 VM 上未生效 →
        # 交互终端询问是否立即 delete+重建(免掉手动两条命令);非交互只提醒,不动现有 VM
        $vmExists = Confirm-RebuildForFeatures -EnabledFeatures $enabledFeatures
    }
    if ($vmExists) {
        Write-Warn "VM 已存在,start 改为只重挂/重起隧道(重建型参数不生效)"
    } else {
        $launchArgs = @("launch", "--name", $vmName,
                        "--cpus", $cpus,
                        "--memory", "${memoryGB}G",
                        "--disk", "${diskGB}G",
                        "--cloud-init", $renderedPath,
                        "--timeout", "1200")
        # 不在 multipass launch 阶段传 bundle；先完成基础 cloud-init,再由后续流程 transfer 并安装。
        $launchArgs += $image
        # 不自动重置 daemon(1.14.1 稳定);launch 失败如实报错,见 troubleshooting.md §F
        # --timeout 1200 把 multipass CLI 自己的超时从默认 5 分钟拉到 20 分钟
        # PS 端给 1300s 留 100s 缓冲,让 multipass 的 --timeout 先触发(而不是 PS 硬杀)
        $r = Invoke-MultipassLaunchWithProgress -ArgumentList $launchArgs -TimeoutSec 1300

        if ($r.TimedOut) {
            # cloud-init 5.x 偶发"完成信号丢失"(非 1.16 特有),VM 可能实际已就绪。
            # 不再探测 VM 实际状态——直接 throw,让用户 multipass list 确认(避免掩盖真问题)。
            throw "multipass launch 超时(20 分钟)。cloud-init 5.x 偶发完成信号丢失,VM 可能实际已就绪;请 'multipass list' 确认——若已 Running,重跑 scripts\launch.ps1 start 只重挂/重起隧道;若未就绪,scripts\launch.ps1 delete 后重试。日志:%USERPROFILE%\.multipass\data"
        }
        if ($r.ExitCode -ne 0) {
            $err = if ($r.Stderr) { $r.Stderr.Trim() } else { "(无 stderr)" }
            throw "multipass launch 失败(ExitCode=$($r.ExitCode)): $err (daemon 卡死见 troubleshooting.md §F;镜像名/后端错误检查参数)"
        }
        Write-Ok "VM 创建并启动"
    }

    # 等 cloud-init,同时在当前窗口显示安全阶段进度
    $cloudInitProgressStatus = Wait-CloudInitWithProgress -VmName $vmName

    # cloud-init 阶段结束后只记录完成,整个 bundle/传输/隧道流程结束时才显示 [6/6]
    if ($cloudInitProgressStatus -eq 'done') {
        $cloudInitSnapshot = Show-CloudInitProgress -VmName $vmName
        Complete-CloudInitProgress -Progress $cloudInitSnapshot
    } elseif ($cloudInitProgressStatus -eq 'error') {
        # error 不中断(基础包缺失不一定全致命,后续 bundle 安装会再验证),但必须显式提醒,
        # 否则真因(APT 源挂了)会被"bundle 本地安装失败"误导
        Write-Warn "cloud-init 结束状态: error(常见是 APT 镜像不可达、基础包装失败)。若后续 bundle 安装报错,先查 'multipass exec $vmName -- cloud-init status --long' 和 /var/log/cloud-init-output.log"
    }

    # 基础 cloud-init 完成后再传 bundle:bundle 是 ~220MB 只读 tarball,不需要"实时挂载"。
    # multipass mount 走 multipass-sshfs,新 VM 上 daemon 首次推 sshfs 二进制经常超 180s
    # (实测 2026-08-12:cloud-init done、daemon 健康、mount 180s 仍未完成)。
    # 改用 transfer -r 直接 SFTP 拷贝,绕开 sshfs 推送瓶颈。
    Write-Step "传输离线 bundle 到 VM..."
    $bundleHost = Join-Path $StateDir 'bundle'
    # 关键文件存在 = 已传过,跳过(幂等)。4 个必需文件全查;wrapper 用 [0-9] 排除 linux-x64 变体(同 install-bundle.sh 的 glob)
    $bundleKeyFiles = 'test -f /home/ubuntu/.bundle/node-v*-linux-x64.tar.xz && test -f /home/ubuntu/.bundle/anthropic-ai-claude-code-[0-9]*.tgz && test -f /home/ubuntu/.bundle/anthropic-ai-claude-code-linux-x64-*.tgz && test -f /home/ubuntu/.bundle/cc-pocket/cc-pocket-daemon-*-linux-x86_64.tar.gz'
    $bundleCheck = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc', $bundleKeyFiles) -TimeoutSec 30
    if ($bundleCheck.TimedOut) { throw "bundle 关键文件检查超时,停止启动" }
    if ($bundleCheck.ExitCode -ne 0) {
        # transfer -r 在 dst 已存在时会拷成 dst/<src-name>/,先 rm -rf 保证干净
        $null = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'sudo', 'rm', '-rf', '/home/ubuntu/.bundle') -TimeoutSec 30
        # 600s:~220MB SFTP,慢网络给足余量
        $bundleTransfer = Invoke-Multipass -ArgumentList @('transfer', '-r', $bundleHost, "${vmName}:/home/ubuntu/.bundle") -TimeoutSec 600
        if ($bundleTransfer.TimedOut -or $bundleTransfer.ExitCode -ne 0) {
            $err = if ($bundleTransfer.Stderr) { $bundleTransfer.Stderr.Trim() } else { '(无 stderr)' }
            throw "bundle 传输失败，停止启动。$err"
        }
        # 传输后再校验关键文件齐全
        $recheck = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc', $bundleKeyFiles) -TimeoutSec 30
        if ($recheck.ExitCode -ne 0 -or $recheck.TimedOut) { throw "bundle 传输后关键文件不完整，停止启动" }
    }
    Write-Ok "bundle 已传输且关键文件齐全"

    # bundle 传输后:先探测是否已装好(已装好跳过重装,省 ~1 分钟),否则执行本地安装
    # 用 type -P(PATH-only)而非 command -v:profile 定义了 claude() 函数,登录 shell 下 command -v 会被函数遮蔽误报成功
    Write-Step "检查 Node.js / Claude Code / cc-pocket 是否已在 VM 内..."
    $probe = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc', 'type -P node >/dev/null && type -P claude >/dev/null && type -P cc-pocket-daemon >/dev/null') -TimeoutSec 30
    if ($probe.ExitCode -eq 0 -and -not $probe.TimedOut) {
        Write-Ok "Node.js、Claude Code、cc-pocket 已在 VM 内,跳过离线重装"
    } else {
        # 以 root 运行(sudo):tar 解到 /usr/local、npm -g 全局安装都需要 root。
        # 安装脚本单独存为 LF 文件,避免默认 fish 解析多行 bash -lc 参数时破坏引号/换行。
        Write-Step "从 bundle 安装 Node.js、Claude Code 和 cc-pocket..."
        $installScriptHost = Join-Path $assetsDir 'install-bundle.sh'
        if (-not (Test-Path $installScriptHost)) { throw "缺少 bundle 安装脚本:$installScriptHost" }
        $transfer = Invoke-Multipass -ArgumentList @('transfer', $installScriptHost, "${vmName}:/tmp/install-bundle.sh") -TimeoutSec 30
        if ($transfer.TimedOut -or $transfer.ExitCode -ne 0) { throw "bundle 安装脚本传入 VM 失败。$($transfer.Stderr)" }
        $install = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'sudo', 'bash', '/tmp/install-bundle.sh') -TimeoutSec 600
        if ($install.TimedOut -or $install.ExitCode -ne 0) { throw "bundle 本地安装失败，停止启动。$($install.Stderr)" }
        Write-Ok "Node.js、Claude Code、cc-pocket 本地安装完成"
    }
    $bundleProgress = Show-CloudInitProgress -VmName $vmName
    Complete-BundleProgress -Progress $bundleProgress
    Write-Step "挂载宿主机 ~/.claude → VM $mountClaudeHost..."
    $hostClaude = Join-Path $env:USERPROFILE ".claude"
    if (-not (Test-Path $hostClaude)) { throw "$hostClaude 不存在,Claude Code 没装?" }
    $null = Try-Mount -MountArgs @('mount', $hostClaude, "${vmName}:${mountClaudeHost}") `
                      -Description "挂载 .claude" `
                      -FailureHint "(cc-switch env 同步会失效,继续)" `
                      -VmTarget $mountClaudeHost
    # 内核层硬 RO:防 VM 里 Claude Code 误写污染宿主机 ~/.claude
    # 失败只 warning(RW 仍可用),不阻塞后续流程
    $null = Set-HostMountReadOnly -Target $mountClaudeHost

    # 挂载 workspace —— 两种模式互斥
    if ($NoRootWorkspace) {
        # 多目录模式:不挂根 workspace,卸掉已有根挂载,~/workspace 保持 VM 本地目录
        # 只挂 mounts.txt/-ExtraMounts 声明的子目录(不做根 workspace 宿主挂载)
        Write-Step "跳过根 workspace 挂载(-NoRootWorkspace),卸掉已有根挂载..."
        # 90s:慢网络 + cloud-init 在跑时 umount 也可能慢;30s 实测不够,会连锁 throw
        $unmountRoot = Invoke-Multipass -ArgumentList @('umount', "${vmName}:${mountWorkspace}") -TimeoutSec 90
        if ($unmountRoot.TimedOut) {
            throw "根 workspace 卸载超时,停止启动以避免嵌套挂载"
        }
        $mkRoot = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'mkdir', '-p', $mountWorkspace) -TimeoutSec 30
        if ($mkRoot.ExitCode -ne 0 -or $mkRoot.TimedOut) {
            throw "无法创建 VM 本地 workspace 根目录,停止启动"
        }
        if (Test-VMTargetMounted -Target $mountWorkspace) {
            throw "根 workspace 仍是宿主机挂载,停止启动以避免嵌套挂载。请检查 Multipass 挂载状态后重试"
        }
        Write-Ok "$mountWorkspace 保持 VM 本地(为 ExtraMounts 子目录挂载做准备)"
    } else {
        Write-Step "挂载 workspace → VM $mountWorkspace..."
        if ($WorkspaceHost) {
            # 用户显式指定宿主机 workspace 目录(存在性已在开头 fail-fast 校验过,不自动创建)
            $wsHost = (Resolve-Path $WorkspaceHost).Path
            Write-Step "使用自定义 workspace 源: $wsHost"
        } else {
            # 默认:项目下 ./workspace(保持原行为)
            $wsHost = Join-Path $StateDir "workspace"
            if (-not (Test-Path $wsHost)) {
                New-Item -ItemType Directory -Path $wsHost | Out-Null
                Write-Warn "workspace/ 不存在,已新建空目录"
            }
        }
        # 换源时清掉 VM 内 ~/workspace 旧挂载,避免"目标已被占用"冲突(首次 umount 失败忽略)
        $null = Invoke-Multipass -ArgumentList @('umount', "${vmName}:${mountWorkspace}") -TimeoutSec 30
        $null = Try-Mount -MountArgs @('mount', $wsHost, "${vmName}:${mountWorkspace}") `
                          -Description "挂载 workspace" `
                          -FailureHint "(中文路径 $wsHost 若挂不上,见 references/troubleshooting.md;继续)" `
                          -VmTarget $mountWorkspace
    }

    # ExtraMounts:仅在 -NoRootWorkspace 下挂到 VM 本地 workspace 子目录
    if ($resolvedExtraMounts.Count -gt 0) {
        if (-not (Mount-ExtraMounts -Mounts $resolvedExtraMounts)) {
            throw "一个或多个额外挂载失败,停止启动以避免 workspace 数据位置不确定"
        }
    }

    # 可选特性 path-map(非重建型,现有 VM 立即生效):挂载已定,按实际映射生成说明块
    if ($enabledFeatures -contains 'path-map') {
        $pathMappings = @()
        if ($NoRootWorkspace) {
            foreach ($m in $resolvedExtraMounts) {
                $pathMappings += @{ HostPrefix = $m.HostPath; VmPath = $m.Target }
            }
        } else {
            # $wsHost 在上面单根挂载分支赋值(PS 无块作用域,函数级可见)
            $pathMappings += @{ HostPrefix = $wsHost; VmPath = $mountWorkspace }
        }
        # 零挂载已在开头 fail-fast(多目录),单根模式恒有 $wsHost,$pathMappings 必非空
        Set-VMClaudeMemory -Mappings $pathMappings
    } else {
        # 取消勾选时移除旧块,VM 内状态与勾选保持一致(幂等,无块时无操作)
        Set-VMClaudeMemory -Remove
    }

    # SSH 反向隧道(仅当宿主机 ANTHROPIC_BASE_URL 指向本地代理时;公网直连则跳过)
    $tunnel = Get-TunnelDecision -ConfiguredPort $CcSwitchPort -ExplicitPort:$ccSwitchPortExplicit
    if ($tunnel.Mode -eq 'direct') {
        Write-Step "跳过 SSH 反向隧道:$($tunnel.Reason)"
    } else {
        $tunnelPort = $tunnel.Port
        Write-Step "启动 SSH 反向隧道(宿主机 $tunnelPort ↔ VM 127.0.0.1:$tunnelPort)..."
        $vmIp = Get-VmIp
        if (-not $vmIp) { throw "无法获取 VM IP,multipass info 看看" }

        $knownHosts = Join-Path $env:TEMP "claude-dev-known-hosts"
        $tunnelArgs = @(
            "-nNT",
            "-R", "${tunnelPort}:127.0.0.1:${tunnelPort}",
            "-i", $keyPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=$knownHosts",
            "-o", "ServerAliveInterval=30",
            "-o", "ExitOnForwardFailure=yes",
            "ubuntu@$vmIp"
        )
        # PS 5.1 的 Start-Process 对 ArgumentList 只按空格拼接、不加引号:
        # $keyPath/$knownHosts 含空格时(用户名带空格的 TEMP、含空格的项目路径)参数会被撕断,手工加引号
        $tunnelArgsQuoted = ($tunnelArgs | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
        }) -join ' '
        $proc = Start-Process -FilePath ssh -ArgumentList $tunnelArgsQuoted -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 800
        if ($proc.HasExited) {
            throw "SSH 隧道秒退,ExitCode=$($proc.ExitCode)。可能是 VM sshd 没起或 key 没注入"
        }
        $proc.Id | Out-File $pidFile -Encoding ascii -Force
        Write-Ok "隧道 PID $($proc.Id)"
    }

    Write-Host ""
    Complete-StartupProgress -EnabledFeatures $enabledFeatures
    Write-Host "==== 完成 ====" -ForegroundColor Green
    Write-Host "进入 VM:    multipass shell $vmName"
    Write-Host "VM 里跑:    claude --dangerously-skip-permissions"
    foreach ($f in $optionalFeatures) {
        if ($enabledFeatures -notcontains $f.Id) { continue }
        if (@($script:skippedRebuildIds) -contains $f.Id) {
            Write-Host "$($f.Name):  已启用但本次跳过了重建,delete + start 后才装进 VM"
        } elseif ($f.FinishHint) {
            Write-Host $f.FinishHint
        }
    }
    Write-Host "状态:       scripts\launch.ps1 status"
    Write-Host "停机:       scripts\launch.ps1 stop"
    Write-Host ""
}

# ====== stop ======
function Stop-ClaudeDev {
    Write-Step "停隧道..."
    Stop-Tunnel
    Write-Step "停 VM..."
    Invoke-VmActionGraceful -MultipassArgs @('stop', $vmName) -DoneMsg "VM 已停" -AbsentMsg "VM 已停止或不存在,跳过"
}

# ====== status ======
function Show-Status {
    Write-Step "VM 状态"
    # Test-VmExists 失败会 throw(fail-fast,报 §F),不会误报"VM 不存在"掩盖 daemon 问题。
    # status 只读,这里不 try/catch,让 throw 直接作为健康信号上抛。
    if (Test-VmExists) {
        multipass info $vmName
    } else {
        Write-Warn "VM 不存在"
    }

    Write-Step "SSH 反向隧道"
    $tunnel = Get-TunnelDecision -ConfiguredPort $CcSwitchPort -ExplicitPort:$ccSwitchPortExplicit
    if ($tunnel.Mode -eq 'direct') {
        Write-Ok "未启用(直连模式:$($tunnel.Reason))"
    } else {
        $pidFile = Join-Path $StateDir ".tunnel.pid"
        if (Test-Path $pidFile) {
            $tpid = (Get-Content $pidFile -First 1).Trim()
            $p = Get-Process -Id $tpid -ErrorAction SilentlyContinue
            if ($p) {
                Write-Ok "隧道在跑 PID $tpid"
            } else {
                Write-Warn ".tunnel.pid 写了 PID $tpid 但进程已死"
            }
        } else {
            Write-Warn ".tunnel.pid 不存在(隧道未起)"
        }
    }

    Write-Step "可选特性"
    $savedFeatures = @(Get-SavedFeatureIds)
    if ($savedFeatures.Count -eq 0) {
        Write-Host "    无(交互终端裸跑 start 弹菜单选择,或编辑 $StateDir\features.txt)" -ForegroundColor DarkGray
    } else {
        foreach ($id in $savedFeatures) {
            $f = $optionalFeatures | Where-Object { $_.Id -eq $id }
            Write-Ok "$($f.Name)(features.txt 已启用)"
        }
    }

    Write-Step "VM 内 LLM 接入探测"
    if ((Get-VmState) -eq "Running") {
        if ($tunnel.Mode -eq 'direct') {
            # 直连模式:从 VM 探测公网 base_url 可达性
            $code = & multipass exec $vmName -- bash -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 '$($tunnel.BaseUrl)/' 2>/dev/null || echo 000"
            if ($code -match '^000') {
                Write-Warn "VM 里 curl base_url = $code (公网不可达?)"
            } else {
                Write-Ok "VM 里 curl base_url 返回 HTTP $code (直连通了)"
            }
        } else {
            # curl -w 连不上时也会打 000 且退出非零,`|| echo 000` 会再补一个 → 输出可能是 000000,
            # 用前缀匹配判失败,避免把探测失败误报成"隧道通了"
            $code = & multipass exec $vmName -- bash -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:$($tunnel.Port)/ 2>/dev/null || echo 000"
            if ($code -match '^000') {
                Write-Warn "VM 里 curl 127.0.0.1:$($tunnel.Port) = $code (隧道可能没通)"
            } else {
                Write-Ok "VM 里 curl 127.0.0.1:$($tunnel.Port) 返回 HTTP $code (隧道通了)"
            }
        }
    }
}

# ====== delete ======
function Delete-ClaudeDev {
    Write-Step "清理隧道..."
    Stop-Tunnel
    Write-Step "删 VM..."
    Invoke-VmActionGraceful -MultipassArgs @('delete', '--purge', $vmName) -DoneMsg "VM 已删除并清理"
    Write-Host ""
    Write-Host "保留: 状态目录($StateDir)里的 workspace/、.ssh-key、.ssh-key.pub(下次 start 复用)" -ForegroundColor Green
}

# ====== 路由 ======
switch ($Action) {
    "start"   { Start-ClaudeDev }
    "stop"    { Stop-ClaudeDev }
    "status"  { Show-Status }
    "delete"  { Delete-ClaudeDev }
}

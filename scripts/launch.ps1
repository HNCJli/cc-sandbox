#Requires -Version 5.0
<#
    claude-dev VM lifecycle manager.
    Usage:
        .\scripts\launch.ps1 start      # 创建/启动 VM + 挂载 + SSH 反向隧道(默认 VM 名 claude-dev)
                                       # (真人终端裸跑:先弹"选择 VM"单选菜单——受管 VM 列表 +
                                       #  "+ 新建 VM…"(回车=上次使用;选新建则现场填名字和挂载目录),
                                       #  再弹"可选特性"多选菜单,回车=保持上次选择;
                                       #  管道/后台/重定向 stdin 时两个菜单都跳过,用 claude-dev 或 -Name)
        .\scripts\launch.ps1 stop       # 停隧道 + 停 VM(受管 VM 多于一台时弹菜单选)
        .\scripts\launch.ps1 status     # 多台时:交互弹菜单选台看详情(菜单即总览)/非交互给总览;单台直接详情
        .\scripts\launch.ps1 delete     # 删 VM + 清理(状态目录配置保留;多台时弹菜单选)

    多 VM:交互终端在 start 菜单里选台/建台,不用记参数;-Name 保留给脚本与非交互场景。
    状态按 VM 分目录(%USERPROFILE%\.cc-sandbox\<名字>\),共享件(bundle 离线包、.ssh-key、
    剪贴板桥 daemon)在根目录;每台默认 4C/8G/30G,多开自己算家底。

    可写状态固定在 %USERPROFILE%\.cc-sandbox(写死,不提供参数/环境变量更换)。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "delete")]
    [string]$Action = "start",

    # VM 名(多 VM):脚本/非交互场景用;交互终端走选择菜单(start 每次弹,回车=上次使用,菜单里可新建)
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Name = 'claude-dev',

    # 可调配置(默认值就在此 param() 块)
    [int]$Cpus         = 4,
    [int]$MemoryGB     = 8,
    [int]$DiskGB       = 30,
    [int]$CcSwitchPort = 15721,         # cc-switch 在宿主机监听的端口

    [string]$AptMirror = "mirrors.aliyun.com" # VM 初始化时使用的 Ubuntu APT 镜像
    # 可选特性(tailscale 等)没有命令行开关:真人终端交互菜单选择,结果持久化到 features.txt
    # workspace 挂载也没有参数:唯一模式,读状态目录 mounts.txt(见 Get-MountEntries)
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

# 可写状态目录:skill 包外,重装/升级 skill 不影响用户数据(写死,想换位置改这里)
# 布局(多 VM):根目录放共享件(bundle/.ssh-key/mounts.example.txt/clip-daemon),
# 每台 VM 一个子目录(<VM 名>\)放自己的 mounts.txt/features.txt/pid/渲染 yaml
$StateDir = Join-Path $env:USERPROFILE '.cc-sandbox'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
if ($Name -eq 'bundle') { throw "VM 名不能用保留字: $Name" }
# $vmStateDir 的确定挪到路由 switch 之前:交互菜单可能改 $Name,不能在这里按默认名提前建子目录

# 一次性迁移:多 VM 布局改造前, mounts.txt/features.txt/pid/渲染 yaml 平铺在根目录。
# 首次跑新版本时自动挪进默认 VM(claude-dev)的子目录;bundle/.ssh-key/模板本就共享,不动
$legacyMoved = @()
foreach ($lf in @('mounts.txt', 'features.txt', '.tunnel.pid', '.clip-tunnel.pid', '.cloud-init.rendered.yaml')) {
    $legacySrc = Join-Path $StateDir $lf
    if (Test-Path $legacySrc) {
        Move-Item $legacySrc (Join-Path (Join-Path $StateDir 'claude-dev') $lf) -Force
        $legacyMoved += $lf
    }
}
if ($legacyMoved.Count -gt 0) {
    if (-not (Test-Path (Join-Path $StateDir 'claude-dev'))) { New-Item -ItemType Directory -Path (Join-Path $StateDir 'claude-dev') -Force | Out-Null }
    Write-Host "    一次性迁移:旧平铺状态($($legacyMoved -join ', '))已移入 claude-dev\ 子目录(多 VM 布局)" -ForegroundColor DarkGray
}

# 状态目录常备 mounts.txt 模板(用户复制/改名为 mounts.txt 后填自己的路径;幂等,已存在不覆盖)
$mountsExampleSrc = Join-Path $assetsDir 'mounts.example.txt'
$mountsExampleDst = Join-Path $StateDir 'mounts.example.txt'
if ((Test-Path $mountsExampleSrc) -and -not (Test-Path $mountsExampleDst)) {
    Copy-Item $mountsExampleSrc $mountsExampleDst
}

# -CcSwitchPort 是否被用户显式传入(未显式传时,允许从 base_url 里自动采信端口)
$ccSwitchPortExplicit = $PSBoundParameters.ContainsKey('CcSwitchPort')
# -Name 是否被用户显式传入(status 用:显式=单台详情,未显式且多台=总览)
$nameExplicit = $PSBoundParameters.ContainsKey('Name')

# ====== 常量(不变项) ======
$vmName         = $Name                                 # 初始=-Name/默认名;交互菜单选择后在路由前重定(见"VM 名最终确定"段)
$vmImage        = "noble"                               # Ubuntu 24.04 LTS(换版本改这里)
$mountClaudeHost = "/home/ubuntu/.claude-host"          # 宿主机 ~/.claude 挂到 VM 哪里
$mountWorkspace = "/home/ubuntu/workspace"              # ./workspace 挂到 VM 哪里(放在 ~/ 下)
$clipBridgePort  = 18339                                # 剪贴板桥端口(宿主 daemon 监听 / VM 垫片 curl,两端一致)
# 可调项见 param() 块:$Cpus / $MemoryGB / $DiskGB / $CcSwitchPort / $AptMirror

# cloud-init 基础包清单(单一来源:渲染进 cloud-init runcmd,progress.ps1 的 [x/N] 计数同源;
# 增减基础包只改这里,别去动 cloud-init.yaml 的 {{BASE_PACKAGES_RUNCMD}} 块)
$basePackages = @(
    'git', 'curl', 'wget', 'vim', 'less', 'jq', 'ripgrep', 'fd-find',
    'tmux', 'fish', 'fzf', 'zoxide', 'openssh-server', 'sudo', 'locales', 'ca-certificates',
    'unzip', 'zip'   # SDKMAN 安装/运行需要(离线解 zip + sdk install 解候选包)
)

# bundle 必需组件清单(单一来源:Test-BundleReady 的宿主侧校验、VM 内 $bundleKeyFiles 校验都由它生成;
# 是相对 $StateDir 的 glob,PS 与 bash 通配语法兼容。加新组件:这里加一行 + install-bundle.sh 接安装)
# 核心 3 件全为原生二进制(AI 工具与 node/npm 解耦;node 归 dev-frontend 的 nvm 管)
$bundleKeyGlobs = @(
    'bundle/anthropic-ai-claude-code-linux-x64-*.tgz',
    'bundle/opencode-linux-x64-*.tgz',
    'bundle/cc-pocket/cc-pocket-daemon-*-linux-x86_64.tar.gz'
)

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
    @{
        Id          = 'clip-bridge'
        Name        = '剪贴板图片粘贴'
        RebuildOnly = $false   # 非重建型:每次 start 拉起宿主 daemon + 部署 VM 垫片 + 起专享反向隧道,现有 VM 立即生效
        Description = '宿主机截图 → VM 里 Claude Code Ctrl+Shift+V 粘图;Ctrl+V 留给终端文本粘贴(PowerShell 常驻服务 + 专享 SSH 反向隧道;multipass shell / ssh 进 VM 均可)'
        Probe       = 'grep -q cc-sandbox /usr/local/bin/xclip 2>/dev/null'
        FinishHint  = '剪贴板桥:  宿主机截图 → VM 里 claude 按 Ctrl+Shift+V 粘图;Ctrl+V=文本粘贴(multipass shell / ssh 进 VM 均可)'
    }
    @{
        Id          = 'dev-java'
        Name        = 'Java 环境'
        RebuildOnly = $false   # 非重建型:勾上后现有 VM 下次 start 即装(probe 过就跳过)
        Description = 'SDKMAN 多版本管理 + 预置 JDK 17 / Maven(离线 bundle 秒装;缺件回退在线 apt)'
        Probe       = 'type -P java >/dev/null 2>&1 && type -P mvn >/dev/null 2>&1'
        FinishHint  = ''
    }
    @{
        Id          = 'dev-python'
        Name        = 'Python 环境'
        RebuildOnly = $false
        Description = '预装 python3 + uv(离线 bundle 秒装;uv 自带 venv/包管理,不装 apt venv)'
        Probe       = 'type -P python3 >/dev/null 2>&1 && type -P uv >/dev/null 2>&1'
        FinishHint  = ''
    }
    @{
        Id          = 'dev-frontend'
        Name        = '前端工具链'
        RebuildOnly = $false
        Description = 'nvm 多版本 Node(默认 20.x)+ pnpm 独立二进制(离线 bundle 优先,与 Node 版本解耦)'
        Probe       = 'pnpm -v >/dev/null 2>&1'
        FinishHint  = ''
    }
)

# ====== 日志 helpers ======
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }

# native 命令参数拼接:含空格/引号的 token 加引号并转义内层引号。
# PS 5.1 手工拼 ProcessStartInfo.Arguments / Start-Process -ArgumentList 都只按空格 join,必须自己处理
function Join-ProcessArguments {
    param([Parameter(Mandatory)] [string[]]$Arguments)
    return ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '
}

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
    $psi.Arguments = Join-ProcessArguments -Arguments $ArgumentList
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
    $psi.Arguments = Join-ProcessArguments -Arguments $ArgumentList
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
# 检测 bundle/ 是否齐全(组件清单见 $bundleKeyGlobs)
# 项目只走离线 bundle 安装,不齐 → start 直接报错(不做在线降级)
function Test-BundleReady {
    # 注意用 -Path(PS 原生通配)而非 -Filter:Win32 -Filter 不支持 [0-9] 字符类,wrapper 的
    # 排除 glob 会静默匹配失败
    foreach ($g in $bundleKeyGlobs) {
        $full = Join-Path $StateDir ($g -replace '/', '\')
        if (-not (Get-ChildItem -Path $full -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $false }
    }
    return $true
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

    # YAML block scalar 缩进辅助:每行加 6 空格(cloud-init.yaml 占位符所在 content: | 块),去尾空行
    function ConvertTo-IndentedBlock {
        param([Parameter(Mandatory)] [string]$Text)
        ((($Text -split "`r?`n") | ForEach-Object { '      ' + $_ }) -join "`n").TrimEnd("`n")
    }
    $tmuxIndented = ConvertTo-IndentedBlock $tmuxRaw
    $statuslineIndented = ConvertTo-IndentedBlock $statuslineRaw

    $pubKeyPath = Join-Path $StateDir ".ssh-key.pub"
    if (-not (Test-Path $pubKeyPath)) { throw ".ssh-key.pub 不存在,Start 流程漏了 keygen 步?" }
    $pubKey = ([System.IO.File]::ReadAllText($pubKeyPath, [System.Text.Encoding]::UTF8)).Trim()

    $rendered = $template.Replace('{{TMUX_CONF_PLACEHOLDER}}', $tmuxIndented)
    $rendered = $rendered.Replace('{{STATUSLINE_PLACEHOLDER}}', $statuslineIndented)
    # SSH_PUBKEY 现在在 runcmd 的 echo "..." 里,不需要缩进
    $rendered = $rendered.Replace('{{SSH_PUBKEY_PLACEHOLDER}}', $pubKey)

    # 基础包逐个安装的 runcmd 块:按 $basePackages 清单生成(2 空格缩进对齐 runcmd 列表项)。
    # 每包记录 packages 文件(防快速步骤被轮询错过)+ progress 信号;末尾 done 信号收尾
    $pkgLines = for ($i = 0; $i -lt $basePackages.Count; $i++) {
        $p = $basePackages[$i]
        "  - apt-get install -y $p && printf '%s\n' $p >> /run/claude-dev/packages && printf '%s\n' 'stage=1' 'package=$($i + 1)' 'package_name=$p' > /run/claude-dev/progress"
    }
    $pkgLines += "  - printf '%s\n' 'stage=1' 'package=$($basePackages.Count)' 'package_name=done' > /run/claude-dev/progress"
    $rendered = $rendered.Replace('{{BASE_PACKAGES_RUNCMD}}', ($pkgLines -join "`n"))

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

    $renderedPath = Join-Path $vmStateDir ".cloud-init.rendered.yaml"
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
    $pidFile = Join-Path $vmStateDir ".tunnel.pid"
    if (-not (Test-Path $pidFile)) { return }
    $tpid = (Get-Content $pidFile -First 1).Trim()
    if ($tpid -and (Get-Process -Id $tpid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $tpid -Force
        Write-Ok "隧道 PID $tpid 已停"
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# ====== 挂载辅助:findmnt 验证挂载点真挂上了 ======
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

# ====== VM 内 Claude Code 全局记忆 managed block(可选特性 path-map + 开发环境共用) ======
# 往 VM 本地 ~/.claude/CLAUDE.md 写 managed block(<!-- cc-sandbox:begin/end --> 标记之间,
# 每次 start 整块刷新,块外用户自己写的内容保留)。
# -Mappings 写"宿主机↔VM 路径映射"节(path-map 勾选时);
# -DevEnvs 写"预装开发环境"节(开发环境勾选且装好时);
# 任一非空就写块;两者皆空 + -Remove 才删块(幂等,无块时无操作)。
# 失败只警告不 throw(CLAUDE.md 写不进不影响 VM 可用性,对齐 Try-Mount 语义)
function Set-VMClaudeMemory {
    param(
        # 每项 @{ HostPrefix=<宿主机绝对路径>; VmPath=<VM 内绝对路径> }
        [AllowEmptyCollection()] [array]$Mappings = @(),
        # 已就绪的开发环境 id(dev-java / dev-python / dev-frontend)
        [AllowEmptyCollection()] [string[]]$DevEnvs = @(),
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

    # 宿主侧拼好整块 markdown,VM 端只做整块替换(避免多行/引号穿透 exec 传参)。
    # 各节按需拼装:path-map 勾选 → 路径映射节;开发环境装好 → 预装环境节
    $sections = @(
        '<!-- cc-sandbox:begin -->'
        '## 沙箱环境(cc-sandbox 自动生成,勿手改本区块)'
        ''
        '你在 Multipass Ubuntu VM(claude-dev)里运行,不是在用户的 Windows 宿主机上。'
    )
    if (@($Mappings).Count -gt 0) {
        $rows = ($Mappings | ForEach-Object {
            "| ``$($_.HostPrefix)`` | ``$($_.VmPath)`` |"
        })
        $exampleHost = "$($Mappings[0].HostPrefix)\test-project\.gitignore"
        $exampleVm   = "$($Mappings[0].VmPath)/test-project/.gitignore"
        $sections += @(
            'workspace 由宿主机挂载进来,同一文件两边路径不同;用户消息里的 Windows 路径,按表换算后再操作。'
            ''
            '### 宿主机路径 ↔ VM 路径映射'
            ''
            '| 宿主机路径前缀 | VM 内路径 |'
            '| --- | --- |'
            $rows
            ''
            '换算规则:'
            ''
            '- 命中判断忽略大小写:用户路径等于某前缀,或以"前缀 + `\`"开头,即命中该行。'
            '- 命中后把前缀部分替换为对应 VM 路径,余下路径的 `\` 换成 `/`。例:`{{EXAMPLE_HOST}}` → `{{EXAMPLE_VM}}`。'.Replace('{{EXAMPLE_HOST}}', $exampleHost).Replace('{{EXAMPLE_VM}}', $exampleVm)
            '- 反向同理:给用户展示文件位置时换算回宿主机路径,方便其在 Windows 侧定位。'
            '- 前缀不在表中的宿主机路径未挂载进 VM,无法访问,应明确告知用户。'
        )
    }
    if (@($DevEnvs).Count -gt 0) {
        $sections += @('', '### 预装开发环境', '')
        foreach ($id in $DevEnvs) {
            switch ($id) {
                'dev-java'     { $sections += '- Java:SDKMAN 多版本管理(`sdk list java` 看已装版本、`sdk default java <id>` 切默认、项目根 `.sdkmanrc` 自动切);预置 JDK 17 + Maven,依赖拉取已配阿里云镜像' }
                'dev-python'   { $sections += '- Python:系统 python3;`uv` 在 /usr/local/bin(`uv init` 建项目、`uv add <pkg>` 加依赖、`uv venv -p 3.x` 建指定版本虚拟环境)' }
                'dev-frontend' { $sections += '- 前端:nvm 管 Node 多版本(`nvm install/use <ver>` 切换,默认 20.x);`pnpm` 独立二进制全局可用,项目内 pnpm 版本由 packageManager 字段自管' }
            }
        }
    }
    $sections += '<!-- cc-sandbox:end -->'
    $block = $sections -join "`n"

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
    $desc = @()
    if (@($Mappings).Count -gt 0) { $desc += "路径映射 $($Mappings.Count) 条" }
    if (@($DevEnvs).Count -gt 0) { $desc += "开发环境 $($DevEnvs.Count) 项" }
    Write-Ok "已写入 VM ~/.claude/CLAUDE.md 记忆块($($desc -join ';'))"
}

# ====== mounts.txt:读取 ======
# 返回 string[];配置文件不存在/为空 → 返回空数组(调用方跳过)
function Get-MountEntries {
    $cfg = Join-Path $vmStateDir "mounts.txt"
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

# ====== mounts.txt:解析 + 校验 ======
# 输入:[string[]] 每项 "HostPath" 或 "HostPath=vmSubdir"
# 输出:hashtable 数组,每项 @{ HostPath=<绝对路径>; VmSubdir=<相对路径>; Target=<VM 内绝对路径> }
# 解析/校验失败直接 throw(参数错误 fail fast)
function Resolve-MountEntries {
    param([Parameter(Mandatory)] [string[]]$Items)

    $result = @()
    $seenSubdirs = @{}
    foreach ($item in $Items) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            throw "mounts.txt 含无效空项。每项格式: HostPath 或 HostPath=vmSubdir"
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
            throw "mounts.txt 项 '$item' 宿主机路径为空。格式: HostPath 或 HostPath=vmSubdir"
        }

        # 校验宿主源目录必须存在(先校验,简写取目录名也依赖它)
        if (-not (Test-Path $hostRaw -PathType Container)) {
            throw "mounts.txt 项 '$item' 的宿主机目录不存在或不是目录: $hostRaw"
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
            throw "mounts.txt 项 '$item' 的 vmSubdir 不能为空或 '.'(不能覆盖 workspace 根目录)"
        }
        $segments = $vmSubdir -split '/'
        if ($segments -contains '.') {
            throw "mounts.txt 项 '$item' 的 vmSubdir 不允许含 '.'(必须是 workspace 下的真实子目录): $vmSubdir"
        }
        if ($vmSubdir -match '(^|/)\.\.(/|$)') {
            throw "mounts.txt 项 '$item' 的 vmSubdir 不允许含 '..'(防逃逸出 workspace): $vmSubdir"
        }

        # 子目录名冲突(两项映射到同一子目录)
        if ($seenSubdirs.ContainsKey($vmSubdir)) {
            throw "mounts.txt 子目录名重复: '$vmSubdir' 同时被 '$($seenSubdirs[$vmSubdir])' 和 '$hostPath' 使用"
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

# ====== mounts.txt:实际挂载 ======
# 前提:~/workspace 是 VM 本地目录(不挂宿主根),子目录挂载才不会嵌套
function Mount-WorkspaceSubdirs {
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
        #    它仍对应当前 mounts.txt 声明的宿主源目录
        $null = Invoke-Multipass -ArgumentList @('umount', "${vmName}:${target}") -TimeoutSec 30

        # 3) 走 Try-Mount:自带 snap-install-progress 自救(首个 mount 触发 lazy install
        #    multipass-sshfs snap,后续 mount 撞 change in progress 时轮询等装完再重试)
        #    + already-mounted 幂等 + 失败重试
        $mounted = Try-Mount -MountArgs @('mount', $src, "${vmName}:${target}") `
                             -Description "挂载 $src → $target" `
                             -FailureHint "(重新运行 .\launch.ps1 start 会再次尝试清理并挂载)" `
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
    $cfg = Join-Path $vmStateDir "features.txt"
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
    $cfg = Join-Path $vmStateDir "features.txt"
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

# ====== start:阶段子函数(bundle / 挂载 / 隧道) ======
# 由 Start-ClaudeDev 按序调用;读 launch.ps1 顶层变量($vmName/$StateDir 等,动态作用域,
# 同 feature-menu.ps1 读 $optionalFeatures 的模式),失败直接 throw,与主流程同语义

# bundle 传输 + 离线安装(基础 cloud-init 完成后调用)
function Invoke-BundlePhase {
    param([AllowEmptyCollection()] [string[]]$EnabledFeatures = @())
    # 基础 cloud-init 完成后再传 bundle:bundle 是 ~220MB 只读 tarball,不需要"实时挂载"。
    # multipass mount 走 multipass-sshfs,新 VM 上 daemon 首次推 sshfs 二进制经常超 180s
    # (实测 2026-08-12:cloud-init done、daemon 健康、mount 180s 仍未完成)。
    # 改用 transfer -r 直接 SFTP 拷贝,绕开 sshfs 推送瓶颈。
    Write-Step "传输离线 bundle 到 VM..."
    $bundleHost = Join-Path $StateDir 'bundle'
    # 关键文件存在 = 已传过,跳过(幂等)。glob 来自 $bundleKeyGlobs(与 Test-BundleReady 同源;VM 内是 .bundle 带点前缀)
    $bundleKeyFiles = ($bundleKeyGlobs | ForEach-Object { 'test -f /home/ubuntu/' + ($_ -replace '^bundle/', '.bundle/') }) -join ' && '
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
    # 用 type -P(PATH-only)而非 command -v:profile 定义了 claude()/opencode() 函数,登录 shell 下 command -v 会被函数遮蔽误报成功
    # node 不在探测列:语言运行时归 dev-* 可选环境(nvm/sdkman/uv),核心只有 AI 工具三件
    Write-Step "检查 Claude Code / opencode / cc-pocket 是否已在 VM 内..."
    $probe = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc', 'type -P claude >/dev/null && type -P opencode >/dev/null && type -P cc-pocket-daemon >/dev/null') -TimeoutSec 30
    if ($probe.ExitCode -eq 0 -and -not $probe.TimedOut) {
        Write-Ok "Claude Code、opencode、cc-pocket 已在 VM 内,跳过离线重装"
    } else {
        # 以 root 运行(sudo):tar 解到 /opt/tools、symlink 到 /usr/local/bin 都需要 root。
        # 安装脚本单独存为 LF 文件,避免默认 fish 解析多行 bash -lc 参数时破坏引号/换行。
        Write-Step "从 bundle 安装 Claude Code、opencode 和 cc-pocket(原生二进制直装)..."
        $installScriptHost = Join-Path $assetsDir 'install-bundle.sh'
        if (-not (Test-Path $installScriptHost)) { throw "缺少 bundle 安装脚本:$installScriptHost" }
        $transfer = Invoke-Multipass -ArgumentList @('transfer', $installScriptHost, "${vmName}:/tmp/install-bundle.sh") -TimeoutSec 30
        if ($transfer.TimedOut -or $transfer.ExitCode -ne 0) { throw "bundle 安装脚本传入 VM 失败。$($transfer.Stderr)" }
        # 可选开发环境按勾选传 --dev-* 标志:单词参数,不受 exec 传参拆词影响;
        # bundle 里缺对应文件时脚本自行跳过,后面 Start-DevEnvs 在线兜底
        $devFlags = @($EnabledFeatures | Where-Object { $_ -like 'dev-*' } | ForEach-Object { "--$_" })
        $install = Invoke-Multipass -ArgumentList (@('exec', $vmName, '--', 'sudo', 'bash', '/tmp/install-bundle.sh') + $devFlags) -TimeoutSec 600
        if ($install.TimedOut -or $install.ExitCode -ne 0) { throw "bundle 本地安装失败，停止启动。$($install.Stderr)" }
        Write-Ok "Claude Code、opencode、cc-pocket 本地安装完成"
    }
    $bundleProgress = Show-CloudInitProgress -VmName $vmName
    Complete-BundleProgress -Progress $bundleProgress
}

# 挂载:.claude-host(硬 RO)+ VM 本地 workspace + mounts.txt 子目录 + path-map 写入
function Invoke-MountPhase {
    param(
        [Parameter(Mandatory)] [array]$Mounts,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$EnabledFeatures,
        # 已就绪的开发环境 id(Start-DevEnvs 产出),写进 VM 记忆块
        [AllowEmptyCollection()] [string[]]$DevEnvs = @()
    )
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

    # workspace 挂载(唯一模式):~/workspace 保持 VM 本地目录,只挂 mounts.txt 声明的子目录。
    # 不做根 workspace 宿主挂载 —— 往已挂载目录内部再挂(嵌套挂载)在 Windows Multipass 上不稳
    Write-Step "准备 VM 本地 $mountWorkspace(卸掉遗留的根挂载)..."
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
    Write-Ok "$mountWorkspace 保持 VM 本地(为 mounts.txt 子目录挂载做准备)"

    # mounts.txt 挂载:挂到 VM 本地 workspace 子目录
    if (-not (Mount-WorkspaceSubdirs -Mounts $Mounts)) {
        throw "一个或多个额外挂载失败,停止启动以避免 workspace 数据位置不确定"
    }

    # VM 记忆块(可选特性 path-map + 开发环境共用,非重建型,现有 VM 立即生效):
    # 挂载已定,按实际映射 + 实际装好的环境生成;任一启用就写块,都不启用才移除
    # (幂等,无块时无操作;块外用户自己写的内容不动)
    $useBlock = ($EnabledFeatures -contains 'path-map') -or (@($DevEnvs).Count -gt 0)
    if ($useBlock) {
        $pathMappings = if ($EnabledFeatures -contains 'path-map') {
            # 映射恒非空:开头已 fail-fast 保证 mounts.txt 至少一项
            foreach ($m in $Mounts) { @{ HostPrefix = $m.HostPath; VmPath = $m.Target } }
        } else { @() }
        Set-VMClaudeMemory -Mappings @($pathMappings) -DevEnvs @($DevEnvs)
    } else {
        Set-VMClaudeMemory -Remove
    }
}

# SSH 反向隧道(仅当宿主机 ANTHROPIC_BASE_URL 指向本地代理时;公网直连则跳过)
function Start-TunnelIfNeeded {
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
        $tunnelArgsQuoted = Join-ProcessArguments -Arguments $tunnelArgs
        $proc = Start-Process -FilePath ssh -ArgumentList $tunnelArgsQuoted -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 800
        if ($proc.HasExited) {
            throw "SSH 隧道秒退,ExitCode=$($proc.ExitCode)。可能是 VM sshd 没起或 key 没注入"
        }
        $proc.Id | Out-File $pidFile -Encoding ascii -Force
        Write-Ok "隧道 PID $($proc.Id)"
    }
}

# ====== 剪贴板桥(可选特性 clip-bridge,非重建型)======
# 链路:宿主 scripts/clip-bridge/host-daemon.ps1(127.0.0.1:$clipBridgePort)
#   ← 专享 ssh -R 隧道(.clip-tunnel.pid)← VM 内 /usr/local/bin/xclip、wl-paste 垫片。
# 与 LLM 隧道相互独立(direct 模式下桥也照常);不依赖用户进 VM 的方式——垫片只打
# VM 回环,multipass shell / ssh 进去都能粘图。
# 未勾选时:停 daemon+隧道即恢复无桥行为;VM 垫片保留(桥不通时它透传/失败退出,
# 与没装过等价),不为省一次 exec 清理去多跑一次探测。

# 按 pidfile 停进程(剪贴板桥 daemon/隧道共用;文件不存在 = 无操作,幂等)
function Stop-PidFileProcess {
    param(
        [Parameter(Mandatory)] [string]$PidFile,
        [string]$Label = ''
    )
    if (-not (Test-Path $PidFile)) { return }
    $procId = (Get-Content $PidFile -First 1).Trim()
    if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $procId -Force
        if ($Label) { Write-Ok "$Label 已停(PID $procId)" }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

function Stop-ClipTunnel {
    Stop-PidFileProcess -PidFile (Join-Path $vmStateDir '.clip-tunnel.pid') -Label "剪贴板桥隧道($vmName)"
}

# daemon 是全局单例(多台 VM 的 ssh -R 都转回它):仅当没有其他受管 VM 正跑且开着
# clip-bridge 时才停;查不清 multipass 状态时保守不停(留着无害,start 会复用)
function Stop-ClipDaemonIfUnused {
    $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 15
    if ($r.ExitCode -ne 0) { return }
    $lines = @($r.Stdout -split "`r?`n")
    foreach ($dir in (Get-ChildItem $StateDir -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -eq $vmName -or $dir.Name -eq 'bundle') { continue }
        $feat = Join-Path $dir.FullName 'features.txt'
        if (-not (Test-Path $feat)) { continue }
        $ids = @(Get-Content $feat -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
        if ($ids -notcontains 'clip-bridge') { continue }
        $line = $lines | Where-Object { $_ -like "$($dir.Name),*" } | Select-Object -First 1
        if ($line -and (($line -split ',')[1] -eq 'Running')) { return }   # 还有别的 VM 在用
    }
    # 停:以端口监听者为准(pid 文件可能过期——孤儿 daemon 不在里面也逃不掉);
    # 确认监听者确是本 skill 的 host-daemon.ps1 才杀,避免误伤碰巧占用端口的其他程序
    $listenerPid = Get-ClipDaemonListenerPid
    if ($listenerPid) {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$listenerPid" -ErrorAction SilentlyContinue
        if ($wmi -and $wmi.CommandLine -match 'host-daemon\.ps1') {
            Stop-Process -Id $listenerPid -Force
            Write-Ok "剪贴板桥 daemon 已停(PID $listenerPid)"
        }
    }
    Remove-Item (Join-Path $StateDir '.clip-daemon.pid') -Force -ErrorAction SilentlyContinue
}

# daemon 的真实身份是端口上的监听进程;pid 文件只是缓存,可能过期或被半途失败的
# 新 daemon 覆盖。返回监听进程 PID(int),拿不到返回 0
function Get-ClipDaemonListenerPid {
    $c = Get-NetTCPConnection -LocalPort $clipBridgePort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
    return 0
}

function Stop-ClipBridge {
    Stop-ClipTunnel
    Stop-ClipDaemonIfUnused
}

# 勾选着 clip-bridge 的每次 start 全量执行(幂等,重装垫片自愈);失败只 warn 不阻塞
# (可选增强,对齐 Try-Mount 语义;读外层 $StateDir/$vmName/$keyPath/$clipBridgePort,同 Start-TunnelIfNeeded)
function Start-ClipBridge {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$EnabledFeatures)

    # 幂等:先停本 VM 的旧隧道(daemon 全局共享,可能别的 VM 还在用,交给引用计数判断)
    Stop-ClipTunnel
    if ($EnabledFeatures -notcontains 'clip-bridge') {
        Stop-ClipDaemonIfUnused
        return
    }

    $bridgeDir   = Join-Path $scriptDir 'clip-bridge'
    $daemonScript = Join-Path $bridgeDir 'host-daemon.ps1'
    $shimXclip    = Join-Path $bridgeDir 'vm-xclip'
    $shimWlPaste  = Join-Path $bridgeDir 'vm-wl-paste'
    foreach ($p in @($daemonScript, $shimXclip, $shimWlPaste)) {
        if (-not (Test-Path $p)) { Write-Warn "剪贴板桥缺文件 $p,本次跳过"; return }
    }

    # 1) 宿主 daemon(全局单例:活着就直接复用——多 VM 场景第二台不再起新进程)。
    #    判活以 /health 端口探测为准;pid 文件只作记录,探通时用端口 owner 纠偏回写
    $daemonPidFile = Join-Path $StateDir '.clip-daemon.pid'
    $null = & curl.exe -s --max-time 3 "http://127.0.0.1:$clipBridgePort/health" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $listenerPid = Get-ClipDaemonListenerPid
        if ($listenerPid) { "$listenerPid" | Out-File $daemonPidFile -Encoding ascii -Force }
        Write-Ok "剪贴板桥 daemon 复用(全局共享,PID $listenerPid)"
    } else {
        Write-Step "启动剪贴板桥 daemon(127.0.0.1:$clipBridgePort)..."
        $daemonProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList (Join-ProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemonScript, '-Port', "$clipBridgePort")) `
            -WindowStyle Hidden -PassThru
        $daemonProc.Id | Out-File $daemonPidFile -Encoding ascii -Force
        Start-Sleep -Milliseconds 1500
        if ($daemonProc.HasExited) {
            # 复探一次:秒退的常见原因就是撞上了判活环节没探到的既有 daemon(孤儿进程占着端口);
            # 探通就按复用收场并用端口 owner 纠偏 pid 文件,不再报错
            $null = & curl.exe -s --max-time 3 "http://127.0.0.1:$clipBridgePort/health" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $listenerPid = Get-ClipDaemonListenerPid
                if ($listenerPid) { "$listenerPid" | Out-File $daemonPidFile -Encoding ascii -Force }
                Write-Ok "剪贴板桥 daemon 复用(既有进程 PID $listenerPid;新起进程因端口占用退出,pid 文件已纠偏)"
            } else {
                Write-Warn "剪贴板桥 daemon 秒退(ExitCode=$($daemonProc.ExitCode))。日志: $StateDir\clip-daemon.log"
            }
        } else {
            Write-Ok "daemon PID $($daemonProc.Id)"
        }
    }

    # 2) VM 垫片:transfer + sudo install(每次覆盖;装 /usr/local/bin,PATH 恒优先于 /usr/bin,
    #    避开 cc-clip 踩过的 ~/.local/bin PATH 优先级坑)
    Write-Step "部署 VM 剪贴板垫片..."
    foreach ($pair in @(@($shimXclip, 'xclip'), @($shimWlPaste, 'wl-paste'))) {
        $t = Invoke-Multipass -ArgumentList @('transfer', $pair[0], "${vmName}:/tmp/cc-sandbox-$($pair[1])") -TimeoutSec 30
        if ($t.TimedOut -or $t.ExitCode -ne 0) {
            $err = if ($t.TimedOut) { "超时" } elseif ($t.Stderr) { $t.Stderr.Trim() } else { "(无 stderr)" }
            Write-Warn "垫片 $($pair[1]) 传入 VM 失败:$err(剪贴板桥本次不可用,其余不受影响)"
            return
        }
    }
    # install/rm 逐条"单参数"执行:实测 sudo bash -c "带空格内联串"经 multipass exec 转发
    # 会被拆词重解析(install 收到零操作数报 missing file operand);每词单独传参则无串可拆
    foreach ($op in @(
        @('install', '-m', '0755', '/tmp/cc-sandbox-xclip',    '/usr/local/bin/xclip'),
        @('install', '-m', '0755', '/tmp/cc-sandbox-wl-paste', '/usr/local/bin/wl-paste'),
        @('rm', '-f', '/tmp/cc-sandbox-xclip', '/tmp/cc-sandbox-wl-paste')
    )) {
        $r = Invoke-Multipass -ArgumentList (@('exec', $vmName, '--', 'sudo') + $op) -TimeoutSec 30
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            $err = if ($r.TimedOut) { "超时" } elseif ($r.Stderr) { $r.Stderr.Trim() } else { "(无 stderr)" }
            Write-Warn "VM 垫片安装失败:$err(剪贴板桥本次不可用,其余不受影响)"
            return
        }
    }
    Write-Ok "垫片已装(/usr/local/bin/xclip、wl-paste)"

    # 2b) claude 键位:粘图改绑 Ctrl+Shift+V(终端层把 Ctrl+V 让给文本粘贴,方案见 troubleshooting §G)。
    #     只在 ~/.claude/keybindings.json 不存在时写入;文件已存在(含用户自定义)保持不动
    $kbJson = Join-Path $bridgeDir 'vm-keybindings.json'
    if (Test-Path $kbJson) {
        $kbTransfer = Invoke-Multipass -ArgumentList @('transfer', $kbJson, "${vmName}:/tmp/cc-sandbox-kb.json") -TimeoutSec 30
        if ($kbTransfer.TimedOut -or $kbTransfer.ExitCode -ne 0) {
            Write-Warn "键位模板传入 VM 失败(不影响剪贴板桥其余部分)"
        } else {
            $kbCmd = 'test -e ~/.claude/keybindings.json && echo KB_EXISTS || (mkdir -p ~/.claude && install -m 0644 /tmp/cc-sandbox-kb.json ~/.claude/keybindings.json && echo KB_WRITTEN); rm -f /tmp/cc-sandbox-kb.json'
            $kbRun = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c', $kbCmd) -TimeoutSec 30
            if ($kbRun.TimedOut -or $kbRun.ExitCode -ne 0) {
                $err = if ($kbRun.TimedOut) { "超时" } elseif ($kbRun.Stderr) { $kbRun.Stderr.Trim() } else { "(无 stderr)" }
                Write-Warn "claude 键位写入失败:$err(不影响剪贴板桥其余部分)"
            } elseif ("$($kbRun.Stdout)" -match 'KB_WRITTEN') {
                Write-Ok "claude 粘图键位已写入 ~/.claude/keybindings.json(Ctrl+Shift+V 粘图)"
            } elseif ("$($kbRun.Stdout)" -match 'KB_EXISTS') {
                Write-Ok "~/.claude/keybindings.json 已存在,保持不动(若无 Ctrl+Shift+V 粘图键位,参考 troubleshooting.md §G 手工补)"
            }
        }
    }

    # 3) 专享反向隧道(独立 pidfile .clip-tunnel.pid;不设 ExitOnForwardFailure——失败多半是
    #    VM 侧端口被残留会话占,隧道进程仍可用于下次;端到端检查会如实暴露)
    $vmIp = Get-VmIp
    if (-not $vmIp) { Write-Warn "无法获取 VM IP,剪贴板桥隧道未起"; return }
    $knownHosts = Join-Path $env:TEMP "claude-dev-known-hosts"
    $clipTunnelArgs = @(
        "-nNT",
        "-R", "${clipBridgePort}:127.0.0.1:${clipBridgePort}",
        "-i", $keyPath,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=$knownHosts",
        "-o", "ServerAliveInterval=30",
        "ubuntu@$vmIp"
    )
    $clipTunnelProc = Start-Process -FilePath ssh -ArgumentList (Join-ProcessArguments -Arguments $clipTunnelArgs) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    if ($clipTunnelProc.HasExited) {
        Write-Warn "剪贴板桥隧道秒退,ExitCode=$($clipTunnelProc.ExitCode)(重跑 start 可自愈)"
        return
    }
    $clipTunnelProc.Id | Out-File (Join-Path $vmStateDir '.clip-tunnel.pid') -Encoding ascii -Force
    Write-Ok "桥隧道 PID $($clipTunnelProc.Id)"

    # 4) 端到端验证(短重试,容忍隧道建立延迟)
    $e2eOk = $false
    foreach ($try in 1..3) {
        $probe = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c',
            "curl -fsS --max-time 5 http://127.0.0.1:$clipBridgePort/health 2>/dev/null || echo BRIDGE_DOWN") -TimeoutSec 20
        if (-not $probe.TimedOut -and $probe.Stdout -match '"status":"ok"') { $e2eOk = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($e2eOk) {
        Write-Ok "剪贴板桥端到端通(VM → 宿主 daemon)"
    } else {
        Write-Warn "剪贴板桥端到端未通(daemon/隧道进程在跑,但 VM 探测失败)。进 VM 验证: curl http://127.0.0.1:$clipBridgePort/health"
    }
}

# ====== 开发环境(可选特性 dev-java / dev-python / dev-frontend,非重建型)======
# 勾上后每次 start:先 probe(装过跳过),缺则装;失败只 warn 不阻塞(环境是增强不是依赖)。
# 装法两级(离线优先):
#   1) bundle 离线:VM 内 /home/ubuntu/.bundle 还留着对应件 → 重跑 install-bundle.sh --dev-*
#      (幂等;核心件原样重装同版本,无害)
#   2) 在线兜底(bundle 缺件/旧 VM):java 走 apt(cloud-init 已配镜像),Maven 幂等配阿里云镜像;
#      uv 用 pip 清华源;node 走 nvm + npmmirror 镜像,pnpm 独立二进制走 npmmirror registry
# 返回:本次确认就绪的环境 id 列表(传给挂载阶段,一并写进 VM 记忆块)。
function Start-DevEnvs {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$EnabledFeatures)

    # apt 索引惰性刷新:首个要装 apt 包的环境前刷一次(全新 VM cloud-init 刷过,通常很快)
    if (-not $script:devAptUpdated) { $script:devAptUpdated = $false }
    # DPkg::Lock::Timeout:Ubuntu 的 unattended-upgrades(自动安全更新)常在后台持 dpkg 锁,
    # 立刻报 "Could not get lock" 秒失败——等锁最长 120s 而不是撞上就认输(实测 2026-08-30)
    $aptLockWait = @('-o', 'DPkg::Lock::Timeout=120')
    function Update-AptIfNeeded {
        if ($script:devAptUpdated) { return $true }
        Write-Step '刷新 apt 索引...'
        $r = Invoke-Multipass -ArgumentList (@('exec', $vmName, '--', 'sudo', 'apt-get') + $aptLockWait + @('update')) -TimeoutSec 300
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            $err = if ($r.TimedOut) { '超时' } elseif ($r.Stderr) { $r.Stderr.Trim() } else { '(无 stderr)' }
            Write-Warn "apt-get update 失败:$err(继续尝试直接安装)"
            return $false
        }
        $script:devAptUpdated = $true
        return $true
    }

    function Test-DevProbe([string]$Probe) { (Test-FeatureInVm -Probe $Probe) -eq $true }

    function Invoke-DevInstall([string[]]$InstallArgs, [int]$TimeoutSec, [string]$Desc) {
        $r = Invoke-Multipass -ArgumentList (@('exec', $vmName, '--') + $InstallArgs) -TimeoutSec $TimeoutSec
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            $err = if ($r.TimedOut) { '超时' } elseif ($r.Stderr) { $r.Stderr.Trim() } else { '(无 stderr)' }
            Write-Warn "$Desc 失败:$err(重跑 start 自愈;不影响其余步骤)"
            return $false
        }
        return $true
    }

    $ready = @()

    # bundle 二级离线装:VM 内 .bundle 有对应件 → 重跑安装脚本(引用 $assetsDir,同主流程)
    function Invoke-DevBundleInstall {
        param([string]$DevFlag, [string]$BundleCheck)
        $chk = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-lc', $BundleCheck) -TimeoutSec 30
        if ($chk.TimedOut -or $chk.ExitCode -ne 0) { return $false }
        $installScriptHost = Join-Path $assetsDir 'install-bundle.sh'
        $t = Invoke-Multipass -ArgumentList @('transfer', $installScriptHost, "${vmName}:/tmp/install-bundle.sh") -TimeoutSec 30
        if ($t.TimedOut -or $t.ExitCode -ne 0) { return $false }
        Write-Step "bundle 离线补装($DevFlag)..."
        $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'sudo', 'bash', '/tmp/install-bundle.sh', $DevFlag) -TimeoutSec 600
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            Write-Warn "bundle 离线补装 $DevFlag 失败:$($r.Stderr)"
            return $false
        }
        return $true
    }

    # 前端在线兜底:整段 bash 脚本经 transfer 传入(引号不穿透 exec);nvm.sh 用宿主 assets vendor 件,
    # node/pnpm 全走 npmmirror(国内可达)
    function Invoke-FrontendOnlineFallback {
        $feScript = @'
#!/usr/bin/env bash
set -e
U=/home/ubuntu
# nvm 本体(若缺):/tmp/nvm.sh 由宿主 assets 传入
if [ ! -s "$U/.nvm/nvm.sh" ] && [ -s /tmp/nvm.sh ]; then
    mkdir -p "$U/.nvm"
    cp /tmp/nvm.sh "$U/.nvm/nvm.sh"
    grep -q 'NVM_DIR' "$U/.bashrc" 2>/dev/null || \
        printf '\nexport NVM_DIR="$HOME/.nvm"\nexport NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n' >> "$U/.bashrc"
fi
# Node 20(若缺):npmmirror 镜像直解进 nvm versions
if [ ! -x /usr/local/bin/node ] && [ -s "$U/.nvm/nvm.sh" ]; then
    ver=v20.20.2
    mkdir -p "$U/.nvm/versions/node/$ver" "$U/.nvm/alias"
    curl -fsSL "https://registry.npmmirror.com/-/binary/node/$ver/node-$ver-linux-x64.tar.xz" | tar -xJ -C "$U/.nvm/versions/node/$ver" --strip-components=1
    echo "$ver" > "$U/.nvm/alias/default"
    for b in node npm npx; do ln -sfn "$U/.nvm/versions/node/$ver/bin/$b" "/usr/local/bin/$b"; done
fi
chown -R ubuntu:ubuntu "$U/.nvm" 2>/dev/null || true
# pnpm 独立二进制(若缺):npmmirror registry tarball(@pnpm/linux-x64 平台包)
if ! pnpm -v >/dev/null 2>&1; then
    v=$(curl -fsSL https://registry.npmmirror.com/@pnpm/linux-x64 | jq -r '."dist-tags".latest')
    curl -fsSL "https://registry.npmmirror.com/@pnpm/linux-x64/-/linux-x64-$v.tgz" | tar -xz -C /tmp --strip-components=1 package/pnpm
    install -m 0755 /tmp/pnpm /usr/local/bin/pnpm && rm -f /tmp/pnpm
    sudo -u ubuntu pnpm config set --global registry https://registry.npmmirror.com || true
fi
pnpm -v >/dev/null 2>&1 && node -v >/dev/null 2>&1
'@
        $scriptHost = Join-Path $env:TEMP 'cc-sandbox-fe-fallback.sh'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($scriptHost, $feScript, $utf8NoBom)
        $nvmHost = Join-Path $assetsDir 'nvm.sh'
        if (-not (Test-Path $nvmHost)) { Write-Warn "缺 assets/nvm.sh($nvmHost)"; return $false }
        $t1 = Invoke-Multipass -ArgumentList @('transfer', $nvmHost, "${vmName}:/tmp/nvm.sh") -TimeoutSec 30
        if ($t1.TimedOut -or $t1.ExitCode -ne 0) { Write-Warn 'nvm.sh 传入 VM 失败'; return $false }
        $t2 = Invoke-Multipass -ArgumentList @('transfer', $scriptHost, "${vmName}:/tmp/cc-sandbox-fe-fallback.sh") -TimeoutSec 30
        if ($t2.TimedOut -or $t2.ExitCode -ne 0) { Write-Warn '前端兜底脚本传入 VM 失败'; return $false }
        $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'sudo', 'bash', '/tmp/cc-sandbox-fe-fallback.sh') -TimeoutSec 600
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            $err = if ($r.TimedOut) { '超时' } elseif ($r.Stderr) { $r.Stderr.Trim() } else { '(无 stderr)' }
            Write-Warn "前端在线兜底失败:$err(npmmirror 不通?重跑 start,或交互终端跑 prepare-bundle 备料)"
            return $false
        }
        return $true
    }

    # Java:SDKMAN + JDK 17 + Maven + 阿里云镜像
    if ($EnabledFeatures -contains 'dev-java') {
        $javaProbe = 'type -P java >/dev/null 2>&1 && type -P mvn >/dev/null 2>&1'
        if (Test-DevProbe $javaProbe) {
            Write-Ok 'Java 环境已在(java / mvn)'
            $ready += 'dev-java'
        } elseif (Invoke-DevBundleInstall -DevFlag '--dev-java' -BundleCheck 'ls /home/ubuntu/.bundle/jdk/OpenJDK17U-*.tar.gz >/dev/null 2>&1 && ls /home/ubuntu/.bundle/maven/apache-maven-*-bin.tar.gz >/dev/null 2>&1') {
            if (Test-DevProbe $javaProbe) {
                Write-Ok 'Java 环境装好(bundle 离线:SDKMAN + JDK + Maven)'
                $ready += 'dev-java'
            } else {
                Write-Warn 'bundle 离线装完 java/mvn 仍不可用(看上方 install-bundle.sh 的 WARN)'
            }
        } else {
            Write-Step '安装 Java 环境(在线兜底:apt OpenJDK 17 + Maven,几百 MB 首次较慢;SDKMAN 需重建 VM 走 bundle)...'
            [void](Update-AptIfNeeded)
            if (Invoke-DevInstall -InstallArgs (@('sudo', 'apt-get') + $aptLockWait + @('install', '-y', 'openjdk-17-jdk', 'maven')) -TimeoutSec 1500 -Desc 'Java 安装') {
                Write-Ok 'Java 环境装好(java / mvn)'
                $ready += 'dev-java'
            }
        }
        # Maven 阿里云镜像(国内拉依赖必需;幂等:已有 settings.xml 不覆盖)
        if ((Test-FeatureInVm -Probe 'test -f ~/.m2/settings.xml') -ne $true) {
            $mavenSettings = @'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <mirrors>
    <mirror>
      <id>aliyun-public</id>
      <name>Aliyun Public (central + jcenter)</name>
      <url>https://maven.aliyun.com/repository/public</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
  </mirrors>
</settings>
'@
            $settingsHost = Join-Path $env:TEMP 'cc-sandbox-maven-settings.xml'
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($settingsHost, $mavenSettings, $utf8NoBom)
            $t = Invoke-Multipass -ArgumentList @('transfer', $settingsHost, "${vmName}:/tmp/cc-maven-settings.xml") -TimeoutSec 30
            if ($t.TimedOut -or $t.ExitCode -ne 0) {
                Write-Warn 'Maven 镜像配置传入 VM 失败(依赖下载会走默认源,慢)'
            } else {
                $m = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c',
                    'mkdir -p ~/.m2 && mv /tmp/cc-maven-settings.xml ~/.m2/settings.xml') -TimeoutSec 30
                if ($m.TimedOut -or $m.ExitCode -ne 0) {
                    Write-Warn 'Maven 镜像配置写入失败(依赖下载会走默认源,慢)'
                } else {
                    Write-Ok 'Maven 已配阿里云镜像(~/.m2/settings.xml)'
                }
            }
        }
    }

    # Python:python3(基础镜像自带)+ uv;venv/包管理全走 uv,不依赖 apt 的 python3-venv。
    # bundle 离线装好的话这里的探测直接通过;走到安装分支 = bundle 无 uv 或 VM 已存在
    if ($EnabledFeatures -contains 'dev-python') {
        $pyProbe = 'type -P python3 >/dev/null 2>&1 && type -P uv >/dev/null 2>&1'
        if (Test-DevProbe $pyProbe) {
            Write-Ok 'Python 环境已在(python3 + uv)'
            $ready += 'dev-python'
        } elseif (Invoke-DevBundleInstall -DevFlag '--dev-python' -BundleCheck 'ls /home/ubuntu/.bundle/uv/uv-*.whl >/dev/null 2>&1') {
            if (Test-DevProbe $pyProbe) {
                Write-Ok 'Python 环境装好(bundle 离线:uv)'
                $ready += 'dev-python'
            } else {
                Write-Warn 'bundle 离线装完 uv 仍不可用(看上方 install-bundle.sh 的 WARN)'
            }
        } else {
            Write-Step '安装 Python 环境(在线兜底:python3 + pip)...'
            [void](Update-AptIfNeeded)
            if (Invoke-DevInstall -InstallArgs (@('sudo', 'apt-get') + $aptLockWait + @('install', '-y', 'python3', 'python3-pip')) -TimeoutSec 600 -Desc 'Python 基础包安装') {
                Write-Step '安装 uv(pip 清华镜像)...'
                if (Invoke-DevInstall -InstallArgs @('sudo', 'pip3', 'install', '--break-system-packages', '-i', 'https://pypi.tuna.tsinghua.edu.cn/simple', 'uv') -TimeoutSec 300 -Desc 'uv 安装') {
                    Write-Ok 'Python 环境装好(python3 + uv)'
                    $ready += 'dev-python'
                }
            }
        }
    }

    # 前端:nvm 多版本 Node + pnpm 独立二进制(自含运行时,与 node 版本解耦)
    if ($EnabledFeatures -contains 'dev-frontend') {
        # 探测用 pnpm -v 而非 type -P:文件在但跑不起来也算未装
        $feProbe = 'pnpm -v >/dev/null 2>&1'
        if (Test-DevProbe $feProbe) {
            Write-Ok '前端工具链已在(pnpm)'
            $ready += 'dev-frontend'
        } elseif (Invoke-DevBundleInstall -DevFlag '--dev-frontend' -BundleCheck 'ls /home/ubuntu/.bundle/node/node-v*-linux-x64.tar.xz >/dev/null 2>&1 && ls /home/ubuntu/.bundle/nvm/nvm-v*.sh >/dev/null 2>&1') {
            if (Test-DevProbe $feProbe) {
                Write-Ok '前端工具链装好(bundle 离线:nvm + Node + pnpm)'
                $ready += 'dev-frontend'
            } else {
                Write-Warn 'bundle 离线装完 pnpm 仍不可用(看上方 install-bundle.sh 的 WARN)'
            }
        } else {
            Write-Step '安装前端工具链(在线兜底:nvm + npmmirror Node + pnpm 独立二进制)...'
            if (Invoke-FrontendOnlineFallback) {
                if (Test-DevProbe $feProbe) {
                    Write-Ok '前端工具链装好(nvm + Node + pnpm)'
                    $ready += 'dev-frontend'
                } else {
                    Write-Warn '在线兜底执行完 pnpm 仍不可用(npmmirror 不通?重跑 start,或交互终端跑 prepare-bundle 备料)'
                }
            }
        }
        # nvm 默认别名 → /usr/local/bin 桥重指(nvm 无 current 链接;
        # 用户 `nvm alias default <ver>` 换默认后重跑 start 即跟随)。
        # 别名文件存的是用户原始输入(可能是 "22" 这种短形式),必须经 nvm 解析成完整版本号
        $refresh = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'sudo', 'bash', '-c',
            'd=$(bash -c ". /home/ubuntu/.nvm/nvm.sh >/dev/null 2>&1 && nvm version default" 2>/dev/null); if [ -n "$d" ] && [ "$d" != "none" ] && [ -d "/home/ubuntu/.nvm/versions/node/$d" ]; then for b in node npm npx; do ln -sfn "/home/ubuntu/.nvm/versions/node/$d/bin/$b" "/usr/local/bin/$b"; done; fi') -TimeoutSec 60
        if ($refresh.TimedOut -or $refresh.ExitCode -ne 0) {
            Write-Warn 'node 桥接 symlink 刷新失败(不影响 VM 内交互使用 nvm)'
        }
    }
    return ,@($ready)
}

# ====== VM 选择:交互菜单 + 新建向导(裸跑免记 -Name)======
# 交互终端:start 每次弹单选菜单(受管 VM 列表 + "+ 新建 VM…",回车 = 上次使用);
# stop/delete 仅在多于一台时弹(单台直接就是它)。非交互/显式 -Name 完全不弹,行为同从前。

# 受管 VM 名 = 状态目录子目录(除 bundle;与 Show-VmsOverview / Stop-ClipDaemonIfUnused 同口径)
function Get-ManagedVmNames {
    return @(Get-ChildItem $StateDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'bundle' } | Sort-Object Name | ForEach-Object { $_.Name })
}

# multipass list 的 名字→状态 映射(拿不到返回空表,菜单退化为只显示名字)
function Get-VmStateMap {
    $map = @{}
    $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 15
    if ($r.ExitCode -ne 0 -or $r.TimedOut) { return $map }
    foreach ($line in ($r.Stdout -split "`r?`n")) {
        $cols = $line -split ','
        if ($cols.Count -ge 2 -and $cols[0]) { $map[$cols[0]] = $cols[1] }
    }
    return $map
}

# 新建向导:问名字 → 逐项问挂载目录(即时校验)→ 生成 <名字>\ 子目录与 mounts.txt。
# 返回 VM 名;名字撞受管目录时直接改选该台(不新建)
function Enter-NewVmWizard {
    param([Parameter(Mandatory)] [hashtable]$VmStateMap)
    $n = ''
    while ($true) {
        # Read-Host 异常兜底(EOF/终端抖动按空输入,同 feature-menu.ps1 的处理)
        try { $n = (Read-Host '新 VM 名(小写字母/数字/连字符,如 dev-java)') } catch { $n = '' }
        $n = "$n".Trim()
        if ($n -eq '') { continue }
        if ($n -notmatch '^[a-z0-9][a-z0-9-]*$') { Write-Warn "名字限小写字母/数字/连字符,且以字母或数字开头: $n"; continue }
        if ($n -eq 'bundle') { Write-Warn "'bundle' 是保留字,换一个"; continue }
        if (@(Get-ManagedVmNames) -contains $n) { Write-Warn "$n 已是受管 VM,直接选用它"; return $n }
        if ($VmStateMap.ContainsKey($n)) { Write-Warn "multipass 里已有名为 $n 的 VM(非本工具管理),换一个名字"; continue }
        break
    }
    New-Item -ItemType Directory -Path (Join-Path $StateDir $n) -Force | Out-Null

    # 挂载目录现场填:把 start 的 mounts 校验前置(目录存在 + 子目录名安全 + 不重复),别让用户
    # 走完向导才在 start 里被 throw 拦下。子目录名规则与 Resolve-MountEntries 一致(显式别名或
    # 宿主目录最后一级),这里只做向导内的即时反馈,权威校验仍在 start 的 Resolve-MountEntries
    $entries = @()
    $subdirs = @{}
    Write-Host '  每行一个宿主机目录,直接回车结束(至少一条)。格式:D:\code\my-project 或 D:\code\my-project=别名' -ForegroundColor DarkGray
    while ($true) {
        try { $line = (Read-Host "挂载目录 $($entries.Count + 1)") } catch { $line = '' }
        $line = "$line".Trim()
        if ($line -eq '') {
            if ($entries.Count -eq 0) { Write-Warn '至少挂载一个目录(源码留宿主机,VM 挂子目录)'; continue }
            break
        }
        $hostPart  = $line.Split('=')[0].Trim()
        $aliasPart = if ($line.Contains('=')) { $line.Split('=')[1].Trim() } else { '' }
        if (-not (Test-Path $hostPart -PathType Container)) { Write-Warn "目录不存在或不是目录: $hostPart"; continue }
        if ($line.Contains('=') -and $aliasPart -eq '') { Write-Warn "'=' 后没写子目录名: $line"; continue }
        $subdir = if ($aliasPart -ne '') { $aliasPart.Replace('\', '/').Trim('/') } else { Split-Path -Leaf ($hostPart.TrimEnd('\', '/')) }
        if ([string]::IsNullOrWhiteSpace($subdir) -or $subdir -eq '.' -or $subdir -match '(^|/)\.\.(/|$)' -or ($subdir -split '/') -contains '.') {
            Write-Warn "子目录名不安全(不能为空/'.'/'..'): $subdir"; continue
        }
        if ($subdirs.ContainsKey($subdir)) { Write-Warn "子目录名重复: $subdir(已用于 $($subdirs[$subdir]))"; continue }
        $subdirs[$subdir] = $hostPart
        $entries += $line
    }
    $mountsFile = Join-Path (Join-Path $StateDir $n) 'mounts.txt'
    $content = ((@('# 新建向导生成,可手改:每行 HostPath 或 HostPath=子目录名,# 起始为注释,空行忽略') + $entries) -join "`n") + "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($mountsFile, $content, $utf8NoBom)
    Write-Ok "已生成 $mountsFile(以后想改挂载就编辑它)"
    return $n
}

# VM 名解析(交互):start 弹菜单(列表 + 新建项);stop/delete/status 多台弹、单台直选。
# 返回最终 VM 名;由调用方(路由前的顶层段)统一落 .last-vm
function Resolve-VmNameInteractive {
    param([Parameter(Mandatory)] [string]$Action)
    $managed = @(Get-ManagedVmNames)
    if ($Action -eq 'start') {
        if ($managed.Count -eq 0) { return 'claude-dev' }        # 全新装机:直接用默认名(与从前一致)
    } else {
        if ($managed.Count -eq 0) { return $Name }               # 没有受管 VM:按默认名走(幂等报"不存在")
        if ($managed.Count -eq 1) { return $managed[0] }         # 单台:不用选
    }
    $stateMap = Get-VmStateMap
    $labels = @($managed | ForEach-Object {
        if ($stateMap.ContainsKey($_) -and $stateMap[$_]) { "$_($($stateMap[$_]))" } else { $_ }
    })
    $options = @($labels)
    if ($Action -eq 'start') { $options += '+ 新建 VM...' }
    # 默认项 = 上次使用;记录失效回退 claude-dev,再回退第一项
    $lastName = ''
    $lastFile = Join-Path $StateDir '.last-vm'
    if (Test-Path $lastFile) { $lastName = ("$(Get-Content $lastFile -First 1 -ErrorAction SilentlyContinue)").Trim() }
    $defaultName = if ($managed -contains $lastName) { $lastName } elseif ($managed -contains 'claude-dev') { 'claude-dev' } else { $managed[0] }
    $i = Select-SingleChoice -Options $options -DefaultIndex ([array]::IndexOf($managed, $defaultName)) -Prompt '选择 VM(回车 = 上次使用)'
    if ($i -lt $labels.Count) { return $managed[$i] }
    return (Enter-NewVmWizard -VmStateMap $stateMap)
}

# ====== start ======
function Start-ClaudeDev {
    Assert-Prerequisites

    # mounts.txt 解析 + 校验(在动 VM 前先 fail fast,避免无效配置触发 daemon 重启等副作用)
    # start 只有唯一的挂载模式:~/workspace 保持 VM 本地目录,mounts.txt 每项挂成一个子目录
    $mountEntries = Get-MountEntries
    $mounts = if ($mountEntries.Count -gt 0) { Resolve-MountEntries -Items $mountEntries } else { @() }
    # mounts.txt 缺失/为空属配置不完整:VM workspace 会是本地空目录,
    # path-map 也无映射可写(勾选了却不生效),启动前拦下
    if ($mounts.Count -eq 0) {
        throw "start 需要 mounts.txt 配置挂载:$vmStateDir\mounts.txt 不存在或为空。把 $StateDir\mounts.example.txt 复制为 $vmStateDir\mounts.txt,填入宿主目录(每行一个)后重跑"
    }

    # 可选特性:交互菜单(真人终端)> features.txt;选择统一写回 features.txt(重建后不丢)
    $enabledFeatures = Resolve-OptionalFeatures
    if (@($enabledFeatures).Count -eq 0) {
        Write-Host "    可选特性: 无(想启用:交互终端裸跑 start 弹菜单,或编辑 $vmStateDir\features.txt)" -ForegroundColor DarkGray
    } else {
        $featureNames = ($optionalFeatures | Where-Object { $enabledFeatures -contains $_.Id } | ForEach-Object { $_.Name }) -join ', '
        Write-Ok "可选特性: $featureNames"
    }

    # 隧道复用/清理:start 幂等可反复跑。停旧隧道(后面会重起)
    Stop-Tunnel
    $pidFile = Join-Path $vmStateDir ".tunnel.pid"

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
        throw "bundle 不完整,停止启动。项目不支持在线安装降级——请先跑 .\scripts\prepare-bundle.ps1 补齐 Claude Code + opencode + cc-pocket 离线包后重试。"
    }
    Write-Ok "检测到 bundle,安装模式: Claude Code/opencode/cc-pocket 原生二进制走本地 bundle"
    $renderedPath = Render-CloudInit -EnabledFeatures $enabledFeatures -AptMirror $AptMirror

    $script:progressState = @{}
    $script:cloudInitShown = $script:progressState
    $script:launchProgressShown = @{}
    Write-Step "启动 VM(若新建:基础 cloud-init + 离线 bundle 装 Claude Code/opencode/cc-pocket;已存在则只重挂/重起隧道)..."
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
        $launchArgs += $vmImage
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

    # cloud-init 阶段结束后只记录完成,整个 bundle/传输/隧道流程结束时才显示 [7/7]
    if ($cloudInitProgressStatus -eq 'done') {
        $cloudInitSnapshot = Show-CloudInitProgress -VmName $vmName
        Complete-CloudInitProgress -Progress $cloudInitSnapshot
    } elseif ($cloudInitProgressStatus -eq 'error') {
        # error 不中断(基础包缺失不一定全致命,后续 bundle 安装会再验证),但必须显式提醒,
        # 否则真因(APT 源挂了)会被"bundle 本地安装失败"误导
        Write-Warn "cloud-init 结束状态: error(常见是 APT 镜像不可达、基础包装失败)。若后续 bundle 安装报错,先查 'multipass exec $vmName -- cloud-init status --long' 和 /var/log/cloud-init-output.log"
    }

    # 四阶段:bundle 传输安装 → 开发环境 → 挂载(含记忆块)→ 隧道(子函数见上,失败各自处理)
    Invoke-BundlePhase -EnabledFeatures $enabledFeatures
    $devEnvs = Start-DevEnvs -EnabledFeatures $enabledFeatures
    Invoke-MountPhase -Mounts $mounts -EnabledFeatures $enabledFeatures -DevEnvs $devEnvs
    Start-TunnelIfNeeded
    Start-ClipBridge -EnabledFeatures $enabledFeatures

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
    Write-Step "停剪贴板桥..."
    Stop-ClipBridge
    Write-Step "停 VM..."
    Invoke-VmActionGraceful -MultipassArgs @('stop', $vmName) -DoneMsg "VM 已停" -AbsentMsg "VM 已停止或不存在,跳过"
}

# ====== status ======
# 全部受管 VM 总览:状态目录的子目录(除 bundle)= 受管名单,与 multipass list 求交集
function Show-VmsOverview {
    Write-Step "受管 VM 总览(状态目录 $StateDir\<VM 名>)"
    $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 15
    if ($r.ExitCode -ne 0) {
        Write-Warn "multipass list 失败,无法总览(见 troubleshooting §F)"
        return
    }
    $lines = @($r.Stdout -split "`r?`n" | Where-Object { $_ })
    $dirs = @(Get-ChildItem $StateDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'bundle' } | Sort-Object Name)
    foreach ($d in $dirs) {
        $line = $lines | Where-Object { $_ -like "$($d.Name),*" } | Select-Object -First 1
        if (-not $line) {
            Write-Warn "$($d.Name):multipass 里不存在(状态目录残留,可 delete 清理)"
            continue
        }
        $cols = $line -split ','
        $feat = Join-Path $d.FullName 'features.txt'
        $featNames = ''
        if (Test-Path $feat) {
            $featNames = (@(Get-Content $feat -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }) -join ',')
        }
        Write-Host ("    {0}{1}{2}特性: {3}" -f $d.Name.PadRight(16), $cols[1].PadRight(10), "$($cols[2])".PadRight(17), $featNames)
    }
}

function Show-Status {
    # 名字未确定(非交互且没传 -Name)且受管 VM 多于一台:给总览。交互终端已在菜单里
    # 选过台(菜单列表自带状态,就是总览),直接给所选台的详情
    if (-not $vmResolved) {
        $dirs = @(Get-ChildItem $StateDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'bundle' })
        if ($dirs.Count -gt 1) {
            Show-VmsOverview
            Write-Host "    单台详情:.\scripts\launch.ps1 status -Name <名字>(交互终端裸跑 status 会弹菜单选)" -ForegroundColor DarkGray
            return
        }
    }
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
        $pidFile = Join-Path $vmStateDir ".tunnel.pid"
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

    Write-Step "剪贴板桥"
    if (@(Get-SavedFeatureIds) -contains 'clip-bridge') {
        $clipDaemonPidFile = Join-Path $StateDir '.clip-daemon.pid'
        $clipDaemonOk = $false
        $clipDaemonPid = ''
        if (Test-Path $clipDaemonPidFile) {
            $clipDaemonPid = (Get-Content $clipDaemonPidFile -First 1).Trim()
            if ($clipDaemonPid -and (Get-Process -Id $clipDaemonPid -ErrorAction SilentlyContinue)) {
                $null = & curl.exe -s --max-time 3 "http://127.0.0.1:$clipBridgePort/health" 2>$null
                $clipDaemonOk = ($LASTEXITCODE -eq 0)
            }
        }
        if ($clipDaemonOk) { Write-Ok "宿主 daemon 在跑(PID $clipDaemonPid,/health ok)" }
        else { Write-Warn "宿主 daemon 未响应(重跑 start 自愈;日志 $StateDir\clip-daemon.log)" }

        $clipTunnelPidFile = Join-Path $vmStateDir '.clip-tunnel.pid'
        if (Test-Path $clipTunnelPidFile) {
            $clipTunnelPid = (Get-Content $clipTunnelPidFile -First 1).Trim()
            if ($clipTunnelPid -and (Get-Process -Id $clipTunnelPid -ErrorAction SilentlyContinue)) {
                Write-Ok "桥隧道在跑 PID $clipTunnelPid"
                if ((Get-VmState) -eq 'Running') {
                    $probe = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c',
                        "curl -fsS --max-time 5 http://127.0.0.1:$clipBridgePort/health 2>/dev/null || echo DOWN") -TimeoutSec 20
                    if (-not $probe.TimedOut -and $probe.Stdout -match '"status":"ok"') {
                        Write-Ok "VM → 宿主 daemon 通(粘图可用)"
                    } else {
                        Write-Warn "VM 内探测 /health 未通(重跑 start 自愈)"
                    }
                }
            } else {
                Write-Warn ".clip-tunnel.pid 写了 PID $clipTunnelPid 但进程已死"
            }
        } else {
            Write-Warn ".clip-tunnel.pid 不存在(桥隧道未起)"
        }
    } else {
        Write-Host "    未启用(features.txt 无 clip-bridge)" -ForegroundColor DarkGray
    }

    Write-Step "开发环境"
    $devEnabledIds = @($optionalFeatures | Where-Object { $_.Id -like 'dev-*' -and (Get-SavedFeatureIds) -contains $_.Id } | ForEach-Object { $_.Id })
    if ($devEnabledIds.Count -eq 0) {
        Write-Host "    未启用(features.txt 无 dev-java/dev-python/dev-frontend)" -ForegroundColor DarkGray
    } elseif ((Get-VmState) -eq 'Running') {
        foreach ($id in $devEnabledIds) {
            $f = $optionalFeatures | Where-Object { $_.Id -eq $id }
            $probe = Test-FeatureInVm -Probe $f.Probe
            if ($probe -eq $true) { Write-Ok "$($f.Name) 已装" }
            elseif ($probe -eq $false) { Write-Warn "$($f.Name) 勾选了但未装上(重跑 start 安装)" }
            else { Write-Warn "$($f.Name) 探测超时" }
        }
    } else {
        $names = ($optionalFeatures | Where-Object { $devEnabledIds -contains $_.Id } | ForEach-Object { $_.Name }) -join ', '
        Write-Host "    VM 未运行,跳过探测(已启用:$names)" -ForegroundColor DarkGray
    }

    Write-Step "可选特性"
    $savedFeatures = @(Get-SavedFeatureIds)
    if ($savedFeatures.Count -eq 0) {
        Write-Host "    无(交互终端裸跑 start 弹菜单选择,或编辑 $vmStateDir\features.txt)" -ForegroundColor DarkGray
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
            $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c', "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 '$($tunnel.BaseUrl)/' 2>/dev/null || echo 000") -TimeoutSec 15
            $code = if ($r.TimedOut -or -not $r.Stdout) { '000' } else { $r.Stdout.Trim() }
            if ($code -match '^000') {
                Write-Warn "VM 里 curl base_url = $code (公网不可达?)"
            } else {
                Write-Ok "VM 里 curl base_url 返回 HTTP $code (直连通了)"
            }
        } else {
            # curl -w 连不上时也会打 000 且退出非零,`|| echo 000` 会再补一个 → 输出可能是 000000,
            # 用前缀匹配判失败,避免把探测失败误报成"隧道通了"
            $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'bash', '-c', "curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:$($tunnel.Port)/ 2>/dev/null || echo 000") -TimeoutSec 15
            $code = if ($r.TimedOut -or -not $r.Stdout) { '000' } else { $r.Stdout.Trim() }
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
    Write-Step "清理剪贴板桥..."
    Stop-ClipBridge
    Write-Step "删 VM..."
    Invoke-VmActionGraceful -MultipassArgs @('delete', '--purge', $vmName) -DoneMsg "VM 已删除并清理"
    # .last-vm 指向被删的 VM 时一并清掉:菜单默认项不能指到不存在的机器上
    $lastFile = Join-Path $StateDir '.last-vm'
    if ((Test-Path $lastFile) -and ("$(Get-Content $lastFile -First 1 -ErrorAction SilentlyContinue)").Trim() -eq $vmName) {
        Remove-Item $lastFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Write-Host "保留: 共享件($StateDir 根:bundle、.ssh-key)+ 该 VM 配置(${vmStateDir}:mounts.txt、features.txt,下次 start 复用)" -ForegroundColor Green
}

# ====== VM 名最终确定(交互菜单/新建向导 → 全局变量)======
# 放在函数定义之后(要用 Select-SingleChoice/Invoke-Multipass)、路由之前(消费方都在路由内跑)。
# .last-vm = 上次使用的 VM 名,交互菜单的默认项;显式 -Name 也写它,让"上次使用"跨场景一致。
# $vmResolved = 名字已被"确定"(显式 -Name 或交互菜单选过):Show-Status 据此区分
# "选定台看详情"与"未选定且多台给总览(非交互)"
$vmResolved = $false
if ($Action -in @('start', 'stop', 'delete', 'status')) {
    if ($nameExplicit) {
        $vmResolved = $true
        "$Name" | Out-File (Join-Path $StateDir '.last-vm') -Encoding ascii -Force
    } elseif (Test-InteractiveConsole) {
        $picked = Resolve-VmNameInteractive -Action $Action
        if ($picked -and $picked -ne $Name) { $Name = $picked }
        $vmResolved = $true
        "$Name" | Out-File (Join-Path $StateDir '.last-vm') -Encoding ascii -Force
    }
}
$vmName    = $Name
$vmStateDir = Join-Path $StateDir $Name
if (-not (Test-Path $vmStateDir)) { New-Item -ItemType Directory -Path $vmStateDir -Force | Out-Null }

# ====== 路由 ======
switch ($Action) {
    "start"   { Start-ClaudeDev }
    "stop"    { Stop-ClaudeDev }
    "status"  { Show-Status }
    "delete"  { Delete-ClaudeDev }
}

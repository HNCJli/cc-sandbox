#Requires -Version 5.0
<#
    claude-dev VM lifecycle manager.
    Usage:
        .\launch.ps1 start      # 创建/启动 VM + 挂载 + SSH 反向隧道
        .\launch.ps1 stop       # 停隧道 + 停 VM
        .\launch.ps1 restart    # stop + start
        .\launch.ps1 status     # 看 VM 状态和隧道状态
        .\launch.ps1 delete     # 删 VM + 清理(不会删 workspace/ 和 .ssh-key)
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "restart", "status", "delete")]
    [string]$Action = "start",

    # 宿主机要挂进 VM ~/workspace 的目录;空 = 用项目下 ./workspace(默认,向后兼容)
    # 仅用于传统单根模式(无 -NoRootWorkspace)
    [Parameter()]
    [string]$WorkspaceHost = "",

    # 可调配置(也可改 $script: 默认值)
    [string]$Image     = "resolute",    # Ubuntu 26.04 LTS
    [int]$Cpus         = 2,
    [int]$MemoryGB     = 4,
    [int]$DiskGB       = 20,
    [int]$CcSwitchPort = 15721,         # cc-switch 在宿主机监听的端口

    # 预装 tailscale(家里跨网络用,配对后手机 4G 能通过 cc-pocket 遥控;公司场景别开,会被软件审计识别)
    [switch]$EnableTailscale,

    # 额外挂载列表,每项 "HostPath" 或 "HostPath=vmSubdir",挂到 ~/workspace/<vmSubdir>
    # 简写时子目录名取宿主目录最后一级。传了此参数则不读 mounts.txt(参数优先)
    # 必须配合 -NoRootWorkspace 使用(避开 Multipass 1.16 嵌套挂载 bug)
    [Parameter()]
    [string[]]$ExtraMounts = @(),

    # 跳过根 workspace 挂载(并卸掉已有根挂载)。开了它,~/workspace 就是 VM 本地目录,
    # ExtraMounts 的子目录挂载便不再"嵌套在另一个挂载里",可避开 multipass 嵌套挂载失效的 bug
    [Parameter()]
    [switch]$NoRootWorkspace
)

# PS 5.1 把 native 命令的 stderr 当 terminating error,会让 multipass info(VM 不存在时)直接挂掉
# 改成 Continue,通过 $LASTEXITCODE + 显式 throw 来管理错误
$ErrorActionPreference = "Continue"
$scriptDir = $PSScriptRoot
Set-Location $scriptDir

# ====== 常量(不变项) ======
$vmName         = "claude-dev"
$mountClaudeHost = "/home/ubuntu/.claude-host"          # 宿主机 ~/.claude 挂到 VM 哪里
$mountWorkspace = "/home/ubuntu/workspace"              # ./workspace 挂到 VM 哪里(放在 ~/ 下)
# 可调项见 param() 块:$Image / $Cpus / $MemoryGB / $DiskGB / $CcSwitchPort

# ====== 日志 helpers ======
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }

# ====== multipass 命令超时包装 + daemon 自愈 ======
# multipassd 在 Windows 上不稳定(尤其 1.16.x),所有调用必须走超时包装,避免 daemon 卡死时连锁失败

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

# 快速探测 daemon 是否响应。绝不自愈,自愈在调用方
# 用 list 而非 version:version 只查进程在不在,daemon 重启后有"半活"窗口(version 秒回但 info/list 卡)
# list 需要查 Hyper-V 后端,能确保 daemon 真正可服务 VM 查询
function Assert-DaemonHealthy {
    $r = Invoke-Multipass -ArgumentList @('list') -TimeoutSec 10
    return (-not $r.TimedOut) -and ($r.ExitCode -eq 0)
}

# 轮询等 daemon 恢复(给 set privileged-mounts 后用)
function Wait-DaemonHealthy {
    param([int]$TimeoutSec = 60, [int]$IntervalSec = 2)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Assert-DaemonHealthy) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

# kill daemon + GUI + 客户端,等 watchdog 拉起新 daemon。返回 bool。
# 必须连 GUI 一起杀:GUI 持有 Hyper-V 句柄,只杀 daemon 时新 daemon 起来仍连不上 Hyper-V
function Reset-Daemon {
    param([int]$RecoverTimeoutSec = 60)
    # PS 5.1:Stop-Process -Name a,b 要求两个进程都存在,任一缺失就报错且不 kill 另一个 → 分次杀
    # 进程名(Stop-Process 是精确匹配):multipassd / multipass.gui / multipass
    Stop-Process -Name multipassd    -Force -ErrorAction SilentlyContinue
    Stop-Process -Name multipass.gui -Force -ErrorAction SilentlyContinue
    Stop-Process -Name multipass     -Force -ErrorAction SilentlyContinue
    # 给 OS 时间让进程真的退出 + 释放 Hyper-V 句柄(太快会拉起不健康的 daemon)
    Start-Sleep -Milliseconds 1500
    $ok = Wait-DaemonHealthy -TimeoutSec $RecoverTimeoutSec
    if ($ok) {
        # list 探测通了但内部状态可能还没完全稳定,多等几秒让 Hyper-V 后端连接完全建立
        Start-Sleep -Seconds 5
    }
    return $ok
}

# 失败时 Reset-Daemon 一次后重试,仍失败抛中文错误
# 注意:成功/失败只看 ExitCode 和 TimedOut,multipass 成功时也会往 stderr 写警告(如 mount 时)
function Invoke-MultipassWithRecovery {
    param(
        [Parameter(Mandatory)] [string[]]$ArgumentList,
        [int]$TimeoutSec = 60
    )
    $r = Invoke-Multipass -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec
    if ($r.TimedOut -or $r.ExitCode -ne 0) {
        Write-Warn "multipass $($ArgumentList -join ' ') 失败/超时,正在重置 daemon..."
        if (-not (Reset-Daemon)) {
            throw "daemon 自动重置失败。建议:任务管理器结束 multipass.gui.exe 后重新打开 Multipass GUI,或重启电脑。"
        }
        Write-Ok "daemon 已恢复,重试命令"
        $r = Invoke-Multipass -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec
        if ($r.TimedOut -or $r.ExitCode -ne 0) {
            $err = if ($r.Stderr) { $r.Stderr.Trim() } else { "(无 stderr)" }
            throw "重试仍失败:multipass $($ArgumentList -join ' ') ExitCode=$($r.ExitCode) stderr=$err"
        }
    }
    return $r
}

# mount 专用 wrapper:成功/已挂载/失败重试,失败时只警告不抛错(保持原版"继续"语义)
# "already mounted" 视为幂等成功,不触发 Reset
function Try-Mount {
    param(
        [Parameter(Mandatory)] [string[]]$MountArgs,
        [Parameter(Mandatory)] [string]$Description,
        [string]$FailureHint = ""
    )
    foreach ($attempt in 1..2) {
        # 120s:慢网络 + cloud-init 在跑时,multipass 跟 VM 的 SSH 通道会慢;60s 实测不够
        $r = Invoke-Multipass -ArgumentList $MountArgs -TimeoutSec 120
        if ($r.ExitCode -eq 0 -or $r.Stderr -match 'already mounted|already.*mount') {
            Write-Ok "$Description 完成"
            return $true
        }
        if ($attempt -eq 1) {
            Write-Warn "$Description 失败/超时,重置 daemon 重试..."
            if (-not (Reset-Daemon)) { break }
        }
    }
    $err = if ($r.Stderr) { $r.Stderr.Trim() } else { "daemon 重置失败或超时" }
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
    # daemon 健康检查:不健康就自愈一次,失败抛错(避免后续命令连锁失败)
    if (-not (Assert-DaemonHealthy)) {
        Write-Warn "multipassd 无响应,正在重置..."
        if (-not (Reset-Daemon)) {
            throw "multipassd 自动重置失败。建议:任务管理器结束 multipass.gui.exe 后重新打开 Multipass GUI,或重启电脑。"
        }
        Write-Ok "daemon 已恢复"
    }
    # Multipass 1.16+ 默认禁用 privileged mounts,需开启才能挂宿主机目录
    # 注意:set 会重启 multipassd,所以只在值未设时执行,且 set 后必须等 daemon 恢复
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
        # 关键:set 触发 daemon 重启,必须等恢复,否则后续 launch/info 撞死 daemon
        Write-Step "等 daemon 重启恢复(开启 privileged-mounts 需要)..."
        if (-not (Wait-DaemonHealthy -TimeoutSec 60)) {
            throw "开启 privileged-mounts 后 daemon 未在 60s 内恢复。建议手动重启 Multipass GUI 后重试。"
        }
        Write-Ok "privileged-mounts 已开启,daemon 已恢复"
    }
}

# 一次 list 调用拿 VM 的 Name/State/IPv4,找不到返回 $null
# Test-VmExists / Get-VmState / Get-VmIp 共用,避免 CSV 解析三处重复
function Get-VmRecord {
    $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 15
    if ($r.ExitCode -ne 0) { return $null }
    $line = ($r.Stdout -split "`r?`n" | Where-Object { $_ -like "$vmName,*" } | Select-Object -First 1)
    if (-not $line) { return $null }
    $cols = $line -split ','
    return @{ Name = $cols[0]; State = $cols[1]; IPv4 = $cols[2] }
}

# VM 是否存在(三态:exists / absent / unknown)
# 绝不在不确定时返回 absent —— 否则上层会跑去 launch 新 VM 把现有 VM 搞乱
# 用 list 而非 info:跟 Assert-DaemonHealthy 用同一命令,daemon 重启后 list 比 info 早可用
function Test-VmExists {
    foreach ($i in 1..3) {
        $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 10
        if ($r.ExitCode -eq 0) {
            if ($r.Stdout -split "`r?`n" | Where-Object { $_ -like "$vmName,*" }) { return 'exists' }
            return 'absent'  # list 成功但 VM 不在列表
        }
        Start-Sleep -Seconds 2
    }
    Write-Warn "multipass list 多次超时,重置 daemon..."
    if (Reset-Daemon) {
        $r = Invoke-Multipass -ArgumentList @('list', '--format', 'csv') -TimeoutSec 15
        if ($r.ExitCode -eq 0) {
            if ($r.Stdout -split "`r?`n" | Where-Object { $_ -like "$vmName,*" }) { return 'exists' }
            return 'absent'
        }
    }
    Write-Warn "无法确认 VM 状态(daemon 抽风)"
    return 'unknown'
}

# stop / delete 共用:直接跑 multipass 命令,不做 Test-VmExists 预检
# 预检路径在 daemon 慢时会触发 30s+ list 重试 + Reset-Daemon 级联;
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
    # "VM 不存在" 类错误:幂等视为已删/已停(实测字面量随版本/multipass 子命令有差异)
    if ($err -match '(?:does not exist|not found|cannot be found|unknown instance|name.*not known)') {
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
# 检测 bundle/ 是否齐全(Node tarball + Claude wrapper + Claude Linux 二进制)
# 齐全 → launch 时加 --mount bundle:/home/ubuntu/.bundle + 渲染离线 runcmd
# 不齐 → 走在线模式(现状)
function Test-BundleReady {
    $bundleDir = Join-Path $scriptDir 'bundle'
    if (-not (Test-Path $bundleDir)) { return $false }
    $hasNode  = Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue |
                Select-Object -First 1
    $hasWrap  = Get-ChildItem $bundleDir -Filter 'anthropic-ai-claude-code-*.tgz' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'linux-x64' } | Select-Object -First 1
    $hasLinux = Get-ChildItem $bundleDir -Filter 'anthropic-ai-claude-code-linux-x64-*.tgz' -ErrorAction SilentlyContinue |
                Select-Object -First 1
    return -not (-not $hasNode -or -not $hasWrap -or -not $hasLinux)
}

# ====== 渲染 cloud-init ======
function Render-CloudInit {
    param(
        [switch]$EnableTailscale,
        [switch]$BundleEnabled
    )
    Write-Step "渲染 cloud-init.yaml..."

    $templatePath = Join-Path $scriptDir "cloud-init.yaml"
    $tmuxPath     = Join-Path $scriptDir "tmux.conf"
    foreach ($p in @($templatePath, $tmuxPath)) {
        if (-not (Test-Path $p)) { throw "缺文件: $p" }
    }

    $template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
    $tmuxRaw  = [System.IO.File]::ReadAllText($tmuxPath, [System.Text.Encoding]::UTF8)

    # YAML block scalar 缩进:cloud-init.yaml 占位符所在 content: | 块是 6 空格缩进
    $tmuxIndented = (($tmuxRaw -split "`r?`n") | ForEach-Object { "      " + $_ }) -join "`n"
    # 去掉末尾多余空行,避免 YAML 末尾混乱
    $tmuxIndented = $tmuxIndented.TrimEnd("`n")

    $pubKeyPath = Join-Path $scriptDir ".ssh-key.pub"
    if (-not (Test-Path $pubKeyPath)) { throw ".ssh-key.pub 不存在,Start 流程漏了 keygen 步?" }
    $pubKey = ([System.IO.File]::ReadAllText($pubKeyPath, [System.Text.Encoding]::UTF8)).Trim()

    $rendered = $template.Replace('{{TMUX_CONF_PLACEHOLDER}}', $tmuxIndented)
    # SSH_PUBKEY 现在在 runcmd 的 echo "..." 里,不需要缩进
    $rendered = $rendered.Replace('{{SSH_PUBKEY_PLACEHOLDER}}', $pubKey)

    # tailscale 块:启用时插入安装命令(2 空格缩进对齐 runcmd 列表项),否则空字符串(留空行不影响 YAML 解析)
    if ($EnableTailscale) {
        $tailscaleBlock = @"
  # tailscale(家里跨网络用;VM 拿 100.x.x.x tailnet IP,配对后手机 4G 能通过 cc-pocket 遥控)
  # 注:仅安装未运行 'tailscale up' 时无出站流量,但软件审计能看到包已装
  - curl -fsSL https://tailscale.com/install.sh | sh
"@
    } else {
        $tailscaleBlock = ""
    }
    $rendered = $rendered.Replace('{{TAILSCALE_BLOCK}}', $tailscaleBlock)

    # bundle 块:启用时用离线 runcmd(从挂载的 /home/ubuntu/.bundle/ 装 Node + Claude Code),
    # 否则在线模式(curl nodesource + npm registry)
    # 离线模式依赖 launch --mount bundle:/home/ubuntu/.bundle,cloud-init runcmd 时该路径已可读
    if ($BundleEnabled) {
        $bundleBlock = @"
  # Node 20(离线:bundle/ 里的官方 tarball,解压到 /usr/local。tarball 自带 npm/npx)
  - tar -xJf /home/ubuntu/.bundle/node-v*-linux-x64.tar.xz -C /usr/local --strip-components=1
  # Claude Code(离线:先装 linux 真二进制,再装 wrapper。wrapper postinstall 把二进制拷到 bin/)
  # 文件名区分:wrapper=anthropic-ai-claude-code-X.X.X.tgz;binary=...-linux-x64-X.X.X.tgz
  # [0-9] glob 跳过 linux-x64 那个(以 'l' 开头)
  - npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-linux-x64-*.tgz
  - npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-[0-9]*.tgz
"@
    } else {
        $bundleBlock = @"
  # Node 20(LTS,在线)
  - curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  - apt-get install -y nodejs
  # Claude Code(在线)
  - npm install -g @anthropic-ai/claude-code
"@
    }
    $rendered = $rendered.Replace('{{BUNDLE_BLOCK}}', $bundleBlock)

    $renderedPath = Join-Path $scriptDir ".cloud-init.rendered.yaml"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($renderedPath, $rendered, $utf8NoBom)
    Write-Ok "渲染完成: $renderedPath"
    return $renderedPath
}

# ====== 杀隧道 ======
function Stop-Tunnel {
    $pidFile = Join-Path $scriptDir ".tunnel.pid"
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

# ====== ExtraMounts:来源(参数优先,否则读 mounts.txt) ======
# 返回 string[];无参数且配置文件不存在/为空 → 返回空数组(调用方跳过)
function Get-ExtraMountsSource {
    if ($ExtraMounts -and $ExtraMounts.Count -gt 0) { return @($ExtraMounts) }
    $cfg = Join-Path $scriptDir "mounts.txt"
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

        # 3) 挂载后再用 findmnt 验证一次 —— 这才是成功的唯一判据
        # 120s:跟 Try-Mount 一致(VM 忙时 SSH 通道慢)
        $mt = Invoke-Multipass -ArgumentList @('mount', $src, "${vmName}:${target}") -TimeoutSec 120
        $ok = (Test-VMTargetMounted -Target $target)
        if ($ok) {
            Write-Ok "挂载 $src → $target 完成"
        } else {
            $err = if ($mt.Stderr) { $mt.Stderr.Trim() } else { "(无 stderr)" }
            if ($err -match 'already mounted') {
                Write-Warn "挂载 $src → $target 失败:multipass 记录卡死(already mounted 但实际未挂载)"
                Write-Warn "  重新运行 .\launch.ps1 start -NoRootWorkspace 会再次尝试清理并挂载;若仍不行,先检查 daemon 状态再决定是否重建 VM"
            } else {
                Write-Warn "挂载 $src → $target 失败:$err"
            }
            $allMounted = $false
        }
    }
    return $allMounted
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
    $resolvedExtraMounts = if ($extraItems.Count -gt 0) { Resolve-ExtraMounts -Items $extraItems } else { @() }

    # 隧道复用/清理:start 幂等可反复跑。停旧隧道(后面会重起)
    Stop-Tunnel
    $pidFile = Join-Path $scriptDir ".tunnel.pid"

    # SSH keypair
    $keyPath = Join-Path $scriptDir ".ssh-key"
    if (-not (Test-Path $keyPath)) {
        Write-Step "生成 SSH keypair..."
        # PowerShell 处理空 passphrase 的坑:-N "" 会被 PS 吞成空,用 '""' 包一层
        & ssh-keygen -t ed25519 -f $keyPath -N '""' -C "claude-dev-tunnel" -q
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen 失败" }
        Write-Ok ".ssh-key 生成"
    }

    # bundle 检测(只对新 launch 生效;现有 VM 已经装过了,不重复走离线)
    $bundleReady = Test-BundleReady
    if ($bundleReady) {
        Write-Ok "检测到 bundle,本次 launch 走离线模式"
    } else {
        Write-Warn "bundle 不齐,走在线模式(跑 .\prepare-bundle.ps1 提速)"
    }
    $renderedPath = Render-CloudInit -EnableTailscale:$EnableTailscale -BundleEnabled:$bundleReady

    # 启动或唤醒 VM
    Write-Step "启动 VM(首次 3-5 分钟,cloud-init 装 Node + Claude Code)..."
    # 三态判断:绝不因 daemon 抽风误判 VM 不存在跑去 launch 新的(会把现有 VM 搞乱)
    switch (Test-VmExists) {
        'unknown' {
            throw "无法确认 VM 是否存在(daemon 异常)。请手动 'multipass list' 检查后再跑,以免误操作现有 VM"
        }
        'exists' {
            $state = Get-VmState
            if ($state -eq "Running") {
                Write-Warn "VM 已在 Running,start 改为只重挂/重起隧道"
            } else {
                Write-Step "唤醒 VM..."
                Invoke-MultipassWithRecovery -ArgumentList @('start', $vmName) -TimeoutSec 90 | Out-Null
                Write-Ok "VM 从 $state 唤醒"
            }
        }
        'absent' {
            $launchArgs = @("launch", "--name", $vmName,
                            "--cpus", $cpus,
                            "--memory", "${memoryGB}G",
                            "--disk", "${diskGB}G",
                            "--cloud-init", $renderedPath,
                            "--timeout", "1200")
            # bundle 齐全时,launch 时就挂载 bundle/ → /home/ubuntu/.bundle
            # 关键:cloud-init runcmd 在首次启动时跑,launch 之后才挂就晚了 → 必须用 --mount
            if ($bundleReady) {
                $bundleHost = Join-Path $scriptDir 'bundle'
                $launchArgs += @('--mount', "${bundleHost}:/home/ubuntu/.bundle")
            }
            $launchArgs += $image
            # launch 不走 WithRecovery:重启 daemon 会让正在创建的 VM 状态更乱
            # 用裸 Invoke-Multipass 超时;超时后用 exec 旁路探测 VM 真实状态
            # --timeout 1200 把 multipass CLI 自己的超时从默认 5 分钟拉到 20 分钟
            # PS 端给 1300s 留 100s 缓冲,让 multipass 的 --timeout 先触发(我们走友好恢复路径)
            $r = Invoke-Multipass -ArgumentList $launchArgs -TimeoutSec 1300

            $needProbe = $false
            if ($r.TimedOut) {
                # cloud-init 5.x 偶发完成信号丢失,multipass launch 一直等 —— VM 其实可能已就绪
                Write-Warn "multipass launch 超时(20 分钟),验证 VM 实际状态..."
                $needProbe = $true
            } elseif ($r.ExitCode -ne 0) {
                $err = if ($r.Stderr) { $r.Stderr.Trim() } else { "(无 stderr)" }
                # multipass 自己的 --timeout / SSH 等待超时触发:VM 可能其实好的,走旁路探测
                # 字面量随版本/触发路径:
                #   "timed out waiting for initialization"(老版本)
                #   "Timed out waiting for instance launch"(1.16.x,实测遇到)
                #   "Timed out waiting for SSH to be up"(SSH 路径)
                if ($err -match '(?:[Tt]imed out waiting for (?:initialization|instance launch|SSH))') {
                    Write-Warn "multipass launch 自身超时触发,验证 VM 实际状态..."
                    $needProbe = $true
                } else {
                    # 真错误(镜像名错、Hyper-V 拒绝创建等),不绕过
                    throw "multipass launch 失败(ExitCode=$($r.ExitCode)): $err"
                }
            }
            if ($needProbe) {
                $probe = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'cloud-init', 'status') -TimeoutSec 30
                if ($probe.ExitCode -eq 0 -and $probe.Stdout -match 'status:\s+(done|running)') {
                    $probeStatus = $Matches[1]
                    Write-Warn "VM 实际已就绪(cloud-init $probeStatus),launch 没返回信号是已知 bug,继续后续步骤"
                } else {
                    $probeErr = if ($probe.Stderr) { $probe.Stderr.Trim() } else { "(无 stderr)" }
                    throw "multipass launch 超时且 VM 未就绪。建议:.\launch.ps1 delete 清理后重试。日志:%USERPROFILE%\.multipass\data\`n旁路探测 ExitCode=$($probe.ExitCode) stdout=$($probe.Stdout) stderr=$probeErr"
                }
            }
            Write-Ok "VM 创建并启动"
        }
    }

    # 等 cloud-init(只有新 launch 会真的跑 runcmd,但 --wait 对已 done 的会立即返回)
    Write-Step "等 cloud-init 完成..."
    # 不走 WithRecovery:cloud-init 偶发 schema validation 警告会让 ExitCode 非零,
    # 走 WithRecovery 会触发不必要的 Reset(60s 浪费);daemon 卡死时超时,后续挂载会兜底自愈
    # 超时给 1200s(20 分钟),慢网络下 npm + cc-pocket JRE 下载可能 15+ 分钟;
    # 之前 300s 太短,会错误前进到挂载,而 cloud-init 还在跑导致挂载/卸载连锁超时
    $r = Invoke-Multipass -ArgumentList @('exec', $vmName, '--', 'cloud-init', 'status', '--wait') -TimeoutSec 1200
    if ($r.TimedOut) {
        Write-Warn "cloud-init status --wait 超时(20 分钟),VM 可能已就绪,继续后续步骤验证"
    } elseif ($r.ExitCode -ne 0) {
        Write-Warn "cloud-init status --wait 返回非零(常见:schema validation 警告 / 已 done 后再查的 transient 状态),继续"
    }

    # 挂载 .claude(RO)
    Write-Step "挂载宿主机 ~/.claude → VM $mountClaudeHost..."
    $hostClaude = Join-Path $env:USERPROFILE ".claude"
    if (-not (Test-Path $hostClaude)) { throw "$hostClaude 不存在,Claude Code 没装?" }
    $null = Try-Mount -MountArgs @('mount', $hostClaude, "${vmName}:${mountClaudeHost}") `
                      -Description "挂载 .claude" `
                      -FailureHint "(cc-switch env 同步会失效,继续)"

    # 挂载 workspace —— 两种模式互斥
    if ($NoRootWorkspace) {
        # 多目录模式:不挂根 workspace,卸掉已有根挂载,~/workspace 保持 VM 本地目录
        # 避免嵌套挂载(Multipass 1.16 在 Windows 不支持)
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
            # 用户显式指定宿主机 workspace 目录:必须已存在,不自动创建
            if (-not (Test-Path $WorkspaceHost -PathType Container)) {
                throw "-WorkspaceHost 必须是已存在的目录: $WorkspaceHost"
            }
            $wsHost = (Resolve-Path $WorkspaceHost).Path
            Write-Step "使用自定义 workspace 源: $wsHost"
        } else {
            # 默认:项目下 ./workspace(保持原行为)
            $wsHost = Join-Path $scriptDir "workspace"
            if (-not (Test-Path $wsHost)) {
                New-Item -ItemType Directory -Path $wsHost | Out-Null
                Write-Warn "workspace/ 不存在,已新建空目录"
            }
        }
        # 换源时清掉 VM 内 ~/workspace 旧挂载,避免"目标已被占用"冲突(首次 umount 失败忽略)
        $null = Invoke-Multipass -ArgumentList @('umount', "${vmName}:${mountWorkspace}") -TimeoutSec 30
        $null = Try-Mount -MountArgs @('mount', $wsHost, "${vmName}:${mountWorkspace}") `
                          -Description "挂载 workspace" `
                          -FailureHint "(中文路径 $wsHost 若挂不上,见 README 故障排查;继续)"
    }

    # ExtraMounts:仅在 -NoRootWorkspace 下挂到 VM 本地 workspace 子目录
    if ($resolvedExtraMounts.Count -gt 0) {
        if (-not (Mount-ExtraMounts -Mounts $resolvedExtraMounts)) {
            throw "一个或多个额外挂载失败,停止启动以避免 workspace 数据位置不确定"
        }
    }

    # SSH 反向隧道
    Write-Step "启动 SSH 反向隧道(宿主机 $ccSwitchPort ↔ VM 127.0.0.1:$ccSwitchPort)..."
    $vmIp = Get-VmIp
    if (-not $vmIp) { throw "无法获取 VM IP,multipass info 看看" }

    $knownHosts = Join-Path $env:TEMP "claude-dev-known-hosts"
    $tunnelArgs = @(
        "-nNT",
        "-R", "${ccSwitchPort}:127.0.0.1:${ccSwitchPort}",
        "-i", $keyPath,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=$knownHosts",
        "-o", "ServerAliveInterval=30",
        "-o", "ExitOnForwardFailure=yes",
        "ubuntu@$vmIp"
    )
    $proc = Start-Process -FilePath ssh -ArgumentList $tunnelArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    if ($proc.HasExited) {
        throw "SSH 隧道秒退,ExitCode=$($proc.ExitCode)。可能是 VM sshd 没起或 key 没注入"
    }
    $proc.Id | Out-File $pidFile -Encoding ascii -Force
    Write-Ok "隧道 PID $($proc.Id)"

    Write-Host ""
    Write-Host "==== 完成 ====" -ForegroundColor Green
    Write-Host "进入 VM:    multipass shell $vmName"
    Write-Host "VM 里跑:    claude --dangerously-skip-permissions"
    if ($EnableTailscale) {
        Write-Host "Tailscale:  VM 里跑 'sudo tailscale up' 配对(已预装,未配对)"
    }
    Write-Host "状态:       .\launch.ps1 status"
    Write-Host "停机:       .\launch.ps1 stop"
    Write-Host ""
}

# ====== stop ======
function Stop-ClaudeDev {
    Write-Step "停隧道..."
    Stop-Tunnel
    Write-Step "停 VM..."
    Invoke-VmActionGraceful -MultipassArgs @('stop', $vmName) -DoneMsg "VM 已停"
}

# ====== status ======
function Show-Status {
    Write-Step "VM 状态"
    switch (Test-VmExists) {
        'exists'  { multipass info $vmName }
        'absent'  { Write-Warn "VM 不存在" }
        'unknown' {
            Write-Warn "VM 状态不确定(daemon 抽风,VM 本身可能正常)"
            Write-Warn "稍等 1-2 分钟重跑;或直接 'multipass shell $vmName' 验证 VM 是否可用"
        }
    }

    Write-Step "SSH 反向隧道"
    $pidFile = Join-Path $scriptDir ".tunnel.pid"
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

    Write-Step "VM 内 cc-switch 端口探测"
    if ((Get-VmState) -eq "Running") {
        $code = & multipass exec $vmName -- bash -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:$ccSwitchPort/ 2>/dev/null || echo 000"
        if ($code -eq "000") {
            Write-Warn "VM 里 curl 127.0.0.1:$ccSwitchPort = $code (隧道可能没通)"
        } else {
            Write-Ok "VM 里 curl 127.0.0.1:$ccSwitchPort 返回 HTTP $code (隧道通了)"
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
    Write-Host "保留: workspace/、.ssh-key、.ssh-key.pub(下次 start 复用)" -ForegroundColor Green
}

# ====== 路由 ======
switch ($Action) {
    "start"   { Start-ClaudeDev }
    "stop"    { Stop-ClaudeDev }
    "restart" { Stop-ClaudeDev; Start-ClaudeDev }
    "status"  { Show-Status }
    "delete"  { Delete-ClaudeDev }
}

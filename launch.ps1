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
    [string]$Action = "start"
)

# PS 5.1 把 native 命令的 stderr 当 terminating error,会让 multipass info(VM 不存在时)直接挂掉
# 改成 Continue,通过 $LASTEXITCODE + 显式 throw 来管理错误
$ErrorActionPreference = "Continue"
$scriptDir = $PSScriptRoot
Set-Location $scriptDir

# ====== 配置 ======
$vmName         = "claude-dev"
$image          = "noble"                              # Ubuntu 24.04 LTS
$cpus           = 2
$memoryGB       = 4
$diskGB         = 20
$ccSwitchPort   = 15721                                # cc-switch 在宿主机监听的端口
$mountClaudeHost = "/home/ubuntu/.claude-host"          # 宿主机 ~/.claude 挂到 VM 哪里
$mountWorkspace = "/workspace"                          # ./workspace 挂到 VM 哪里

# ====== 日志 helpers ======
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }

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
    # Multipass 1.16+ 默认禁用 privileged mounts,需开启才能挂宿主机目录
    # 注意:这一步会重启 multipassd 服务,把已运行的 VM 挂起。所以只在值未设时执行,且最好在 launch 前
    $cur = & multipass get local.privileged-mounts 2>$null
    if ($LASTEXITCODE -ne 0 -or $cur.Trim() -ne "true") {
        Write-Step "开启 Multipass privileged-mounts (首次会重启 multipassd)..."
        & multipass set local.privileged-mounts=true
        if ($LASTEXITCODE -eq 0) { Write-Ok "已开启" } else { Write-Warn "set 失败,挂载可能不可用" }
    }
}

# ====== VM 是否存在 ======
function Test-VmExists {
    $null = & multipass info $vmName --format csv 2>&1
    return ($LASTEXITCODE -eq 0)
}

# ====== VM 是否在 Running ======
function Get-VmState {
    if (-not (Test-VmExists)) { return $null }
    $info = (& multipass info $vmName --format csv 2>&1) | Select-Object -Skip 1
    # CSV header: Name,State,IPv4,Image,ReleaseNotes
    return ($info -split ',')[1]
}

function Get-VmIp {
    $info = (& multipass info $vmName --format csv 2>&1) | Select-Object -Skip 1
    return ($info -split ',')[2]
}

# ====== 渲染 cloud-init ======
function Render-CloudInit {
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

# ====== start ======
function Start-ClaudeDev {
    Assert-Prerequisites

    # 隧道孤儿进程清理
    $pidFile = Join-Path $scriptDir ".tunnel.pid"
    if (Test-Path $pidFile) {
        $oldPid = (Get-Content $pidFile -First 1).Trim()
        if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
            throw "已有隧道进程在跑(PID $oldPid)。先 .\launch.ps1 stop 再 start。"
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    # SSH keypair
    $keyPath = Join-Path $scriptDir ".ssh-key"
    if (-not (Test-Path $keyPath)) {
        Write-Step "生成 SSH keypair..."
        # PowerShell 处理空 passphrase 的坑:-N "" 会被 PS 吞成空,用 '""' 包一层
        & ssh-keygen -t ed25519 -f $keyPath -N '""' -C "claude-dev-tunnel" -q
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen 失败" }
        Write-Ok ".ssh-key 生成"
    }

    $renderedPath = Render-CloudInit

    # 启动或唤醒 VM
    Write-Step "启动 VM(首次 3-5 分钟,cloud-init 装 Node + Claude Code)..."
    if (Test-VmExists) {
        $state = Get-VmState
        if ($state -eq "Running") {
            Write-Warn "VM 已在 Running,start 改为只重挂/重起隧道"
        } else {
            multipass start $vmName
            Write-Ok "VM 从 $state 唤醒"
        }
    } else {
        $args = @("launch", "--name", $vmName,
                  "--cpus", $cpus,
                  "--memory", "${memoryGB}G",
                  "--disk", "${diskGB}G",
                  "--cloud-init", $renderedPath,
                  $image)
        & multipass @args
        if ($LASTEXITCODE -ne 0) { throw "multipass launch 失败" }
        Write-Ok "VM 创建并启动"
    }

    # 等 cloud-init(只有新 launch 会真的跑 runcmd,但 --wait 对已 done 的会立即返回)
    Write-Step "等 cloud-init 完成..."
    & multipass exec $vmName -- cloud-init status --wait
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "cloud-init status --wait 返回非零(可能是已 done 后再查的 transient 状态),继续"
    }

    # 挂载 .claude(RO)
    Write-Step "挂载宿主机 ~/.claude → VM $mountClaudeHost..."
    $hostClaude = Join-Path $env:USERPROFILE ".claude"
    if (-not (Test-Path $hostClaude)) { throw "$hostClaude 不存在,Claude Code 没装?" }
    & multipass mount $hostClaude "${vmName}:${mountClaudeHost}" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "挂载完成"
    } else {
        Write-Warn "mount 失败(可能已挂载,继续)"
    }
    # best-effort 让 VM 内的挂载源变 RO
    & multipass exec $vmName -- sudo chmod -R a-w $mountClaudeHost 2>$null
    Write-Ok ".claude-host RO(best-effort)"

    # 挂载 workspace
    Write-Step "挂载 workspace → VM $mountWorkspace..."
    $wsHost = Join-Path $scriptDir "workspace"
    if (-not (Test-Path $wsHost)) {
        New-Item -ItemType Directory -Path $wsHost | Out-Null
        Write-Warn "workspace/ 不存在,已新建空目录"
    }
    & multipass mount $wsHost "${vmName}:${mountWorkspace}" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "挂载完成"
    } else {
        Write-Warn "mount 失败(可能已挂载,继续)。中文路径($wsHost)若挂不上,见 README 的故障排查"
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
    Write-Host "状态:       .\launch.ps1 status"
    Write-Host "停机:       .\launch.ps1 stop"
    Write-Host ""
}

# ====== stop ======
function Stop-ClaudeDev {
    Write-Step "停隧道..."
    Stop-Tunnel
    Write-Step "停 VM..."
    if (Test-VmExists) {
        multipass stop $vmName
        Write-Ok "VM 已停"
    } else {
        Write-Warn "VM 不存在,跳过"
    }
}

# ====== status ======
function Show-Status {
    Write-Step "VM 状态"
    if (Test-VmExists) {
        multipass info $vmName
    } else {
        Write-Warn "VM 不存在"
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
    if (Test-VmExists) {
        multipass delete --purge $vmName
        Write-Ok "VM 已删除并清理"
    } else {
        Write-Warn "VM 不存在,跳过"
    }
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

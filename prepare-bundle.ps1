<#
.SYNOPSIS
    准备离线 bundle(Node 20 LTS + Claude Code),让 cloud-init 不用联网下载。

.PARAMETER Force
    重新下载所有,即使文件已存在。

.PARAMETER NodeVersion
    指定 Node 版本(如 "v20.20.2")。不指定时自动取最新 20.x LTS。

.EXAMPLE
    .\prepare-bundle.ps1              # 缺啥下啥
    .\prepare-bundle.ps1 -Force       # 重新下载所有
    .\prepare-bundle.ps1 -NodeVersion v20.20.2  # 指定版本

bundle 内容(约 117MB):
  - node-vXX.X.X-linux-x64.tar.xz          Node 20 LTS Linux 二进制 (~25MB)
  - anthropic-ai-claude-code-X.X.X.tgz     Claude Code wrapper 包 (~25KB)
  - anthropic-ai-claude-code-linux-x64-X.X.X.tgz  Claude Code Linux 真二进制 (~93MB)

注意:@anthropic-ai/claude-code 是 wrapper 包,真二进制在平台特定的
@anthropic-ai/claude-code-linux-x64。两个都要 bundle,wrapper 的 postinstall
才会把真二进制装到位。
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$NodeVersion
)

$ErrorActionPreference = 'Stop'
$bundleDir = Join-Path $PSScriptRoot 'bundle'

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "    !   $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "    X   $m" -ForegroundColor Red }

if (-not (Test-Path $bundleDir)) {
    New-Item -ItemType Directory -Path $bundleDir | Out-Null
}

# ---------- 1. Node 20 LTS ----------
Write-Step "查 Node 20 LTS 版本..."

if (-not $NodeVersion) {
    try {
        $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
        $latest20 = $idx | Where-Object {
            $_.version -match '^v20\.' -and $_.lts -ne $false -and $null -ne $_.lts
        } | Select-Object -First 1
        if (-not $latest20) { throw "index.json 里找不到 20.x LTS" }
        $NodeVersion = $latest20.version
    } catch {
        Write-Err "拉 Node 版本索引失败:$($_.Exception.Message)"
        Write-Err "可用 -NodeVersion v20.20.2 显式指定"
        exit 1
    }
}

$nodeFile = "node-$NodeVersion-linux-x64.tar.xz"
$nodePath = Join-Path $bundleDir $nodeFile
$nodeUrl  = "https://nodejs.org/dist/$NodeVersion/$nodeFile"

if ((-not $Force) -and (Test-Path $nodePath)) {
    Write-Ok "Node 已存在:$nodeFile(用 -Force 重下)"
} else {
    if ($Force) {
        Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Write-Step "下载 $nodeUrl (~25MB)..."
    try {
        $proto = [System.Net.ServicePointManager]::SecurityProtocol
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $nodeUrl -OutFile $nodePath -TimeoutSec 600 -UseBasicParsing
        [System.Net.ServicePointManager]::SecurityProtocol = $proto
        $size = [math]::Round((Get-Item $nodePath).Length / 1MB, 1)
        Write-Ok "Node 下载完成:$nodeFile ($size MB)"
    } catch {
        Write-Err "Node 下载失败:$($_.Exception.Message)"
        if (Test-Path $nodePath) { Remove-Item $nodePath -Force -ErrorAction SilentlyContinue }
        exit 1
    }
}

# ---------- 2. Claude Code(wrapper + Linux 真二进制)----------
Write-Step "查 Claude Code npm 包..."

$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) {
    Write-Err "宿主机没装 npm。装 Node 后重试"
    exit 1
}

# 两份 tgz:wrapper(小,~25KB)+ Linux 真二进制(大,~93MB)
$wrapperPattern = 'anthropic-ai-claude-code-*.tgz'
$linuxPattern   = 'anthropic-ai-claude-code-linux-x64-*.tgz'
# 排除 linux-x64:wrapper 文件名是 anthropic-ai-claude-code-X.X.X.tgz,linux 是 ...-linux-x64-X.X.X.tgz
$existingWrapper = Get-ChildItem $bundleDir -Filter $wrapperPattern -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'linux-x64' } | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$existingLinux   = Get-ChildItem $bundleDir -Filter $linuxPattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1

function Invoke-NpmPack {
    param([string]$Pkg)
    Push-Location $bundleDir
    try {
        # 用 cmd 执行避免 PowerShell 流处理 npm 的 stderr notice
        $tmpOut = Join-Path $env:TEMP "npm-pack-$([guid]::NewGuid().ToString('N')).txt"
        $proc = Start-Process -FilePath 'npm' -ArgumentList @('pack', $Pkg) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tmpOut -RedirectStandardError "$tmpOut.err"
        if ($proc.ExitCode -ne 0) {
            $err = Get-Content "$tmpOut.err" -Raw -ErrorAction SilentlyContinue
            Remove-Item $tmpOut, "$tmpOut.err" -Force -ErrorAction SilentlyContinue
            throw "npm pack $Pkg 失败(ExitCode=$($proc.ExitCode)):$err"
        }
        # npm pack 输出最后非空行是文件名
        # 注意:Get-Content 单行返回 string 不是数组,$lines[-1] 会取到字符;
        # 用 @() 强制数组,再 Select-Object -Last 1 取最后一行
        $lines = @(Get-Content $tmpOut | Where-Object { $_ -match '\.tgz$' })
        Remove-Item $tmpOut, "$tmpOut.err" -Force -ErrorAction SilentlyContinue
        if ($lines.Count -eq 0) { throw "npm pack $Pkg 没产出 .tgz" }
        $packedName = ($lines | Select-Object -Last 1).Trim()
        $packedPath = Join-Path $bundleDir $packedName
        if (-not (Test-Path $packedPath)) { throw "npm pack 报告 $packedName 但文件不在 bundle/" }
        return $packedPath
    } finally {
        Pop-Location
    }
}

# wrapper 包(小,快)
if ((-not $Force) -and $existingWrapper) {
    Write-Ok "Claude Code wrapper 已存在:$($existingWrapper.Name)"
} else {
    if ($Force) {
        Get-ChildItem $bundleDir -Filter $wrapperPattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'linux-x64' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Write-Step "npm pack @anthropic-ai/claude-code(wrapper,~25KB)..."
    try {
        $p = Invoke-NpmPack -Pkg '@anthropic-ai/claude-code'
        Write-Ok "wrapper 打包完成:$(Split-Path $p -Leaf)"
    } catch {
        Write-Err $_.Exception.Message
        exit 1
    }
}

# Linux 真二进制(大,慢)
if ((-not $Force) -and $existingLinux) {
    Write-Ok "Claude Code Linux 二进制已存在:$($existingLinux.Name)"
} else {
    if ($Force) {
        Get-ChildItem $bundleDir -Filter $linuxPattern -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Write-Step "npm pack @anthropic-ai/claude-code-linux-x64(真二进制,~93MB,慢)..."
    try {
        $p = Invoke-NpmPack -Pkg '@anthropic-ai/claude-code-linux-x64'
        $size = [math]::Round((Get-Item $p).Length / 1MB, 1)
        Write-Ok "Linux 二进制打包完成:$(Split-Path $p -Leaf) ($size MB)"
    } catch {
        Write-Err $_.Exception.Message
        exit 1
    }
}

# ---------- 3. 状态汇总 ----------
Write-Step "bundle 状态:"
$nodeOk   = Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue | Select-Object -First 1
$wrapOk   = Get-ChildItem $bundleDir -Filter $wrapperPattern -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'linux-x64' } | Select-Object -First 1
$linuxOk  = Get-ChildItem $bundleDir -Filter $linuxPattern -ErrorAction SilentlyContinue | Select-Object -First 1

if ($nodeOk) { Write-Ok "Node:               $($nodeOk.Name)" }   else { Write-Err "Node:               缺" }
if ($wrapOk) { Write-Ok "Claude wrapper:     $($wrapOk.Name)" }   else { Write-Err "Claude wrapper:     缺" }
if ($linuxOk) { Write-Ok "Claude Linux 二进制:$($linuxOk.Name)" } else { Write-Err "Claude Linux 二进制:缺" }

if ($nodeOk -and $wrapOk -and $linuxOk) {
    $totalMB = [math]::Round(($nodeOk.Length + $wrapOk.Length + $linuxOk.Length) / 1MB, 1)
    Write-Host ""
    Write-Host "bundle 就绪($totalMB MB)。" -ForegroundColor Green
    Write-Host "下次 .\launch.ps1 start 会自动走离线模式,cloud-init 应 < 2 分钟(主要剩 cc-pocket 在线,失败不阻断)。" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Err "bundle 不完整,launch.ps1 会降级为在线模式(网络慢时 cloud-init 13+ 分钟)"
    exit 1
}

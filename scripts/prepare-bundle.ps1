<#
.SYNOPSIS
    准备离线 bundle(Claude Code + opencode + cc-pocket 原生二进制 + 可选开发环境件),
    让 VM 创建不依赖网络下载。

    架构(2026-08 多版本改造):AI 工具与语言运行时解耦——
      核心 3 件全部原生二进制直装(tar 解包 + symlink),不再经 npm/node:
        Claude Code  npm 双包的平台包(anthropic-ai-claude-code-linux-x64),内含单个原生二进制
        opencode     同上(opencode-linux-x64)
        cc-pocket    自带 JRE 的独立 tarball
      可选开发环境件(版本管理器接管多版本,默认跳过,交互菜单选装;
      非交互且无缓存直接跳过不下载,要装就在交互终端跑一次):
        JDK 17    Adoptium Temurin tarball,清华镜像(~190MB)→ SDKMAN candidates 预置
        Maven     bin tarball,阿里云 apache 镜像(~9MB)→ SDKMAN candidates 预置
        SDKMAN    cli + native 两 zip(broker 302→GitHub release;GitHub 不通走 ghfast.top 镜像)
        uv        PyPI manylinux wheel,清华镜像(~35MB)
        pnpm      @pnpm/linux-x64 独立二进制包 npm pack(~26MB,自含运行时,与 node 版本解耦)
        Node      nodejs.org tarball(默认 v20.20.2)→ nvm versions 预置;多版本并存,可交互追加
        nvm       不下载——assets/nvm.sh 已 vendor 进仓库,拷入 bundle 即可

.PARAMETER Force
    重新选版本 + 重新下载(即使文件已存在)。
    不加时:文件已存在的组件直接沿用缓存,零交互零网络。

    版本选择(仅当该组件需要下载时才弹;非交互终端自动用默认):
      Claude Code  默认最新版(latest);菜单另列最近 5 个正式版(npm 实时取)、
                   与宿主机一致(探测 claude --version)/ 保持缓存 / 手动输入
      opencode     默认最新版(latest);菜单同 Claude Code
      cc-pocket    默认"保持缓存"(无缓存则最新)
    核心件切换版本会自动清掉 bundle 里的旧版本文件
    (install-bundle.sh 按 glob 装,不容忍核心件多版本并存;Node 是多版本件,共存不清)。

.EXAMPLE
    .\scripts\prepare-bundle.ps1              # 缺啥下啥;缺的组件交互选版本(非交互用默认)
    .\scripts\prepare-bundle.ps1 -Force       # 重新选版本 + 全量重下

bundle 下载到状态目录 %USERPROFILE%\.cc-sandbox\bundle(写死,与 launch.ps1 同一位置),
不占用 skill 包目录。核心件(约 180 MB):
  - anthropic-ai-claude-code-linux-x64-X.X.X.tgz  Claude Code Linux 原生二进制(单文件)
  - opencode-linux-x64-X.X.X.tgz                  opencode Linux 原生二进制(单文件)
  - cc-pocket/cc-pocket-daemon-X.X.X-linux-x86_64.tar.gz  cc-pocket 手机遥控(自带 JRE)
可选开发环境件(另约 300 MB,全选时):
  - jdk/OpenJDK17U-jdk_x64_linux_hotspot_17.0.X_Y.tar.gz
  - maven/apache-maven-X.X.X-bin.tar.gz
  - sdkman/sdkman-cli-X.X.X.zip + sdkman-native-X.X.X-linuxx64.zip
  - uv/uv-X.X.X-py3-none-manylinux_x86_64.whl
  - pnpm/pnpm-linux-x64-X.X.X.tgz
  - node/node-vXX.X.X-linux-x64.tar.xz(可多份并存)
  - nvm/nvm-vX.X.X.sh(自 assets/nvm.sh 拷贝)
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# 状态目录(与 launch.ps1 同一位置,写死)
$StateDir = Join-Path $env:USERPROFILE '.cc-sandbox'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$bundleDir = Join-Path $StateDir 'bundle'
if (-not (Test-Path $bundleDir)) { New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null }

. (Join-Path $PSScriptRoot 'feature-menu.ps1')

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "    !   $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "    X   $m" -ForegroundColor Red }

# 真人终端才弹菜单(与 launch.ps1 同原则:管道/后台/Claude 代跑自动用默认)
$interactive = Test-InteractiveConsole

function Invoke-NpmPack {
    param([string]$Pkg)
    Push-Location $bundleDir
    try {
        # Start-Process 不能直接执行 npm.ps1;显式使用 npm.cmd,避免 Windows 报 "%1 is not a valid Win32 application"
        $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
        if (-not $npmCmd) { throw "找不到 npm.cmd。请确认 Node.js/npm 已加入 PATH" }
        $tmpOut = Join-Path $env:TEMP "npm-pack-$([guid]::NewGuid().ToString('N')).txt"
        $proc = Start-Process -FilePath $npmCmd -ArgumentList @('pack', $Pkg) `
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

# ---------- 0. nvm(vendor 件:assets/nvm.sh 拷入 bundle,零网络)----------
# nvm 是单文件 bash 脚本,GitHub 常不可达 → vendor 进仓库钉版本(升级:换 assets/nvm.sh +
# 同步下方版本/SHA 常量)。SHA 校验防文件被误改/换版本忘更新常量。
$nvmVendorVer  = '0.40.3'
$nvmVendorSha  = '390260AB9EB1DA20E8BC0EBEA2EE90F528D53E5E9F6E13B16717DB4AF454DF9D'
$nvmAssetPath  = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\nvm.sh'
$nvmBundleDir  = Join-Path $bundleDir 'nvm'
$nvmBundlePath = Join-Path $nvmBundleDir "nvm-v$nvmVendorVer.sh"
if (-not (Test-Path $nvmAssetPath)) { Write-Err "缺 assets/nvm.sh"; exit 1 }
$nvmSha = (Get-FileHash $nvmAssetPath -Algorithm SHA256).Hash
if ($nvmSha -ne $nvmVendorSha) {
    Write-Err "assets/nvm.sh SHA256 校验失败(换了新版 nvm?同步脚本里的 \$nvmVendorVer/\$nvmVendorSha 常量)"
    Write-Err "  期望 $nvmVendorSha"
    Write-Err "  实际 $nvmSha"
    exit 1
}
if (-not (Test-Path $nvmBundlePath)) {
    New-Item -ItemType Directory -Path $nvmBundleDir -Force | Out-Null
    Copy-Item $nvmAssetPath $nvmBundlePath -Force
    # 清掉旧版本(多版本并存无意义,install-bundle.sh 取 glob 第一个)
    Get-ChildItem $nvmBundleDir -Filter 'nvm-v*.sh' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "nvm-v$nvmVendorVer.sh" } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
Write-Ok "nvm v$nvmVendorVer 就绪(vendor 件,自 assets/nvm.sh 拷贝)"

# ---------- 0b. 旧架构残留清理 + 迁移 ----------
# wrapper 包不再使用(原生直装只要平台包);根目录 node tarball 迁入 bundle/node/
Get-ChildItem $bundleDir -Filter 'anthropic-ai-claude-code-*.tgz' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'linux-x64' } |
    ForEach-Object { Write-Warn "清理旧架构残留(wrapper 包不再使用):$($_.Name)"; Remove-Item $_.FullName -Force }
Get-ChildItem $bundleDir -Filter 'opencode-ai-*.tgz' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Warn "清理旧架构残留(opencode wrapper 不再使用):$($_.Name)"; Remove-Item $_.FullName -Force }
$nodeDir = Join-Path $bundleDir 'node'
New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSIsContainer -eq $false } |
    ForEach-Object { Write-Warn "迁移旧布局:$($_.Name) → bundle\node\"; Move-Item $_.FullName -Destination $nodeDir -Force }

# ---------- 1. Claude Code(Linux 原生二进制)----------
$ccPattern = 'anthropic-ai-claude-code-linux-x64-*.tgz'
$existingCc = Get-ChildItem $bundleDir -Filter $ccPattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

# 宿主机 claude 版本(默认选项的锚点;探测不到就退回"最新")
$hostVer = $null
try {
    $v = (& claude --version 2>$null | Select-Object -First 1)
    if ($v -match '(\d+\.\d+\.\d+)') { $hostVer = $Matches[1] }
} catch { }

if ((-not $Force) -and $existingCc) {
    Write-Ok "Claude Code 已存在:$($existingCc.Name)(用 -Force 重选/重下)"
} else {
    $cachedVer = $null
    if ($existingCc -and $existingCc.Name -match 'claude-code-linux-x64-(\d+\.\d+\.\d+)\.tgz') { $cachedVer = $Matches[1] }
    $recentCc = @()
    if ($interactive) {
        try {
            $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
            if (-not $npmCmd) { throw 'npm.cmd 不在 PATH' }
            $out = & $npmCmd view '@anthropic-ai/claude-code' versions --json 2>$null
            # PS 5.1 多行 JSON 坑:先 -join 回完整文本、裸赋值(不加 @()),下游会自行枚举数组
            $vers = ConvertFrom-Json ($out -join "`n")
            # 过滤预发布(带 - 的),取最近 5 个正式版,倒序(新→旧)
            $recentCc = @($vers | Where-Object { "$_" -notmatch '-' } | Select-Object -Last 5)
            [array]::Reverse($recentCc)
        } catch {
            Write-Warn "拉取 Claude Code 版本列表失败(离线?只提供 默认/宿主一致/手动)"
        }
    }
    $choices = @()
    if ($cachedVer) {
        $choices += @{ Label = "保持缓存版本 v$cachedVer(不重新下载)"; Ver = "cached:$cachedVer" }
        $defaultLabel = "v$cachedVer(保持缓存)"
    } else {
        $choices += @{ Label = '最新版(latest)'; Ver = 'latest' }
        $defaultLabel = 'latest'
    }
    foreach ($v in ($recentCc | Where-Object { $_ -ne $cachedVer })) { $choices += @{ Label = "$v"; Ver = $v } }
    if ($hostVer -and $hostVer -ne $cachedVer) { $choices += @{ Label = "与宿主机一致 v$hostVer"; Ver = $hostVer } }
    $choices += @{ Label = '手动输入版本号'; Ver = 'manual' }

    $pick = $choices[0]   # 非交互默认:有缓存用缓存,否则最新
    if ($interactive) {
        $labels = @($choices | ForEach-Object { $_.Label })
        $i = Select-SingleChoice -Options $labels -DefaultIndex 0 -Prompt "Claude Code 版本(默认 $defaultLabel)"
        $pick = $choices[$i]
    }

    if ($pick.Ver -like 'cached:*') {
        Write-Ok "Claude Code 沿用缓存 v$($pick.Ver.Split(':')[1])"
    } else {
        $ccVer = $pick.Ver
        if ($ccVer -eq 'manual') {
            while ($true) {
                $ccVer = (Read-Host '输入 Claude Code 版本(如 2.1.239)').Trim()
                if ($ccVer -match '^\d+\.\d+\.\d+$') { break }
                Write-Warn "格式应为 X.Y.Z,当前输入: $ccVer"
            }
        }
        $pkgSuffix = if ($ccVer -eq 'latest') { '' } else { "@$ccVer" }
        $npm = Get-Command npm -ErrorAction SilentlyContinue
        if (-not $npm) {
            Write-Err "宿主机没装 npm。装 Node 后重试"
            exit 1
        }
        Write-Step "npm pack @anthropic-ai/claude-code-linux-x64$pkgSuffix(原生二进制,~93MB,慢)..."
        try {
            $packed = Invoke-NpmPack -Pkg "@anthropic-ai/claude-code-linux-x64$pkgSuffix"
            $size = [math]::Round((Get-Item $packed).Length / 1MB, 1)
            Write-Ok "打包完成:$(Split-Path $packed -Leaf) ($size MB)"
        } catch {
            Write-Err $_.Exception.Message
            exit 1
        }
    }
    # 换版本清旧:以最终留在目录里的最新文件为基准,删其它版本
    $keepCc = Get-ChildItem $bundleDir -Filter $ccPattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($keepCc -and $keepCc.Name -match 'claude-code-linux-x64-(\d+\.\d+\.\d+)\.tgz') {
        $keepVer = $Matches[1]
        Get-ChildItem $bundleDir -Filter $ccPattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch [regex]::Escape($keepVer) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 2. opencode(Linux 原生二进制,与 Claude Code 同构)----------
$ocPattern = 'opencode-linux-x64-*.tgz'
$existingOc = Get-ChildItem $bundleDir -Filter $ocPattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

# 宿主机 opencode 版本(菜单锚点;探测不到就不给该项)
$hostOcVer = $null
try {
    $v = (& opencode --version 2>$null | Select-Object -First 1)
    if ($v -match '(\d+\.\d+\.\d+)') { $hostOcVer = $Matches[1] }
} catch { }

if ((-not $Force) -and $existingOc) {
    Write-Ok "opencode 已存在:$($existingOc.Name)(用 -Force 重选/重下)"
} else {
    $cachedOcVer = $null
    if ($existingOc -and $existingOc.Name -match 'opencode-linux-x64-(\d+\.\d+\.\d+)\.tgz') { $cachedOcVer = $Matches[1] }
    $recentOc = @()
    if ($interactive) {
        try {
            $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
            if (-not $npmCmd) { throw 'npm.cmd 不在 PATH' }
            $out = & $npmCmd view opencode-ai versions --json 2>$null
            # PS 5.1 多行 JSON 坑:先 -join 回完整文本再 ConvertFrom-Json(详见 Claude Code 段注释)
            $vers = ConvertFrom-Json ($out -join "`n")
            $recentOc = @($vers | Where-Object { "$_" -notmatch '-' } | Select-Object -Last 5)
            [array]::Reverse($recentOc)
        } catch {
            Write-Warn "拉取 opencode 版本列表失败(离线?只提供 默认/宿主一致/手动)"
        }
    }
    $ocChoices = @()
    if ($cachedOcVer) {
        $ocChoices += @{ Label = "保持缓存版本 v$cachedOcVer(不重新下载)"; Ver = "cached:$cachedOcVer" }
        $ocDefaultLabel = "v$cachedOcVer(保持缓存)"
    } else {
        $ocChoices += @{ Label = '最新版(latest)'; Ver = 'latest' }
        $ocDefaultLabel = 'latest'
    }
    foreach ($v in ($recentOc | Where-Object { $_ -ne $cachedOcVer })) { $ocChoices += @{ Label = "$v"; Ver = $v } }
    if ($hostOcVer -and $hostOcVer -ne $cachedOcVer) { $ocChoices += @{ Label = "与宿主机一致 v$hostOcVer"; Ver = $hostOcVer } }
    $ocChoices += @{ Label = '手动输入版本号'; Ver = 'manual' }

    $ocPick = $ocChoices[0]   # 非交互默认:有缓存用缓存,否则最新
    if ($interactive) {
        $labels = @($ocChoices | ForEach-Object { $_.Label })
        $i = Select-SingleChoice -Options $labels -DefaultIndex 0 -Prompt "opencode 版本(默认 $ocDefaultLabel)"
        $ocPick = $ocChoices[$i]
    }

    if ($ocPick.Ver -like 'cached:*') {
        Write-Ok "opencode 沿用缓存 v$($ocPick.Ver.Split(':')[1])"
    } else {
        $ocVer = $ocPick.Ver
        if ($ocVer -eq 'manual') {
            while ($true) {
                $ocVer = (Read-Host '输入 opencode 版本(如 1.18.25)').Trim()
                if ($ocVer -match '^\d+\.\d+\.\d+$') { break }
                Write-Warn "格式应为 X.Y.Z,当前输入: $ocVer"
            }
        }
        $ocSuffix = if ($ocVer -eq 'latest') { '' } else { "@$ocVer" }
        $npm = Get-Command npm -ErrorAction SilentlyContinue
        if (-not $npm) {
            Write-Err "宿主机没装 npm。装 Node 后重试"
            exit 1
        }
        Write-Step "npm pack opencode-linux-x64$ocSuffix(原生二进制,~60MB,慢)..."
        try {
            $packed = Invoke-NpmPack -Pkg "opencode-linux-x64$ocSuffix"
            $size = [math]::Round((Get-Item $packed).Length / 1MB, 1)
            Write-Ok "打包完成:$(Split-Path $packed -Leaf) ($size MB)"
        } catch {
            Write-Err $_.Exception.Message
            exit 1
        }
    }
    # 换版本清旧
    $keepOc = Get-ChildItem $bundleDir -Filter $ocPattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($keepOc -and $keepOc.Name -match 'opencode-linux-x64-(\d+\.\d+\.\d+)\.tgz') {
        $keepOcVer = $Matches[1]
        Get-ChildItem $bundleDir -Filter $ocPattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch [regex]::Escape($keepOcVer) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 3. cc-pocket Linux x86_64 ----------
Write-Step "查 cc-pocket daemon 版本..."
# 缓存版本直接取文件名(缺啥下啥;-Force 或无缓存才需要解析/选择)
$cachedAsset = Get-ChildItem (Join-Path $bundleDir 'cc-pocket') -Filter 'cc-pocket-daemon-*-linux-x86_64.tar.gz' -ErrorAction SilentlyContinue |
    Select-Object -First 1
$cachedPocketVer = $null
if ($cachedAsset -and $cachedAsset.Name -match '^cc-pocket-daemon-(.+)-linux-x86_64\.tar\.gz$') {
    $cachedPocketVer = $Matches[1]
}

function Resolve-LatestCcPocketVersion {
    # Avoid GitHub API rate limits: releases/latest redirects to the tag without API access.
    try {
        $request = [System.Net.HttpWebRequest]::Create('https://github.com/heypandax/cc-pocket/releases/latest')
        $request.AllowAutoRedirect = $false
        $response = $request.GetResponse()
        $location = $response.Headers['Location']
        $response.Close()
        if ($location -notmatch '/tag/([^/?#]+)') { throw '无法从 releases/latest 重定向地址解析版本' }
        return $Matches[1].TrimStart('v')
    } catch {
        throw "无法解析 cc-pocket 最新版本（已避开 GitHub API 限流）: $($_.Exception.Message)"
    }
}

$ccVersion = $null
if ((-not $Force) -and $cachedPocketVer) {
    $ccVersion = $cachedPocketVer
    Write-Ok "cc-pocket 已缓存,版本取自文件名: v$ccVersion(用 -Force 重选/重下)"
} else {
    $pickVer = if ($cachedPocketVer) { "cached:$cachedPocketVer" } else { 'latest' }
    if ($interactive) {
        $choices = @()
        $dflt = 0
        if ($cachedPocketVer) {
            $choices += @{ Label = "保持缓存版本 v$cachedPocketVer(不重新下载)"; Ver = "cached:$cachedPocketVer" }
        }
        $choices += @{ Label = '最新版(latest,需访问 GitHub)'; Ver = 'latest' }
        $choices += @{ Label = '手动输入版本号'; Ver = 'manual' }
        if (-not $cachedPocketVer) { $dflt = 0 } else { $dflt = 0 }
        $labels = @($choices | ForEach-Object { $_.Label })
        $i = Select-SingleChoice -Options $labels -DefaultIndex $dflt -Prompt 'cc-pocket 版本'
        $pickVer = $choices[$i].Ver
    }
    if ($pickVer -like 'cached:*') {
        $ccVersion = $pickVer.Split(':')[1]
    } elseif ($pickVer -eq 'manual') {
        while ($true) {
            $v = (Read-Host '输入 cc-pocket 版本(如 1.8.1)').Trim().TrimStart('v')
            if ($v -match '^\d+\.\d+\.\d+$') { $ccVersion = $v; break }
            Write-Warn "格式应为 X.Y.Z,当前输入: $v"
        }
    } else {
        $ccVersion = Resolve-LatestCcPocketVersion
    }
}

$ccAsset = "cc-pocket-daemon-$ccVersion-linux-x86_64.tar.gz"
$ccDir = Join-Path $bundleDir 'cc-pocket'
$ccPath = Join-Path $ccDir $ccAsset
if (-not (Test-Path $ccPath)) {
    New-Item -ItemType Directory -Path $ccDir -Force | Out-Null
    $ccUrl = "https://github.com/heypandax/cc-pocket/releases/download/v$ccVersion/$ccAsset"
    Write-Step "下载 $ccUrl..."
    Invoke-WebRequest -Uri $ccUrl -OutFile $ccPath -TimeoutSec 600 -UseBasicParsing
}
# 换版本清旧
Get-ChildItem $ccDir -Filter 'cc-pocket-daemon-*-linux-x86_64.tar.gz' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $ccAsset } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$ccShaPath = Join-Path $ccDir 'SHA256SUMS'
# 从 sums 文件里取该 tarball 的期望哈希(兼容 * 二进制模式前缀),无文件/无条目返 $null
function Get-ExpectedCcHash {
    param([string]$SumsPath, [string]$Asset)
    if (-not (Test-Path $SumsPath)) { return $null }
    foreach ($line in (Get-Content $SumsPath)) {
        if ($line -match "^\s*([0-9a-fA-F]{64})\s+\*?\s*$([regex]::Escape($Asset))\s*$") { return $Matches[1].ToLower() }
    }
    return $null
}
# 校验 tarball 完整性(root 解压进 VM 的三方二进制,必须验)。
# 缓存优先:本地 sums 有条目且哈希匹配 → 离线通过;本地缺文件/缺条目(版本更新后旧 sums 没新条目)
# → 联网重下 sums;本地有条目但哈希不符 = tarball 坏,直接删文件退出,不联网(sums 是权威基准)
$expectedHash = Get-ExpectedCcHash -SumsPath $ccShaPath -Asset $ccAsset
$actualHash = (Get-FileHash $ccPath -Algorithm SHA256).Hash.ToLower()
if (-not $expectedHash) {
    Invoke-WebRequest -Uri "https://github.com/heypandax/cc-pocket/releases/download/v$ccVersion/SHA256SUMS" -OutFile $ccShaPath -TimeoutSec 60 -UseBasicParsing
    $expectedHash = Get-ExpectedCcHash -SumsPath $ccShaPath -Asset $ccAsset
    if (-not $expectedHash) { Write-Err "SHA256SUMS 里找不到 $ccAsset 的条目"; exit 1 }
}
if ($expectedHash -ne $actualHash) {
    Write-Err "cc-pocket SHA256 校验失败: $ccAsset"
    Write-Err "  期望 $expectedHash"
    Write-Err "  实际 $actualHash(已删坏文件,重跑本脚本会重新下载)"
    Remove-Item $ccPath -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Ok "cc-pocket SHA256 校验通过"
Write-Ok "cc-pocket bundle 就绪:$ccAsset"

# ---------- 4. 可选开发环境组件(JDK/Maven/SDKMAN/uv/pnpm/Node)----------
# 与核心件同构的版本菜单,差别:非交互且无缓存 → 跳过不下载(可选件不自动下大包,
# 要装就在交互终端跑一次本脚本)。镜像刻意选国内源:Adoptium/uv 官方都在 GitHub(常不可达)。

# 可选件下载(TLS1.2;失败 warn 不退出——留给下次重跑或 start 在线兜底)
function Save-OptionalFile {
    param([string]$Url, [string]$OutPath, [string]$Label)
    New-Item -ItemType Directory -Path (Split-Path $OutPath) -Force | Out-Null
    Write-Step "下载 $Url..."
    $proto = [System.Net.ServicePointManager]::SecurityProtocol
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -TimeoutSec 900 -UseBasicParsing
        $size = [math]::Round((Get-Item $OutPath).Length / 1MB, 1)
        Write-Ok "$Label 下载完成:$(Split-Path $OutPath -Leaf) ($size MB)"
        return $true
    } catch {
        Write-Warn "$Label 下载失败:$($_.Exception.Message)(已跳过;重跑再试或交互选其它版本)"
        if (Test-Path $OutPath) { Remove-Item $OutPath -Force -ErrorAction SilentlyContinue }
        return $false
    } finally {
        [System.Net.ServicePointManager]::SecurityProtocol = $proto
    }
}

# 可选件版本选择:返回 "cached:<ver>" / "skip" / 版本串(含手动输入)。
# 非交互:有缓存保持缓存,无缓存跳过(交互才弹菜单;默认项 = 首项)
function Select-OptionalComponentVersion {
    param([string]$Prompt, [string]$CachedVer, [string[]]$Recent = @(), [string]$ManualPattern, [string]$ManualExample)
    if (-not $interactive) {
        if ($CachedVer) { return "cached:$CachedVer" }
        return 'skip'
    }
    $choices = @()
    if ($CachedVer) { $choices += @{ Label = "保持缓存版本 $CachedVer(不重新下载)"; Ver = "cached:$CachedVer" } }
    $choices += @{ Label = '跳过(本次不装/不更新)'; Ver = 'skip' }
    foreach ($v in ($Recent | Where-Object { $_ -ne $CachedVer })) { $choices += @{ Label = "$v"; Ver = $v } }
    $choices += @{ Label = '手动输入版本号'; Ver = 'manual' }
    $labels = @($choices | ForEach-Object { $_.Label })
    $i = Select-SingleChoice -Options $labels -DefaultIndex 0 -Prompt $Prompt
    $pick = $choices[$i].Ver
    if ($pick -eq 'manual') {
        while ($true) {
            # Read-Host 异常兜底:同 Select-SingleChoice(见 feature-menu.ps1)
            try { $v = Read-Host "输入版本(如 $ManualExample)" } catch { $v = $null }
            $v = if ($null -ne $v) { "$v".Trim() } else { '' }
            if ($v -match $ManualPattern) { return $v }
            Write-Warn "格式不符(应为形如 $ManualExample),当前输入: $v"
        }
    }
    return $pick
}

# --- JDK 17(Adoptium Temurin tarball,清华镜像;~190MB)---
$jdkDir = Join-Path $bundleDir 'jdk'
$tunaJdkBase = 'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux'
$cachedJdk = Get-ChildItem $jdkDir -Filter 'OpenJDK17U-jdk_x64_linux_hotspot_*.tar.gz' -ErrorAction SilentlyContinue | Select-Object -First 1
$cachedJdkVer = $null
if ($cachedJdk -and $cachedJdk.Name -match 'hotspot_(\d+(?:\.\d+)+)_(\d+)\.tar\.gz') { $cachedJdkVer = "$($Matches[1])+$($Matches[2])" }

if ((-not $Force) -and $cachedJdk) {
    Write-Ok "JDK 17 已缓存:$($cachedJdk.Name)(用 -Force 重选/重下)"
} else {
    $recentJdk = @()
    if ($interactive) {
        try {
            $html = (Invoke-WebRequest -Uri "$tunaJdkBase/" -TimeoutSec 30 -UseBasicParsing).Content
            $recentJdk = @([regex]::Matches($html, 'OpenJDK17U-jdk_x64_linux_hotspot_(\d+(?:\.\d+)+)_(\d+)\.tar\.gz') |
                ForEach-Object { "$($_.Groups[1].Value)+$($_.Groups[2].Value)" } |
                Sort-Object -Property @{ e = { [version]($_ -split '\+')[0] } }, @{ e = { [int]($_ -split '\+')[1] } } -Descending |
                Select-Object -Unique -First 5)
        } catch { Write-Warn "拉取 JDK 版本列表失败(离线?):$($_.Exception.Message)" }
    }
    $pick = Select-OptionalComponentVersion -Prompt 'JDK 17(Adoptium,清华镜像;装进 VM 的 SDKMAN)' -CachedVer $cachedJdkVer -Recent $recentJdk -ManualPattern '^\d+(\.\d+)+\+\d+$' -ManualExample '17.0.20.1+1'
    if ($pick -like 'cached:*') {
        Write-Ok "JDK 17 沿用缓存 $($pick.Split(':', 2)[1])"
    } elseif ($pick -eq 'skip') {
        Write-Host '    --  JDK 17:跳过(未缓存;start 勾选 dev-java 时在线兜底)' -ForegroundColor DarkGray
    } else {
        $file = "OpenJDK17U-jdk_x64_linux_hotspot_$($pick -replace '\+', '_').tar.gz"
        if (Save-OptionalFile -Url "$tunaJdkBase/$file" -OutPath (Join-Path $jdkDir $file) -Label 'JDK 17') {
            Get-ChildItem $jdkDir -Filter 'OpenJDK17U-*.tar.gz' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $file } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Maven(bin tarball,阿里云 apache 镜像;~9MB;镜像只留各系列最新,旧版本用手动+archive)---
$mvnDir = Join-Path $bundleDir 'maven'
$aliyunMvnBase = 'https://mirrors.aliyun.com/apache/maven/maven-3'
$cachedMvn = Get-ChildItem $mvnDir -Filter 'apache-maven-*-bin.tar.gz' -ErrorAction SilentlyContinue | Select-Object -First 1
$cachedMvnVer = $null
if ($cachedMvn -and $cachedMvn.Name -match '^apache-maven-(\d+\.\d+\.\d+)-bin\.tar\.gz$') { $cachedMvnVer = $Matches[1] }

if ((-not $Force) -and $cachedMvn) {
    Write-Ok "Maven 已缓存:$($cachedMvn.Name)(用 -Force 重选/重下)"
} else {
    $recentMvn = @()
    if ($interactive) {
        try {
            $html = (Invoke-WebRequest -Uri "$aliyunMvnBase/" -TimeoutSec 30 -UseBasicParsing).Content
            $recentMvn = @([regex]::Matches($html, '(\d+\.\d+\.\d+)/') | ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Property { [version]$_ } -Descending | Select-Object -Unique -First 5)
        } catch { Write-Warn "拉取 Maven 版本列表失败(离线?):$($_.Exception.Message)" }
    }
    $pick = Select-OptionalComponentVersion -Prompt 'Maven(阿里云镜像;装进 VM 的 SDKMAN)' -CachedVer $cachedMvnVer -Recent $recentMvn -ManualPattern '^\d+\.\d+\.\d+$' -ManualExample '3.9.16'
    if ($pick -like 'cached:*') {
        Write-Ok "Maven 沿用缓存 $($pick.Split(':', 2)[1])"
    } elseif ($pick -eq 'skip') {
        Write-Host '    --  Maven:跳过(未缓存;start 勾选 dev-java 时在线兜底)' -ForegroundColor DarkGray
    } else {
        $file = "apache-maven-$pick-bin.tar.gz"
        if (Save-OptionalFile -Url "$aliyunMvnBase/$pick/binaries/$file" -OutPath (Join-Path $mvnDir $file) -Label 'Maven') {
            Get-ChildItem $mvnDir -Filter 'apache-maven-*-bin.tar.gz' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $file } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- uv(PyPI wheel,清华镜像;~35MB;VM 内解出二进制)---
$uvDir = Join-Path $bundleDir 'uv'
$tunaPypiJson = 'https://pypi.tuna.tsinghua.edu.cn/pypi/uv/json'
$cachedUv = Get-ChildItem $uvDir -Filter 'uv-*.whl' -ErrorAction SilentlyContinue | Select-Object -First 1
$cachedUvVer = $null
if ($cachedUv -and $cachedUv.Name -match '^uv-(\d+\.\d+\.\d+)-') { $cachedUvVer = $Matches[1] }

if ((-not $Force) -and $cachedUv) {
    Write-Ok "uv 已缓存:$($cachedUv.Name)(用 -Force 重选/重下)"
} else {
    $uvJson = $null
    $recentUv = @()
    if ($interactive) {
        try {
            $uvJson = Invoke-RestMethod -Uri $tunaPypiJson -TimeoutSec 30
            $recentUv = @($uvJson.releases.PSObject.Properties.Name |
                Where-Object { $_ -notmatch '[a-zA-Z]' } |
                Sort-Object -Property { [version]$_ } -Descending | Select-Object -First 5)
        } catch { Write-Warn "拉取 uv 版本列表失败(离线?):$($_.Exception.Message)" }
    }
    $pick = Select-OptionalComponentVersion -Prompt 'uv(清华 PyPI 镜像)' -CachedVer $cachedUvVer -Recent $recentUv -ManualPattern '^\d+\.\d+\.\d+$' -ManualExample '0.8.6'
    if ($pick -like 'cached:*') {
        Write-Ok "uv 沿用缓存 $($pick.Split(':', 2)[1])"
    } elseif ($pick -eq 'skip') {
        Write-Host '    --  uv:跳过(未缓存;start 勾选 dev-python 时在线兜底)' -ForegroundColor DarkGray
    } else {
        # 版本 → manylinux x86_64 wheel 的直链(tuna 与 pythonhosted 路径结构一致,换前缀即可)
        $uvUrl = $null; $uvFile = $null
        try {
            if (-not $uvJson) { $uvJson = Invoke-RestMethod -Uri $tunaPypiJson -TimeoutSec 30 }
            $rel = $uvJson.releases.PSObject.Properties[$pick].Value
            $asset = @($rel) | Where-Object { $_.filename -match '^uv-.*-py3-none-manylinux.*x86_64.*\.whl$' } | Select-Object -First 1
            if ($asset) {
                $uvFile = $asset.filename
                $uvUrl = ($asset.url -replace '^https?://[^/]+', 'https://pypi.tuna.tsinghua.edu.cn')
            }
        } catch { Write-Warn "解析 uv $pick 的 wheel 下载地址失败:$($_.Exception.Message)" }
        if ($uvUrl) {
            if (Save-OptionalFile -Url $uvUrl -OutPath (Join-Path $uvDir $uvFile) -Label 'uv') {
                Get-ChildItem $uvDir -Filter 'uv-*.whl' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne $uvFile } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Warn "uv $pick 没有 manylinux x86_64 wheel(奇怪),已跳过"
        }
    }
}

# --- pnpm(独立二进制:@pnpm/linux-x64 平台包,自含运行时,与 node 版本解耦;~26MB)---
# 不再用 pnpm 的 npm JS 包(需 node 才能跑);独立二进制直接放 /usr/local/bin,
# 项目内多版本由 pnpm 自己管(packageManager 字段 + manage-package-manager-versions)。
$pnpmDir = Join-Path $bundleDir 'pnpm'
$cachedPnpm = Get-ChildItem $pnpmDir -Filter 'pnpm-linux-x64-*.tgz' -ErrorAction SilentlyContinue | Select-Object -First 1
$cachedPnpmVer = $null
if ($cachedPnpm -and $cachedPnpm.Name -match '^pnpm-linux-x64-(\d+\.\d+\.\d+)\.tgz$') { $cachedPnpmVer = $Matches[1] }

if ((-not $Force) -and $cachedPnpm) {
    Write-Ok "pnpm 独立二进制已缓存:$($cachedPnpm.Name)(用 -Force 重选/重下)"
} else {
    # 旧架构残留:JS 包 tgz(pnpm-X.Y.Z.tgz)不再使用
    Get-ChildItem $pnpmDir -Filter 'pnpm-*.tgz' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^pnpm-linux-x64-' } |
        ForEach-Object { Write-Warn "清理旧架构残留(pnpm JS 包不再使用):$($_.Name)"; Remove-Item $_.FullName -Force }
    $recentPnpm = @()
    if ($interactive) {
        try {
            $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
            if (-not $npmCmd) { throw 'npm.cmd 不在 PATH' }
            $out = & $npmCmd view '@pnpm/linux-x64' versions --json 2>$null
            $vers = ConvertFrom-Json ($out -join "`n")
            # 只列 10 系:项目侧 Node 由 nvm 管,10 系为当前默认大版本(要 11 系手动输入)
            $recentPnpm = @($vers | Where-Object { "$_" -match '^10\.' -and "$_" -notmatch '-' } | Select-Object -Last 5)
            [array]::Reverse($recentPnpm)
        } catch { Write-Warn "拉取 pnpm 版本列表失败(离线?):$($_.Exception.Message)" }
    }
    $pick = Select-OptionalComponentVersion -Prompt 'pnpm 独立二进制(@pnpm/linux-x64,10 系)' -CachedVer $cachedPnpmVer -Recent $recentPnpm -ManualPattern '^\d+\.\d+\.\d+$' -ManualExample '10.34.5'
    if ($pick -like 'cached:*') {
        Write-Ok "pnpm 沿用缓存 $($pick.Split(':', 2)[1])"
    } elseif ($pick -eq 'skip') {
        Write-Host '    --  pnpm:跳过(未缓存;start 勾选 dev-frontend 时在线兜底)' -ForegroundColor DarkGray
    } else {
        try {
            $packed = Invoke-NpmPack -Pkg "@pnpm/linux-x64@$pick"
            New-Item -ItemType Directory -Path $pnpmDir -Force | Out-Null
            Move-Item $packed (Join-Path $pnpmDir (Split-Path $packed -Leaf)) -Force
            Get-ChildItem $pnpmDir -Filter 'pnpm-linux-x64-*.tgz' | Where-Object { $_.Name -ne (Split-Path $packed -Leaf) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Ok "pnpm 独立二进制打包完成:$(Split-Path $packed -Leaf)"
        } catch {
            Write-Warn "pnpm 打包失败:$($_.Exception.Message)(已跳过)"
        }
    }
}

# --- Node(nvm 预置用;多版本并存于 bundle/node/;nodejs.org 官方源)---
$nodeDefault = 'v20.20.2'   # 实测锁定版,恒为默认
function Save-NodeTarball {
    param([string]$Ver)
    $file = "node-$Ver-linux-x64.tar.xz"
    $out = Join-Path $nodeDir $file
    if (Test-Path $out) { Write-Ok "Node $Ver 已在缓存"; return $true }
    return (Save-OptionalFile -Url "https://nodejs.org/dist/$Ver/$file" -OutPath $out -Label "Node $Ver")
}

$cachedNodes = @(Get-ChildItem $nodeDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue | Sort-Object Name)
# 版本索引(交互才拉;默认版 + 最近 20.x/22.x 各 5 个 LTS)
$nodeRecent20 = @(); $nodeRecent22 = @()
if ($interactive) {
    try {
        $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
        $nodeRecent20 = @($idx | Where-Object { $_.version -match '^v20\.' -and $null -ne $_.lts } | Select-Object -First 5 | ForEach-Object { $_.version })
        $nodeRecent22 = @($idx | Where-Object { $_.version -match '^v22\.' -and $null -ne $_.lts } | Select-Object -First 5 | ForEach-Object { $_.version })
    } catch { Write-Warn "拉取 Node 版本索引失败(离线?只提供默认+手动输入): $($_.Exception.Message)" }
}

if ((-not $Force) -and $cachedNodes.Count -gt 0) {
    Write-Ok "Node 已缓存:$($cachedNodes.Name -join ', ')(多版本并存;-Force 重选/追加)"
} else {
    $nodeChoice = $nodeDefault
    if ($interactive) {
        $options = @()
        if ($nodeRecent20 -notcontains $nodeDefault) { $options += $nodeDefault }
        $options += $nodeRecent20
        $options += '(手动输入版本号)'
        $i = Select-SingleChoice -Options $options `
            -DefaultIndex ([array]::IndexOf($options, $nodeDefault)) `
            -Prompt "Node 版本(默认 $nodeDefault;多版本并存,稍后可追加)"
        if ($options[$i] -like '(手动输入*)') {
            while ($true) {
                $v = (Read-Host '输入 Node 版本(如 v22.14.0)').Trim()
                if ($v -match '^v\d+\.\d+\.\d+$') { $nodeChoice = $v; break }
                Write-Warn "格式应为 vX.Y.Z,当前输入: $v"
            }
        } else {
            $nodeChoice = $options[$i]
        }
    }
    [void](Save-NodeTarball -Ver $nodeChoice)
}

# 追加第二个 Node 版本(交互才有;默认跳过;已缓存的版本不再列出)
if ($interactive -and (Get-ChildItem $nodeDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
    $have = @(Get-ChildItem $nodeDir -Filter 'node-v*-linux-x64.tar.xz' | ForEach-Object { if ($_.Name -match '^node-(v[\d.]+)-linux') { $Matches[1] } })
    $extraOpts = @($nodeRecent22 + @($nodeRecent20) | Where-Object { $have -notcontains $_ } | Select-Object -Unique -First 8)
    $options = @($extraOpts) + @('(手动输入版本号)') + @('(跳过,不追加)')
    $i = Select-SingleChoice -Options $options -DefaultIndex ($options.Count - 1) -Prompt '追加另一个 Node 版本?(默认跳过)'
    if ($options[$i] -like '(手动输入*)') {
        while ($true) {
            $v = (Read-Host '输入 Node 版本(如 v22.14.0)').Trim()
            if ($v -match '^v\d+\.\d+\.\d+$') { [void](Save-NodeTarball -Ver $v); break }
            Write-Warn "格式应为 vX.Y.Z,当前输入: $v"
        }
    } elseif ($options[$i] -notlike '(跳过*') {
        [void](Save-NodeTarball -Ver $options[$i])
    }
} elseif (-not $interactive -and $cachedNodes.Count -eq 0) {
    Write-Host '    --  Node:跳过(未缓存;start 勾选 dev-frontend 时在线兜底 npmmirror)' -ForegroundColor DarkGray
}

# --- SDKMAN(cli + native 两 zip;broker 302→GitHub release,GitHub 不通走 ghfast.top)---
# 版本发现:get.sdkman.io 的 bootstrap 脚本内嵌最新 SDKMAN_VERSION / SDKMAN_NATIVE_VERSION。
# 下载:api.sdkman.io broker 只做 302 → GitHub release 直链;直链失败(常不可达)换
# ghfast.top 镜像前缀重试。cli 与 native 版本号独立(5.23.0 / 0.7.34),无手动输入项。
$sdkDir = Join-Path $bundleDir 'sdkman'
$cachedSdkCli = Get-ChildItem $sdkDir -Filter 'sdkman-cli-*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
$cachedSdkNative = Get-ChildItem $sdkDir -Filter 'sdkman-native-*-linuxx64.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
$cachedSdkCliVer = $null; $cachedSdkNativeVer = $null
if ($cachedSdkCli -and $cachedSdkCli.Name -match '^sdkman-cli-([\d.]+)\.zip$') { $cachedSdkCliVer = $Matches[1] }
if ($cachedSdkNative -and $cachedSdkNative.Name -match '^sdkman-native-([\d.]+)-linuxx64\.zip$') { $cachedSdkNativeVer = $Matches[1] }

# 候选名单 CSV(api.sdkman.io,~600B 小文本):sdkman-init.sh 硬依赖(缺文件直接报错),
# 缺了就补;拉不到写兜底名单 java,maven(离线装 JDK/Maven 不受影响)
$candidatesCsv = Join-Path $sdkDir 'candidates.csv'
if (-not (Test-Path $candidatesCsv)) {
    New-Item -ItemType Directory -Path $sdkDir -Force | Out-Null
    try {
        Invoke-WebRequest -Uri 'https://api.sdkman.io/2/candidates/all' -OutFile $candidatesCsv -TimeoutSec 30 -UseBasicParsing
        Write-Ok "SDKMAN 候选名单已下载:sdkman\candidates.csv"
    } catch {
        Write-Warn "SDKMAN 候选名单下载失败,写兜底名单 java,maven:$($_.Exception.Message)"
        'java,maven' | Out-File -FilePath $candidatesCsv -Encoding ascii -Force
    }
}

# bootstrap 内嵌 export SDKMAN_VERSION="X" / SDKMAN_NATIVE_VERSION="Y",用 [regex]::Match
# 显式解析两次(-match 的 $Matches 会被后一次覆盖,不能连用)
function Resolve-LatestSdkmanVersions {
    try {
        $bs = (Invoke-WebRequest -Uri 'https://get.sdkman.io?raw=true' -TimeoutSec 30 -UseBasicParsing).Content
        $cli = [regex]::Match($bs, 'SDKMAN_VERSION="([\d.]+)"').Groups[1].Value
        $native = [regex]::Match($bs, 'SDKMAN_NATIVE_VERSION="([\d.]+)"').Groups[1].Value
        if (-not $cli -or -not $native) { throw 'bootstrap 里解析不到版本号' }
        return @{ Cli = $cli; Native = $native }
    } catch {
        throw "无法解析 SDKMAN 最新版本: $($_.Exception.Message)"
    }
}

function Save-SdkmanZip {
    # $Kind: 'sdkman' 或 'native';broker 302 出 GitHub 直链,直链不通走 ghfast.top
    param([string]$Kind, [string]$Version, [string]$OutPath, [string]$Label)
    $broker = "https://api.sdkman.io/2/broker/download/$Kind/install/$Version/linuxx64"
    try {
        $request = [System.Net.HttpWebRequest]::Create($broker)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        $response = $request.GetResponse()
        $ghUrl = $response.Headers['Location']
        $response.Close()
        if (-not $ghUrl) { throw 'broker 没给出重定向地址' }
    } catch {
        Write-Warn "$Label broker 解析失败:$($_.Exception.Message)(已跳过)"
        return $false
    }
    Write-Step "下载 $ghUrl(GitHub 直链)..."
    if (Save-OptionalFile -Url $ghUrl -OutPath $OutPath -Label $Label) { return $true }
    Write-Step "直链失败,改走 ghfast.top 镜像..."
    $mirror = "https://ghfast.top/$ghUrl"
    return (Save-OptionalFile -Url $mirror -OutPath $OutPath -Label $Label)
}

if ((-not $Force) -and $cachedSdkCli -and $cachedSdkNative) {
    Write-Ok "SDKMAN 已缓存:cli $cachedSdkCliVer + native $cachedSdkNativeVer(用 -Force 重选/重下)"
} else {
    $pick = 'skip'
    if ($interactive) {
        $choices = @()
        if ($cachedSdkCliVer -and $cachedSdkNativeVer) {
            $choices += @{ Label = "保持缓存版本 cli $cachedSdkCliVer / native $cachedSdkNativeVer"; Ver = 'cached' }
        }
        $choices += @{ Label = '最新版(解析 get.sdkman.io)'; Ver = 'latest' }
        $choices += @{ Label = '跳过(本次不装/不更新)'; Ver = 'skip' }
        $labels = @($choices | ForEach-Object { $_.Label })
        $i = Select-SingleChoice -Options $labels -DefaultIndex 0 -Prompt 'SDKMAN(cli + native,java 版本管理)'
        $pick = $choices[$i].Ver
    } elseif ($cachedSdkCliVer -and $cachedSdkNativeVer) {
        $pick = 'cached'
    }

    if ($pick -eq 'cached') {
        Write-Ok "SDKMAN 沿用缓存 cli $cachedSdkCliVer / native $cachedSdkNativeVer"
    } elseif ($pick -eq 'skip') {
        Write-Host '    --  SDKMAN:跳过(未缓存;start 勾选 dev-java 时在线兜底)' -ForegroundColor DarkGray
    } else {
        try {
            $latest = Resolve-LatestSdkmanVersions
        } catch {
            Write-Warn "$($_.Exception.Message)(SDKMAN 跳过)"
            $latest = $null
        }
        if ($latest) {
            $cliOk = $false; $nativeOk = $false
            if ((-not $cachedSdkCliVer) -or $cachedSdkCliVer -ne $latest.Cli) {
                $cliOk = Save-SdkmanZip -Kind 'sdkman' -Version $latest.Cli `
                    -OutPath (Join-Path $sdkDir "sdkman-cli-$($latest.Cli).zip") -Label 'SDKMAN cli'
            } else { $cliOk = $true }
            if ((-not $cachedSdkNativeVer) -or $cachedSdkNativeVer -ne $latest.Native) {
                $nativeOk = Save-SdkmanZip -Kind 'native' -Version $latest.Native `
                    -OutPath (Join-Path $sdkDir "sdkman-native-$($latest.Native)-linuxx64.zip") -Label 'SDKMAN native'
            } else { $nativeOk = $true }
            # 换版本清旧(两件都拿到新版本才清,防半套)
            $newCli = Get-ChildItem $sdkDir -Filter 'sdkman-cli-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
            $newNative = Get-ChildItem $sdkDir -Filter 'sdkman-native-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
            if ($cliOk -and $newCli) {
                Get-ChildItem $sdkDir -Filter 'sdkman-cli-*.zip' | Where-Object { $_.Name -ne $newCli.Name } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            if ($nativeOk -and $newNative) {
                Get-ChildItem $sdkDir -Filter 'sdkman-native-*.zip' | Where-Object { $_.Name -ne $newNative.Name } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------- 5. 状态汇总 ----------
Write-Step "bundle 状态:"
$ccOk  = Get-ChildItem $bundleDir -Filter $ccPattern -ErrorAction SilentlyContinue | Select-Object -First 1
$ocOk  = Get-ChildItem $bundleDir -Filter $ocPattern -ErrorAction SilentlyContinue | Select-Object -First 1

if ($ccOk) { Write-Ok "Claude 原生二进制: $($ccOk.Name)" }   else { Write-Err "Claude 原生二进制: 缺" }
if ($ocOk) { Write-Ok "opencode 原生二进制:$($ocOk.Name)" } else { Write-Err "opencode 原生二进制:缺" }

$ccPocketOk = @(Get-ChildItem (Join-Path $bundleDir 'cc-pocket') -Filter 'cc-pocket-daemon-*-linux-x86_64.tar.gz' -ErrorAction SilentlyContinue).Count -gt 0
if ($ccPocketOk) { Write-Ok "cc-pocket:        已准备" } else { Write-Err "cc-pocket:        缺" }

# 可选开发环境组件:缺了不算失败(交互终端重跑本脚本选装;start 勾选时在线兜底)
foreach ($opt in @(
    @{ Name = 'JDK 17';  Dir = 'jdk';     Pat = 'OpenJDK17U-jdk_x64_linux_hotspot_*.tar.gz' },
    @{ Name = 'Maven';   Dir = 'maven';   Pat = 'apache-maven-*-bin.tar.gz' },
    @{ Name = 'SDKMAN';  Dir = 'sdkman';  Pat = 'sdkman-cli-*.zip' },
    @{ Name = 'uv';      Dir = 'uv';      Pat = 'uv-*.whl' },
    @{ Name = 'pnpm';    Dir = 'pnpm';    Pat = 'pnpm-linux-x64-*.tgz' }
)) {
    $f = Get-ChildItem (Join-Path $bundleDir $opt.Dir) -Filter $opt.Pat -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { Write-Ok "$($opt.Name):$($f.Name)" }
    else    { Write-Host "    --  $($opt.Name):未缓存(可选)" -ForegroundColor DarkGray }
}
# SDKMAN native(与 cli 配对)
$sdkNativeOk = Get-ChildItem (Join-Path $bundleDir 'sdkman') -Filter 'sdkman-native-*-linuxx64.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sdkNativeOk) { Write-Ok "SDKMAN native:$($sdkNativeOk.Name)" }
elseif (Get-ChildItem (Join-Path $bundleDir 'sdkman') -Filter 'sdkman-cli-*.zip' -ErrorAction SilentlyContinue) {
    Write-Host "    --  SDKMAN native:未缓存(cli 有、native 缺,重跑补齐)" -ForegroundColor DarkGray
}
# Node(多版本)
$nodeFiles = @(Get-ChildItem $nodeDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue)
if ($nodeFiles.Count -gt 0) {
    Write-Ok "Node:             $($nodeFiles.Name -join ', ')"
} else {
    Write-Host "    --  Node:未缓存(可选,nvm 用)" -ForegroundColor DarkGray
}
# nvm(vendor 件)
$nvmOk = Get-ChildItem $nvmBundleDir -Filter 'nvm-v*.sh' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nvmOk) { Write-Ok "nvm:              $($nvmOk.Name)" }

if ($ccOk -and $ocOk -and $ccPocketOk) {
    $totalMB = [math]::Round(((Get-ChildItem $bundleDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
    Write-Host "bundle 就绪($totalMB MB,含可选件)。" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Err "bundle 不完整,launch.ps1 start 会直接报错(项目不支持在线降级)。补齐全后再启动"
    exit 1
}

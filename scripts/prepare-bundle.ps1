<#
.SYNOPSIS
    准备离线 bundle(Node 20 LTS + Claude Code + opencode + cc-pocket),让 VM 创建不依赖网络下载。

.PARAMETER Force
    重新选版本 + 重新下载(即使文件已存在)。
    不加时:文件已存在的组件直接沿用缓存,零交互零网络。

    版本选择(仅当该组件需要下载时才弹;非交互终端自动用默认):
      Node         默认 v20.20.2(实测锁定版,恒为默认,无"上次选择");
                   菜单实时列最近 5 个 20.x LTS + 手动输入
      Claude Code  默认最新版(latest);菜单另列最近 5 个正式版(npm 实时取)、
                   与宿主机一致(探测 claude --version)/ 保持缓存 / 手动输入
      opencode     默认最新版(latest,与平台包版本严格配对);菜单同 Claude Code
      cc-pocket    默认"保持缓存"(无缓存则最新)
    可选开发环境组件(JDK17/Maven/uv/pnpm,默认跳过,交互菜单选装;
    非交互且无缓存直接跳过不下载,要装就在交互终端跑一次):
      JDK 17   Adoptium Temurin tarball,清华镜像(~190MB)
      Maven    bin tarball,阿里云 apache 镜像(~9MB)
      uv       PyPI manylinux wheel,清华镜像(~35MB)
      pnpm     npm pack 本地 tgz(~9MB)
    切换版本会自动清掉 bundle 里的旧版本文件
    (install-bundle.sh 按 glob 装,不容忍多版本并存)。

.EXAMPLE
    .\scripts\prepare-bundle.ps1              # 缺啥下啥;缺的组件交互选版本(非交互用默认)
    .\scripts\prepare-bundle.ps1 -Force       # 重新选版本 + 全量重下

bundle 下载到状态目录 %USERPROFILE%\.cc-sandbox\bundle(写死,与 launch.ps1 同一位置),
不占用 skill 包目录。核心件(约 260 MB):
  - node-vXX.X.X-linux-x64.tar.xz          Node 20 LTS Linux 官方 tarball
  - anthropic-ai-claude-code-X.X.X.tgz     Claude Code wrapper 包(postinstall 装真二进制)
  - anthropic-ai-claude-code-linux-x64-X.X.X.tgz  Claude Code Linux 真二进制
  - opencode-ai-X.X.X.tgz                  opencode wrapper 包(optionalDependencies 装平台包)
  - opencode-linux-x64-X.X.X.tgz           opencode Linux 真二进制
  - cc-pocket/cc-pocket-daemon-X.X.X-linux-x86_64.tar.gz  cc-pocket 手机遥控(自带 JRE)
可选开发环境件(另约 240 MB,全选时):
  - jdk/OpenJDK17U-jdk_x64_linux_hotspot_17.0.X_Y.tar.gz
  - maven/apache-maven-X.X.X-bin.tar.gz
  - uv/uv-X.X.X-py3-none-manylinux_x86_64.whl
  - pnpm/pnpm-X.X.X.tgz
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

# ---------- 1. Node 20 LTS ----------
# 默认恒为 v20.20.2(实测锁定,无"上次选择");缓存文件本身就是状态——
# 不加 -Force 且文件在 → 直接沿用,不弹菜单不联网
$nodeDefault = 'v20.20.2'
$existingNode = Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ((-not $Force) -and $existingNode) {
    Write-Ok "Node 已存在:$($existingNode.Name)(用 -Force 重选/重下)"
} else {
    # 选版本:默认 v20.20.2 + 实时最近 5 个 20.x LTS + 手动输入
    $recent = @()
    if ($interactive) {
        try {
            $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
            $recent = @($idx | Where-Object { $_.version -match '^v20\.' -and $null -ne $_.lts } |
                Select-Object -First 5 | ForEach-Object { $_.version })
        } catch {
            Write-Warn "拉取 Node 版本索引失败(离线?只提供默认+手动输入): $($_.Exception.Message)"
        }
    }
    $nodeChoice = $nodeDefault
    if ($interactive) {
        $options = @()
        if ($recent -notcontains $nodeDefault) { $options += $nodeDefault }
        $options += $recent
        $options += '(手动输入版本号)'
        $i = Select-SingleChoice -Options $options `
            -DefaultIndex ([array]::IndexOf($options, $nodeDefault)) `
            -Prompt "Node 版本(默认 $nodeDefault)"
        if ($options[$i] -like '(手动输入*)') {
            while ($true) {
                $v = (Read-Host '输入 Node 版本(如 v20.19.1)').Trim()
                if ($v -match '^v20\.\d+\.\d+$') { $nodeChoice = $v; break }
                Write-Warn "格式应为 v20.x.y,当前输入: $v"
            }
        } else {
            $nodeChoice = $options[$i]
        }
    } else {
        if (-not $recent) { Write-Host "    Node 版本:非交互,用默认 $nodeDefault" -ForegroundColor DarkGray }
    }

    $nodeFile = "node-$nodeChoice-linux-x64.tar.xz"
    $nodePath = Join-Path $bundleDir $nodeFile
    $nodeUrl  = "https://nodejs.org/dist/$nodeChoice/$nodeFile"
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
    # 换版本清旧:删掉非当前版本的其他 node tarball
    Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $nodeFile } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------- 2. Claude Code(wrapper + Linux 真二进制)----------
$wrapperPattern = 'anthropic-ai-claude-code-*.tgz'
$linuxPattern   = 'anthropic-ai-claude-code-linux-x64-*.tgz'
# 排除 linux-x64:wrapper 文件名是 anthropic-ai-claude-code-X.X.X.tgz,linux 是 ...-linux-x64-X.X.X.tgz
$existingWrapper = Get-ChildItem $bundleDir -Filter $wrapperPattern -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'linux-x64' } | Sort-Object LastWriteTime -Desc | Select-Object -First 1
$existingLinux   = Get-ChildItem $bundleDir -Filter $linuxPattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Desc | Select-Object -First 1

# 宿主机 claude 版本(默认选项的锚点;探测不到就退回"最新")
$hostVer = $null
try {
    $v = (& claude --version 2>$null | Select-Object -First 1)
    if ($v -match '(\d+\.\d+\.\d+)') { $hostVer = $Matches[1] }
} catch { }

if ((-not $Force) -and $existingWrapper -and $existingLinux) {
    Write-Ok "Claude Code 已存在:$($existingWrapper.Name) / $($existingLinux.Name)(用 -Force 重选/重下)"
} else {
    # 选项与 Node 同构:默认项排第一 = 当前缓存版本,其后 npm 最近 5 个正式版。
    # 缓存两件套(wrapper+linux)齐全才给"保持缓存"——只剩一半时默认回"最新"重下补齐,避免坏包
    $cachedVer = $null
    if ($existingWrapper -and $existingLinux -and $existingWrapper.Name -match 'claude-code-(\d+\.\d+\.\d+)\.tgz') { $cachedVer = $Matches[1] }
    $recentCc = @()
    if ($interactive) {
        try {
            $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
            if (-not $npmCmd) { throw 'npm.cmd 不在 PATH' }
            $out = & $npmCmd view '@anthropic-ai/claude-code' versions --json 2>$null
            # 两个 PS 5.1 坑,叠加导致"最近 5 个"从来没生效过、菜单里出现空格拼接的巨串(实测):
            # 1) 多行 JSON 逐行管道进 ConvertFrom-Json,它把拼出的整个数组当"单个对象"返回;
            # 2) @(ConvertFrom-Json ...) 收集管道输出,同样只得 1 个嵌套数组对象。
            # 必须:先 -join 回完整文本、裸赋值(不加 @()),下游 "$vers | ..." 会自行枚举数组
            $vers = ConvertFrom-Json ($out -join "`n")
            # 过滤预发布(带 - 的),取最近 5 个正式版,倒序(新→旧,与 Node 菜单一致)
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
        Write-Step "npm pack @anthropic-ai/claude-code$pkgSuffix(wrapper,~25KB)..."
        try {
            Invoke-NpmPack -Pkg "@anthropic-ai/claude-code$pkgSuffix" | Out-Null
        } catch {
            Write-Err $_.Exception.Message
            exit 1
        }
        Write-Step "npm pack @anthropic-ai/claude-code-linux-x64$pkgSuffix(真二进制,~93MB,慢)..."
        try {
            $packed = Invoke-NpmPack -Pkg "@anthropic-ai/claude-code-linux-x64$pkgSuffix"
            $size = [math]::Round((Get-Item $packed).Length / 1MB, 1)
            Write-Ok "Linux 二进制打包完成:$(Split-Path $packed -Leaf) ($size MB)"
        } catch {
            Write-Err $_.Exception.Message
            exit 1
        }
    }
    # 换版本清旧:以最终留在目录里的最新文件为基准,删其它版本
    $keepWrapper = Get-ChildItem $bundleDir -Filter $wrapperPattern -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'linux-x64' } | Sort-Object LastWriteTime -Desc | Select-Object -First 1
    if ($keepWrapper -and $keepWrapper.Name -match 'claude-code-(\d+\.\d+\.\d+)\.tgz') {
        $keepVer = $Matches[1]
        Get-ChildItem $bundleDir -Filter 'anthropic-ai-claude-code-*.tgz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch [regex]::Escape($keepVer) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 3. opencode(wrapper + Linux 真二进制,与 Claude Code 同构)----------
# npm 官方双包:opencode-ai wrapper 的 optionalDependencies 钉死平台包版本(同步发版),
# VM 内离线安装机制与 Claude Code 完全一致(wrapper 先装、平台包后装,npm 容忍 optional 联网失败)
# 注:wrapper 模式用普通 * 而非 [0-9](Claude wrapper 需 [0-9] 排除 linux-x64 变体;opencode 两包
# 前缀不同不冲突),且 -Filter 不支持 [0-9] 字符类会静默匹配失败(launch.ps1 Test-BundleReady 同坑)
$ocWrapperPattern = 'opencode-ai-*.tgz'
$ocLinuxPattern   = 'opencode-linux-x64-*.tgz'
$existingOcWrapper = Get-ChildItem $bundleDir -Filter $ocWrapperPattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$existingOcLinux   = Get-ChildItem $bundleDir -Filter $ocLinuxPattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

# 宿主机 opencode 版本(菜单锚点;探测不到就不给该项)
$hostOcVer = $null
try {
    $v = (& opencode --version 2>$null | Select-Object -First 1)
    if ($v -match '(\d+\.\d+\.\d+)') { $hostOcVer = $Matches[1] }
} catch { }

if ((-not $Force) -and $existingOcWrapper -and $existingOcLinux) {
    Write-Ok "opencode 已存在:$($existingOcWrapper.Name) / $($existingOcLinux.Name)(用 -Force 重选/重下)"
} else {
    # 与 Claude Code 段同构:缓存两件套齐全才给"保持缓存",缺一半回"最新"重下补齐
    $cachedOcVer = $null
    if ($existingOcWrapper -and $existingOcLinux -and $existingOcWrapper.Name -match '^opencode-ai-(\d+\.\d+\.\d+)\.tgz$') { $cachedOcVer = $Matches[1] }
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
        Write-Step "npm pack opencode-ai$ocSuffix(wrapper,~20KB)..."
        try {
            Invoke-NpmPack -Pkg "opencode-ai$ocSuffix" | Out-Null
        } catch {
            Write-Err $_.Exception.Message
            exit 1
        }
        Write-Step "npm pack opencode-linux-x64$ocSuffix(真二进制,~60MB,慢)..."
        try {
            $packed = Invoke-NpmPack -Pkg "opencode-linux-x64$ocSuffix"
            $size = [math]::Round((Get-Item $packed).Length / 1MB, 1)
            Write-Ok "Linux 二进制打包完成:$(Split-Path $packed -Leaf) ($size MB)"
        } catch {
            Write-Err $_.Exception.Message
            exit 1
        }
    }
    # 换版本清旧:以最终留在目录里的最新 wrapper 为基准,删其它版本的 wrapper + 平台包
    $keepOcWrapper = Get-ChildItem $bundleDir -Filter $ocWrapperPattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($keepOcWrapper -and $keepOcWrapper.Name -match '^opencode-ai-(\d+\.\d+\.\d+)\.tgz$') {
        $keepOcVer = $Matches[1]
        Get-ChildItem $bundleDir -Filter 'opencode-ai-*.tgz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch [regex]::Escape($keepOcVer) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem $bundleDir -Filter 'opencode-linux-x64-*.tgz' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch [regex]::Escape($keepOcVer) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 4. cc-pocket Linux x86_64 ----------
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

# ---------- 5. 可选开发环境组件(JDK 17 / Maven / uv / pnpm)----------
# 与核心三件同构的版本菜单,差别:非交互且无缓存 → 跳过不下载(可选件不自动下大包,
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
    $pick = Select-OptionalComponentVersion -Prompt 'JDK 17(Adoptium,清华镜像)' -CachedVer $cachedJdkVer -Recent $recentJdk -ManualPattern '^\d+(\.\d+)+\+\d+$' -ManualExample '17.0.20.1+1'
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
    $pick = Select-OptionalComponentVersion -Prompt 'Maven(阿里云镜像)' -CachedVer $cachedMvnVer -Recent $recentMvn -ManualPattern '^\d+\.\d+\.\d+$' -ManualExample '3.9.16'
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

# --- pnpm(npm pack 本地打包,与 Claude Code 同路数;~9MB)---
$pnpmDir = Join-Path $bundleDir 'pnpm'
$cachedPnpm = Get-ChildItem $pnpmDir -Filter 'pnpm-*.tgz' -ErrorAction SilentlyContinue | Select-Object -First 1
$cachedPnpmVer = $null
if ($cachedPnpm -and $cachedPnpm.Name -match '^pnpm-(\d+\.\d+\.\d+)\.tgz$') { $cachedPnpmVer = $Matches[1] }

if ((-not $Force) -and $cachedPnpm) {
    Write-Ok "pnpm 已缓存:$($cachedPnpm.Name)(用 -Force 重选/重下)"
} else {
    $recentPnpm = @()
    if ($interactive) {
        try {
            $npmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
            if (-not $npmCmd) { throw 'npm.cmd 不在 PATH' }
            $out = & $npmCmd view pnpm versions --json 2>$null
            # PS 5.1 多行 JSON 坑:必须先 -join 回整段再 ConvertFrom-Json(详见 Claude Code 段注释)
            $vers = ConvertFrom-Json ($out -join "`n")
            # 只列 10.x:pnpm 11.x 需 Node≥22,bundle 的 Node 锁 20.x(要升 11 得连 Node 一起换)
            $recentPnpm = @($vers | Where-Object { "$_" -match '^10\.' -and "$_" -notmatch '-' } | Select-Object -Last 5)
            [array]::Reverse($recentPnpm)
        } catch { Write-Warn "拉取 pnpm 版本列表失败(离线?):$($_.Exception.Message)" }
    }
    $pick = Select-OptionalComponentVersion -Prompt 'pnpm 10 系(npm pack;11.x 需 Node 22 不兼容)' -CachedVer $cachedPnpmVer -Recent $recentPnpm -ManualPattern '^\d+\.\d+\.\d+$' -ManualExample '10.15.0'
    if ($pick -like 'cached:*') {
        Write-Ok "pnpm 沿用缓存 $($pick.Split(':', 2)[1])"
    } elseif ($pick -eq 'skip') {
        Write-Host '    --  pnpm:跳过(未缓存;start 勾选 dev-frontend 时在线兜底)' -ForegroundColor DarkGray
    } else {
        try {
            $packed = Invoke-NpmPack -Pkg "pnpm@$pick"
            New-Item -ItemType Directory -Path $pnpmDir -Force | Out-Null
            Move-Item $packed (Join-Path $pnpmDir (Split-Path $packed -Leaf)) -Force
            Get-ChildItem $pnpmDir -Filter 'pnpm-*.tgz' | Where-Object { $_.Name -ne (Split-Path $packed -Leaf) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Ok "pnpm 打包完成:$(Split-Path $packed -Leaf)"
        } catch {
            Write-Warn "pnpm 打包失败:$($_.Exception.Message)(已跳过)"
        }
    }
}

# ---------- 6. 状态汇总 ----------
Write-Step "bundle 状态:"
$nodeOk   = Get-ChildItem $bundleDir -Filter 'node-v*-linux-x64.tar.xz' -ErrorAction SilentlyContinue | Select-Object -First 1
$wrapOk   = Get-ChildItem $bundleDir -Filter $wrapperPattern -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'linux-x64' } | Select-Object -First 1
$linuxOk  = Get-ChildItem $bundleDir -Filter $linuxPattern -ErrorAction SilentlyContinue | Select-Object -First 1
$ocWrapOk  = Get-ChildItem $bundleDir -Filter $ocWrapperPattern -ErrorAction SilentlyContinue | Select-Object -First 1
$ocLinuxOk = Get-ChildItem $bundleDir -Filter $ocLinuxPattern -ErrorAction SilentlyContinue | Select-Object -First 1

if ($nodeOk) { Write-Ok "Node:               $($nodeOk.Name)" }   else { Write-Err "Node:               缺" }
if ($wrapOk) { Write-Ok "Claude wrapper:     $($wrapOk.Name)" }   else { Write-Err "Claude wrapper:     缺" }
if ($linuxOk) { Write-Ok "Claude Linux 二进制:$($linuxOk.Name)" } else { Write-Err "Claude Linux 二进制:缺" }
if ($ocWrapOk)  { Write-Ok "opencode wrapper:   $($ocWrapOk.Name)" }   else { Write-Err "opencode wrapper:   缺" }
if ($ocLinuxOk) { Write-Ok "opencode Linux 二进制:$($ocLinuxOk.Name)" } else { Write-Err "opencode Linux 二进制:缺" }

$ccOk = @(Get-ChildItem (Join-Path $bundleDir 'cc-pocket') -Filter 'cc-pocket-daemon-*-linux-x86_64.tar.gz' -ErrorAction SilentlyContinue).Count -gt 0
if ($ccOk) { Write-Ok "cc-pocket:        已准备" } else { Write-Err "cc-pocket:        缺" }

# 可选开发环境组件:缺了不算失败(交互终端重跑本脚本选装;start 勾选时在线兜底)
foreach ($opt in @(
    @{ Name = 'JDK 17'; Dir = 'jdk';   Pat = 'OpenJDK17U-jdk_x64_linux_hotspot_*.tar.gz' },
    @{ Name = 'Maven';  Dir = 'maven'; Pat = 'apache-maven-*-bin.tar.gz' },
    @{ Name = 'uv';     Dir = 'uv';    Pat = 'uv-*.whl' },
    @{ Name = 'pnpm';   Dir = 'pnpm';  Pat = 'pnpm-*.tgz' }
)) {
    $f = Get-ChildItem (Join-Path $bundleDir $opt.Dir) -Filter $opt.Pat -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { Write-Ok "$($opt.Name):$($f.Name)" }
    else    { Write-Host "    --  $($opt.Name):未缓存(可选)" -ForegroundColor DarkGray }
}

if ($nodeOk -and $wrapOk -and $linuxOk -and $ocWrapOk -and $ocLinuxOk -and $ccOk) {
    $totalMB = [math]::Round(((Get-ChildItem $bundleDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
    Write-Host "bundle 就绪($totalMB MB,含可选件)。" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Err "bundle 不完整,launch.ps1 start 会直接报错(项目不支持在线降级)。补齐全后再启动"
    exit 1
}

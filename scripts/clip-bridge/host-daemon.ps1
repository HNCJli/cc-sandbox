#Requires -Version 5.0
<#
    cc-sandbox 剪贴板桥 —— 宿主端常驻服务(可选特性 clip-bridge)

    监听 127.0.0.1:$Port(默认 18339),VM 内的 xclip/wl-paste 垫片经 launch.ps1 起的
    专享 SSH 反向隧道(-R)curl 过来读宿主机剪贴板。参考了 cc-clip 的垫片拦截协议。

    端点(全部 GET):
      /health       探活                  → {"status":"ok"}
      /clip/state   剪贴板内容形态        → {"image":true|false,"text":true|false}
      /clip/image   剪贴板图片 PNG 字节   → 200 image/png;无图 404
      /clip/text    剪贴板纯文本          → 200 text/plain;无文本 404

    为什么用 TcpListener 手写 HTTP 而不是 HttpListener:HttpListener 非 localhost
    前缀需要管理员 URLACL;回环 + 极简 GET 协议手写只有几十行,curl 完全够用。

    生命周期:由 launch.ps1 Start-ClipBridge 以隐藏窗口拉起,PID 写状态目录
    .clip-daemon.pid;stop/delete 时被停。日志:状态目录 clip-daemon.log。
#>
param(
    [int]$Port = 18339,
    [string]$LogDir = (Join-Path $env:USERPROFILE '.cc-sandbox')
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$logPath = Join-Path $LogDir 'clip-daemon.log'
# 日志超 1MB 就清零(daemon 重启时才检查,避免写日志本身做 IO 判断)
if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 1MB) { Set-Content -Path $logPath -Value '' }

function Write-Log([string]$Msg) {
    Add-Content -Path $logPath -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) -Encoding UTF8
}

# PowerShell bool → JSON 小写 true/false
function ConvertTo-LowerBool([bool]$Value) { if ($Value) { 'true' } else { 'false' } }

function Get-ClipStateJson {
    $img = $false; $txt = $false
    try { $img = ($null -ne (Get-Clipboard -Format Image)) } catch { Write-Log "读剪贴板图片形态异常: $($_.Exception.Message)" }
    try { $txt = (-not [string]::IsNullOrEmpty((Get-Clipboard -Raw))) } catch { Write-Log "读剪贴板文本形态异常: $($_.Exception.Message)" }
    return ('{"image":' + (ConvertTo-LowerBool $img) + ',"text":' + (ConvertTo-LowerBool $txt) + '}')
}

# 剪贴板图片 → PNG 字节;无图返回 $null
# PS 5.1 的 Get-Clipboard -Format Image 返回 System.Drawing.Bitmap(GDI+),
# 不是 WPF BitmapSource——直接喂 BitmapFrame.Create 会撞重载不匹配
# (实测 2026-08-23:"Cannot convert ... to System.Uri")。两种类型都兜住,统一输出 PNG 字节
function Get-ClipboardImagePng {
    $img = $null
    try { $img = Get-Clipboard -Format Image } catch { Write-Log "读剪贴板图片异常: $($_.Exception.Message)"; return $null }
    if ($null -eq $img) { return $null }
    $ms = New-Object System.IO.MemoryStream
    if ($img -is [System.Drawing.Image]) {
        $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    } elseif ($img -is [System.Windows.Media.Imaging.BitmapSource]) {
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($img))
        $enc.Save($ms)
    } else {
        Write-Log "未知剪贴板图片类型: $($img.GetType().FullName)"
        return $null
    }
    return ,$ms.ToArray()
}

function Send-HttpResponse {
    param(
        [Parameter(Mandatory)] [System.IO.Stream]$Stream,
        [Parameter(Mandatory)] [string]$Status,       # 如 '200 OK' / '404 Not Found'
        [Parameter(Mandatory)] [string]$ContentType,
        [byte[]]$Body = @()
    )
    $header = "HTTP/1.1 $Status`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($hb, 0, $hb.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch {
    Write-Log "监听 127.0.0.1:$Port 失败: $($_.Exception.Message)(端口被占?另一个 daemon 在跑?)"
    exit 1
}
Write-Log "clipboard daemon 已监听 127.0.0.1:$Port"

# 串行 accept:单用户场景(cutpaste 请求稀疏、毫秒级返回),不值得上并发
while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000   # 连上不发数据的死客户端,5s 后抛异常回收

        # 读到请求头结束(\r\n\r\n)。垫片只用 GET 无 body,读完头即可路由
        $ms = New-Object System.IO.MemoryStream
        $chunk = New-Object byte[] 8192
        while ($ms.Length -lt 64KB) {
            $n = $stream.Read($chunk, 0, $chunk.Length)
            if ($n -le 0) { break }
            $ms.Write($chunk, 0, $n)
            if ([System.Text.Encoding]::ASCII.GetString($ms.ToArray()).Contains("`r`n`r`n")) { break }
        }

        $reqText = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
        $firstLine = ($reqText -split "`r`n")[0]
        if ($firstLine -notmatch '^GET\s+(\S+)') {
            Send-HttpResponse -Stream $stream -Status '405 Method Not Allowed' -ContentType 'text/plain' -Body ([System.Text.Encoding]::UTF8.GetBytes('GET only'))
            continue
        }
        $path = $Matches[1]

        switch -Wildcard ($path) {
            '/health' {
                Send-HttpResponse -Stream $stream -Status '200 OK' -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"status":"ok"}'))
            }
            '/clip/state' {
                Send-HttpResponse -Stream $stream -Status '200 OK' -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes((Get-ClipStateJson)))
            }
            '/clip/image' {
                $png = Get-ClipboardImagePng
                if ($png) {
                    Send-HttpResponse -Stream $stream -Status '200 OK' -ContentType 'image/png' -Body $png
                } else {
                    Send-HttpResponse -Stream $stream -Status '404 Not Found' -ContentType 'text/plain' -Body ([System.Text.Encoding]::UTF8.GetBytes('no image'))
                }
            }
            '/clip/text' {
                $txt = $null
                try { $txt = Get-Clipboard -Raw } catch {}
                if ([string]::IsNullOrEmpty($txt)) {
                    Send-HttpResponse -Stream $stream -Status '404 Not Found' -ContentType 'text/plain' -Body ([System.Text.Encoding]::UTF8.GetBytes('no text'))
                } else {
                    Send-HttpResponse -Stream $stream -Status '200 OK' -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($txt))
                }
            }
            default {
                Send-HttpResponse -Stream $stream -Status '404 Not Found' -ContentType 'text/plain' -Body ([System.Text.Encoding]::UTF8.GetBytes('not found'))
            }
        }
    } catch {
        Write-Log "处理请求异常: $($_.Exception.Message)"
    } finally {
        try { $client.Close() } catch {}
    }
}

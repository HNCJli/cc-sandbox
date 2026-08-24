# 故障排查

## 前置

- Multipass:推荐/实测 **1.14.1**,勿升 1.16.x(其 daemon 在 Windows 不稳,list/launch 会卡死或超时)。
- OpenSSH 客户端:Windows 10+ 通常自带(`ssh -V` 验证);缺则 设置 → 应用 → 可选功能 → 添加 OpenSSH 客户端。
- 可写状态(mounts.txt、.ssh-key、.tunnel.pid、bundle、workspace)都在状态目录,默认 `%USERPROFILE%\.cc-sandbox\`。

## VM 里 Claude Code 报连不上 LLM / cc-switch

```powershell
# 1. status 全景(本地代理模式看隧道,直连模式看 base_url 探测)
.\scripts\launch.ps1 status         # 返回 HTTP 4xx = 通(根路径不响应但服务在);000 = 断

# 2. VM 里手动 curl(本地代理模式)
multipass exec claude-dev -- curl -v http://127.0.0.1:15721/
# connection refused → 隧道断了,stop 再 start(或按 §E 只重起隧道)

# 3. settings.json 同步了吗(应含 env + 本地 statusLine,无 mcpServers 等;含明文 token,别直接 cat)
multipass exec claude-dev -- bash -lc "jq -e '.env | type == \"object\" and length > 0' ~/.claude/settings.json >/dev/null && echo 'env 同步 OK' || echo 'env 为空'"
```

## 隧道进程死了

```powershell
.\scripts\launch.ps1 stop           # 重拉一切 = 先停再起
.\scripts\launch.ps1 start
# 或只重起隧道(不重启 VM):
Stop-Process -Id (Get-Content "$env:USERPROFILE\.cc-sandbox\.tunnel.pid") -Force
Remove-Item "$env:USERPROFILE\.cc-sandbox\.tunnel.pid"
.\scripts\launch.ps1 start          # 检测到 VM 在 Running 会跳过 launch,只重挂/重起隧道
```

## 挂载失败 / Multipass 报 "Mounts are disabled"

Windows 上 Multipass 默认可能禁用 privileged-mounts。`launch.ps1 start` 首次会自动开启(`multipass set local.privileged-mounts=true`),若失败手动执行一次即可。

## 挂载失败:新 VM 首次挂载报 "install-snap change in progress"

刚重建的 VM 上连续挂载(先 `~/.claude` 再 workspace)时,multipass daemon 要先往 VM 里装 `multipass-sshfs` snap,两个挂载请求撞上同一次安装就会报:

```
Failed to install 'multipass-sshfs': error: snap "multipass-sshfs" has "install-snap" change in progress
mount failed: Error enabling mount support in 'claude-dev'
```

`start` 对此是**警告后继续**(其余步骤不受影响),幂等重跑一次 `start` 即可补挂(实测 2026-08-17:重跑后 `.claude` 挂载成功且 RO 生效)。若重跑仍失败,等 snap 装完再跑,或手动 `multipass mount`。

## 挂载失败(非 ASCII 路径)

如果 Windows 账号名或项目路径含中文等非 ASCII 字符,`multipass mount` 在 Windows 上支持不稳。

**mounts.txt 条目挂不上**的备选:在 ASCII 路径建 Windows junction 指向真实目录,把 mounts.txt 里的条目换成 junction 路径:
   ```powershell
   New-Item -ItemType Junction -Path C:\dev\myrepo -Target "<实际中文路径>\myrepo"
   # mounts.txt 里写 C:\dev\myrepo
   ```

**`~/.claude` 挂不上**:用 junction:
```powershell
New-Item -ItemType Junction -Path C:\dev\claude-config -Target "$env:USERPROFILE\.claude"
# 编辑 scripts\launch.ps1 把 $hostClaude 改成 C:\dev\claude-config
```

## cloud-init 没跑完

```powershell
multipass exec claude-dev -- cloud-init status --long    # 看详细
multipass exec claude-dev -- sudo cat /var/log/cloud-init-output.log
```

## 想完全重来

```powershell
.\scripts\launch.ps1 delete
.\scripts\launch.ps1 start
```

`.ssh-key`、状态目录里的 `workspace\` 不会删,会复用。

---

# 深度排障(§A–§G)

按主流程报错的现象查对应小节。**这些都是"遇到才处理"的分支,不是每台机器都会碰到。** 涉及改全局设置或文件权限的动作(§A/§C),先跟用户确认再执行——这是对外可见的状态改动。

所有 `$xxx` 变量在 Git Bash 里会被吞,把 PowerShell 命令写成 `.ps1` 临时文件再 `powershell -File` 执行(见 §D)。

## §A 镜像源被改成非官方源

**现象**:`.\scripts\launch.ps1 start` 报
```
launch failed: Remote "" is unknown or unreachable.
multipass launch 失败
```
但网络正常、`multipass version` 正常。

**根因**:Multipass 全局配了非官方镜像源(常见于国内加速,如清华 TUNA),而该源的 simplestreams 索引解析不出 `noble` 别名对应的 remote。

**诊断**:
```powershell
multipass get local.image.mirror
```
若返回一个 URL(如 `https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/`)就是它。

**确认后修复**(这是全局设置改动,会重启 multipassd;无运行中 VM 时无副作用):
```powershell
multipass set local.image.mirror=
```
清空后恢复官方源。验证:
```powershell
multipass get local.image.mirror     # 应为空
multipass find                        # 应能列出 24.04 / noble 别名
```
然后重跑 `.\scripts\launch.ps1 start`。

> 若用户在墙内、官方源连不上,别清镜像源——那样会拉不到镜像。改为让用户先连能访问官方源的网络(如切 VPN 节点)再清,或保留镜像源但改用能解析的完整镜像 URL。

## §B launch 后 cloud-init 探测

**现象**:`.\scripts\launch.ps1 start` 在等待阶段提示:
```
cloud-init status 等待超时(20 分钟),继续后续步骤验证
```

**含义**:等待超时不直接说明 VM 创建失败或成功。`launch.ps1` 内部轮询 `cloud-init status`(上限 20 分钟),超时后脚本会继续后续步骤(传输 bundle + 装软件 + 起隧道);若后续步骤真正失败会直接报错终止。先 `multipass list` 确认 VM 是否已 Running(cloud-init 5.x 偶发不返回完成信号),已 Running 就重跑 `start` 只重传/重起隧道。

**诊断**:
```powershell
multipass exec claude-dev -- cloud-init status --long
multipass exec claude-dev -- sudo tail -n 80 /var/log/cloud-init-output.log
```

- `status: running`:安装仍在进行,继续等待;长时间无新日志再排查网络或安装命令
- `status: done`:安装已完成。若原启动流程被中断,重新 `start`,它会复用 Running VM 并补齐挂载和隧道
- `status: error` 或日志有明确失败:保留日志定位原因;只有确认要干净重装时才 `delete + start`。重新 `start` 不会自动重跑已失败的 cloud-init

如需确认工具是否已装好,可在 `status: done` 后检查:
```powershell
multipass exec claude-dev -- bash -lc "node -v; command -v claude; command -v fish"
```

> **cloud-init 太慢(>10 分钟)?** 项目只走离线安装,先跑 `.\scripts\prepare-bundle.ps1` 准备离线 bundle(~220MB 含 cc-pocket,一次性),之后 `delete + start` 走离线模式,cloud-init < 2 分钟。bundle 不齐 `launch.ps1 start` 会直接报错。详见 [bundle.md](bundle.md)。

## §C 宿主机 .claude 权限锁死,env 同步为空(VM 弹登录菜单)

**现象**:VM 里 `claude` 弹「Select login method」登录菜单;`multipass exec claude-dev -- bash -lc "cat ~/.claude/settings.json"` 是 `{"env":{}}`(空 env)。

**避免泄露凭证**:不要用 `cat ~/.claude/settings.json`、`jq .env`、截图或聊天日志输出该文件;其中的 token 可能是明文。改用无输出校验:
```powershell
multipass exec claude-dev -- bash -lc "jq -e '.env | type == \"object\" and length > 0' ~/.claude/settings.json >/dev/null && echo OK || echo EMPTY"
```

**根因链**:
1. 宿主机 `%USERPROFILE%\.claude\settings.json` 或 `.claude` 目录的 Windows ACL 异常(缺当前用户条目 / 所有者是 Administrators / ACL 空)。
2. multipass 挂载进程读不到该文件(Linux 权限位 `-rw-rw-rw-` 是假象,拦截在宿主机 NTFS 层——连 VM 内 `sudo cat` 都 Permission denied)。
3. 同步脚本 `jq '{env:(.env//{})}'` 读失败 → 退化成 `{"env":{}}`。
4. VM 里 Claude Code 没凭证 → 弹登录菜单。

**诊断**(在宿主机):
```powershell
icacls C:\Users\<你>\.claude\settings.json
(Get-Acl C:\Users\<你>\.claude).Owner
```
问题特征:文件 ACL 里没有当前用户、或 `.claude` 目录 Owner 是 `BUILTIN\Administrators` 而非当前用户、或 Everyone 只给了 `(RX)`。

**确认后修复**(改宿主机权限,对外可见,先征得用户同意)。因为普通用户常常连 takeown 目录都被拒,最干净的做法是**管理员 PowerShell** 里夺回所有权 + 重置为继承标准值。让用户执行(以管理员身份运行 PowerShell):

```powershell
takeown /f C:\Users\<你>\.claude /r /d y /a
icacls C:\Users\<你>\.claude /reset /t /c
```
- `takeown ... /a`:把所有权给 Administrators 组(比给单用户成功率高;不加 `/a` 常报 "does not have ownership privileges")
- `icacls ... /reset /t`:递归清掉显式 ACL,让 `.claude` 及内部所有文件**继承** `C:\Users\<你>` 的标准权限

重置后应为标准三条:`SYSTEM(F)` / `Administrators(F)` / `<你>(F)`,全部继承 `(I)`。

**验证修好了**:
```powershell
# 宿主机能读(只看长度,不打印内容)
powershell -Command "(Get-Content C:\Users\<你>\.claude\settings.json -Raw).Length"
# VM 重新同步后,只验证 env 为非空对象;不要打印 token
multipass exec claude-dev -- bash -lc "source /etc/profile.d/05-claude-config.sh; sync_claude_config; jq -e '.env | type == \"object\" and length > 0' ~/.claude/settings.json >/dev/null && echo OK || echo EMPTY"
```

> **重要教训**:不要为了"让 VM 读到"而对 settings.json 单独 `icacls /grant <用户>:(R)` ——只给读会覆盖掉 cc-switch 依赖的写权限,导致 cc-switch 换 provider 时报 `IO 错误 ... settings.json.tmp ... 拒绝访问 (os error 5)`。正确做法是上面的 `/reset` 恢复标准继承权限(读写都在),一步到位。
>
> 若已误伤导致 cc-switch 保存报 os error 5:同样用上面的 `takeown /a` + `icacls /reset /t` 修复,之后 cc-switch 保存恢复正常。

## §D Git Bash spawn bug(与 VM 无关,但会反复打断操作)

**现象**:命令随机报
```
0 [main] bash (NNNN) C:\Program Files\Git\bin\..\usr\bin\bash.exe: *** fatal error - add_item ("\??\C:\Program Files\Git", "/", ...) failed, errno 1
```
PowerShell 根本没启动,exit code 5。这是 Git Bash 环境自身的 fork/spawn 缺陷,**不是命令写错**。

**应对**:
- **重试**:同一条命令再跑一两次通常就过。
- **减少 fork**:把多步 PowerShell 逻辑写成一个 `.ps1` 临时文件,`powershell -NoProfile -ExecutionPolicy Bypass -File C:\...\x.ps1` 一次执行,别用长管道 / 多命令拼接。
- **变量被吞**:Git Bash 会把 `$var`、`$_` 当自己的变量吞掉,导致 PowerShell 报 "Missing expression"。同样用 `.ps1` 文件规避,别在 `powershell -Command "..."` 里内联 `$`。
- **VM 内路径被改写**:`multipass exec claude-dev -- cat /home/...` 会被 MSYS 把 `/home/...` 改写成 `C:/Program Files/Git/home/...`。用 `bash -lc '...'` 包一层(`multipass exec claude-dev -- bash -lc 'ls ~/workspace'`);涉及 settings 时只做无输出检查,例如 `multipass exec claude-dev -- bash -lc 'jq -e ".env | type == \"object\" and length > 0" ~/.claude/settings.json >/dev/null'`,不要 `cat` 该文件;或前置 `MSYS_NO_PATHCONV=1`。

## §E SSH 反向隧道问题

**现象**:`.\scripts\launch.ps1 status` 里隧道 `已死`,或端口探测返回 `000`;VM 里 `claude` 连不上 LLM(仅本地代理模式相关,见下)。

**修复**:
```powershell
.\scripts\launch.ps1 stop
.\scripts\launch.ps1 start
# 或只重起隧道不重启 VM:
Stop-Process -Id (Get-Content "$env:USERPROFILE\.cc-sandbox\.tunnel.pid") -Force
Remove-Item "$env:USERPROFILE\.cc-sandbox\.tunnel.pid"
.\scripts\launch.ps1 start        # 检测到 VM Running,只重挂/重起隧道
```

隧道秒退多半是 VM sshd 没起或 key 没注入,`.\scripts\launch.ps1 delete` 后 `start` 重建。

> **隧道是否需要已自动判定**:launch.ps1 读宿主机 `~/.claude/settings.json` 的 `env.ANTHROPIC_BASE_URL`——`127.0.0.1`/`localhost`(cc-switch 类本地代理)才起隧道;公网网关(如 `https://xxx.com`)自动跳过,VM 直连。手动确认 VM 里实际用的是哪种:
> ```powershell
> multipass exec claude-dev -- bash -lc "jq -r .env.ANTHROPIC_BASE_URL ~/.claude/settings.json"
> ```
> 是 `127.0.0.1:15721` → 依赖隧道,§E 要认真修;是公网 URL → 隧道断了也不影响 claude,先测 VM 能否直连该 URL(`curl -sS -o /dev/null -w '%{http_code}' <url>`)。

### §E.1 宿主机 `.ssh-key` 权限过宽(ExitCode 255)

**现象**:VM `Running`、`sshd` 已运行、`multipass exec` 正常,但启动隧道仍报:

```text
SSH 隧道秒退,ExitCode=255
```

用宿主机 PowerShell 运行同等 SSH 命令并加 `-vvv` 后,若末尾出现:

```text
WARNING: UNPROTECTED PRIVATE KEY FILE!
Bad permissions ... .ssh-key
Load key ".\\.ssh-key": bad permissions
```

**根因**:状态目录里的 `.ssh-key` 继承了 `NT AUTHORITY\Authenticated Users`、`BUILTIN\Users` 或 `Everyone` 的访问权。Windows OpenSSH 因私钥可被其他用户读取而拒绝用它签名;这会表现为认证后的隧道 ExitCode 255。

**确认后修复**(改宿主机私钥 ACL,先确认再执行;任意目录 PowerShell 均可):

```powershell
$key = Join-Path $env:USERPROFILE '.cc-sandbox\.ssh-key'
icacls $key /inheritance:r
icacls $key /remove:g 'NT AUTHORITY\Authenticated Users' 'BUILTIN\Users' 'Everyone'
icacls $key /grant:r "${env:USERNAME}:(R)"
icacls $key
```

最后输出不应再有 `Authenticated Users`、`BUILTIN\Users` 或 `Everyone`;当前 Windows 用户保留 `(R)` 即可。然后无需重建 VM,直接:

```powershell
.\scripts\launch.ps1 start        # VM Running 时只重挂/重起隧道
.\scripts\launch.ps1 status
```

> 已有的 `.ssh-key` 原本可以正常工作;若突然发生此问题,通常是目录/文件 ACL 后来被继承或被其他权限操作修改,不是 VM 的 sshd 或公钥注入故障。

## §F Multipass Windows 服务/后端卡死

> **1.14.1 上 daemon 稳定**,`launch.ps1` 也已去掉了自动强杀 daemon 的逻辑(失败会如实报错并指到这里)。本节只在极少数 Windows `Multipass` 服务 / Hyper-V 后端本身卡死时用到。

**现象**:`multipass list` 一直不返回/超时;或 `launch.ps1` 报 `无法确认 VM 是否存在`、`multipass start 失败`、`multipass stop/delete ... 超时`;也包括 `multipass launch` 卡在 `Waiting for SSH to be up`、报 `Timed out waiting for instance launch`。这些都不能直接说明 VM 不存在或 cloud-init 损坏。

**根因边界**:以上现象通常是 Windows 的 `Multipass` 服务或 Hyper-V 后端本身未释放,需要管理员权限处理。不要反复运行 `start`,也**不要在 VM 状态未知时执行 `delete`**。

**确认后修复**(会终止 Multipass 的进行中操作、改变 Windows 服务状态,先征得用户同意;以**管理员身份**打开 PowerShell):

```powershell
# 先尝试正常重启服务
Restart-Service -Name Multipass -Force
```

若该命令一直停在 `Waiting for service ... to stop...`,按 `Ctrl+C` 中断等待;再查询**当前**服务进程 PID 后,只结束该 PID,随后启动服务(不要复用旧日志中的 PID):

```powershell
$svc = Get-CimInstance Win32_Service -Filter "Name='Multipass'"
$svc.ProcessId
Stop-Process -Id $svc.ProcessId -Force
Start-Service -Name Multipass
```

等几秒后必须先验证控制面已恢复:

```powershell
multipass list
```

能列出 VM 后,先看 `claude-dev` 是否已经是 `Running`;它可能已由 Hyper-V 创建,只是原 launch 未等到 SSH。若是 Running,直接补完流程(VM Running 时不会重新 launch 镜像,只重挂/重起隧道):

```powershell
.\scripts\launch.ps1 start        # mounts.txt 挂载自动重挂
.\scripts\launch.ps1 status
```

若强制结束服务进程后仍无法启动服务,或 `multipass list` 仍卡住,重启 Windows 后再验证 `multipass list`;恢复前不要 delete/rebuild VM。

## §G 剪贴板桥:claude 里 Ctrl+V 没反应 / 粘图失败

**现象**:status 的"剪贴板桥"三件套全绿,但 VM 里 claude 输入框按 Ctrl+V 完全没反应(连附件标记都不出现)。

**最常见根因:终端自己吃掉了 Ctrl+V**。多数终端默认把 `Ctrl+V` 绑定为"粘贴文本"——按键被终端消费,从未到达 claude;而剪贴板里是图片(终端粘不了图),于是"什么都没发生"。

**30 秒判别**:宿主机复制一段**文字** → claude 输入框按 `Ctrl+V`:

- 文字被敲进输入框 → 实锤终端拦截,按下表解绑
- 无任何反应 → 跳到下面的三层排查

**解绑 Ctrl+V(实测 2026-08-23)**:

| 终端 | 操作 |
|---|---|
| **Warp** | `Ctrl+,`(Ctrl 和逗号)→ Keyboard Shortcuts → 搜 `paste` → 占着 `Ctrl+V` 的是 **Alternate Terminal Paste**(实测如此,Paste 本身绑的是 Ctrl+Shift+V)→ 点该按键块,按 Backspace 清空。粘文本继续用 `Ctrl+Shift+V` |
| Windows Terminal | `Ctrl+,` → 操作(Actions)→ 删除"粘贴 · Ctrl+V" → 粘文本用 Ctrl+Shift+V 或右键 |

设置即时生效,不用重启终端,claude 里直接再按 Ctrl+V 验证。

**不是终端拦截时的三层排查**(宿主机 PowerShell 逐条,哪层挂修哪层):

```powershell
# ① 宿主 daemon 活着吗(预期 {"status":"ok"})
curl http://127.0.0.1:18339/health
# ② VM 侧隧道通吗(预期 {"status":"ok"})
multipass exec claude-dev -- bash -lc "curl -s --max-time 5 http://127.0.0.1:18339/health"
# ③ 垫片在位且优先吗(预期 /usr/local/bin/xclip)
multipass exec claude-dev -- bash -lc "which xclip"
```

任何一层不对 → 重跑 `.\scripts\launch.ps1 start`(自动重起 daemon/隧道、重装垫片)。桥是否真通,VM 里一条命令直测(宿主机剪贴板先放张图):

```bash
xclip -selection clipboard -t image/png -o | wc -c   # 吐出字节数 = 管道通
```

**另一种现象**:附件标记出现了,但模型说"看不到图/读不到图片内容"——桥没问题,是 **LLM 网关丢弃 image 块**(部分 OpenAI 协议中转对 Anthropic 协议图片内容的转换缺失)。换后端验证,别折腾桥。

**判定后端是否真的能看图:红图验色法(30 秒)**。给后端发一张**纯色 PNG**(如纯红),问"这张图什么颜色?一个词"。答对颜色 = 通;答错(紫/蓝/黑…)= 后端断图。必须用已知颜色的图,不能问开放式问题——**模型会一本正经地瞎猜**(2026-08-24 实测:glm-5.3 的 thinking 里自述 "The image is likely a solid color" 然后猜了个错的颜色)。

实测(2026-08-24):bigmodel 的 **Anthropic 兼容层**(`/api/anthropic`)对所有模型(glm-5.3 / glm-4.5v / glm-4.6v)都丢图,base64 图片块被转成模型取不到内容的 URL 引用;其**原生 API**(`/api/paas/v4`)视觉正常(glm-4v-flash 免费模型读色正确)。即:Claude Code + bigmodel = 看不了图,属网关缺陷,与本项目/剪贴板桥无关。出路:看图任务用 cc-switch 换后端,或等 bigmodel 修复;验证任何新后端,用上面的红图验色法。

## 安全提醒

排障过程不应输出 `ANTHROPIC_AUTH_TOKEN`:不要 `cat ~/.claude/settings.json`、`jq .env`,也不要把该文件截图或写入聊天日志。若已在协作/日志环境暴露 token,去 cc-switch 轮换它。

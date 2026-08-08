# start-vm 排障参考

按主流程报错的现象查对应小节。**这些都是"遇到才处理"的分支,不是每台机器都会碰到。** 涉及改全局设置或文件权限的动作(§A/§C),先跟用户确认再执行——这是对外可见的状态改动。

所有 `$xxx` 变量在 Git Bash 里会被吞,把 PowerShell 命令写成 `.ps1` 临时文件再 `powershell -File` 执行(见 §D)。

---

## §A 镜像源被改成非官方源

**现象**:`.\launch.ps1 start` 报
```
launch failed: Remote "" is unknown or unreachable.
multipass launch 失败
```
但网络正常、`multipass version` 正常。

**根因**:Multipass 全局配了非官方镜像源(常见于国内加速,如清华 TUNA),而该源的 simplestreams 索引解析不出 `resolute` 别名对应的 remote。

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
multipass find                        # 应能列出 26.04 / resolute 别名
```
然后重跑 `.\launch.ps1 start`。

> 若用户在墙内、官方源连不上,别清镜像源——那样会拉不到镜像。改为让用户先连能访问官方源的网络(如切 VPN 节点)再清,或保留镜像源但改用能解析的完整镜像 URL。

---

## §B launch.ps1 判定失败但 VM 其实已创建成功

**现象**:`.\launch.ps1 start` 抛
```
multipass launch 失败
At ...launch.ps1:168 char:36 + if ($LASTEXITCODE -ne 0) { throw ...
```
但 `multipass list` 显示 `claude-dev  Running`。

**根因**:`multipass launch` 打进度条时,PowerShell 5.1 会把它的 `$LASTEXITCODE` 误判为非零,脚本 `throw` 提前中断——**VM 实际创建成功了**,只是后续的挂载 + SSH 隧道没执行。

**修复**:不用 delete 重来。直接**再跑一次**:
```powershell
.\launch.ps1 start
```
脚本检测到 VM 已 `Running` 会跳过 launch,只补挂载 + 起隧道(见 launch.ps1 的 `Start-ClaudeDev`:`if ($state -eq "Running") { 只重挂/重起隧道 }`)。

先确认 VM 和工具装好了:
```powershell
multipass list
multipass exec claude-dev -- bash -lc "node -v; which claude"
```

> 潜在根治(可选,改 launch.ps1):首次 launch 后不靠 `$LASTEXITCODE`,改用 `Test-VmExists` / `Get-VmState -eq 'Running'` 判断成功。当前 skill 不改脚本,靠"再跑一次"绕过。

---

## §C 宿主机 .claude 权限锁死,env 同步为空(VM 弹登录菜单)

**现象**:VM 里 `claude` 弹「Select login method」登录菜单;`multipass exec claude-dev -- bash -lc "cat ~/.claude/settings.json"` 是 `{"env":{}}`(空 env)。

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
# 宿主机能读
powershell -Command "(Get-Content C:\Users\<你>\.claude\settings.json -Raw).Length"
# VM 重新同步后 env 非空
multipass exec claude-dev -- bash -lc "source /etc/profile.d/05-claude-config.sh; sync_claude_config; cat ~/.claude/settings.json"
```

> **重要教训**:不要为了"让 VM 读到"而对 settings.json 单独 `icacls /grant <用户>:(R)` ——只给读会覆盖掉 cc-switch 依赖的写权限,导致 cc-switch 换 provider 时报 `IO 错误 ... settings.json.tmp ... 拒绝访问 (os error 5)`。正确做法是上面的 `/reset` 恢复标准继承权限(读写都在),一步到位。
>
> 若已误伤导致 cc-switch 保存报 os error 5:同样用上面的 `takeown /a` + `icacls /reset /t` 修复,之后 cc-switch 保存恢复正常。

---

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
- **VM 内路径被改写**:`multipass exec claude-dev -- cat /home/...` 会被 MSYS 把 `/home/...` 改写成 `C:/Program Files/Git/home/...`。用 `bash -lc '...'` 包一层(`multipass exec claude-dev -- bash -lc 'cat ~/.claude/settings.json'`),或前置 `MSYS_NO_PATHCONV=1`。

---

## §E SSH 反向隧道问题

**现象**:`.\launch.ps1 status` 里隧道 `已死`,或 cc-switch 端口探测返回 `000`;VM 里 `claude` 连不上 LLM(但你用的是 localhost 代理模式时才相关,见下方注意)。

**修复**:
```powershell
.\launch.ps1 restart
# 或只重起隧道不重启 VM:
Stop-Process -Id (Get-Content .tunnel.pid) -Force; Remove-Item .tunnel.pid
.\launch.ps1 start        # 检测到 VM Running,只重挂/重起隧道
```

隧道秒退多半是 VM sshd 没起或 key 没注入,`.\launch.ps1 delete` 后 `start` 重建。

> **注意 — 隧道未必需要**:项目 README 假设 cc-switch 在 `127.0.0.1:15721` 跑本地代理,VM 靠反向隧道回连。但如果用户的 `ANTHROPIC_BASE_URL` 是**公网网关**(如 `https://xxx.com`,而非 `127.0.0.1:15721`),VM 直连公网即可,反向隧道是多余的(留着无害)。判断:
> ```powershell
> multipass exec claude-dev -- bash -lc "jq -r .env.ANTHROPIC_BASE_URL ~/.claude/settings.json"
> ```
> 是 `127.0.0.1:15721` → 依赖隧道,§E 要认真修;是公网 URL → 隧道断了也不影响 claude,先测 VM 能否直连该 URL(`curl -sS -o /dev/null -w '%{http_code}' <url>`)。

---

## 安全提醒

排障 §C 过程中会读到宿主机 `settings.json` 里的 `ANTHROPIC_AUTH_TOKEN`(明文)。若在协作/日志环境下暴露了,提醒用户去 cc-switch 轮换该 token。

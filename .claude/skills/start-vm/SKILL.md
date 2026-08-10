---
name: start-vm
description: 用 launch.ps1 在 Windows 上启动/唤醒 claude-dev Multipass VM(Ubuntu + Claude Code + cc-switch env 同步)。当用户说"启 VM""起个 VM""启动 claude-dev""跑一下这个项目的虚拟机"等,用此 skill。仅 Windows。
---

# start-vm — 启动 claude-code-multipass 的 VM

把 Claude Code 关进 Multipass Ubuntu VM(最大权限沙箱)。宿主机 cc-switch 写的 LLM env(token / base_url / 模型映射)只读同步进 VM;workspace 双向挂载。详见项目 README.md。

**平台:仅 Windows。** 后端 Hyper-V 或 VirtualBox。VM 名固定 `claude-dev`。

## 主流程(happy path)

多数机器按这几步就能起来。先跑,遇到失败再翻「排障」。

### 1. 前置检查(全绿再往下)

```powershell
multipass version           # 要 >= 1.11
ssh -V                      # OpenSSH 客户端
netstat -ano | findstr 15721   # cc-switch 应 LISTENING 在 127.0.0.1:15721
```

三者缺一见 README「前置」。cc-switch 端口若非 15721,跑 `start` 时带 `-CcSwitchPort <端口>`。

### 2. 启动(选一种挂载模式)

**传统单根模式**(默认,简单):项目下 `./workspace/` 挂为 VM 根 `~/workspace`。

```powershell
.\launch.ps1 start
```

**多目录模式**(挂多个宿主目录到 `~/workspace/<子目录>`):先复制 `mounts.example.txt` 为本地 `mounts.txt` 填好路径,或直接传 `-ExtraMounts`。

```powershell
.\launch.ps1 start -NoRootWorkspace                     # 读本地 mounts.txt
.\launch.ps1 start -NoRootWorkspace -ExtraMounts "D:\repo1","E:\repo2=alias2"
```

两种模式不可混用;`-WorkspaceHost` 只在传统模式下用。多目录模式必须 `-NoRootWorkspace`(Multipass 1.16 在 Windows 不支持嵌套挂载)。

首次 3–5 分钟(下载 Ubuntu 镜像 + cloud-init 装 Node 20 + Claude Code + Fish/fzf/zoxide)。脚本会自动:开 privileged-mounts → 创建/唤醒 VM → 挂 `~/.claude`(RO)和 workspace → 起 SSH 反向隧道。

> **后台跑法**:首次因为要下载镜像,建议后台运行 + 轮询输出文件看进度,别干等。

### 3. 验证(必做)

```powershell
.\launch.ps1 status
```

要看到三项都 OK:VM `Running`、隧道 `在跑`、`VM 里 curl 127.0.0.1:15721 返回 HTTP 4xx(隧道通了)`。

再确认 VM 里 env 同步到位(**这步最容易被权限问题坑,务必查**;**不要 `cat` settings.json,里面有 token**):

```powershell
multipass exec claude-dev -- bash -lc "jq -e '.env | type == \"object\" and length > 0' ~/.claude/settings.json >/dev/null && echo OK || echo EMPTY"
```

输出 `OK` = 同步到位;`EMPTY` → env 没同步进来 → 见 [排障 §C](./references/troubleshooting.md)。

最后确认 workspace 挂载真到位(**不要只看 launch 输出,以 VM 内 findmnt 为准**):

```powershell
multipass exec claude-dev -- bash -lc "findmnt | grep /home/ubuntu/workspace"
multipass exec claude-dev -- bash -lc "ls -la ~/workspace"
```

传统单根模式应看到根 `/home/ubuntu/workspace` 一行 mount;多目录模式应看到各子目录的 mount 记录。

### 4. 用起来

```powershell
multipass shell claude-dev
# VM 内(Fish 交互 shell):
claude --dangerously-skip-permissions
```

进 VM 是 fish 提示符:灰色历史建议(`→` 或 `Ctrl+F` 接受)、`Ctrl+R` 模糊搜历史、`z <关键词>` 跳目录(zoxide)。临时要 bash 敲 `bash`。

每次敲 `claude` 前(fish 和 bash 都一样)profile 脚本会自动重新同步 env,宿主机 cc-switch 切 provider 后 VM 会跟上。

### cc-pocket(可选,手机遥控)

VM 里预装了 cc-pocket daemon,正常情况下 `delete + start` 重建后已自启。

**首次配对**(VM 内):
```bash
cc-pocket-daemon pair   # 出 QR + 6 位码,手机 App 扫一下
```

若 pair 报 `no daemon on 127.0.0.1:8799`(cloud-init 阶段 D-Bus 没起来,服务没注册),手动补一次注册:
```bash
cc-pocket-daemon service-install --apply --exec ~/.local/bin/cc-pocket-daemon
systemctl --user enable --now cc-pocket-daemon
```
之后配对即可。配对一次后 daemon 由 systemd 用户服务托管,VM 重启自动起(linger 已开)。手机 App 从 [cc-pocket 项目](https://github.com/heypandax/cc-pocket) README 列出的商店下载。

跨网络用 cc-pocket(手机 4G 遥控)?家里 VM 重建时加 `-EnableTailscale` 预装(`.\launch.ps1 start -EnableTailscale`),进 VM `sudo tailscale up` 配对后即可。见 README 的 Tailscale 章节。**公司场景别开**(会被软件审计识别)。

## 常用子命令

```powershell
.\launch.ps1 status    # VM + 隧道 + cc-switch 端口探测
.\launch.ps1 stop      # 停隧道 + 停 VM(挂载持久,下次 start 自动重挂)
.\launch.ps1 restart   # stop + start
.\launch.ps1 delete    # 删 VM + 清隧道(workspace/ 和 .ssh-key 保留)
```

## 排障

主流程失败时按现象查 [references/troubleshooting.md](./references/troubleshooting.md):

| 现象 | 分支 |
|---|---|
| `multipass list` 卡住/超时,或 `launch.ps1` 报 `daemon 自动重置失败`,或 launch 卡在 SSH | §F Multipass Windows 服务/后端卡死;先恢复控制面,勿立刻 delete |
| `launch failed: Remote "" is unknown or unreachable` | §A 镜像源被改成了非官方源 |
| `cloud-init status --wait` 超时/返回非零 | §B launch 后 cloud-init 探测 |
| VM 里 env 检查是 `EMPTY`,或 `claude` 弹登录菜单 | §C 宿主机 .claude 权限锁死,env 同步为空 |
| `bash: *** fatal error - add_item ... errno 1` | §D Git Bash spawn bug(与 VM 无关) |
| SSH 隧道秒退 / cc-switch 端口探测 000 | §E 隧道;ExitCode 255 + `UNPROTECTED PRIVATE KEY FILE` 见 §E.1 |
| 挂载失败 / 非 ASCII 路径 | 见项目 README「挂载失败」 |

**注意**:§A(镜像源)和 §C(权限)这两类问题**不是每台机器都有**——只在遇到对应报错时才处理,别在正常机器上预防性乱改全局设置或文件权限。

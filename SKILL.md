---
name: cc-sandbox
description: 用 scripts/launch.ps1 在 Windows 上启动/唤醒 claude-dev Multipass VM(Ubuntu + Claude Code + cc-switch env 同步)。当用户说"启 VM""起个 VM""启动 claude-dev""跑一下这个项目的虚拟机"等,用此 skill。仅 Windows。
---

# cc-sandbox — 启动 Multipass 沙箱 VM

把 Claude Code 关进 Multipass Ubuntu VM(最大权限沙箱)。宿主机 cc-switch 写的 LLM env(token / base_url / 模型映射)只读同步进 VM;workspace 双向挂载。

**平台:仅 Windows。** 后端 Hyper-V 或 VirtualBox。VM 名固定 `claude-dev`。

## 目录约定(重要)

本 skill 包是**只读**的,可整体覆盖升级;所有**可写状态**(bundle 缓存、workspace、mounts.txt、SSH 密钥、隧道 pid)在状态目录,默认 `%USERPROFILE%\.cc-sandbox\`(参数 `-StateDir` 或环境变量 `CC_SANDBOX_HOME` 可覆盖):

```
<skill 包>/                       # 只读:scripts/、assets/、references/
%USERPROFILE%\.cc-sandbox\        # 可写:bundle\、workspace\、mounts.txt、.ssh-key、.tunnel.pid
```

从仓库根(开发模式)或 skills 安装目录(用户模式)运行均可,脚本自动定位资产与状态。

## 主流程(happy path)

多数机器按这几步就能起来。先跑,遇到失败再翻「排障」。

### 1. 前置检查(全绿再往下)

```powershell
multipass version           # 推荐/实测 1.14.1,勿升 1.16.x(其 daemon 在 Windows 不稳)
ssh -V                      # OpenSSH 客户端
```

两者缺一见 references/troubleshooting.md「前置」。宿主机 cc-switch(可选,见下"隧道自适应"):`netstat -ano | findstr 15721` 应 LISTENING;端口非默认时 `start` 带 `-CcSwitchPort <端口>`。

**必须准备 bundle**:项目只走离线安装,先跑一次 `.\scripts\prepare-bundle.ps1` 准备离线 bundle(~220MB 含 cc-pocket,首次慢但只下一次,存入状态目录)。之后 `delete + start` 的 cloud-init 从 13 分钟 → < 2 分钟。bundle 不齐 `launch.ps1 start` 会直接报错,先补齐再启动。

### 2. 启动(选一种挂载模式)

**传统单根模式**(默认,简单):状态目录下 `workspace\` 挂为 VM 根 `~/workspace`。

```powershell
.\scripts\launch.ps1 start
```

**多目录挂载**(挂多个宿主目录到 `~/workspace/<子目录>`):先把 `assets\mounts.example.txt` 复制为状态目录下 `mounts.txt` 填好路径,或直接传 `-ExtraMounts`。

```powershell
.\scripts\launch.ps1 start -NoRootWorkspace                     # 读状态目录的 mounts.txt
.\scripts\launch.ps1 start -NoRootWorkspace -ExtraMounts "D:\repo1","E:\repo2=alias2"
```

多目录模式必须 `-NoRootWorkspace`(Windows 上 Multipass 对嵌套挂载支持不稳);`-WorkspaceHost` 只在传统模式(单根)下用。

**`start` 全部参数**(权威来源:`scripts\launch.ps1` 顶部 `param()` 块):

| 参数 | 默认 | 备注 |
|---|---|---|
| `-WorkspaceHost <目录>` | `""` → 状态目录 `workspace\` | 单根模式自定义宿主 workspace 源;须已存在,与 `-NoRootWorkspace` 互斥 |
| `-StateDir <目录>` | `%USERPROFILE%\.cc-sandbox` | 可写状态目录(也受环境变量 `CC_SANDBOX_HOME` 影响) |
| `-Image` / `-Cpus` / `-MemoryGB` / `-DiskGB` | `noble` / `4` / `8` / `30` | VM 资源,仅 `delete + start` 重建时生效 |
| `-CcSwitchPort <端口>` | `15721` | 本地代理端口(反向隧道目标),每次启动生效;未显式传时自动采信 base_url 里的端口 |
| `-AptMirror <域名>` | `mirrors.aliyun.com` | VM 内 APT 镜像,渲染进 cloud-init,仅重建生效 |
| `-EnableTailscale` | 关 | 预装 Tailscale(见 references/optional-features.md),仅重建生效 |
| `-ExtraMounts <列表>` | 空 | `"路径"` / `"路径=子目录"`;须配 `-NoRootWorkspace`;优先于 mounts.txt |
| `-NoRootWorkspace` | 关 | 多目录模式:跳过根 workspace 挂载 |

首次 3–15 分钟(下载 Ubuntu 镜像 + cloud-init 装基础包;Node/Claude 从 bundle 离线装)。脚本会自动:开 privileged-mounts → 创建/唤醒 VM → 挂 `~/.claude`(RO)和 workspace → 起隧道(如需要)。

**隧道自适应**:脚本读宿主机 `~/.claude/settings.json` 的 `env.ANTHROPIC_BASE_URL`——指向 `127.0.0.1`/`localhost`(cc-switch 类本地代理)时起 SSH 反向隧道回连;是公网地址则自动跳过隧道,VM 直连。没有 cc-switch 的机器也能用。

> **后台跑法**:首次因为要下载镜像,建议后台运行 + 轮询输出文件看进度,别干等。

### 3. 验证(必做)

```powershell
.\scripts\launch.ps1 status
```

要看到:VM `Running`、隧道在跑或"直连模式"、`VM 里 curl ... 返回 HTTP 4xx`(4xx = 服务在,通;000 = 断)。

再确认 VM 里 env 同步到位(**这步最容易被权限问题坑,务必查**;**不要 `cat` settings.json,里面有 token**):

```powershell
multipass exec claude-dev -- bash -lc "jq -e '.env | type == \"object\" and length > 0' ~/.claude/settings.json >/dev/null && echo OK || echo EMPTY"
```

输出 `OK` = 同步到位;`EMPTY` → env 没同步进来 → 见 [排障 §C](references/troubleshooting.md)。

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

VM 里预装了 cc-pocket daemon,正常情况下 `delete + start` 重建后已自启;cc-pocket 已支持任意网络遥控,不需要 Tailscale。

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

## 常用子命令

```powershell
.\scripts\launch.ps1 status    # VM + 隧道/直连 + LLM 接入探测
.\scripts\launch.ps1 stop      # 停隧道 + 停 VM(挂载持久,下次 start 自动重挂)
.\scripts\launch.ps1 restart   # stop + start
.\scripts\launch.ps1 delete    # 删 VM + 清隧道(状态目录里的 workspace/ 和 .ssh-key 保留)
```

用户也可以不经过 Claude 手动跑这些命令(可在 PowerShell profile 里加
`function vm { & <skill 路径>\scripts\launch.ps1 @args }`,之后 `vm start` / `vm status` 直达)。

## 排障

主流程失败时按现象查 [references/troubleshooting.md](references/troubleshooting.md):

| 现象 | 分支 |
|---|---|
| `multipass list` 卡住/超时,或 launch 卡在 SSH | §F Multipass Windows 服务/后端卡死;先恢复控制面,勿立刻 delete |
| `launch failed: Remote "" is unknown or unreachable` | §A 镜像源被改成了非官方源 |
| `cloud-init status --wait` 超时/返回非零 | §B launch 后 cloud-init 探测 |
| VM 里 env 检查是 `EMPTY`,或 `claude` 弹登录菜单 | §C 宿主机 .claude 权限锁死,env 同步为空 |
| `bash: *** fatal error - add_item ... errno 1` | §D Git Bash spawn bug(与 VM 无关) |
| SSH 隧道秒退 / 端口探测 000 | §E 隧道;ExitCode 255 + `UNPROTECTED PRIVATE KEY FILE` 见 §E.1 |
| 挂载失败 / 非 ASCII 路径 | 见 references/troubleshooting.md 挂载章节 |

**注意**:§A(镜像源)和 §C(权限)这两类问题**不是每台机器都有**——只在遇到对应报错时才处理,别在正常机器上预防性乱改全局设置或文件权限。

## 回归验证

改了 scripts\launch.ps1 / assets\cloud-init.yaml / assets\tmux.conf 之后,跑 [references/verification.md](references/verification.md) 的清单(至少测试 1 + 4)确认没破。

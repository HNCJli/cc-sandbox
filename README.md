# claude-dev (Multipass VM)

> **目标读者**:Windows 用户,已经在用 cc-switch 管理 Claude Code 的 LLM provider,希望把 Claude Code 关进 VM 里跑 `--dangerously-skip-permissions` 最大权限,不污染宿主机。
>
> **平台**:仅支持 **Windows 10/11**(`launch.ps1` 是 PowerShell,后端是 Hyper-V 或 VirtualBox 的 Multipass)。Mac/Linux 不适用。

## 这是什么

把 Claude Code 关进 Multipass Ubuntu VM。VM 是个沙箱,可以放心给最大权限;配置仅复用宿主机 cc-switch 写的 **LLM env**(token / base_url / 模型映射,VM 内只读),其余字段一律过滤、用 Claude Code 默认配置;workspace 像数据卷一样双向同步。

**核心机制**:cc-switch 在宿主机 `127.0.0.1:15721` 跑本地代理(只听 localhost),VM 跨网络连不上。本项目用 **SSH 反向隧道**把宿主机 `15721` ↔ VM `15721` 接通:VM 里 Claude Code 访问自己的 `127.0.0.1:15721`,流量被隧道偷渡回宿主机 cc-switch。cc-switch 完全零改动。

## 快速开始

如果宿主机已装好 cc-switch + Multipass:

```powershell
git clone <repo-url>
cd claude-code-multipass
.\prepare-bundle.ps1         # 必须:准备离线 bundle(~220MB 含 cc-pocket,首次慢,后续 delete+start 提速 10+ 分钟)
.\launch.ps1 start           # 首次 3–15 分钟(镜像下载 + bundle 离线装软件)
multipass shell claude-dev
# VM 内:
claude --dangerously-skip-permissions
```

## 架构

```
Windows 宿主机
├─ cc-switch.exe                      监听 127.0.0.1:15721(只听 localhost)
├─ ~/.claude/settings.json            cc-switch 管理
├─ launch.ps1                         管 VM 生命周期 + SSH 反向隧道保活
│    └─ ssh -R 15721:127.0.0.1:15721  宿主机 → VM 的反向隧道
└─ Multipass VM "claude-dev"          Ubuntu 24.04 (noble)
     ├─ ubuntu 用户(非 root,免密 sudo)
     ├─ Claude Code                    npm 全局装
     ├─ Fish + fzf + zoxide + tmux      交互 shell + TUI 修复
     ├─ ~/.claude/settings.json        只含 env(白名单),RO,Claude Code 改不了
     ├─ ~/.claude-host/                ← 宿主机 ~/.claude 整目录挂载(内核层硬 RO,bind+remount)
     ├─ ~/workspace                     ← 传统模式:./workspace/ 持久挂载;
     │                                   多目录模式(-NoRootWorkspace):VM 本地父目录
     │                                   + 各宿主目录挂到 ~/workspace/<子目录>
     └─ 127.0.0.1:15721                ← SSH 反向隧道 ← 宿主机 cc-switch
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `cloud-init.yaml` | VM 装机脚本模板(含占位符,launch.ps1 渲染后喂给 multipass) |
| `launch.ps1` | VM 生命周期管理(start / stop / restart / status / delete) + 隧道保活 |
| `tmux.conf` | tmux 配置,cloud-init 渲染时注入 VM |
| `prepare-bundle.ps1` | 准备离线 bundle(Node + Claude Code + cc-pocket,含 SHA256 校验) |
| `install-bundle.sh` | VM 内从 bundle 离线装 Node/Claude Code/cc-pocket + 注册自启服务 |
| `progress.ps1` | 启动/cloud-init 进度显示(launch.ps1 引入) |
| `statusline.sh` | VM 内 Claude Code statusLine,cloud-init 渲染时注入 VM |
| `mounts.example.txt` | 多目录挂载配置示例(复制为本地 `mounts.txt`) |
| `workspace/` | 工作目录,挂到 VM `~/workspace`,VM 重建不丢(首次 start 自动创建) |

## 延伸文档

| 文档 | 内容 |
|---|---|
| [docs/mounts.md](docs/mounts.md) | 多目录挂载(`-NoRootWorkspace` / `-ExtraMounts` / `mounts.txt`)、junction 汇聚多个工作目录 |
| [docs/parameters.md](docs/parameters.md) | `start` 全部参数与默认值 |
| [docs/vm-daily.md](docs/vm-daily.md) | 外部 SSH 进 VM(IDE 集成)、Fish、tmux 快捷键 |
| [docs/optional-features.md](docs/optional-features.md) | 可选:VM 内装 Docker、Tailscale 跨网络直连 VM 服务(如 VM 里启动的 web) |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 故障排查:隧道 / 挂载 / cloud-init |
| [bundle/README.md](bundle/README.md) | 离线 bundle:准备、更新、失败诊断 |
| [docs/plans/clipboard-image-bridge.md](docs/plans/clipboard-image-bridge.md) | **未实施方案**:Windows 剪贴板图片桥接进 VM 的设计记录 |

## 前置

### 1. Multipass(推荐/实测 1.14.1,**勿升 1.16.x**)

下载 Windows installer: <https://multipass.run/install>

> 项目实测并锁定 **Multipass 1.14.1**:1.16.x 的 daemon(multipassd)在 Windows 上不稳,list/launch 会卡死或超时,需要管理员重启服务。请保持 1.14.1,不要点 Multipass 的升级提示。

后端二选一:
- **Hyper-V**(推荐,Win10/11 Pro 自带):需先在「启用或关闭 Windows 功能」勾选 Hyper-V
- **VirtualBox**:Hyper-V 不可用时(家庭版等)

装好后 PowerShell 验证:
```powershell
multipass version     # 应为 1.14.1,勿升 1.16.x
```

### 2. OpenSSH 客户端

Windows 10+ 通常自带。验证:
```powershell
ssh -V
Get-Command ssh-keygen   # 能列出路径即可
```

若缺:设置 → 应用 → 可选功能 → 添加功能 → OpenSSH 客户端。

### 3. cc-switch 在跑

宿主机上 `claude` 能正常用 → cc-switch 就在跑。验证:
```powershell
netstat -ano | findstr 15721
```
应看到 `TCP 127.0.0.1:15721 ... LISTENING`。

> cc-switch 端口若不是默认的 15721,跑 `start` 时带 `-CcSwitchPort <端口>` 即可。

## 常用操作

### 一行启动

```powershell
.\launch.ps1 start
```

首次 3–15 分钟(主要花在 Ubuntu 镜像下载;软件走 bundle 离线装)。完成后自动:
1. 开启 Multipass privileged-mounts(首次会触发 multipassd 重启,正常现象)
2. 创建/唤醒 VM
3. 挂载 `~/.claude` → VM `/home/ubuntu/.claude-host`(RO)
4. 挂载 `./workspace/` → VM `~/workspace`
5. 后台拉 SSH 反向隧道(`.tunnel.pid` 记录进程号)

**挂自定义目录**:加 `-WorkspaceHost` 指定宿主机任意已存在的目录,代替默认的项目下 `./workspace`:

```powershell
.\launch.ps1 start -WorkspaceHost D:\code\myrepo
```

VM 里仍挂到 `~/workspace`(位置不变)。换目录时直接再 `start` 一次即可,无需 `restart`。

要同时挂多个目录?用多目录模式(`-NoRootWorkspace` + `mounts.txt`),见 [docs/mounts.md](docs/mounts.md)。全部启动参数见 [docs/parameters.md](docs/parameters.md)。

### 进 VM

```powershell
multipass shell claude-dev
```

VM 内:
```bash
claude --dangerously-skip-permissions   # 启动 Claude Code,最大权限
tmux new -s work                        # tmux 会话
```

交互 shell 是 Fish,常用快捷键与外部 SSH 见 [docs/vm-daily.md](docs/vm-daily.md)。

### 其他子命令

```powershell
.\launch.ps1 status      # 看 VM + 隧道状态 + 自动 curl 探测 cc-switch 端口通不通
.\launch.ps1 stop        # 停隧道 + 停 VM(挂载持久记录,下次 start 自动重挂)
.\launch.ps1 restart     # stop + start
.\launch.ps1 delete      # 删 VM + 清理隧道(workspace/ 和 .ssh-key 保留)
```

### 宿主机重启后

直接 `.\launch.ps1 start`。脚本会自动清理上次留下的死隧道进程(`.tunnel.pid` 里写的 PID 在重启后已失效),重起一条新的。VM 自己会被 Multipass 唤醒。

唯一注意:cc-switch 不一定开机自启,如果 `start` 时它没跑,VM 里 Claude Code 会连不上 LLM —— 手动开一下 cc-switch 即可。

## 配置管理

### 改 Claude 配置

宿主机用 cc-switch UI 切 provider / 改 `~/.claude/settings.json` 后,VM 会自动同步 **LLM 相关 env**(token / base_url / 模型映射)。同步是**白名单**:只提取 `env` 字段,加上一个 VM 本地注入的 `statusLine`(指向 `~/.claude-statusline.sh`,显示模型/目录/分支/进度条/费用/时长);`mcpServers` / `hooks` / `permissions` 等一律不进 VM,走 Claude Code 默认配置。

- VM 里每次敲 `claude` 前会自动重新同步,**同一 shell 内切 provider 后立即生效**
- 新开 shell 也会同步一次(profile 脚本)

VM 里 `~/.claude/settings.json` 是 `chmod 444`,**Claude Code 在 VM 里改不了**,只能从宿主机改。

### 改 tmux 配置

编辑 `tmux.conf`,然后:
```powershell
.\launch.ps1 delete
.\launch.ps1 start
```
(tmux.conf 是 cloud-init 阶段注入的,改完要重建 VM)

### 改 launch.ps1 默认参数

CPU / 内存 / 磁盘 / 镜像 / cc-switch 端口 / APT 镜像等都参数化了。临时改用命令行参数(完整参数表见 [docs/parameters.md](docs/parameters.md)),想永久改默认值就编辑 `launch.ps1` 顶部 `param()` 块。

## 备注

- **单 VM 设计**:VM 名固定 `claude-dev`,workspace 默认独占 —— 不支持同时起多个 VM 共用同一个 workspace 目录(会两边互相覆盖)
- VM 行为:`multipass stop` 后不会自动起,需手动 `.\launch.ps1 start`
- VM 里改 `~/.claude/settings.json` 会被 chmod 444 挡住;真要改就改宿主机的
- cc-switch 端口(默认 15721)若变了,用 `-CcSwitchPort` 参数或改 `launch.ps1` 的 `param()` 块默认值
- 资源占用:默认 4 CPU / 8G 内存 / 30G 盘,调整见 [docs/parameters.md](docs/parameters.md)(改资源配置需 `delete + start` 重建生效)

## License

MIT,见 [LICENSE](LICENSE)。

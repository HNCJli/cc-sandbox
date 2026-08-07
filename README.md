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
.\launch.ps1 start          # 首次 3-5 分钟,装 Node + Claude Code
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
└─ Multipass VM "claude-dev"          Ubuntu 24.04
     ├─ ubuntu 用户(非 root,免密 sudo)
     ├─ Claude Code                    npm 全局装
     ├─ tmux + TUI 修复
     ├─ ~/.claude/settings.json        只含 env(白名单),RO,Claude Code 改不了
     ├─ ~/.claude-host/                ← 宿主机 ~/.claude 整目录挂载(VM 内 RO)
     ├─ ~/workspace                     ← ./workspace/ 持久挂载
     └─ 127.0.0.1:15721                ← SSH 反向隧道 ← 宿主机 cc-switch
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `cloud-init.yaml` | VM 装机脚本模板(含占位符,launch.ps1 渲染后喂给 multipass) |
| `launch.ps1` | VM 生命周期管理(start / stop / restart / status / delete) + 隧道保活 |
| `tmux.conf` | tmux 配置,cloud-init 渲染时注入 VM |
| `workspace/` | 工作目录,挂到 VM `~/workspace`,VM 重建不丢(首次 start 自动创建) |

## 前置

### 1. Multipass ≥ 1.11

下载 Windows installer: <https://multipass.run/install>

后端二选一:
- **Hyper-V**(推荐,Win10/11 Pro 自带):需先在「启用或关闭 Windows 功能」勾选 Hyper-V
- **VirtualBox**:Hyper-V 不可用时(家庭版等)

装好后 PowerShell 验证:
```powershell
multipass version     # 要求 ≥ 1.11
```

### 2. OpenSSH 客户端

Windows 10+ 通常自带。验证:
```powershell
ssh -V
ssh-keygen -h    # 任意输出即可
```

若缺:设置 → 应用 → 可选功能 → 添加功能 → OpenSSH 客户端。

### 3. cc-switch 在跑

宿主机上 `claude` 能正常用 → cc-switch 就在跑。验证:
```powershell
netstat -ano | findstr 15721
```
应看到 `TCP 127.0.0.1:15721 ... LISTENING`。

> cc-switch 端口若不是默认的 15721,改 `launch.ps1` 顶部 `$ccSwitchPort` 一处即可。

## 常用操作

### 一行启动

```powershell
.\launch.ps1 start
```

首次 3–5 分钟(cloud-init 装 Node + Claude Code)。完成后自动:
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

### 进 VM

```powershell
multipass shell claude-dev
```

VM 内:
```bash
claude --dangerously-skip-permissions   # 启动 Claude Code,最大权限
tmux new -s work                        # tmux 会话
```

### 其他子命令

```powershell
.\launch.ps1 status      # 看 VM + 隧道状态 + 自动 curl 探测 cc-switch 端口通不通
.\launch.ps1 stop        # 停隧道 + 停 VM(挂载持久记录,下次 start 自动重挂)
.\launch.ps1 restart     # stop + start
.\launch.ps1 delete      # 删 VM + 清理隧道(workspace/ 和 .ssh-key 保留)
```

## 配置管理

### 改 Claude 配置

宿主机用 cc-switch UI 切 provider / 改 `~/.claude/settings.json` 后,VM 会自动同步 **LLM 相关 env**(token / base_url / 模型映射)。同步是**白名单**:只提取 `env` 字段,statusLine / mcpServers / hooks / permissions 等一律不进 VM,其余走 Claude Code 默认配置。

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

编辑 `launch.ps1` 顶部「配置」段:CPU、内存、磁盘、cc-switch 端口等。

## SSH 进 VM(IDE 集成 / 外部 SSH 客户端)

VM 默认通过 `multipass shell` 进,不用密码。若要外部 SSH(如 VSCode Remote-SSH):

`~/.ssh/config` 加:
```
Host claude-dev
    HostName <VM IP>            # multipass info claude-dev 看 IPv4
    User ubuntu
    IdentityFile <项目路径>/.ssh-key
    StrictHostKeyChecking no
```

VM IP 在 stop/start 后可能变,需更新。持久的 `multipass shell` 不受影响。

## 可选:VM 内装 Docker

cloud-init 留了注释掉的 Docker 安装代码块。需要时编辑 `cloud-init.yaml`,取消 `runcmd` 末尾 3 行注释:

```yaml
  - apt-get install -y docker.io
  - usermod -aG docker ubuntu
  - systemctl enable --now docker
```

然后:
```powershell
.\launch.ps1 delete
.\launch.ps1 start
```

## tmux 快捷键

| 操作 | 快捷键 / 命令 |
|---|---|
| 新建会话 | `tmux new -s <名字>` |
| 退到后台(detach) | `Ctrl+B` 松开,再按 `D`(Shift) |
| 重新连回 | `tmux a` 或 `tmux a -t <名字>` |
| 列出会话 | `tmux ls`(没会话时报 `error connecting to ...` 是正常提示,不是 bug) |
| 不依赖快捷键的退出 | 在 tmux 内的 shell 敲 `tmux detach-client` |

> 若再遇到小写 `d` 不触发 detach(原作者容器时代曾遇到),在 `tmux.conf` 加一行 `bind d detach-client` 显式绑。

## 故障排查

### VM 里 Claude Code 报连不上 LLM / cc-switch

```powershell
# 1. 隧道在不在?
.\launch.ps1 status                    # 看 "SSH 反向隧道" 段 + "VM 内 cc-switch 端口探测"
                                       # 返回 HTTP 404 = 通(根路径不响应但服务在);000 = 隧道断

# 2. VM 里手动 curl
multipass exec claude-dev -- curl -v http://127.0.0.1:15721/
# connection refused → 隧道断了,restart

# 3. settings.json 同步了吗(应只含 env,无 statusLine/mcpServers 等)
multipass exec claude-dev -- cat /home/ubuntu/.claude/settings.json
```

### 隧道进程死了

```powershell
.\launch.ps1 restart                   # 重拉一切
# 或只重起隧道(不重启 VM):
Stop-Process -Id (Get-Content .tunnel.pid) -Force
Remove-Item .tunnel.pid
.\launch.ps1 start                     # 检测到 VM 在 Running 会跳过 launch,只重挂/重起隧道
```

### 挂载失败 / Multipass 报 "Mounts are disabled"

Multipass 1.16+ 默认禁 privileged-mounts。`launch.ps1 start` 首次会自动开启(`multipass set local.privileged-mounts=true`),若失败手动执行一次即可。

### 挂载失败(非 ASCII 路径)

如果 Windows 账号名或项目路径含中文等非 ASCII 字符,`multipass mount` 在 Windows 上支持不稳。

**workspace 挂不上**的备选:
1. 把项目挪到 ASCII 路径(如 `C:\dev\claude-vm\`),重新 `.\launch.ps1 start`
2. 或在 ASCII 路径建 Windows junction 指向真实路径:
   ```powershell
   New-Item -ItemType Junction -Path C:\dev\workspace -Target "<项目实际路径>\workspace"
   ```
   然后 `.\launch.ps1 start -WorkspaceHost C:\dev\workspace` 用 junction 路径启动

**`~/.claude` 挂不上**:用 junction:
```powershell
New-Item -ItemType Junction -Path C:\dev\claude-config -Target "$env:USERPROFILE\.claude"
# 编辑 launch.ps1 把 $hostClaude 改成 C:\dev\claude-config
```

### cloud-init 没跑完

```powershell
multipass exec claude-dev -- cloud-init status --long    # 看详细
multipass exec claude-dev -- sudo cat /var/log/cloud-init-output.log
```

### 想完全重来

```powershell
.\launch.ps1 delete
.\launch.ps1 start
```

`.ssh-key`、`workspace/` 不会删,会复用。

## 备注

- VM 行为:`multipass stop` 后不会自动起,需手动 `.\launch.ps1 start`
- VM 里改 `~/.claude/settings.json` 会被 chmod 444 挡住;真要改就改宿主机的
- cc-switch 端口(默认 15721)若变了,改 `launch.ps1` 顶部 `$ccSwitchPort`(cloud-init.yaml 里只有注释,无需改)
- 资源占用:默认 2 CPU / 4G 内存 / 20G 盘,内存吃紧时调 `launch.ps1` 的 `$memoryGB`

## License

MIT,见 [LICENSE](LICENSE)。

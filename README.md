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
.\launch.ps1 start           # 首次 3-15 分钟(镜像下载 + bundle 离线装软件)
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
| `workspace/` | 工作目录,挂到 VM `~/workspace`,VM 重建不丢(首次 start 自动创建) |

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
ssh-keygen -h    # 任意输出即可
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

首次 3–5 分钟(bundle 离线装 Node + Claude Code)。完成后自动:
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

### 多目录挂载(挂多个 workspace 子目录)

需要同时挂多个宿主机目录到 VM 时,用 `-NoRootWorkspace` + `-ExtraMounts`(或本地 `mounts.txt`):

```powershell
.\launch.ps1 start -NoRootWorkspace -ExtraMounts "D:\code\repo1","E:\proj\repo2=alias2"
```

每项格式 `HostPath` 或 `HostPath=vmSubdir`;简写时子目录名取宿主目录最后一级。VM 内挂成 `~/workspace/<子目录>`。

也可在项目根目录建本地 `mounts.txt`(基于 `mounts.example.txt` 复制,每行一项,`#` 起始为注释),`-ExtraMounts` 未传时自动读它:

```text
D:\code\repo1
E:\proj\repo2=alias2
```

`mounts.txt` 是本地配置(`.gitignore` 忽略)。

> **为什么必须 `-NoRootWorkspace`**:Windows 上 Multipass 对嵌套挂载(把目录挂到另一个已挂载目录内部)支持不稳,曾出现挂载失败甚至卡死。根 `~/workspace` 默认挂着 `./workspace`,此时再往 `~/workspace/xxx` 挂会踩到这个问题。`-NoRootWorkspace` 跳过根挂载,让 `~/workspace` 变回 VM 本地目录,子目录挂载便不再嵌套。
>
> 多目录模式下,`~/workspace` 是 VM 本地目录,**`delete` VM 时会丢**(子目录里的内容跟着没了)。子目录里别放原始代码,源码留在宿主机目录。

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

### 宿主机重启后

直接 `.\launch.ps1 start`。脚本会自动清理上次留下的死隧道进程(`.tunnel.pid` 里写的 PID 在重启后已失效),重起一条新的。VM 自己会被 Multipass 唤醒。

唯一注意:cc-switch 不一定开机自启,如果 `start` 时它没跑,VM 里 Claude Code 会连不上 LLM —— 手动开一下 cc-switch 即可。

### 临时换配置

CPU / 内存 / 磁盘 / 镜像版本都参数化了,不用改源码:

```powershell
.\launch.ps1 start -MemoryGB 8 -Cpus 4                # 临时给大点
.\launch.ps1 start -Image noble                        # 指定镜像版本(默认 noble / 24.04)
```
(只有 `delete + start` 重建时这些参数才生效;已存在的 VM 改参数不会动)

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

CPU / 内存 / 磁盘 / 镜像 / cc-switch 端口都参数化了,见 `launch.ps1` 顶部 `param()` 块默认值。临时改用命令行参数(见上文"临时换配置"),想永久改默认值就编辑 `param()` 块。

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

## VM 交互 shell:Fish

VM 默认交互 shell 是 **Fish**(配 fzf + zoxide)。`multipass shell claude-dev` 进去就是 fish 提示符:

- **灰色历史建议**:边敲边显示匹配的历史命令,`→` 或 `Ctrl+F` 接受
- **`Tab` 补全** / **`Ctrl+R`** 模糊搜历史(fzf)
- **`z <关键词>`** 智能跳转目录(zoxide,基于使用频率)
- 临时需要 bash 敲 `bash`;`.sh` 脚本和 cloud-init 仍走 bash

每次敲 `claude` 前,fish 和 bash 一样会自动重新同步 cc-switch env(读 `~/.claude-host`,jq 过滤,写 `~/.claude/settings.json` chmod 444)。

## 离线 bundle(慢网络/迭代快)

慢网络下在线装 Node + Claude Code 要 10–15 分钟,反复 `delete + start` 浪费时间。**离线 bundle** 把 Node 20 LTS + Claude Code + cc-pocket 预下载到本地,launch 时直接挂进 VM 装,cloud-init 压到 < 2 分钟。

### 准备

```powershell
.\prepare-bundle.ps1              # 缺啥下啥,首次约 220 MB(含 cc-pocket,慢网络可能 5-10 分钟)
# 之后:
.\launch.ps1 delete               # 清旧 VM(旧 VM 已装过,不重建用不上新 bundle)
.\launch.ps1 start                # 新 VM 走离线模式,< 2 分钟完成 cloud-init
```

`launch.ps1 start` 会检测 bundle/,**必须齐全才启动**:不齐直接报错(项目只走离线安装,不做在线降级),先跑 `.\prepare-bundle.ps1` 补齐。已建好的 VM 重跑 `start` 同样要求 bundle 齐全。

### 更新

`@anthropic-ai/claude-code` 发新版或想升 Node 版本:

```powershell
.\prepare-bundle.ps1 -Force       # 重下最新
.\launch.ps1 delete
.\launch.ps1 start
```

### 内容

| 文件 | 大小 | 用途 |
|---|---|---|
| `node-vXX.X.X-linux-x64.tar.xz` | ~25 MB | Node 20 LTS Linux 二进制(含 npm/npx) |
| `anthropic-ai-claude-code-X.X.X.tgz` | ~25 KB | Claude Code wrapper 包 |
| `anthropic-ai-claude-code-linux-x64-X.X.X.tgz` | ~93 MB | Claude Code Linux 真二进制 |
| `cc-pocket/cc-pocket-daemon-X.X.X-linux-x86_64.tar.gz` | ~105 MB | cc-pocket 手机遥控(自带 JRE) |

> `@anthropic-ai/claude-code` 是 wrapper 包,真二进制在平台特定的 `@anthropic-ai/claude-code-linux-x64`。两个都要 bundle,wrapper postinstall 才能把二进制装到位。

bundle 不进 git(只 `bundle/README.md` 进),只本地存。详见 [`bundle/README.md`](bundle/README.md)。

## 可选:VM 内装 Docker

VM 已经是 Ubuntu,直接 `apt install` 就行,不用重建:

```bash
# 进 VM 后
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker ubuntu     # 然后退出重进 shell 让组生效
sudo systemctl enable --now docker
```

## 可选:跨网络访问 VM(Tailscale)

家里跨网络(手机 4G、外面咖啡店)想直连 VM 时,加 `-EnableTailscale` 预装:

```powershell
.\launch.ps1 delete                # cloud-init 只在 launch 时跑,改预装必须重建 VM
.\launch.ps1 start -EnableTailscale
```

VM 起来后,**进 VM 手动配对**(cloud-init 阶段没法弹浏览器):
```bash
sudo tailscale up              # 弹 URL,浏览器登录同一个 tailscale 账号
tailscale ip                   # 看 VM 拿到的 100.x.x.x 内网 IP
```

手机/其他设备登同一个 tailscale 账号后,就能用那个 100.x.x.x IP SSH / 直连 VM 上任意服务。

**⚠️ 公司场景千万别开**:
- `-EnableTailscale` 会真的把 tailscale 包装进 VM
- 即使不 `tailscale up` 没有出站流量,公司软件审计(SCCM 类)能扫到包已装
- 公司禁远控/打洞软件时,这会被识别为违规
- 公司场景用 `.\launch.ps1 start`(不带 `-EnableTailscale`),完全不碰

**关于 cc-pocket(核心场景)**:宿主机实测过 —— 装 tailscale + 配对后,手机用 4G 流量能通过 cc-pocket 连到本机 Claude Code。VM 里同理:**装 `-EnableTailscale` + 配对后,手机跨网络也能用 cc-pocket 遥控 VM 里的 Claude Code**。这是本功能的主要动机,不是顺带的 SSH/直连能力。

## tmux 快捷键

| 操作 | 快捷键 / 命令 |
|---|---|
| 新建会话 | `tmux new -s <名字>` |
| 退到后台(detach) | `Ctrl+B` 松开,再按 `D`(Shift) |
| 重新连回 | `tmux a` 或 `tmux a -t <名字>` |
| 列出会话 | `tmux ls`(没会话时报 `error connecting to ...` 是正常提示,不是 bug) |
| 不依赖快捷键的退出 | 在 tmux 内的 shell 敲 `tmux detach-client` |

## 故障排查

### VM 里 Claude Code 报连不上 LLM / cc-switch

```powershell
# 1. 隧道在不在?
.\launch.ps1 status                    # 看 "SSH 反向隧道" 段 + "VM 内 cc-switch 端口探测"
                                       # 返回 HTTP 404 = 通(根路径不响应但服务在);000 = 隧道断

# 2. VM 里手动 curl
multipass exec claude-dev -- curl -v http://127.0.0.1:15721/
# connection refused → 隧道断了,restart

# 3. settings.json 同步了吗(应含 env + 本地 statusLine,无 mcpServers 等;含明文 token,别直接 cat)
multipass exec claude-dev -- bash -lc "jq -e '.env | type == \"object\" and length > 0' ~/.claude/settings.json >/dev/null && echo 'env 同步 OK' || echo 'env 为空'"
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

Windows 上 Multipass 默认可能禁用 privileged-mounts。`launch.ps1 start` 首次会自动开启(`multipass set local.privileged-mounts=true`),若失败手动执行一次即可。

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

- **单 VM 设计**:VM 名固定 `claude-dev`,workspace 默认独占 —— 不支持同时起多个 VM 共用同一个 workspace 目录(会两边互相覆盖)
- VM 行为:`multipass stop` 后不会自动起,需手动 `.\launch.ps1 start`
- VM 里改 `~/.claude/settings.json` 会被 chmod 444 挡住;真要改就改宿主机的
- cc-switch 端口(默认 15721)若变了,用 `-CcSwitchPort` 参数或改 `launch.ps1` 的 `param()` 块默认值
- 资源占用:默认 2 CPU / 4G 内存 / 20G 盘,内存吃紧时 `-MemoryGB 8` 临时调大

## License

MIT,见 [LICENSE](LICENSE)。

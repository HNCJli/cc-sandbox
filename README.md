# cc-sandbox

> **这是什么**:把 Claude Code 关进 Multipass Ubuntu VM 的 Windows 沙箱,预装 Fish/fzf/zoxide/tmux/cc-pocket,开箱即用。VM 里可以放心跑 `--dangerously-skip-permissions` 最大权限,不污染宿主机;LLM env(token / base_url / 模型映射)从宿主机只读同步进 VM;workspace 双向挂载。
>
> **平台**:仅 **Windows 10/11**(Hyper-V 或 VirtualBox 后端)。Mac/Linux 不适用。

本仓库同时是一个 **Claude Code skill 包**:clone 到 skills 目录即完成安装,Claude 会被触发帮你起 VM、排障、跑回归。

## 安装

```powershell
# 前提:已装 Multipass(推荐 1.14.1,勿升 1.16.x)
git clone https://github.com/HNCJli/cc-sandbox.git "$env:USERPROFILE\.claude\skills\cc-sandbox"
```

装好后对 Claude 说"启 VM / 起个 VM / 启动 claude-dev"即可,skill 入口见 [SKILL.md](SKILL.md)。

没有 cc-switch 也能用:脚本读宿主机 `~/.claude/settings.json` 的 `ANTHROPIC_BASE_URL` 自动判定——本地代理(cc-switch 类)起 SSH 反向隧道,公网地址直连跳过隧道。

## 从旧版升级(前身 claude-dev-vm)

新版状态目录固定为 `~\.cc-sandbox`(不提供环境变量/参数更换),**不兼容旧版**(旧的 `CLAUDE_DEV_VM_HOME` 不再识别)。旧版用户三步迁移:

```powershell
Move-Item "$env:USERPROFILE\.claude-dev-vm" "$env:USERPROFILE\.cc-sandbox"  # 状态整体搬家,免重下 220MB bundle
& $vm delete                                                                 # 删旧 VM(workspace/.ssh-key 在状态目录,已保留)
& $vm start                                                                  # 重建 VM(VM 名仍是 claude-dev,镜像有缓存)
```

VM 内 Tailscale / cc-pocket 需重新配对。skill 目录若按旧路径安装,重新 clone 到 `skills\cc-sandbox` 即可。

## 手动使用(不经过 Claude)

```powershell
$vm = "$env:USERPROFILE\.claude\skills\cc-sandbox\scripts\launch.ps1"
& $vm start          # 创建/启动 VM + 挂载 + 隧道(如需要);首次先跑 & $vm 所在目录的 prepare-bundle.ps1
& $vm status         # VM + 隧道/直连 + LLM 接入探测
& $vm stop | delete
```

嫌长可在 PowerShell profile 加一行,之后任何目录 `vm start`:

```powershell
function vm { & "$env:USERPROFILE\.claude\skills\cc-sandbox\scripts\launch.ps1" @args }
```

开发本仓库时,从仓库根直接 `.\scripts\launch.ps1 start` 同样可用。

## 目录结构

```
/(skill 包,只读)             %USERPROFILE%\.cc-sandbox\(状态目录,可写)
├─ SKILL.md                    ├─ bundle\         离线包(~220MB,prepare-bundle 下载)
├─ scripts/                    ├─ mounts.txt      挂载配置(基于 assets\mounts.example.txt)
│  ├─ launch.ps1               ├─ mounts.example.txt  模板(脚本自动放置)
│  ├─ feature-menu.ps1         ├─ features.txt    可选特性选择(start 交互菜单自动改写)
│  ├─ prepare-bundle.ps1       ├─ .ssh-key(.pub)  VM SSH 密钥
│  └─ progress.ps1
│                               └─ .tunnel.pid     隧道进程号
├─ assets/                     (状态目录固定 %USERPROFILE%\.cc-sandbox,不可更换)
│  ├─ cloud-init.yaml          旧布局(状态放仓库根)首次运行自动迁移到状态目录,原文件保留
│  ├─ install-bundle.sh
│  ├─ statusline.sh
│  ├─ tmux.conf
│  ├─ mounts.example.txt
│  └─ features.example.txt
├─ references/
└─ README.md / LICENSE
```

## 快速开始(手动)

```powershell
cd $env:USERPROFILE\.claude\skills\cc-sandbox
.\scripts\prepare-bundle.ps1    # 必须:离线 bundle(~220MB 含 cc-pocket,首次慢,只下一次)
.\scripts\launch.ps1 start      # 首次 3–15 分钟(镜像下载 + bundle 离线装软件)
multipass shell claude-dev
# VM 内:
claude --dangerously-skip-permissions
```

workspace 挂载(mounts.txt,每项挂成 `~/workspace/<子目录>`)见 [references/mounts.md](references/mounts.md);可选特性(Tailscale 等)在真人终端裸跑 `start` 时弹菜单选择,持久化到 features.txt,见 [references/optional-features.md](references/optional-features.md)。

## 架构

```
Windows 宿主机
├─ cc-switch.exe(可选)           监听 127.0.0.1:15721(只听 localhost)
├─ ~/.claude/settings.json        LLM env 来源(白名单同步进 VM)
├─ scripts\launch.ps1             管 VM 生命周期 + SSH 反向隧道保活(按需)
│    └─ ssh -R 15721:127.0.0.1:15721  宿主机 → VM 的反向隧道(仅本地代理模式)
└─ Multipass VM "claude-dev"      Ubuntu 24.04 (noble)
     ├─ ubuntu 用户(非 root,免密 sudo)
     ├─ Claude Code                bundle 离线装
     ├─ Fish + fzf + zoxide + tmux
     ├─ ~/.claude/settings.json    只含 env(白名单),RO
     ├─ ~/.claude-host/            ← 宿主机 ~/.claude 整目录挂载(内核层硬 RO)
     ├─ ~/workspace               ← VM 本地父目录
     │                               + mounts.txt 各宿主目录挂到 ~/workspace/<子目录>
     └─ 127.0.0.1:15721            ← SSH 反向隧道 ← 宿主机 cc-switch(或直连公网网关)
```

## 文档

| 文档 | 内容 |
|---|---|
| [SKILL.md](SKILL.md) | skill 入口:启动主流程、参数表、验证步骤、排障索引 |
| [references/mounts.md](references/mounts.md) | 多目录挂载、mounts.txt、junction 汇聚多个工作目录 |
| [references/parameters.md](references/parameters.md) | `start` 全部参数与默认值 |
| [references/vm-daily.md](references/vm-daily.md) | 外部 SSH 进 VM(IDE 集成)、Fish、tmux 快捷键 |
| [references/optional-features.md](references/optional-features.md) | 可选:VM 内装 Docker、Tailscale 跨网络直连 VM 服务 |
| [references/troubleshooting.md](references/troubleshooting.md) | 故障排查:快速排查 + 深度排障(§A–§F) |
| [references/bundle.md](references/bundle.md) | 离线 bundle:准备、更新、失败诊断 |
| [references/verification.md](references/verification.md) | 回归验证清单 |
| [references/plans/clipboard-image-bridge.md](references/plans/clipboard-image-bridge.md) | **未实施方案**:Windows 剪贴板图片桥接进 VM 的设计记录 |

## License

MIT,见 [LICENSE](LICENSE)。

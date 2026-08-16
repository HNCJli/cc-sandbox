# `start` 参数表

`.\scripts\launch.ps1 start` 全部参数。**权威来源:`scripts\launch.ps1` 顶部 `param()` 块**——本文档与它不一致时以 `param()` 块为准。

| 参数 | 默认 | 说明 |
|---|---|---|
| `-WorkspaceHost <目录>` | `""` → 状态目录 `workspace\` | 单根模式自定义宿主 workspace 目录(须已存在,不自动创建;与 `-NoRootWorkspace` 互斥) |
| `-StateDir <目录>` | `%USERPROFILE%\.claude-dev-vm` | 可写状态目录(bundle/workspace/mounts.txt/.ssh-key 等;也受 `CLAUDE_DEV_VM_HOME` 影响) |
| `-Image <镜像>` | `noble` | Ubuntu 镜像(24.04 LTS) |
| `-Cpus <n>` | `4` | VM CPU 核数 |
| `-MemoryGB <n>` | `8` | VM 内存(GB) |
| `-DiskGB <n>` | `30` | VM 磁盘(GB) |
| `-CcSwitchPort <端口>` | `15721` | 本地代理端口(反向隧道目标);未显式传时自动采信 base_url 里的端口 |
| `-AptMirror <域名>` | `mirrors.aliyun.com` | VM 内 APT 镜像(渲染进 cloud-init) |
| `-EnableTailscale` | 关 | 预装 Tailscale(见 [optional-features.md](optional-features.md)) |
| `-ExtraMounts <列表>` | 空 | `"路径"` / `"路径=子目录"`,挂到 `~/workspace/<子目录>`;须配 `-NoRootWorkspace`;优先于 mounts.txt(见 [mounts.md](mounts.md)) |
| `-NoRootWorkspace` | 关 | 多目录挂载模式(见 [mounts.md](mounts.md)) |

```powershell
.\scripts\launch.ps1 start -MemoryGB 16 -Cpus 8   # 临时给大点(需重建生效)
.\scripts\launch.ps1 start -Image noble           # 指定镜像版本(默认 noble / 24.04)
```

> `-Image / -Cpus / -MemoryGB / -DiskGB / -AptMirror / -EnableTailscale` 都是**建 VM 时**生效(传给 `multipass launch` / 渲染进 cloud-init);VM 已存在时 `start` 只重挂/重起隧道,改这些参数不会动现有 VM——要生效得 `delete + start` 重建。`-CcSwitchPort` 每次启动都生效。

**隧道自适应**:脚本读宿主机 `~/.claude/settings.json` 的 `env.ANTHROPIC_BASE_URL`——指向 `127.0.0.1`/`localhost`(cc-switch 类本地代理)时起 SSH 反向隧道;是公网地址则自动跳过隧道,VM 直连。

想永久改默认值:编辑 `scripts\launch.ps1` 顶部 `param()` 块。

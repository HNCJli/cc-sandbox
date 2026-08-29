# `start` 参数表

`.\scripts\launch.ps1 start` 全部参数。**权威来源:`scripts\launch.ps1` 顶部 `param()` 块**——本文档与它不一致时以 `param()` 块为准。

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Name <名字>` | `claude-dev` | VM 名(多 VM):所有子命令(start/stop/status/delete)可用;每台 VM 状态独立子目录,bundle/SSH key 共享。status 不带 -Name 且受管 VM 多于一台时给总览 |
| `-Cpus <n>` | `4` | VM CPU 核数 |
| `-MemoryGB <n>` | `8` | VM 内存(GB) |
| `-DiskGB <n>` | `30` | VM 磁盘(GB) |
| `-CcSwitchPort <端口>` | `15721` | 本地代理端口(反向隧道目标);未显式传时自动采信 base_url 里的端口 |
| `-AptMirror <域名>` | `mirrors.aliyun.com` | VM 内 APT 镜像(渲染进 cloud-init) |

workspace 挂载没有参数:唯一模式,读该 VM 子目录的 `mounts.txt`(见 [mounts.md](mounts.md))。

```powershell
.\scripts\launch.ps1 start -MemoryGB 16 -Cpus 8        # 临时给大点(需重建生效)
.\scripts\launch.ps1 start -Name dev-java -MemoryGB 4  # 起第二台 VM
```

> `-Cpus / -MemoryGB / -DiskGB / -AptMirror` 都是**建 VM 时**生效(传给 `multipass launch` / 渲染进 cloud-init);VM 已存在时 `start` 只重挂/重起隧道,改这些参数不会动现有 VM——要生效得 `delete + start` 重建(交互终端跑 `start` 时,新启用的特性会被探测到并询问是否一键重建)。`-CcSwitchPort` 每次启动都生效。镜像固定 noble(Ubuntu 24.04 LTS),换版本编辑 `launch.ps1` 常量区 `$vmImage`。

## 可选特性选择(交互菜单 / features.txt)

可选特性(如 Tailscale)**没有命令行开关**,只认两种来源,优先级从高到低:

1. **交互菜单**:真人终端裸跑 `start` 弹方向键多选菜单(↑↓ 移动、空格 勾选、回车 确认;数字键直接切换某项,`a`/`n` 全选/全不选;不支持按键或窗口过小的终端自动降级为编号输入)
2. **features.txt**:状态目录下的持久化文件(每行一个特性 id,`#` 注释;格式见 `assets\features.example.txt`)

菜单的选择会**写回 features.txt**,所以 `delete + start` 重建、日常 start 都自动沿用,不用记参数;想关掉就在菜单里选 `n`,或删掉文件里那行(重建型特性关闭后需重建 VM 才真正卸载)。stdin 被重定向时(后台/管道/Claude 代跑)自动跳过菜单、静默读 features.txt。当前全部特性见 [optional-features.md](optional-features.md);`status` 子命令也会显示已启用的特性。

**隧道自适应**:脚本读宿主机 `~/.claude/settings.json` 的 `env.ANTHROPIC_BASE_URL`——指向 `127.0.0.1`/`localhost`(cc-switch 类本地代理)时起 SSH 反向隧道;是公网地址则自动跳过隧道,VM 直连。

想永久改默认值:编辑 `scripts\launch.ps1` 顶部 `param()` 块。

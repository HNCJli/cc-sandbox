# bundle/ 离线包目录

这个目录存 cloud-init 离线安装用的本地包,**让 VM 创建不依赖网络下载**。

## 内容(约 113 MB)

| 文件 | 大小 | 说明 |
|---|---|---|
| `node-vXX.X.X-linux-x64.tar.xz` | ~25 MB | Node 20 LTS Linux 官方 tarball |
| `anthropic-ai-claude-code-X.X.X.tgz` | ~25 KB | Claude Code wrapper 包(postinstall 装真二进制) |
| `anthropic-ai-claude-code-linux-x64-X.X.X.tgz` | ~93 MB | Claude Code Linux 真二进制 |

## 怎么准备

```powershell
.\prepare-bundle.ps1              # 缺啥下啥,首次约 113 MB
.\prepare-bundle.ps1 -Force       # 重新下载所有
.\prepare-bundle.ps1 -NodeVersion v20.20.2  # 指定 Node 版本
```

`prepare-bundle.ps1` 是幂等的,文件已存在就跳过(除非 `-Force`)。

## 怎么用

不用手动用。`.\launch.ps1 start` 启动时会自动检测 bundle/:

- **齐全** → launch 时挂载 `bundle/` → VM `/home/ubuntu/.bundle`,cloud-init 从本地装 Node + Claude Code,**离线模式**,cloud-init < 2 分钟
- **不齐** → 走在线模式(curl nodesource + npm registry),慢网络下 cloud-init 13+ 分钟

bundle 准备好后,需要 `delete + start` 重建 VM 才生效(现有 VM 已经在线装过了)。

## 更新策略

`@anthropic-ai/claude-code` 发新版后想升级:

```powershell
.\prepare-bundle.ps1 -Force       # 重下最新版
.\launch.ps1 delete
.\launch.ps1 start                # 重建 VM,用新版 bundle
```

Node 版本升级同理。

## 为什么不进 git

二进制大文件(Node 25MB + Claude 93MB)不适合 git 仓库。`bundle/` 在 `.gitignore` 里,只保留 `README.md` 跟踪在版本控制。

## 失败诊断

- **`npm pack` 失败**:宿主机没装 Node/npm?装一个宿主机版 Node。
- **下载超时**:网络太慢,挂 VPN 或换镜像源后重试。
- **bundle 不齐就跑 launch**:不阻断,自动降级为在线模式(`launch.ps1` 会提示)。

# bundle/ 离线包目录

这个目录存 cloud-init 离线安装用的本地包,**让 VM 创建不依赖网络下载**。

## 内容(约 220 MB,含 cc-pocket)

| 文件 | 大小 | 说明 |
|---|---|---|
| `node-vXX.X.X-linux-x64.tar.xz` | ~25 MB | Node 20 LTS Linux 官方 tarball |
| `anthropic-ai-claude-code-X.X.X.tgz` | ~25 KB | Claude Code wrapper 包(postinstall 装真二进制) |
| `anthropic-ai-claude-code-linux-x64-X.X.X.tgz` | ~93 MB | Claude Code Linux 真二进制 |
| `cc-pocket/cc-pocket-daemon-X.X.X-linux-x86_64.tar.gz` | ~105 MB | cc-pocket 手机遥控(自带 JRE) |

## 怎么准备

```powershell
.\prepare-bundle.ps1              # 缺啥下啥,首次约 220 MB
.\prepare-bundle.ps1 -Force       # 重新下载所有
.\prepare-bundle.ps1 -NodeVersion v20.20.2  # 指定 Node 版本
```

`prepare-bundle.ps1` 是幂等的,文件已存在就跳过(除非 `-Force`)。

## 怎么用

不用手动用。`.\launch.ps1 start` 启动时会检测 bundle/,**必须齐全才启动**(项目只走离线安装,不做在线降级):

- **齐全** → launch 时通过 `multipass transfer -r` 把 `bundle/` 拷到 VM `/home/ubuntu/.bundle`,从本地装 Node + Claude Code + cc-pocket,**离线模式**,cloud-init < 2 分钟
- **不齐** → `launch.ps1 start` 直接报错终止,先跑 `.\prepare-bundle.ps1` 补齐再启动

bundle 准备好后,需要 `delete + start` 重建 VM 才生效(现有 VM 已经装过了)。

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
- **bundle 不齐就跑 launch**:`launch.ps1 start` 直接报错终止,先跑 `.\prepare-bundle.ps1` 补齐(项目不支持在线降级)。

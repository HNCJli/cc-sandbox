# bundle 离线包(状态目录)

bundle 存 cloud-init 离线安装用的本地包,**让 VM 创建不依赖网络下载**。位置固定在 `%USERPROFILE%\.cc-sandbox\bundle\`(写死,不提供参数/环境变量更换;**所有 VM 共享这一份**,多 VM 也只下载一次),不占用 skill 包目录,升级 skill 不受影响。

慢网络下在线装 Node + Claude Code 要 10–15 分钟,反复 `delete + start` 浪费时间;离线 bundle 把 Node 20 LTS + Claude Code + cc-pocket 预下载到本地,launch 时直接挂进 VM 装,cloud-init 压到 < 2 分钟。

## 内容(核心约 220 MB;可选开发环境件另约 240 MB)

核心件(必须齐全,缺了 start 直接报错):

| 文件 | 大小 | 说明 |
|---|---|---|
| `node-vXX.X.X-linux-x64.tar.xz` | ~25 MB | Node 20 LTS Linux 官方 tarball |
| `anthropic-ai-claude-code-X.X.X.tgz` | ~25 KB | Claude Code wrapper 包(postinstall 装真二进制) |
| `anthropic-ai-claude-code-linux-x64-X.X.X.tgz` | ~93 MB | Claude Code Linux 真二进制 |
| `cc-pocket/cc-pocket-daemon-X.X.X-linux-x86_64.tar.gz` | ~105 MB | cc-pocket 手机遥控(自带 JRE) |

可选开发环境件(默认跳过,交互菜单选装;给 `dev-java`/`dev-python`/`dev-frontend` 特性离线用,装的是你在菜单里选定的版本):

| 文件 | 大小 | 说明 |
|---|---|---|
| `jdk/OpenJDK17U-jdk_x64_linux_hotspot_*.tar.gz` | ~190 MB | Adoptium Temurin JDK 17(清华镜像;apt 的 openjdk 没法离线打包,用官方 tarball 代替) |
| `maven/apache-maven-*-bin.tar.gz` | ~9 MB | Maven 官方 bin tarball(阿里云 apache 镜像) |
| `uv/uv-*-py3-none-manylinux_x86_64.whl` | ~35 MB | uv(PyPI wheel,清华镜像;VM 内解出二进制装 /usr/local/bin) |
| `pnpm/pnpm-*.tgz` | ~9 MB | pnpm **10 系**(npm pack 本地打包,VM 内 npm -g 本地安装;10.x 兼容 Node 20,11.x 需 Node 22) |

## 怎么准备

```powershell
.\scripts\prepare-bundle.ps1              # 缺啥下啥,首次核心约 220 MB
.\scripts\prepare-bundle.ps1 -Force       # 重新选版本 + 全量重下
```

- 不加 `-Force` 时,文件已存在的组件直接沿用缓存——零交互零网络;只有**缺的组件**才需要选版本
- **版本选择(交互终端弹单选菜单,↑↓ / 回车 / 数字键)**:
  - **Node**:默认恒为 `v20.20.2`(实测锁定);菜单实时列最近 5 个 20.x LTS + 手动输入
  - **Claude Code**(与 Node 同构):默认**当前缓存版本**(排第一,回车即保持);其后 npm 最近 5 个正式版 + 与宿主机一致 + 手动输入;无缓存时默认最新
  - **cc-pocket**:默认保持缓存版本(无缓存则最新)
  - **JDK 17 / Maven / uv / pnpm**(可选件):有缓存默认"保持缓存",无缓存默认**跳过**;菜单列镜像上最近版本 + 手动输入
- **非交互**(管道/后台/Claude 代跑):不弹菜单自动用默认(Node=v20.20.2;Claude=缓存或最新;cc-pocket=缓存或最新;**四个可选件无缓存时直接跳过不下载**——要装就在交互终端跑一次)
- 切换版本会自动清掉 bundle 里的旧版本文件(`install-bundle.sh` 按 glob 装,不容忍多版本并存)

`prepare-bundle.ps1` 是幂等的,文件已存在就跳过(除非 `-Force`)。

## 怎么用

不用手动用。`.\scripts\launch.ps1 start` 启动时会检测状态目录的 bundle,**必须齐全才启动**(项目只走离线安装,不做在线降级):

- **齐全** → launch 时通过 `multipass transfer -r` 把 bundle 拷到 VM `/home/ubuntu/.bundle`,从本地装 Node + Claude Code + cc-pocket,**离线模式**,cloud-init < 2 分钟
- **不齐** → `launch.ps1 start` 直接报错终止,先跑 `.\scripts\prepare-bundle.ps1` 补齐再启动

bundle 准备好后,需要 `delete + start` 重建 VM 才生效(现有 VM 已经装过了)。

## 更新策略

`@anthropic-ai/claude-code` 发新版后想升级:

```powershell
.\scripts\prepare-bundle.ps1 -Force       # 菜单默认是"保持缓存",升级请在列表里选新版
.\scripts\launch.ps1 delete
.\scripts\launch.ps1 start                # 重建 VM,用新版 bundle
```

Node / cc-pocket / JDK / Maven / uv / pnpm 版本升级同理(菜单里选)。VM 里的版本不会自己变——bundle 是唯一来源,升 bundle 才升 VM。

## 为什么不在 skill 包里

二进制大文件(Node 25MB + Claude 93MB)不适合跟 skill 包走(升级要整目录覆盖)。bundle 放在包外的状态目录,天然与版本控制、skill 升级互不干扰。

## 失败诊断

- **`npm pack` 失败**:宿主机没装 Node/npm?装一个宿主机版 Node。
- **下载超时**:网络太慢,挂 VPN 或换镜像源后重试。
- **bundle 不齐就跑 launch**:`launch.ps1 start` 直接报错终止,先跑 `.\scripts\prepare-bundle.ps1` 补齐(项目不支持在线降级)。

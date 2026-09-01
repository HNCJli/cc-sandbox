# bundle 离线包(状态目录)

bundle 存 cloud-init 离线安装用的本地包,**让 VM 创建不依赖网络下载**。位置固定在 `%USERPROFILE%\.cc-sandbox\bundle\`(写死,不提供参数/环境变量更换;**所有 VM 共享这一份**,多 VM 也只下载一次),不占用 skill 包目录,升级 skill 不受影响。

慢网络下在线装 Claude Code 要 10–15 分钟,反复 `delete + start` 浪费时间;离线 bundle 把 Claude Code + opencode + cc-pocket(以及可选的开发环境件)预下载到本地,launch 时直接挂进 VM 装,cloud-init 压到 < 2 分钟。

**架构(AI 工具与语言运行时解耦)**:核心三件全是原生二进制,tar 解包 + symlink 即装,**不经 npm/node**;语言运行时归版本管理器——java/maven 进 SDKMAN、node 进 nvm、python 归 uv,均作为可选开发环境件提供。

## 内容(核心约 180 MB;可选开发环境件另约 300 MB)

核心件(必须齐全,缺了 start 直接报错):

| 文件 | 大小 | 说明 |
|---|---|---|
| `anthropic-ai-claude-code-linux-x64-X.X.X.tgz` | ~93 MB | Claude Code Linux 原生二进制(单文件,自包含) |
| `opencode-linux-x64-X.X.X.tgz` | ~60 MB | opencode Linux 原生二进制(单文件,自包含) |
| `cc-pocket/cc-pocket-daemon-X.X.X-linux-x86_64.tar.gz` | ~105 MB | cc-pocket 手机遥控(自带 JRE) |

可选开发环境件(默认跳过,交互菜单选装;给 `dev-java`/`dev-python`/`dev-frontend` 特性离线用,装的是你在菜单里选定的版本):

| 文件 | 大小 | 说明 |
|---|---|---|
| `jdk/OpenJDK17U-jdk_x64_linux_hotspot_*.tar.gz` | ~190 MB | Adoptium Temurin JDK 17(清华镜像;预置进 VM 的 SDKMAN candidates) |
| `maven/apache-maven-*-bin.tar.gz` | ~9 MB | Maven 官方 bin tarball(阿里云 apache 镜像;同样进 SDKMAN) |
| `sdkman/sdkman-cli-*.zip` + `sdkman-native-*-linuxx64.zip` | ~2 MB | SDKMAN 本体 cli + native(broker 302→GitHub release;GitHub 不通自动走 ghfast.top 镜像) |
| `uv/uv-*-py3-none-manylinux_x86_64.whl` | ~35 MB | uv(PyPI wheel,清华镜像;VM 内解出二进制装 /usr/local/bin) |
| `pnpm/pnpm-linux-x64-*.tgz` | ~26 MB | pnpm **独立二进制**(@pnpm/linux-x64 平台包,自含运行时;与 node 版本解耦,项目内多版本由 packageManager 字段自管) |
| `node/node-vXX.X.X-linux-x64.tar.xz` | ~25 MB/版 | Node 官方 tarball(预置进 VM 的 nvm versions;**多版本并存**,可追加) |
| `nvm/nvm-vX.X.X.sh` | ~150 KB | nvm 本体(不下载——**vendor 在仓库 `assets/nvm.sh`**,钉版本,自动拷入 bundle) |

## 怎么准备

```powershell
.\scripts\prepare-bundle.ps1              # 缺啥下啥,首次核心约 180 MB
.\scripts\prepare-bundle.ps1 -Force       # 重新选版本 + 全量重下
```

- 不加 `-Force` 时,文件已存在的组件直接沿用缓存——零交互零网络;只有**缺的组件**才需要选版本
- **版本选择(交互终端弹单选菜单,↑↓ / 回车 / 数字键)**:
  - **Claude Code**:默认**当前缓存版本**(排第一,回车即保持);其后 npm 最近 5 个正式版 + 与宿主机一致 + 手动输入;无缓存时默认最新
  - **opencode**(与 Claude Code 同构):默认缓存版本(无缓存则最新)
  - **cc-pocket**:默认保持缓存版本(无缓存则最新)
  - **JDK 17 / Maven / uv / pnpm / Node / SDKMAN**(可选件):有缓存默认"保持缓存",无缓存默认**跳过**;菜单列镜像上最近版本 + 手动输入(Node 还可交互追加第二版本,默认跳过)
- **非交互**(管道/后台/Claude 代跑):不弹菜单自动用默认(Claude=缓存或最新;opencode=缓存或最新;cc-pocket=缓存或最新;**可选件无缓存时直接跳过不下载**——要装就在交互终端跑一次)
- 核心件切换版本会自动清掉 bundle 里的旧版本文件(`install-bundle.sh` 按 glob 装,不容忍多版本并存);**Node 例外**——多版本并存不清,不用了手动删 `bundle\node\` 下的 tarball

`prepare-bundle.ps1` 是幂等的,文件已存在就跳过(除非 `-Force`)。

## 怎么用

不用手动用。`.\scripts\launch.ps1 start` 启动时会检测状态目录的 bundle,**必须齐全才启动**(项目只走离线安装,不做在线降级):

- **齐全** → launch 时通过 `multipass transfer -r` 把 bundle 拷到 VM `/home/ubuntu/.bundle`,从本地装 Claude Code + opencode + cc-pocket(原生直装)及勾选的开发环境件,**离线模式**,cloud-init < 2 分钟
- **不齐** → `launch.ps1 start` 直接报错终止,先跑 `.\scripts\prepare-bundle.ps1` 补齐再启动

bundle 准备好后,需要 `delete + start` 重建 VM 才生效(现有 VM 已经装过了)。

## 更新策略

`@anthropic-ai/claude-code` 发新版后想升级:

```powershell
.\scripts\prepare-bundle.ps1 -Force       # 菜单默认是"保持缓存",升级请在列表里选新版
.\scripts\launch.ps1 delete
.\scripts\launch.ps1 start                # 重建 VM,用新版 bundle
```

Node / opencode / cc-pocket / JDK / Maven / SDKMAN / uv / pnpm 版本升级同理(菜单里选)。VM 里的版本不会自己变——bundle 是唯一来源,升 bundle 才升 VM。nvm 本体升级:换 `assets/nvm.sh` + 同步 `prepare-bundle.ps1` 里的版本/SHA 常量。

## 为什么不在 skill 包里

二进制大文件(Claude 93MB 等)不适合跟 skill 包走(升级要整目录覆盖)。bundle 放在包外的状态目录,天然与版本控制、skill 升级互不干扰。唯一例外 nvm.sh:单文件纯 bash 脚本且 GitHub 常不可达,vendor 进 `assets/`(钉版本)最稳。

## 失败诊断

- **`npm pack` 失败**:宿主机没装 Node/npm?装一个宿主机版 Node(claude/opencode/pnpm 三件经 npm registry 打包)。
- **SDKMAN 下载失败**:GitHub 直链不通时会自动改走 ghfast.top 镜像;仍失败重跑本脚本。
- **下载超时**:网络太慢,挂 VPN 或换镜像源后重试。
- **bundle 不齐就跑 launch**:`launch.ps1 start` 直接报错终止,先跑 `.\scripts\prepare-bundle.ps1` 补齐(项目不支持在线降级)。

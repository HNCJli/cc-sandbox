# 可选功能:VM 内 Docker / 跨网络访问(Tailscale) / 宿主机路径换算 / 剪贴板图片粘贴 / 预装开发环境

## 宿主机路径自动换算(路径映射记忆)

勾选后,`start` 会在挂载完成后往 **VM 内** Claude Code 的全局记忆(`~/.claude/CLAUDE.md`)写入"沙箱说明 + 宿主机↔VM 路径映射表"(只含 workspace 挂载,按本次 mounts.txt 实际挂载生成,每条挂载一项)。之后在 VM 里的 Claude Code 对话中**直接贴宿主机 Windows 路径**即可,如:

```
看下 D:\multipass-share-dir-worksapce\share-dir-01\test-project\.gitignore
```

VM 里的 Claude Code 按表换算成 `/home/ubuntu/workspace/share-dir-01/test-project/.gitignore` 再读写,也会在展示文件位置时反向换算回 Windows 路径。

- 勾选方式同 Tailscale:交互菜单空格勾选,或直接编辑 `features.txt` 加一行 `path-map`
- **非重建型**:勾上后现有 VM 下次 `start` 即写入,不需要 delete + start;每次 start 按当前挂载刷新
- 取消勾选后,下次 `start` 映射节即消失;若同时未勾选任何 dev-* 环境,整块移除(`CLAUDE.md` 中标记 `<!-- cc-sandbox:begin/end -->` 之间的内容,块外自己写的内容不动)——路径映射与预装环境共用同一个 managed block

## 剪贴板图片粘贴(clip-bridge)

宿主机截图后,**VM 里的 Claude Code 直接按 Ctrl+V 就能粘图**,体验与本机跑 claude 一致——发报错截图、设计稿、UI 图不用再存文件传路径。

原理(参考 cc-clip 的拦截协议,宿主机零额外安装,纯 Windows 内置能力):

- 宿主侧:`start` 拉起一个 PowerShell 常驻服务(`scripts\clip-bridge\host-daemon.ps1`,监听 `127.0.0.1:18339`,按需读 Windows 剪贴板;PID 在状态目录 `.clip-daemon.pid`,日志 `clip-daemon.log`)
- 隧道:`start` 起一条**专享** SSH 反向隧道(`-R 18339`,`.clip-tunnel.pid`),与 LLM 隧道相互独立——直连模式(公网 base_url)下桥也照常工作
- VM 侧:垫片装在 `/usr/local/bin/xclip`、`/usr/local/bin/wl-paste`(PATH 恒优先于 `/usr/bin`)。Claude Code 在 Linux 上读剪贴板就是调这两个命令,垫片把请求经隧道 curl 到宿主 daemon

使用要点:

- **入口不限**:`multipass shell claude-dev` 或 `ssh claude-dev` 进去都能粘——垫片打的是 VM 回环,不依赖你自己的会话带隧道
- **非重建型**:勾上后现有 VM 下次 `start` 即生效,不需要 delete + start
- 取消勾选:下次 `start` 自动停 daemon 和隧道(恢复无桥行为;多台 VM 下其他 VM 还勾着 clip-bridge 时,daemon 会保留);VM 里的垫片文件保留但无害(桥不通时它透传/失败退出,与没装过等价),想彻底清除可 `sudo rm /usr/local/bin/xclip /usr/local/bin/wl-paste` 或 delete + start 重建
- 粘贴**文本**不受影响(文本走终端通道);桥只服务"Claude Code 主动读剪贴板"这个动作(图片为主,文本读取也顺带打通)
- **终端快捷键坑(实测 2026-08-23)**:多数终端默认占用 `Ctrl+V` 当"粘贴文本",按键到不了 claude,粘图表现为"没反应"。Warp:设置 → Keyboard Shortcuts 搜 `paste`,清空 **Alternate Terminal Paste** 上的 Ctrl+V 绑定(Paste 本身是 Ctrl+Shift+V,保留);Windows Terminal:设置 → 操作 → 删除"粘贴 Ctrl+V"。详见 troubleshooting.md §G
- 体检:`.\scripts\launch.ps1 status` 的"剪贴板桥"段显示 daemon / 桥隧道 / VM→宿主端到端三项状态
- 出问题看日志 `%USERPROFILE%\.cc-sandbox\clip-daemon.log`;端到端没通多半是隧道没起好,重跑 `start` 自愈
- 注意:桥只负责**把图送进 Claude Code**;模型能不能真"看见"图,取决于当时接的 LLM 后端是否支持/透传 image 块(部分中转网关会丢 tool_result 里的图片,与桥无关)

## 预装开发环境(dev-java / dev-python / dev-frontend)

勾选后,`start` 自动在 VM 里装好对应环境(非重建型,不用 delete + start),已装的探测到就跳过(幂等):

| 特性 id | 装什么 | 装法 |
|---|---|---|
| `dev-java` | JDK 17(Adoptium Temurin)+ Maven + 阿里云镜像 | **离线 bundle 优先**(bundle 里的 jdk/maven tarball,秒装);bundle 缺件或 VM 已存在时**回退在线 apt**(几百 MB,首次较慢;apt 装的是 Ubuntu 打包的 OpenJDK 17,非 Temurin)。Maven 幂等写入 `~/.m2/settings.xml` 镜像(已有配置不覆盖) |
| `dev-python` | python3(基础镜像自带)+ `uv` | **离线 bundle 优先**(uv wheel 解出二进制);缺件时回退在线 apt+pip。venv/包管理全走 uv(`uv venv`/`uv add`),不装 apt 的 python3-venv |
| `dev-frontend` | `pnpm`(10 系) | **离线 bundle 优先**(本地 tgz npm -g);缺件时回退 npm 全局装 `pnpm@10`。10.x 兼容 Node 20(11.x 需 Node 22,故不提供) |

- **离线件从哪来**:`.\scripts\prepare-bundle.ps1` 交互终端跑一次,菜单里给 JDK/Maven/uv/pnpm 选装版本(默认跳过,选了才下;非交互跑不会自动下这 ~240MB)。装进 VM 的就是当时选定的版本
- 现有 VM 首次勾选走在线兜底装;之后 delete + start 重建的 VM 全走离线秒装
- 装好后写进 VM 里 Claude Code 的全局记忆(`~/.claude/CLAUDE.md` 的 managed block):VM 里的 claude 知道自己有哪些环境、uv/pnpm 怎么用
- 与"路径映射记忆"**共用同一个 managed block**:任一启用就写,全部取消勾选才移除整块
- 安装失败只警告不阻塞 start(环境是增强不是依赖);重跑 `start` 自愈
- 取消勾选只是"不再管理":装好的包留在 VM 里,记忆块也不再提它(想彻底清掉用 delete + start 重建)
- 体检:`.\scripts\launch.ps1 status` 的"开发环境"段按勾选逐项探测

## VM 内装 Docker

VM 已经是 Ubuntu,直接 `apt install` 就行,不用重建:

```bash
# 进 VM 后
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker ubuntu     # 然后退出重进 shell 让组生效
sudo systemctl enable --now docker
```

## 跨网络访问 VM(Tailscale)

在外面(手机 4G、咖啡店 WiFi)想直连 VM 上跑的服务时启用 Tailscale。**没有命令行开关,只用交互菜单**:真人终端裸跑 `start`,在"可选特性"菜单里用 **↑↓ 移动、空格 勾选、回车 确认**(按数字 `1` 也可直接切换该项;已勾选状态直接回车保持):

```powershell
.\scripts\launch.ps1 start      # 弹菜单 → 空格勾选 Tailscale → 回车;直接回车=保持上次
```

选择会写进状态目录该 VM 子目录的 `features.txt`(每行一个特性 id),之后 `delete + start` 重建、日常 start 都自动沿用,不用再记参数;想关掉就再跑菜单选 `n`,或删掉文件里那行(关掉后需重建 VM 才真正卸载)。非交互场景(脚本/CI/Claude 代跑)没有菜单,静默沿用 features.txt;要改选择就直接编辑该文件,格式见 `assets\features.example.txt`。

**已有 VM 时启用**:cloud-init 只在创建 VM 时跑,预装必须重建。交互终端下 `start` 探测到 VM 里没装,会直接问:

```
新启用的 Tailscale 需要重建 VM(cloud-init 只在创建 VM 时跑;状态目录的 workspace/SSH key 等保留)
现在删除并重建 VM?(y=重建, N=跳过)
```

答 `y` 一条命令完成删除重建;答 `N`(或直接回车)= 跳过:VM 保持原样,特性在下次 `delete + start` 重建时装进(收尾提示会注明"已启用但本次跳过了重建",别急着去配对——那时包还没进 VM)。非交互场景(管道/后台/Claude 代跑)只提醒一句,不动现有 VM——要生效自己 `delete + start`。手动改配置文件的话,格式见 `assets\features.example.txt`。

VM 起来后,**进 VM 手动配对**(cloud-init 阶段没法弹浏览器):
```bash
sudo tailscale up              # 弹 URL,浏览器登录同一个 tailscale 账号
tailscale ip                   # 看 VM 拿到的 100.x.x.x 内网 IP
```

手机/其他设备登同一个 tailscale 账号后,就能用那个 100.x.x.x IP SSH / 直连 VM 上任意服务。例如 VM 里起了 web 服务(`python -m http.server 8000`),在任何网络下浏览器开 `http://100.x.x.x:8000` 即可访问。

**⚠️ 公司场景千万别开**:
- 启用 Tailscale(菜单勾选)会真的把 tailscale 包装进 VM
- 即使不 `tailscale up` 没有出站流量,公司软件审计(SCCM 类)能扫到包已装
- 公司禁远控/打洞软件时,这会被识别为违规
- 公司场景在菜单里保持 Tailscale 未勾选(直接回车即可),完全不碰

**cc-pocket 与 Tailscale 的关系(定位已变化)**:cc-pocket 现已支持任意网络遥控 VM 里的 Claude Code,**不需要 Tailscale**。Tailscale 的用途是跨网络直连 VM 上任意 TCP/UDP 服务(SSH、VM 里启动的 web 等),与 cc-pocket 无关。

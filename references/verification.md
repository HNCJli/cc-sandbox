# cc-sandbox 验证清单

回归测试用。按顺序跑,前 4 项 + 测试 6(cc-pocket 随 bundle)必跑,测试 5(Tailscale)/ 测试 7(可选特性菜单)/ 测试 8(路径映射记忆)/ 测试 9(剪贴板图片粘贴)可选。每次改 scripts\launch.ps1 / assets\cloud-init.yaml / assets\tmux.conf 后建议至少跑 1 + 4。

**通用约定**:
- 所有 `multipass exec claude-dev -- bash -lc "..."` 命令**别换成 `cat ~/.claude/settings.json`** —— 该文件含明文 token,见 troubleshooting §C。
- 验证中发现异常,按现象查 [troubleshooting.md](./troubleshooting.md) 对应小节。

---

## 测试 1:基础启动回归(必跑)

**目的**:确认 `.\scripts\launch.ps1 start`(无参数,读 mounts.txt)不破,且新目录布局(assets/scripts/状态目录)工作正常。前置:状态目录有 `mounts.txt`(至少一项)。

### 步骤

```powershell
.\scripts\launch.ps1 delete          # 干净起步
.\scripts\launch.ps1 start           # 首次 3–15 分钟(取决于网络 + 是否用了 bundle)
```

### 验证

```powershell
# 1. status 全景
.\scripts\launch.ps1 status
# 预期:VM Running;隧道在跑(本地代理模式)或"直连模式"(公网 base_url);LLM 接入探测 HTTP 4xx

# 2. env 同步到位(应输出 OK,不是 EMPTY)
multipass exec claude-dev -- bash -lc "jq -e .env ~/.claude/settings.json >/dev/null && echo OK || echo EMPTY"

# 3. workspace 挂载真到位(以 findmnt 为准)
multipass exec claude-dev -- bash -lc "findmnt | grep /home/ubuntu/workspace"
multipass exec claude-dev -- bash -lc "ls -la ~/workspace"
# 预期:mounts.txt 各项对应子目录的 mount 记录;~/workspace 本身无宿主根挂载

# 4. Fish + 工具链 + Node + Claude Code 装好了
multipass exec claude-dev -- bash -lc "echo SHELL=\$(getent passwd ubuntu | cut -d: -f7); which fish fzf zoxide; node -v; command -v claude"

# 5. 进 VM,看 Fish 提示符 + Claude Code 能跑
multipass shell claude-dev
# VM 内(fish 提示符):
claude --dangerously-skip-permissions
# 预期:不弹登录菜单,直接进 Claude Code。Ctrl+C 退出。exit 退 VM。
```

### 预期汇总

| 检查项 | 预期 |
|---|---|
| `status` | VM Running + 隧道在跑/直连模式 + 探测 HTTP 4xx |
| env 检查 | `OK` |
| findmnt | mounts.txt 各项子目录 mount(fuse.sshfs),无宿主根挂载 |
| 工具链 | shell=/usr/bin/fish;fish/fzf/zoxide 都有路径;Node v20.x;claude 在 |
| `claude` 进 VM | 不弹登录菜单 |

### 布局解耦检查(目录重排后必看)

```powershell
# 状态目录生效:bundle/密钥/挂载点都在 %USERPROFILE%\.cc-sandbox 下
Test-Path "$env:USERPROFILE\.cc-sandbox\bundle"
Test-Path "$env:USERPROFILE\.cc-sandbox\.ssh-key"
# 旧仓库根若有 mounts.txt/bundle 等旧布局状态,首次 start 应打印"迁移旧布局状态: ..."且原文件保留
```

---

## 测试 2:多目录模式(必跑)

**目的**:验证 mounts.txt 挂多个宿主目录到 `~/workspace/<子目录>`(多项 + 别名)。

### 准备(一次性)

```powershell
# 改成你本机路径,或临时建两个测试目录
mkdir D:\code\test1 -ErrorAction SilentlyContinue
mkdir D:\code\test2 -ErrorAction SilentlyContinue
"hello from test1" | Out-File D:\code\test1\a.txt
"hello from test2" | Out-File D:\code\test2\b.txt
```

### 步骤

```powershell
# 写测试用 mounts.txt(会覆盖你自己的配置,测完记得还原)
'D:\code\test1','D:\code\test2=alias2' | Set-Content "$env:USERPROFILE\.cc-sandbox\mounts.txt"
.\scripts\launch.ps1 delete
.\scripts\launch.ps1 start
```

### 验证

```powershell
.\scripts\launch.ps1 status

# findmnt 看到两条 mount(test1 + alias2)
multipass exec claude-dev -- bash -lc "findmnt | grep /home/ubuntu/workspace"

# ~/workspace 下有两个子目录(~/workspace 是 VM 本地目录,不挂宿主根)
multipass exec claude-dev -- bash -lc "ls -la ~/workspace"

# 内容能读到(各 cat 输出对应 hello 字符串)
multipass exec claude-dev -- bash -lc "cat ~/workspace/test1/a.txt"
multipass exec claude-dev -- bash -lc "cat ~/workspace/alias2/b.txt"
```

### 预期

- findmnt 输出含 `~/workspace/test1` 和 `~/workspace/alias2` 两条(不嵌套在宿主根挂载下)
- `ls` 看到两个子目录
- 两个 cat 输出 `hello from test1` / `hello from test2`

---

## 测试 3:多目录模式重起 VM(覆盖性)

**目的**:验证 VM Running 时 `start` 只重挂/重起隧道,不重新 launch。

### 步骤

```powershell
.\scripts\launch.ps1 stop
.\scripts\launch.ps1 start     # 沿用测试 2 写入的 mounts.txt
```

### 验证

```powershell
# 启动应秒级完成(不重新下载镜像)
# findmnt 仍看到两个子目录 mount
multipass exec claude-dev -- bash -lc "findmnt | grep /home/ubuntu/workspace"
```

### 预期

- `start` 秒级完成(输出 `VM 已在 Running,start 改为只重挂/重起隧道` 或类似)
- findmnt 仍输出两条 mount(test1 + alias2)

---

## 测试 4:mounts.txt 校验(必跑,最快)

**目的**:确认非法配置立刻 throw,不进 launch。

### 步骤(每条都应立刻 throw)

```powershell
# (a) mounts.txt 的宿主目录不存在
'D:\nonexistent-dir-xyz' | Set-Content "$env:USERPROFILE\.cc-sandbox\mounts.txt"
.\scripts\launch.ps1 start

# (b) mounts.txt 的 vmSubdir 含 '..' 逃逸
'D:\code\test1=..\..' | Set-Content "$env:USERPROFILE\.cc-sandbox\mounts.txt"
.\scripts\launch.ps1 start

# (c) mounts.txt 两个项映射到同一子目录
'D:\code\test1','D:\code\test2=test1' | Set-Content "$env:USERPROFILE\.cc-sandbox\mounts.txt"
.\scripts\launch.ps1 start

# (d) mounts.txt 不存在/为空(零挂载)
Rename-Item "$env:USERPROFILE\.cc-sandbox\mounts.txt" mounts.txt.bak
.\scripts\launch.ps1 start
# 预期额外:状态目录自动出现 mounts.example.txt 模板(已存在则不覆盖)

# 测完恢复自己的 mounts.txt(把 mounts.txt.bak 改回,或重写配置)
```

### 预期

四条都报 PowerShell throw,提示 `宿主机目录不存在` / `不允许含 '..'` / `子目录名重复` / `start 需要 mounts.txt 配置挂载`。**不进 launch**;(d) 报错文案指向状态目录的 `mounts.example.txt` 模板。

---

## 测试 5:Tailscale 回归(可选)

**目的**:验证交互菜单勾选 Tailscale 后,重建的 VM 里真的装上 tailscale(完整菜单流程见测试 7)。用途:跨网络直连 VM 上跑的服务(如通过 `100.x.x.x:端口` 访问 VM 里启动的 web);cc-pocket 已支持任意网络遥控,不依赖 tailscale。

### 步骤

```powershell
.\scripts\launch.ps1 delete
.\scripts\launch.ps1 start      # 真人终端:菜单输 1 勾选 Tailscale;重建询问答 y
multipass exec claude-dev -- bash -lc "which tailscale"
```

### 预期

`/usr/bin/tailscale`。进 VM 后 `sudo tailscale up` 配对(已配过同账号会自动恢复)。

另:菜单选择会写回状态目录 `features.txt`;之后裸跑 `start`(含 delete + start 重建)也会沿用。想关掉:交互菜单选 `n` 或删掉 features.txt 里那行,再 delete + start。

### 组合测试(可选)

Tailscale 和多目录应能叠加(菜单勾选 + mounts.txt):

```powershell
'D:\code\test1' | Set-Content "$env:USERPROFILE\.cc-sandbox\mounts.txt"
.\scripts\launch.ps1 start
multipass exec claude-dev -- bash -lc "which tailscale; findmnt | grep /home/ubuntu/workspace"
```

---

## 测试 6:cc-pocket 随 bundle 安装

**目的**:验证 cc-pocket 已从 bundle 离线装好。cc-pocket 是 bundle 必需组件,不做在线降级/容错;缺失会导致 `launch.ps1 start` 直接报错。

### 步骤

正常装完后:

```powershell
multipass exec claude-dev -- bash -lc "command -v cc-pocket-daemon && echo INSTALLED || echo NOT_INSTALLED"
multipass exec claude-dev -- bash -lc "systemctl --user status cc-pocket-daemon 2>&1 | head -5"
```

### 预期

- `INSTALLED`(bundle 离线安装,`install-bundle.sh` 最后一步 `command -v cc-pocket-daemon` 强制)
- 若 `NOT_INSTALLED`:说明 bundle 缺 cc-pocket 离线包,`launch.ps1 start` 会在启动前报错;先 `.\scripts\prepare-bundle.ps1` 补齐,再 `delete + start`。

---

## 测试 7:可选特性交互菜单 / features.txt(可选)

**目的**:验证真人终端裸跑 `start` 弹多选菜单、选择持久化到 features.txt、重建确认一条命令完成;非交互(管道/后台/Claude 代跑)不弹菜单不卡死。

### 步骤

```powershell
# (a) 真人 PowerShell 终端裸跑,应弹"可选特性"方向键多选菜单(TUI)
.\scripts\launch.ps1 start
#   ↑↓ 移动高亮(黄行)、空格 勾选/取消([x]/[ ])、按数字 1 直接切换该项、
#   a=全选 n=全不选、回车 提交(写 features.txt)
#   勾选 Tailscale 后回车;VM 已存在且没装时,应追问"现在删除并重建 VM?",答 y
#   → 一条命令完成 delete + 重建(不再需要手动跑两条)
#   答 N/回车 = 跳过:VM 不动,收尾提示"已启用但本次跳过了重建,delete + start 后才装进 VM"

# (b) 选择应已写入 features.txt
Get-Content "$env:USERPROFILE\.cc-sandbox\features.txt"
# 预期:两行注释头 + 一行 tailscale

# (c) 再裸跑一次 start,菜单应预勾选 [x](Tailscale 已勾选),直接回车选择不变

# (d) 非交互不弹菜单:stdin 重定向跑(模拟 Claude/后台)
cmd /c ".\scripts\launch.ps1 start < nul"
# 预期:无菜单、不卡住;输出"可选特性: Tailscale";VM 里已装(探测通过),不问重建

# (e) status 显示已启用特性
.\scripts\launch.ps1 status
# 预期:"可选特性" 段显示 "Tailscale(features.txt 已启用)"

# (f) 关闭:菜单输 n 回车 → features.txt 不再含特性行;delete + start 后 VM 里应无 tailscale
```

### 预期汇总

| 检查项 | 预期 |
|---|---|
| (a) 交互菜单 | 方向键多选(↑↓/空格/回车/数字/a/n);重建询问答 N 走"跳过"提示 |
| (b) features.txt | 注释头 + tailscale 一行 |
| (c) 回车保持 | `[x]` 预勾选,回车后文件不变 |
| (d) 非交互 | 不弹菜单直接沿用 features.txt,输出"可选特性: Tailscale" |
| (e) status | "可选特性" 段列出已启用项 |
| (f) 关闭 | 选 n 后重建,VM 内 `which tailscale` 无输出 |

---

## 测试 8:路径映射记忆(path-map,建议跑)

**目的**:验证可选特性 path-map——start 往 VM 内 `~/.claude/CLAUDE.md` 写入宿主机↔VM 路径映射块;取消勾选后块被移除。

### 步骤(非交互下模拟勾选 = 直接编辑 features.txt)

```powershell
# (a) 启用:features.txt 加一行 path-map(交互终端则裸跑 start 菜单勾选)
Add-Content "$env:USERPROFILE\.cc-sandbox\features.txt" "path-map"
.\scripts\launch.ps1 start    # 唤醒/重挂后应打印"已写入宿主机↔VM 路径映射"

# (b) VM 内看映射块(多目录模式:每条挂载一行 + .claude-host 只读行)
multipass exec claude-dev -- bash -lc "sed -n '/cc-sandbox:begin/,/cc-sandbox:end/p' ~/.claude/CLAUDE.md"

# (c) 幂等:再跑一次 start,块不重复(计数应为 1、总行数不变)
.\scripts\launch.ps1 start
multipass exec claude-dev -- bash -lc "grep -c 'cc-sandbox:begin' ~/.claude/CLAUDE.md; wc -l < ~/.claude/CLAUDE.md"

# (d) 取消勾选:start 后块应被移除(计数应为 0)
(Get-Content "$env:USERPROFILE\.cc-sandbox\features.txt") | Where-Object { $_ -ne 'path-map' } | Set-Content "$env:USERPROFILE\.cc-sandbox\features.txt"
.\scripts\launch.ps1 start
multipass exec claude-dev -- bash -lc "grep -c 'cc-sandbox:begin' ~/.claude/CLAUDE.md"
```

### 预期汇总

| 检查项 | 预期 |
|---|---|
| (a) start 输出 | `已写入宿主机↔VM 路径映射到 VM ~/.claude/CLAUDE.md(N 条)` |
| (b) 映射块内容 | 表格仅含 workspace 挂载:mounts.txt 每条挂载一行(前缀=宿主绝对路径、VM 路径=`/home/ubuntu/workspace/<子目录>`),不含 `.claude-host` 条目;含 `.gitignore` 换算示例 |
| (c) 幂等 | begin 计数 = 1;重复 start 后总行数不变(不累积空行/重复块) |
| (d) 移除 | begin 计数 = 0;`CLAUDE.md` 若有块外内容应保留 |

---

## 测试 9:剪贴板图片粘贴(clip-bridge,建议跑)

**目的**:验证可选特性 clip-bridge——start 自动拉起宿主 daemon、部署 VM 垫片、起专享反向隧道;文本/图片都能经桥读取;取消勾选后 daemon/隧道停。

### 步骤(非交互下模拟勾选 = 直接编辑 features.txt)

```powershell
# (a) 启用:features.txt 加一行 clip-bridge(交互终端则裸跑 start 菜单勾选)
Add-Content "$env:USERPROFILE\.cc-sandbox\features.txt" "clip-bridge"
.\scripts\launch.ps1 start
# 预期输出:daemon PID → 垫片已装 → 桥隧道 PID → "剪贴板桥端到端通(VM → 宿主 daemon)"

# (b) status 显示桥三件套
.\scripts\launch.ps1 status
# 预期:"剪贴板桥"段:宿主 daemon 在跑 + 桥隧道在跑 + "VM → 宿主 daemon 通(粘图可用)"

# (c) 宿主机剪贴板放一段文本,VM 里经垫片读回
Set-Clipboard "bridge-text-test"
multipass exec claude-dev -- bash -lc '/usr/local/bin/xclip -selection clipboard -o'
# 预期:输出 bridge-text-test

# (d) 剪贴板放一张图(截图或复制图片文件),垫片应报 image/png 并能取到 PNG
multipass exec claude-dev -- bash -lc '/usr/local/bin/xclip -selection clipboard -t TARGETS -o'
# 预期:含 image/png 一行
multipass exec claude-dev -- bash -lc '/usr/local/bin/xclip -selection clipboard -t image/png -o | head -c 8 | od -An -tx1'
# 预期:89 50 4e 47 开头(PNG magic number)

# (e) 幂等:再跑一次 start 不报错;wl-paste 垫片在位
multipass exec claude-dev -- bash -lc '/usr/local/bin/wl-paste --list-types'

# (f) 取消勾选:start 后 daemon/隧道应停(features.txt 删掉 clip-bridge 行)
(Get-Content "$env:USERPROFILE\.cc-sandbox\features.txt") | Where-Object { $_ -ne 'clip-bridge' } | Set-Content "$env:USERPROFILE\.cc-sandbox\features.txt"
.\scripts\launch.ps1 start
.\scripts\launch.ps1 status
# 预期:"剪贴板桥"段显示未启用;宿主机上 daemon 进程已退出

# (g) 真人端到端:记事本写 HELLO-9527 → Win+Shift+S 截图 → VM 里 claude 按 Ctrl+V
#     → 问"图里写了什么数字" → 应答出 9527
#     前置:所用终端没占用 Ctrl+V(Warp 实测占用者是 Alternate Terminal Paste,
#     见 troubleshooting.md §G);Ctrl+V 没反应先按 §G 判别终端拦截
```

### 预期汇总

| 检查项 | 预期 |
|---|---|
| (a) start 输出 | daemon PID / 垫片已装 / 桥隧道 PID / 端到端通 |
| (b) status | daemon + 桥隧道 + VM→宿主探测三条 OK |
| (c) 文本读取 | 输出放入剪贴板的字符串 |
| (d) 图片读取 | TARGETS 含 image/png;取回字节以 `89 50 4e 47` 开头 |
| (e) 幂等 | 重复 start 无报错;wl-paste --list-types 正常 |
| (f) 关闭 | status 显示未启用;宿主 daemon 进程退出 |
| (g) 真人粘图 | 附件出现 + 模型答出图中文字;附件在但答不出 = 网关丢 image 块(见 §G) |

---

## 测试 10:预装开发环境(dev-java / dev-python / dev-frontend,建议跑)

**目的**:验证开发环境特性——离线 bundle 优先安装(重建 VM 秒装)、在线兜底、记忆块含环境说明、取消勾选单项后对应行消失。

### 步骤

```powershell
# (a) 准备离线件(需真人终端,菜单里给 JDK/Maven/uv/pnpm 选版本;Claude 代跑=非交互会跳过)
.\scripts\prepare-bundle.ps1
# 状态汇总应出现 jdk/OpenJDK17U-*.tar.gz、maven/*.tar.gz、uv/*.whl、pnpm/*.tgz 四行 OK

# (b) 启用三项并重建 VM(离线装只在新建 VM 时发生;现有 VM 走在线兜底)
Add-Content "$env:USERPROFILE\.cc-sandbox\claude-dev\features.txt" "dev-java"
Add-Content "$env:USERPROFILE\.cc-sandbox\claude-dev\features.txt" "dev-python"
Add-Content "$env:USERPROFILE\.cc-sandbox\claude-dev\features.txt" "dev-frontend"
.\scripts\launch.ps1 delete
.\scripts\launch.ps1 start
# 预期:bundle 安装阶段进度事件含 "dev-java:JDK 17 已离线安装" 等;Start-DevEnvs 三行"已在"

# (c) VM 内验证工具链 + Maven 镜像
multipass exec claude-dev -- bash -lc "java -version 2>&1 | head -1; mvn -v 2>/dev/null | head -1; uv --version; pnpm -v"
multipass exec claude-dev -- bash -lc "grep -c aliyun ~/.m2/settings.xml"   # 预期 2(id 和 url)
# java 预期 Temurin:openjdk version "17.0.x" 20xx-xx-xx(Temurin 标记,不再是 Ubuntu 打包版)

# (d) 记忆块含"预装开发环境"节
multipass exec claude-dev -- bash -lc "sed -n '/cc-sandbox:begin/,/cc-sandbox:end/p' ~/.claude/CLAUDE.md"

# (e) 幂等:再跑一次 start,应显示"已在"并秒过
.\scripts\launch.ps1 start

# (f) status 探测
.\scripts\launch.ps1 status     # "开发环境"段三项 OK

# (g) 取消勾选 dev-frontend:path-map 仍启用 → 块保留,环境节不再含 pnpm 行
(Get-Content "$env:USERPROFILE\.cc-sandbox\claude-dev\features.txt") | Where-Object { $_ -ne 'dev-frontend' } | Set-Content "$env:USERPROFILE\.cc-sandbox\claude-dev\features.txt"
.\scripts\launch.ps1 start
multipass exec claude-dev -- bash -lc "sed -n '/cc-sandbox:begin/,/cc-sandbox:end/p' ~/.claude/CLAUDE.md | grep -c pnpm"

# (h) 在线兜底(可选,验证降级路径):临时挪走 uv 缓存后重建
Move-Item "$env:USERPROFILE\.cc-sandbox\bundle\uv" "$env:USERPROFILE\.cc-sandbox\bundle\uv.bak"
.\scripts\launch.ps1 delete
.\scripts\launch.ps1 start      # 预期:uv 走"在线兜底"提示并 pip 安装成功
Move-Item "$env:USERPROFILE\.cc-sandbox\bundle\uv.bak" "$env:USERPROFILE\.cc-sandbox\bundle\uv" -Force
```

### 预期汇总

| 检查项 | 预期 |
|---|---|
| (a) prepare-bundle | 四个可选件菜单出现(默认跳过,选版本才下);状态汇总四行 OK |
| (b) start(新 VM) | "JDK 17/Maven/uv/pnpm 已离线安装"事件 + 探测三行"已在" |
| (c) 版本 | Temurin openjdk 17.0.x / Maven 3.x / uv x.y.z / pnpm x.y.z |
| (d) 记忆块 | 含 `### 预装开发环境`,三项各一行;uv 行含 `uv venv` 用法 |
| (e) 幂等 | 三行"已在",秒级 |
| (f) status | "开发环境"段三项"已装" |
| (g) 关闭单项 | grep 计数 0;包仍留在 VM 里(pnpm -v 仍可用) |
| (h) 兜底 | uv 提示"在线兜底"并装上;其余离线件不受影响 |

**prepare-bundle 版本菜单**(需真人终端):裸跑 `.\scripts\prepare-bundle.ps1 -Force` 应依次弹核心三件 + 四个可选件的单选菜单(TUI,窗口小自动降级编号输入);非交互(如 `cmd /c ".\scripts\prepare-bundle.ps1 < nul"`,不加 -Force)不弹菜单,核心件沿用缓存,可选件无缓存时打印"跳过"提示。

---

## 测试 11:多 VM(-Name)并存与共享(建议跑)

**目的**:验证 `-Name` 起独立 VM;状态按 VM 分目录;clip-daemon 全局单例被多台复用(停一台另一台仍可用);status 总览。

### 步骤

```powershell
# (a) 为第二台 VM 准备独立配置(子目录 = VM 名)
New-Item -ItemType Directory "$env:USERPROFILE\.cc-sandbox\dev-t2" -Force
Copy-Item "$env:USERPROFILE\.cc-sandbox\claude-dev\mounts.txt" "$env:USERPROFILE\.cc-sandbox\dev-t2\mounts.txt"
Set-Content "$env:USERPROFILE\.cc-sandbox\dev-t2\features.txt" "clip-bridge"   # 只开剪贴板桥,便于验证 daemon 共享

# (b) 起第二台(镜像已缓存,几分钟)
.\scripts\launch.ps1 start -Name dev-t2
# 预期:剪贴板桥 daemon "复用(全局共享,PID ...)"——不再起新进程;桥隧道按 VM 各自一条

# (c) 两台并存,status 无 -Name 给总览
.\scripts\launch.ps1 status
# 预期:claude-dev 与 dev-t2 两行(状态/IP/特性)
.\scripts\launch.ps1 status -Name dev-t2     # 单台详情

# (d) daemon 共享验证:停默认台,daemon 应存活(dev-t2 还在用)
.\scripts\launch.ps1 stop
Get-Process -Id (Get-Content "$env:USERPROFILE\.cc-sandbox\.clip-daemon.pid") -ErrorAction SilentlyContinue
# 预期:进程存在(未停)
multipass exec dev-t2 -- bash -lc "curl -s --max-time 5 http://127.0.0.1:18339/health"
# 预期:{"status":"ok"} —— dev-t2 的桥不受 claude-dev 停机影响

# (e) 全部停掉后 daemon 才退场
.\scripts\launch.ps1 stop -Name dev-t2
Get-Process -Id (Get-Content "$env:USERPROFILE\.cc-sandbox\.clip-daemon.pid" -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue
# 预期:无输出(daemon 已停)

# (f) 清理第二台
.\scripts\launch.ps1 delete -Name dev-t2
Remove-Item "$env:USERPROFILE\.cc-sandbox\dev-t2" -Recurse -Force
.\scripts\launch.ps1 start     # 恢复默认台
```

### 预期汇总

| 检查项 | 预期 |
|---|---|
| (b) 第二台 start | daemon 复用不重起;垫片/隧道独立部署到 dev-t2 |
| (c) status 总览 | 两台 VM 一行一台;`-Name` 进单台详情 |
| (d) 停一台 | daemon 存活;另一台桥仍通 |
| (e) 全停 | daemon 退出 |
| (f) delete -Name | 只删指定台;默认台不受影响 |

另:一次性迁移验证——首次用新版跑任意子命令,根目录旧的 mounts.txt/features.txt 等应自动移入 `claude-dev\` 子目录并打印"一次性迁移"提示。

---

## 发现问题怎么办

按现象查 [troubleshooting.md](./troubleshooting.md):

| 现象 | 章节 |
|---|---|
| `multipass launch` 报 `Timed out waiting for instance launch` | §F(launch 现在超时/失败直接 throw;先 `multipass list` 看是否已 Running,已 Running 就重跑 `start` 只重挂/重起隧道) |
| `cloud-init status --wait` 超时 / 非零 | §B |
| env 同步 `EMPTY` / `claude` 弹登录菜单 | §C |
| Git Bash 报 `fatal error - add_item ... errno 1` | §D |
| 隧道秒退 / 端口探测 000 | §E |
| 隧道报 `ExitCode=255` + `UNPROTECTED PRIVATE KEY FILE` | §E.1 |
| `multipass list` 卡住 / launch 卡在 SSH | §F |
| cloud-init 太慢(>15 分钟) | 跑 `prepare-bundle.ps1` 走离线模式(见 [bundle.md](bundle.md)) |

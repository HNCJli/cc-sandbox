# start-vm 验证清单

回归测试用。按顺序跑,前 4 项 + 测试 6(cc-pocket 随 bundle)必跑,测试 5(Tailscale)可选。每次改 launch.ps1 / cloud-init.yaml / tmux.conf 后建议至少跑 1 + 4。

**通用约定**:
- 所有 `multipass exec claude-dev -- bash -lc "..."` 命令**别换成 `cat ~/.claude/settings.json`** —— 该文件含明文 token,见 troubleshooting §C。
- 验证中发现异常,按现象查 [troubleshooting.md](./troubleshooting.md) 对应小节。

---

## 测试 1:传统单根模式回归(必跑)

**目的**:确认 `.\launch.ps1 start`(无参数)的老用法不破。

### 步骤

```powershell
cd C:\Users\<你>\Desktop\multipass\claude-code-multipass
.\launch.ps1 delete          # 干净起步
.\launch.ps1 start           # 首次 3–15 分钟(取决于网络 + 是否用了 bundle)
```

### 验证

```powershell
# 1. status 三项全 OK
.\launch.ps1 status
# 预期:VM Running、隧道在跑、cc-switch 端口探测 HTTP 4xx

# 2. env 同步到位(应输出 OK,不是 EMPTY)
multipass exec claude-dev -- bash -lc "jq -e .env ~/.claude/settings.json >/dev/null && echo OK || echo EMPTY"

# 3. workspace 挂载真到位(以 findmnt 为准)
multipass exec claude-dev -- bash -lc "findmnt | grep /home/ubuntu/workspace"
multipass exec claude-dev -- bash -lc "ls -la ~/workspace"

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
| `status` 三项 | 全 OK |
| env 检查 | `OK` |
| findmnt | `/home/ubuntu/workspace` 一行 mount(fuse.sshfs) |
| 工具链 | shell=/usr/bin/fish;fish/fzf/zoxide 都有路径;Node v20.x;claude 在 |
| `claude` 进 VM | 不弹登录菜单 |

---

## 测试 2:多目录模式(必跑)

**目的**:验证 `-NoRootWorkspace` + `-ExtraMounts` 挂多个宿主目录到 `~/workspace/<子目录>`。

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
.\launch.ps1 delete
.\launch.ps1 start -NoRootWorkspace -ExtraMounts "D:\code\test1","D:\code\test2=alias2"
```

### 验证

```powershell
.\launch.ps1 status

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
.\launch.ps1 stop
.\launch.ps1 start -NoRootWorkspace -ExtraMounts "D:\code\test1","D:\code\test2=alias2"
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

## 测试 4:参数冲突校验(必跑,最快)

**目的**:确认非法参数组合立刻 throw,不进 launch。

### 步骤(每条都应立刻 throw)

```powershell
# (a) -NoRootWorkspace 和 -WorkspaceHost 不能同时用
.\launch.ps1 start -NoRootWorkspace -WorkspaceHost D:\foo

# (b) 普通 start 加 -ExtraMounts 会触发嵌套挂载
.\launch.ps1 start -ExtraMounts D:\code\test1

# (c) -ExtraMounts 的宿主目录不存在
.\launch.ps1 start -ExtraMounts "D:\nonexistent-dir-xyz"

# (d) -ExtraMounts 的 vmSubdir 含 '..' 逃逸
.\launch.ps1 start -ExtraMounts "D:\code\test1=..\.."

# (e) -ExtraMounts 两个项映射到同一子目录
.\launch.ps1 start -ExtraMounts "D:\code\test1","D:\code\test2=test1"

# (f) -WorkspaceHost 目录不存在
.\launch.ps1 start -WorkspaceHost "D:\nonexistent-ws"
```

### 预期

六条都报 PowerShell throw,提示 `不能同时使用` / `请加 -NoRootWorkspace` / `宿主机目录不存在` / `不允许含 '..'` / `子目录名重复` / `-WorkspaceHost 必须是已存在的目录`。**不进 launch**。

---

## 测试 5:Tailscale 回归(可选)

**目的**:验证 `-EnableTailscale` 仍能装上 tailscale。用途:跨网络直连 VM 上跑的服务(如通过 `100.x.x.x:端口` 访问 VM 里启动的 web);cc-pocket 已支持任意网络遥控,不依赖 tailscale。

### 步骤

```powershell
.\launch.ps1 delete
.\launch.ps1 start -EnableTailscale
multipass exec claude-dev -- bash -lc "which tailscale"
```

### 预期

`/usr/bin/tailscale`。进 VM 后 `sudo tailscale up` 配对(已配过同账号会自动恢复)。

### 组合测试(可选)

`-EnableTailscale` 和多目录应能叠加:

```powershell
.\launch.ps1 start -EnableTailscale -NoRootWorkspace -ExtraMounts "D:\code\test1"
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
- 若 `NOT_INSTALLED`:说明 bundle 缺 cc-pocket 离线包,`launch.ps1 start` 会在启动前报错;先 `.\prepare-bundle.ps1` 补齐,再 `delete + start`。

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
| cloud-init 太慢(>15 分钟) | 跑 `prepare-bundle.ps1` 走离线模式(见 `bundle/README.md`) |

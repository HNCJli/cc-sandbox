# start-vm 验证清单

回归测试用。按顺序跑,前 4 项必跑,5–6 可选。每次改 launch.ps1 / cloud-init.yaml / tmux.conf 后建议至少跑 1 + 4。

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

## 测试 2:多目录模式(必跑,新功能)

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

# ~/workspace 下有两个子目录
multipass exec claude-dev -- bash -lc "ls -la ~/workspace"

# 内容能读到(各 cat 输出对应 hello 字符串)
multipass exec claude-dev -- bash -lc "cat ~/workspace/test1/a.txt"
multipass exec claude-dev -- bash -lc "cat ~/workspace/alias2/b.txt"
```

### 预期

- findmnt 输出含 `~/workspace/test1` 和 `~/workspace/alias2` 两条
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
- findmnt 仍输出两条 mount

---

## 测试 4:参数冲突校验(必跑,最快)

**目的**:确认互斥参数组合立刻报错,不进 launch。

### 步骤(两条都应立刻 throw)

```powershell
# (a) -NoRootWorkspace 和 -WorkspaceHost 不能同时用
.\launch.ps1 start -NoRootWorkspace -WorkspaceHost D:\foo

# (b) 普通 start 加 -ExtraMounts 会触发嵌套挂载
.\launch.ps1 start -ExtraMounts D:\code\test1
```

### 预期

两条都报 PowerShell throw,提示参数冲突 / 必须带 `-NoRootWorkspace`。**不进 launch**。

---

## 测试 5:Tailscale 回归(可选)

**目的**:验证 `-EnableTailscale` 仍能装上 tailscale(只在用 cc-pocket 跨网络遥控时才需要)。

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

## 测试 6:cc-pocket 失败不阻断(可选)

**目的**:验证 cc-pocket 装失败时,核心 VM(Node + Claude Code)仍可用。

### 步骤

正常装完后:

```powershell
multipass exec claude-dev -- bash -lc "command -v cc-pocket-daemon && echo INSTALLED || echo NOT_INSTALLED"
multipass exec claude-dev -- bash -lc "systemctl --user status cc-pocket-daemon 2>&1 | head -5"
```

### 预期

- `INSTALLED`(正常装上)
- 或 `NOT_INSTALLED`(网络断/版本不兼容)但 `claude` 仍能跑 —— 这是设计上的容错

**判断标准**:`command -v claude` 在 + claude 能启动 = 测试通过,不管 cc-pocket 是否装上。

---

## 发现问题怎么办

按现象查 [troubleshooting.md](./troubleshooting.md):

| 现象 | 章节 |
|---|---|
| `multipass launch` 报 `Timed out waiting for instance launch` | §F(也可能是 launch.ps1 已修的旁路探测,VM 其实已就绪 → `multipass list` 看状态) |
| `cloud-init status --wait` 超时 / 非零 | §B |
| env 同步 `EMPTY` / `claude` 弹登录菜单 | §C |
| Git Bash 报 `fatal error - add_item ... errno 1` | §D |
| 隧道秒退 / 端口探测 000 | §E |
| 隧道报 `ExitCode=255` + `UNPROTECTED PRIVATE KEY FILE` | §E.1 |
| `multipass list` 卡住 / launch 卡在 SSH | §F |
| cloud-init 太慢(>15 分钟) | 跑 `prepare-bundle.ps1` 走离线模式(见 README「离线 bundle」) |

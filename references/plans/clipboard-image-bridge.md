# Windows Warp 图片剪贴板桥接到 VM Claude Code — **未实施方案**

> 本文仅记录候选设计，仓库当前**没有** `clipboard-image-bridge.ahk`、AutoHotkey 依赖或自动热键行为；不能把本文当作已可用功能、测试结论或支持承诺。

## 背景

当前工作链路：

```text
Windows Warp → multipass shell claude-dev → Fish →（可选）tmux → Claude Code CLI
```

普通文本可通过 `Ctrl+V` 作为终端字符流到达 VM；Windows 剪贴板图片是 Bitmap/DIB/PNG 等富媒体对象，普通终端流无法将它作为 Claude Code CLI 的原生图片附件传入。

本方案不改变 VM 中 Claude Code 的运行位置，而是在 **Windows 宿主机**上将剪贴板图片转为 PNG 文件，再通过现有 Multipass 挂载让 VM 中的 Claude Code 读取该文件。最终在 Warp 中仍由用户按普通 `Ctrl+V` 触发。

> 这不是 Claude Code TUI 中的原生图片缩略图附件。Claude Code 会收到一段包含 VM 图片绝对路径的文字，并从文件系统读取真实 PNG。

## 最终用户体验

在 Warp 为前台、并且光标位于直接 VM Shell 或 tmux 中的 Claude Code 输入框时：

```text
Windows 截图
→ Ctrl+V
→ 宿主机脚本保存截图 PNG
→ 当前 Warp 输入框自动写入：
  请分析图片：/home/ubuntu/workspace/clipboard/clipboard-<唯一名>.png
→ 用户确认后按 Enter
```

行为规则：

| 条件 | Ctrl+V 行为 |
|---|---|
| Warp 前台，剪贴板没有图片（普通文本、文件列表等） | 原样普通粘贴，不改变行为。 |
| Warp 前台，剪贴板有可读取图片 | 阻止原始粘贴；保存 PNG；输入 VM 路径提示；**不自动按 Enter**。 |
| Warp 前台，图片读取/保存失败 | 显示简短错误提示，回放原始 Ctrl+V，避免吞掉用户输入。 |
| 图片保存期间 Warp 焦点发生变化 | 保留已保存 PNG，但不向其他窗口注入文字；显示保存结果和 VM 路径。 |
| 其他应用前台 | 不注册热键，原生 Ctrl+V 完全不受影响。 |

如果剪贴板同时有文本和图片，**图片优先**。

## 专用截图收件箱挂载

不要将截图写进代码项目目录。新增独立收件箱：

```text
宿主机：<用户选择的目录>\ClaudeClipboardInbox
VM：    /home/ubuntu/workspace/clipboard
```

在状态目录的**用户本地、未跟踪** `mounts.txt` 追加：

```text
<用户选择的目录>\ClaudeClipboardInbox=clipboard
```

创建目录并使挂载生效：

```powershell
New-Item -ItemType Directory -Path <用户选择的目录>\ClaudeClipboardInbox
.\launch.ps1 start
```

该挂载是 `~/workspace` 下的顶级额外挂载（`~/workspace` 保持 VM 本地目录,Windows 上 Multipass 对嵌套挂载支持不稳）。此方案依赖用户在本机创建并维护收件箱及 `mounts.txt`；它们不会随仓库克隆或 VM 删除自动恢复。VM 重建时仅能按当时仍存在、可访问的本地声明重新挂载，不能承诺原样回放。

图片对应关系：

```text
宿主机：<用户选择的目录>\ClaudeClipboardInbox\clipboard-YYYYMMDD-HHMMSS-<GUID>.png
VM：    /home/ubuntu/workspace/clipboard/clipboard-YYYYMMDD-HHMMSS-<GUID>.png
```

## 需要新增的文件

在项目根目录新增：

```text
clipboard-image-bridge.ahk
```

它是仅运行在 Windows 宿主机的 **AutoHotkey v2** 脚本：

- 不写入 `cloud-init.yaml`；
- 不由 `launch.ps1` 自动启动或停止；
- 不修改 Fish、tmux、Claude Code；
- 初版以 `.ahk` 源码运行，验证稳定后再可选编译为 exe 或设为开机启动。

脚本顶部应有明确配置：

```ahk
HostImageDir := "<用户选择的目录>\ClaudeClipboardInbox"
VmImageDir   := "/home/ubuntu/workspace/clipboard"
WarpSelector := "ahk_exe Warp.exe"  ; 必须用 AutoHotkey Window Spy 实测确认
```

## AutoHotkey 实现要求

### Ctrl+V 热键

只在 Warp 前台时拦截，使用 `$` 避免脚本自身回放粘贴时递归：

```ahk
#HotIf WinActive(WarpSelector)
$^v::HandleWarpPaste()
#HotIf
```

`HandleWarpPaste()` 的执行顺序：

1. 保存当前前台 Warp HWND。
2. 检测 Windows 剪贴板是否含支持的图片格式。
3. 没有图片时，执行 `SendInput "^v"`，保持普通粘贴行为。
4. 有图片时，设置重入保护，读取图片并原子写入 PNG。
5. 保存完成后再次验证前台 HWND 仍为最初 Warp 窗口。
6. 焦点仍正确时，使用 `SendText()` 输入：

   ```text
   请分析图片："/home/ubuntu/workspace/clipboard/<文件名>.png"
   ```

7. 不注入 Enter。
8. 所有路径都必须在 `finally` 中清理重入标记、clipboard/GDI+ 资源和失败临时文件。

### 图片格式与读取

不要把 `A_Clipboard` 或 PowerShell `Get-Clipboard` 当作图像接口；它们不适合作为可靠图片读取方式。

使用 Win32 + GDI+，按优先级检查：

1. `CF_DIBV5`（17）
2. `CF_DIB`（8）
3. 注册 `RegisterClipboardFormatW("PNG")` 返回的格式
4. `CF_BITMAP`（2）

实现细节：

- `OpenClipboard` 应短暂重试（例如 10–20 次，每次 10–25 ms），避免截图工具暂时占用剪贴板。
- DIB/DIBV5：`GetClipboardData` → `GlobalLock` → `GdipCreateBitmapFromGdiDib`；确保 `GlobalUnlock`。
- PNG：HGLOBAL 原始 PNG 字节 → 内存 stream → GDI+ bitmap；stream 必须持有到 bitmap 保存/释放完成。
- Bitmap fallback：`GdipCreateBitmapFromHBITMAP`；**不得**释放 clipboard 所有的 HBITMAP，仅释放新建的 GDI+ image。
- 脚本启动时 `GdiplusStartup`；退出时 `GdiplusShutdown`。
- 可选择将一个明确支持 AutoHotkey v2 的最小 GDI+ helper 随脚本一并纳入项目，或直接用最小 `DllCall` 包装实现。

### 安全的文字注入

使用：

```ahk
SendText(prompt)
```

不要用普通 `Send` 发送路径文本，避免 `!`、`^`、`{}`、引号等字符被解释成按键语法。

保存图片后，如果焦点已经不再是最初的 Warp HWND：

- 不向当前窗口注入任何内容；
- 图片保留；
- 用 TrayTip 等方式提示已保存的 VM 路径。

脚本与 Warp 应以相同完整性级别运行（建议均为普通用户），避免 Windows UIPI 阻止模拟输入。

## 文件保存与清理策略

### 原子保存

目标目录：

```text
<用户选择的目录>\ClaudeClipboardInbox
```

命名：

```text
clipboard-YYYYMMDD-HHMMSS-<GUID>.png
```

流程：

1. 在同一目录写入 `.tmp-<GUID>.png`；
2. 完成 PNG 编码、关闭文件/释放 GDI+ 资源；
3. 用同目录 rename（如 `MoveFileExW`）发布最终唯一文件名；
4. 最终文件已出现后，才向 Warp 输入 VM 路径；
5. 失败时删除临时文件，绝不注入不存在的路径。

### 自动清理

每次**成功保存并发布**新 PNG 后，只在专用收件箱内执行：

1. 删除超过 **7 天**的 `clipboard-*.png`；
2. 按最后写入时间倒序，只保留最近 **100 张**；
3. 删除残留 `.tmp-*.png` 临时文件；
4. 不递归，不删除任何非本桥接器创建的文件，也不删除项目目录内容。

图片路径使用唯一文件名。要长期保留某张图，用户应显式复制/移动到具体项目目录；不要依赖收件箱的保留策略。

## README 需要更新的内容

在 `README.md` 新增“Warp 中向 VM Claude Code 粘贴图片”小节：

1. 说明 Ctrl+V 图片会被转换为已挂载 PNG 文件和路径文字，不是原生 TUI 图片附件。
2. 前置：安装 **AutoHotkey v2**。
3. 创建 `<用户选择的目录>\ClaudeClipboardInbox`，在 `mounts.txt` 添加：

   ```text
   <用户选择的目录>\ClaudeClipboardInbox=clipboard
   ```

4. 执行 `.\launch.ps1 start` 使新挂载生效(自动读 `mounts.txt`,子目录挂到 `~/workspace` 下)。
5. 运行 `clipboard-image-bridge.ahk`；托盘退出即可禁用并恢复 Warp 原生 Ctrl+V。
6. 列出 Ctrl+V 的图片/文本行为差异；强调不自动 Enter。
7. 说明直接 VM Shell 与 tmux 会话中的 Claude Code 均适用。
8. 写明 7 天 / 100 张 / 临时文件清理规则，以及长期保留图片的方式。
9. 排障：
   - 用 AHK Window Spy 确认 Warp 实际进程选择器；
   - 检查 VM 是否有 `/home/ubuntu/workspace/clipboard`；
   - 用 `multipass exec claude-dev -- bash -lc "ls -la ~/workspace/clipboard"` 验证挂载；
   - 检查 host 收件箱目录是否可写。
10. 安全说明：剪贴板图片可能含敏感内容，会保存在宿主机专用目录，并可被 VM 读取。

## 验证清单

1. **文本回归**：Warp 前台复制纯文本，Ctrl+V 与未运行脚本时一致；非 Warp 应用 Ctrl+V 也不变。
2. **直接 VM Claude Code**：在 `multipass shell claude-dev` 内运行 Claude；截图后 Ctrl+V，输入框出现 VM 路径但不自动提交；VM 内确认文件存在；发送后 Claude 能描述图片。
3. **tmux Claude Code**：`tmux a` 后重复上项，验证同样可用。
4. **图片来源**：测试 Snipping Tool、浏览器复制图片、透明 PNG。
5. **焦点竞态**：保存期间切换窗口；不得向非 Warp 窗口输入文本。
6. **失败回退**：无图、clipboard busy、目标目录不可写、编码失败时，给出提示并回放普通 Ctrl+V，不吞输入。
7. **清理**：构造过期文件、超过 100 张的文件和 `.tmp-*.png`，验证仅专用目录中目标文件被清理。
8. **退出**：退出 AHK 脚本后，Warp Ctrl+V 完全恢复原生行为。

## 明确不做的方案

- 不用 OSC 52、tmux passthrough、Base64 文本注入或终端图片显示协议解决图片输入；它们不提供 Windows 剪贴板图片 → 远端 Claude Code CLI 附件的标准通道。
- 不拦截所有 Windows 应用的 Ctrl+V；仅 Warp 前台时有效。
- 不自动按 Enter，避免焦点错误或未审阅 prompt 时误发送。
- 不让 `launch.ps1` 隐式管理常驻热键进程。

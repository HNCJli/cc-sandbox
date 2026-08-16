# 故障排查

## VM 里 Claude Code 报连不上 LLM / cc-switch

```powershell
# 1. 隧道在不在?
.\launch.ps1 status                    # 看 "SSH 反向隧道" 段 + "VM 内 cc-switch 端口探测"
                                       # 返回 HTTP 404 = 通(根路径不响应但服务在);000 = 隧道断

# 2. VM 里手动 curl
multipass exec claude-dev -- curl -v http://127.0.0.1:15721/
# connection refused → 隧道断了,restart

# 3. settings.json 同步了吗(应含 env + 本地 statusLine,无 mcpServers 等;含明文 token,别直接 cat)
multipass exec claude-dev -- bash -lc "jq -e '.env | type == \"object\" and length > 0' ~/.claude/settings.json >/dev/null && echo 'env 同步 OK' || echo 'env 为空'"
```

## 隧道进程死了

```powershell
.\launch.ps1 restart                   # 重拉一切
# 或只重起隧道(不重启 VM):
Stop-Process -Id (Get-Content .tunnel.pid) -Force
Remove-Item .tunnel.pid
.\launch.ps1 start                     # 检测到 VM 在 Running 会跳过 launch,只重挂/重起隧道
```

## 挂载失败 / Multipass 报 "Mounts are disabled"

Windows 上 Multipass 默认可能禁用 privileged-mounts。`launch.ps1 start` 首次会自动开启(`multipass set local.privileged-mounts=true`),若失败手动执行一次即可。

## 挂载失败(非 ASCII 路径)

如果 Windows 账号名或项目路径含中文等非 ASCII 字符,`multipass mount` 在 Windows 上支持不稳。

**workspace 挂不上**的备选:
1. 把项目挪到 ASCII 路径(如 `C:\dev\claude-vm\`),重新 `.\launch.ps1 start`
2. 或在 ASCII 路径建 Windows junction 指向真实路径:
   ```powershell
   New-Item -ItemType Junction -Path C:\dev\workspace -Target "<项目实际路径>\workspace"
   ```
   然后 `.\launch.ps1 start -WorkspaceHost C:\dev\workspace` 用 junction 路径启动

**`~/.claude` 挂不上**:用 junction:
```powershell
New-Item -ItemType Junction -Path C:\dev\claude-config -Target "$env:USERPROFILE\.claude"
# 编辑 launch.ps1 把 $hostClaude 改成 C:\dev\claude-config
```

## cloud-init 没跑完

```powershell
multipass exec claude-dev -- cloud-init status --long    # 看详细
multipass exec claude-dev -- sudo cat /var/log/cloud-init-output.log
```

## 想完全重来

```powershell
.\launch.ps1 delete
.\launch.ps1 start
```

`.ssh-key`、`workspace/` 不会删,会复用。

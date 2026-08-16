# VM 日常:外部 SSH / Fish / tmux

## SSH 进 VM(IDE 集成 / 外部 SSH 客户端)

VM 默认通过 `multipass shell` 进,不用密码。若要外部 SSH(如 VSCode Remote-SSH):

`~/.ssh/config` 加:
```
Host claude-dev
    HostName <VM IP>            # multipass info claude-dev 看 IPv4
    User ubuntu
    IdentityFile <项目路径>/.ssh-key
    StrictHostKeyChecking no
```

VM IP 在 stop/start 后可能变,需更新。持久的 `multipass shell` 不受影响。

## VM 交互 shell:Fish

VM 默认交互 shell 是 **Fish**(配 fzf + zoxide)。`multipass shell claude-dev` 进去就是 fish 提示符:

- **灰色历史建议**:边敲边显示匹配的历史命令,`→` 或 `Ctrl+F` 接受
- **`Tab` 补全** / **`Ctrl+R`** 模糊搜历史(fzf)
- **`z <关键词>`** 智能跳转目录(zoxide,基于使用频率)
- 临时需要 bash 敲 `bash`;`.sh` 脚本和 cloud-init 仍走 bash

每次敲 `claude` 前,fish 和 bash 一样会自动重新同步 cc-switch env(读 `~/.claude-host`,jq 过滤,写 `~/.claude/settings.json` chmod 444)。

## tmux 快捷键

| 操作 | 快捷键 / 命令 |
|---|---|
| 新建会话 | `tmux new -s <名字>` |
| 退到后台(detach) | `Ctrl+B` 松开,再按 `D`(Shift) |
| 重新连回 | `tmux a` 或 `tmux a -t <名字>` |
| 列出会话 | `tmux ls`(没会话时报 `error connecting to ...` 是正常提示,不是 bug) |
| 不依赖快捷键的退出 | 在 tmux 内的 shell 敲 `tmux detach-client` |

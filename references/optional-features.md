# 可选功能:VM 内 Docker / 跨网络访问(Tailscale) / 宿主机路径换算

## 宿主机路径自动换算(路径映射记忆)

勾选后,`start` 会在挂载完成后往 **VM 内** Claude Code 的全局记忆(`~/.claude/CLAUDE.md`)写入"沙箱说明 + 宿主机↔VM 路径映射表"(只含 workspace 挂载,按本次 mounts.txt 实际挂载生成,每条挂载一项)。之后在 VM 里的 Claude Code 对话中**直接贴宿主机 Windows 路径**即可,如:

```
看下 D:\multipass-share-dir-worksapce\share-dir-01\test-project\.gitignore
```

VM 里的 Claude Code 按表换算成 `/home/ubuntu/workspace/share-dir-01/test-project/.gitignore` 再读写,也会在展示文件位置时反向换算回 Windows 路径。

- 勾选方式同 Tailscale:交互菜单空格勾选,或直接编辑 `features.txt` 加一行 `path-map`
- **非重建型**:勾上后现有 VM 下次 `start` 即写入,不需要 delete + start;每次 start 按当前挂载刷新
- 取消勾选后,下次 `start` 会把 VM 里这段映射块移除(`CLAUDE.md` 中标记 `<!-- cc-sandbox:begin/end -->` 之间的内容,块外自己写的内容不动)

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

选择会写进状态目录 `features.txt`(每行一个特性 id),之后 `delete + start` 重建、日常 start 都自动沿用,不用再记参数;想关掉就再跑菜单选 `n`,或删掉文件里那行(关掉后需重建 VM 才真正卸载)。非交互场景(脚本/CI/Claude 代跑)没有菜单,静默沿用 features.txt;要改选择就直接编辑该文件,格式见 `assets\features.example.txt`。

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

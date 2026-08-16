# 可选功能:VM 内 Docker / 跨网络访问(Tailscale)

## VM 内装 Docker

VM 已经是 Ubuntu,直接 `apt install` 就行,不用重建:

```bash
# 进 VM 后
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker ubuntu     # 然后退出重进 shell 让组生效
sudo systemctl enable --now docker
```

## 跨网络访问 VM(Tailscale)

在外面(手机 4G、咖啡店 WiFi)想直连 VM 上跑的服务时,加 `-EnableTailscale` 预装:

```powershell
.\scripts\launch.ps1 delete                # cloud-init 只在 launch 时跑,改预装必须重建 VM
.\scripts\launch.ps1 start -EnableTailscale
```

VM 起来后,**进 VM 手动配对**(cloud-init 阶段没法弹浏览器):
```bash
sudo tailscale up              # 弹 URL,浏览器登录同一个 tailscale 账号
tailscale ip                   # 看 VM 拿到的 100.x.x.x 内网 IP
```

手机/其他设备登同一个 tailscale 账号后,就能用那个 100.x.x.x IP SSH / 直连 VM 上任意服务。例如 VM 里起了 web 服务(`python -m http.server 8000`),在任何网络下浏览器开 `http://100.x.x.x:8000` 即可访问。

**⚠️ 公司场景千万别开**:
- `-EnableTailscale` 会真的把 tailscale 包装进 VM
- 即使不 `tailscale up` 没有出站流量,公司软件审计(SCCM 类)能扫到包已装
- 公司禁远控/打洞软件时,这会被识别为违规
- 公司场景用 `.\scripts\launch.ps1 start`(不带 `-EnableTailscale`),完全不碰

**cc-pocket 与 Tailscale 的关系(定位已变化)**:cc-pocket 现已支持任意网络遥控 VM 里的 Claude Code,**不需要 Tailscale**。Tailscale 的用途是跨网络直连 VM 上任意 TCP/UDP 服务(SSH、VM 里启动的 web 等),与 cc-pocket 无关。

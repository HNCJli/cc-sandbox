#!/usr/bin/env bash
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/home/ubuntu/.local/bin:$PATH
printf '%s\n' 'stage=3' 'package=0' 'package_name=Node.js' > /run/claude-dev/progress
printf '%s\n' 'event=stage:3|[3/6] 安装 Node.js' >> /run/claude-dev/events
tar -xJf /home/ubuntu/.bundle/node-v*-linux-x64.tar.xz -C /usr/local --strip-components=1
printf '%s\n' 'stage=4' 'package=0' 'package_name=Claude Code' > /run/claude-dev/progress
printf '%s\n' 'event=stage:4|[4/6] 安装 Claude Code' >> /run/claude-dev/events
printf '%s\n' 'event=stage:3|[3/6] 安装 Claude Code' >> /run/claude-dev/events
npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-linux-x64-*.tgz
npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-[0-9]*.tgz
cc_asset=$(find /home/ubuntu/.bundle/cc-pocket -maxdepth 1 -name 'cc-pocket-daemon-*-linux-x86_64.tar.gz' | head -1)
mkdir -p /home/ubuntu/.local/share/cc-pocket/versions/"${cc_asset##*/}"
tar -xzf "$cc_asset" -C /home/ubuntu/.local/share/cc-pocket/versions/"${cc_asset##*/}"
cc_dir=$(find /home/ubuntu/.local/share/cc-pocket/versions/"${cc_asset##*/}" -maxdepth 1 -type d -name cc-pocket-daemon | head -1)
mkdir -p /home/ubuntu/.local/bin
ln -sfn "$cc_dir/bin/cc-pocket-daemon" /home/ubuntu/.local/bin/cc-pocket-daemon
chown -R ubuntu:ubuntu /home/ubuntu/.local/share/cc-pocket /home/ubuntu/.local/bin

# 注册 cc-pocket 的 systemd 用户服务,让 daemon 自启(离线流程不跑官方 install.sh,得自己补注册)。
# 关键:root 上下文没有 D-Bus user session,必须先起 user@1000 + 显式给 XDG_RUNTIME_DIR,
# 否则 systemctl --user / service-install 失败,daemon 不会自起(cloud-init 时代踩过的坑)。
# 失败只警告不退出:二进制已装好,服务注册可按 SKILL.md 的手动命令补
if loginctl enable-linger ubuntu && systemctl start user@1000.service; then
    for i in $(seq 1 20); do [ -S /run/user/1000/bus ] && break; sleep 0.5; done
    if sudo -u ubuntu \
        XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        /home/ubuntu/.local/bin/cc-pocket-daemon service-install --apply --exec /home/ubuntu/.local/bin/cc-pocket-daemon \
       && sudo -u ubuntu \
        XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        systemctl --user enable --now cc-pocket-daemon; then
        printf '%s\n' 'event=cc-pocket 服务已注册并自启' >> /run/claude-dev/events
    else
        echo 'WARN: cc-pocket 服务注册失败。手动补: cc-pocket-daemon service-install --apply --exec ~/.local/bin/cc-pocket-daemon && systemctl --user enable --now cc-pocket-daemon' >&2
    fi
else
    echo 'WARN: user@1000/linger 启动失败,cc-pocket 服务未注册(手动补法见上)' >&2
fi

command -v node && command -v npm && command -v claude && command -v cc-pocket-daemon

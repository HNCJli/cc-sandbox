#!/usr/bin/env bash
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/home/ubuntu/.local/bin:$PATH
printf '%s\n' 'stage=3' 'package=0' 'package_name=Node.js' > /run/claude-dev/progress
printf '%s\n' 'event=stage:3|[3/7] 安装 Node.js' >> /run/claude-dev/events
tar -xJf /home/ubuntu/.bundle/node-v*-linux-x64.tar.xz -C /usr/local --strip-components=1
printf '%s\n' 'stage=4' 'package=0' 'package_name=Claude Code' > /run/claude-dev/progress
printf '%s\n' 'event=stage:4|[4/7] 安装 Claude Code' >> /run/claude-dev/events
npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-linux-x64-*.tgz
npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-[0-9]*.tgz
# opencode:npm 双包与 Claude Code 同构(wrapper 的 optionalDependencies 指向平台包,
# 离线装时 npm 对 optional 联网拉取失败只警告,平台包随后本地 tgz 补上)
printf '%s\n' 'stage=5' 'package=0' 'package_name=opencode' > /run/claude-dev/progress
printf '%s\n' 'event=stage:5|[5/7] 安装 opencode' >> /run/claude-dev/events
npm install -g /home/ubuntu/.bundle/opencode-linux-x64-*.tgz
npm install -g /home/ubuntu/.bundle/opencode-ai-[0-9]*.tgz
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

# ---------- 可选开发环境(dev-java / dev-python / dev-frontend)----------
# launch.ps1 按 features.txt 勾选传 --dev-* 标志(单词参数,免疫 exec 传参拆词);
# bundle 缺件跳过、安装失败只警告——都不中断脚本(核心件已装好),launch 侧 Start-DevEnvs 在线兜底。
# 全部离线装:tar 解 /opt + symlink /usr/local/bin、wheel 解出二进制、本地 tgz npm -g。
want_java=
want_python=
want_frontend=
for arg in "$@"; do
    case "$arg" in
        --dev-java)     want_java=1 ;;
        --dev-python)   want_python=1 ;;
        --dev-frontend) want_frontend=1 ;;
    esac
done

if [ -n "$want_java" ]; then
    jdk_tar=$(find /home/ubuntu/.bundle/jdk -maxdepth 1 -name 'OpenJDK17U-jdk_x64_linux_hotspot_*.tar.gz' 2>/dev/null | head -1)
    if [ -n "$jdk_tar" ]; then
        # 命令都在 if 条件里:set -e 不触发,失败走 warn 分支
        if mkdir -p /opt && tar -xzf "$jdk_tar" -C /opt; then
            for b in java javac jar jshell; do ln -sfn /opt/jdk-17*/bin/"$b" /usr/local/bin/"$b"; done
            printf '%s\n' 'event=dev-java:JDK 17 已离线安装(/opt + /usr/local/bin 链接)' >> /run/claude-dev/events
        else
            echo 'WARN: JDK 离线安装失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 JDK:bundle/jdk 无 tarball(launch 将在线兜底)' >&2
    fi
    mvn_tar=$(find /home/ubuntu/.bundle/maven -maxdepth 1 -name 'apache-maven-*-bin.tar.gz' 2>/dev/null | head -1)
    if [ -n "$mvn_tar" ]; then
        if mkdir -p /opt && tar -xzf "$mvn_tar" -C /opt && ln -sfn /opt/apache-maven-*/bin/mvn /usr/local/bin/mvn; then
            printf '%s\n' 'event=dev-java:Maven 已离线安装(/opt + /usr/local/bin/mvn)' >> /run/claude-dev/events
        else
            echo 'WARN: Maven 离线安装失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 Maven:bundle/maven 无 tarball(launch 将在线兜底)' >&2
    fi
fi

if [ -n "$want_python" ]; then
    uv_whl=$(find /home/ubuntu/.bundle/uv -maxdepth 1 -name 'uv-*.whl' 2>/dev/null | head -1)
    if [ -n "$uv_whl" ]; then
        # wheel 就是 zip:系统 python3 自带 zipfile 模块解包,取出 uv/uvx 二进制装 /usr/local/bin。
        # 实测 wheel 布局:二进制在 <name>.data/scripts/uv(第 3 层),find 深度须 ≥3
        rm -rf /tmp/uv-extract && mkdir -p /tmp/uv-extract
        if python3 -m zipfile -e "$uv_whl" /tmp/uv-extract &&
           install -m 0755 "$(find /tmp/uv-extract -maxdepth 3 -type f -name uv | head -1)" /usr/local/bin/uv &&
           { uvx_bin=$(find /tmp/uv-extract -maxdepth 3 -type f -name uvx | head -1);
             [ -z "$uvx_bin" ] || install -m 0755 "$uvx_bin" /usr/local/bin/uvx; }; then
            rm -rf /tmp/uv-extract
            printf '%s\n' 'event=dev-python:uv 已离线安装(/usr/local/bin)' >> /run/claude-dev/events
        else
            rm -rf /tmp/uv-extract
            echo 'WARN: uv 离线安装失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 uv:bundle/uv 无 wheel(launch 将在线兜底)' >&2
    fi
fi

if [ -n "$want_frontend" ]; then
    pnpm_tgz=$(find /home/ubuntu/.bundle/pnpm -maxdepth 1 -name 'pnpm-*.tgz' 2>/dev/null | head -1)
    if [ -n "$pnpm_tgz" ]; then
        # pnpm 的 npm 包自带全部依赖(bundle 版),本地 tgz 安装不触网。
        # 自检 pnpm -v:防"装上但跑不起来"(如 pnpm 11 需 Node 22,VM 是 Node 20)
        if npm install -g "$pnpm_tgz" && pnpm --version >/dev/null 2>&1; then
            printf '%s\n' 'event=dev-frontend:pnpm 已离线安装(npm 本地 tgz)' >> /run/claude-dev/events
        else
            echo 'WARN: pnpm 离线安装或自检失败(可能与 Node 版本不兼容;launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 pnpm:bundle/pnpm 无 tgz(launch 将在线兜底)' >&2
    fi
fi

command -v node && command -v npm && command -v claude && command -v opencode && command -v cc-pocket-daemon

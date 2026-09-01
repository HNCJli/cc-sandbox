#!/usr/bin/env bash
# 离线安装(以 root 运行:sudo bash /tmp/install-bundle.sh [--dev-java] [--dev-python] [--dev-frontend])
# 架构:AI 工具原生二进制直装(/opt/tools/<name>/<ver>/ + /usr/local/bin symlink),不经 npm/node;
#       语言运行时归版本管理器——java/maven 进 SDKMAN candidates,node 进 nvm versions,uv 直装,
#       pnpm 独立二进制(与 node 版本解耦)。
# 本脚本只在核心件缺失时执行(launch.ps1 幂等探测),re-run 安全(symlink -f、先 rm 再 mv)。
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/home/ubuntu/.local/bin:$PATH
U=/home/ubuntu   # 目标用户家目录(sudo 下 $HOME 是 /root,必须显式)
B=/home/ubuntu/.bundle

# ---------- 核心:Claude Code 原生二进制(stage 3)----------
claude_tgz=$(find "$B" -maxdepth 1 -name 'anthropic-ai-claude-code-linux-x64-*.tgz' | head -1)
if [ -z "$claude_tgz" ]; then echo 'FATAL: bundle 缺 Claude Code 平台包' >&2; exit 1; fi
printf '%s\n' 'stage=3' 'package=0' 'package_name=Claude Code' > /run/claude-dev/progress
printf '%s\n' 'event=stage:3|[3/7] 安装 Claude Code' >> /run/claude-dev/events
claude_ver=$(basename "$claude_tgz" | sed 's/^anthropic-ai-claude-code-linux-x64-\(.*\)\.tgz$/\1/')
rm -rf /opt/tools/claude && mkdir -p /opt/tools/claude/"$claude_ver"
# tgz 内布局 package/claude(单文件原生二进制);--strip-components=1 剥掉 package/
tar -xzf "$claude_tgz" -C /opt/tools/claude/"$claude_ver" --strip-components=1
chmod 755 /opt/tools/claude/"$claude_ver"/claude
ln -sfn /opt/tools/claude/"$claude_ver"/claude /usr/local/bin/claude
printf '%s\n' "event=claude $claude_ver 原生直装完成(/opt/tools/claude/$claude_ver)" >> /run/claude-dev/events

# ---------- 核心:opencode 原生二进制(stage 4)----------
oc_tgz=$(find "$B" -maxdepth 1 -name 'opencode-linux-x64-*.tgz' | head -1)
if [ -z "$oc_tgz" ]; then echo 'FATAL: bundle 缺 opencode 平台包' >&2; exit 1; fi
printf '%s\n' 'stage=4' 'package=0' 'package_name=opencode' > /run/claude-dev/progress
printf '%s\n' 'event=stage:4|[4/7] 安装 opencode' >> /run/claude-dev/events
oc_ver=$(basename "$oc_tgz" | sed 's/^opencode-linux-x64-\(.*\)\.tgz$/\1/')
rm -rf /opt/tools/opencode && mkdir -p /opt/tools/opencode/"$oc_ver"
# tgz 内布局 package/bin/opencode(单文件原生二进制)
tar -xzf "$oc_tgz" -C /opt/tools/opencode/"$oc_ver" --strip-components=1
chmod 755 /opt/tools/opencode/"$oc_ver"/bin/opencode
ln -sfn /opt/tools/opencode/"$oc_ver"/bin/opencode /usr/local/bin/opencode
printf '%s\n' "event=opencode $oc_ver 原生直装完成(/opt/tools/opencode/$oc_ver)" >> /run/claude-dev/events

# ---------- 核心:cc-pocket(stage 5)----------
printf '%s\n' 'stage=5' 'package=0' 'package_name=cc-pocket' > /run/claude-dev/progress
printf '%s\n' 'event=stage:5|[5/7] 安装 cc-pocket' >> /run/claude-dev/events
cc_asset=$(find "$B/cc-pocket" -maxdepth 1 -name 'cc-pocket-daemon-*-linux-x86_64.tar.gz' | head -1)
mkdir -p "$U/.local/share/cc-pocket/versions/${cc_asset##*/}"
tar -xzf "$cc_asset" -C "$U/.local/share/cc-pocket/versions/${cc_asset##*/}"
cc_dir=$(find "$U/.local/share/cc-pocket/versions/${cc_asset##*/}" -maxdepth 1 -type d -name cc-pocket-daemon | head -1)
mkdir -p "$U/.local/bin"
ln -sfn "$cc_dir/bin/cc-pocket-daemon" "$U/.local/bin/cc-pocket-daemon"
chown -R ubuntu:ubuntu "$U/.local/share/cc-pocket" "$U/.local/bin"

# 注册 cc-pocket 的 systemd 用户服务,让 daemon 自启(离线流程不跑官方 install.sh,得自己补注册)。
# 关键:root 上下文没有 D-Bus user session,必须先起 user@1000 + 显式给 XDG_RUNTIME_DIR,
# 否则 systemctl --user / service-install 失败,daemon 不会自起(cloud-init 时代踩过的坑)。
# 失败只警告不退出:二进制已装好,服务注册可按 SKILL.md 的手动命令补
if loginctl enable-linger ubuntu && systemctl start user@1000.service; then
    for i in $(seq 1 20); do [ -S /run/user/1000/bus ] && break; sleep 0.5; done
    if sudo -u ubuntu \
        XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        "$U/.local/bin/cc-pocket-daemon" service-install --apply --exec "$U/.local/bin/cc-pocket-daemon" \
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

# AI 工具自更新统一关闭:装在 root 目录(/opt/tools),自更新必然失败,预先关掉省噪声
printf '%s\n' 'export DISABLE_AUTOUPDATER=1' > /etc/profile.d/cc-sandbox.sh

# ---------- 可选开发环境(dev-java / dev-python / dev-frontend)----------
# launch.ps1 按 features.txt 勾选传 --dev-* 标志(单词参数,免疫 exec 传参拆词);
# bundle 缺件跳过、安装失败只警告——都不中断脚本(核心件已装好),launch 侧 Start-DevEnvs 在线兜底。
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
    sdk_dir="$U/.sdkman"   # JDK/Maven 预置段也引用,必须在缺件分支外定义
    # --- SDKMAN 本体(cli + native 两 zip 复刻官方安装布局)---
    cli_zip=$(find "$B/sdkman" -maxdepth 1 -name 'sdkman-cli-*.zip' 2>/dev/null | head -1)
    native_zip=$(find "$B/sdkman" -maxdepth 1 -name 'sdkman-native-*-linuxx64.zip' 2>/dev/null | head -1)
    if [ -n "$cli_zip" ] && [ -n "$native_zip" ]; then
        # 命令都在 if 条件里:set -e 不触发,失败走 warn 分支
        if mkdir -p "$sdk_dir"/{bin,src,libexec,etc,var,candidates,ext} &&
           rm -rf /tmp/sdkman-extract && mkdir -p /tmp/sdkman-extract &&
           unzip -qo "$cli_zip" -d /tmp/sdkman-extract &&
           cp -rf /tmp/sdkman-extract/sdkman-*/* "$sdk_dir"/ &&
           rm -rf /tmp/sdkman-extract/* &&
           unzip -qo "$native_zip" -d /tmp/sdkman-extract &&
           cp -rf /tmp/sdkman-extract/sdkman-*/* "$sdk_dir"/ &&
           rm -rf /tmp/sdkman-extract; then
            cli_ver=$(basename "$cli_zip" | sed 's/^sdkman-cli-\(.*\)\.zip$/\1/')
            native_ver=$(basename "$native_zip" | sed 's/^sdkman-native-\(.*\)-linuxx64\.zip$/\1/')
            echo "$cli_ver" > "$sdk_dir"/var/version
            echo "$native_ver" > "$sdk_dir"/var/version_native
            echo linuxx64 > "$sdk_dir"/var/platform
            # var/candidates:候选名单 CSV(正常从 api.sdkman.io 拉;bundle 带全量,缺件退 java,maven)。
            # 必须存在,否则 sdkman-init.sh 与 native 二进制直接报错(实测 2026-09-01)
            if [ -s "$B/sdkman/candidates.csv" ]; then
                cp "$B/sdkman/candidates.csv" "$sdk_dir"/var/candidates
            else
                echo 'java,maven' > "$sdk_dir"/var/candidates
            fi
            chmod +x "$sdk_dir"/libexec/* 2>/dev/null || true
            # 官方 bootstrap 写的默认 config,唯一改动:sdkman_auto_env=true(项目 .sdkmanrc 自动切)
            cat > "$sdk_dir"/etc/config <<'EOF'
sdkman_auto_answer=false
sdkman_colour_enable=true
sdkman_selfupdate_feature=true
sdkman_auto_complete=true
sdkman_auto_env=true
sdkman_beta_channel=false
sdkman_checksum_enable=true
sdkman_curl_connect_timeout=7
sdkman_curl_max_time=10
sdkman_debug_mode=false
sdkman_healthcheck_enable=true
sdkman_insecure_ssl=false
sdkman_native_enable=true
EOF
            # .bashrc init(幂等;官方要求 snippet 在文件末尾)
            grep -q 'sdkman-init.sh' "$U"/.bashrc 2>/dev/null || \
                printf '\n#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!\nexport SDKMAN_DIR="$HOME/.sdkman"\n[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"\n' >> "$U"/.bashrc
            printf '%s\n' "event=dev-java:SDKMAN $cli_ver/$native_ver 已离线安装(~/.sdkman,auto_env 开)" >> /run/claude-dev/events
        else
            rm -rf /tmp/sdkman-extract
            echo 'WARN: SDKMAN 离线安装失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 SDKMAN:bundle/sdkman 缺 zip(launch 将在线兜底)' >&2
    fi

    # --- JDK 17 预置进 SDKMAN candidates(目录即版本,sdk default/use 直接可用)---
    jdk_tar=$(find "$B/jdk" -maxdepth 1 -name 'OpenJDK17U-jdk_x64_linux_hotspot_*.tar.gz' 2>/dev/null | head -1)
    if [ -n "$jdk_tar" ]; then
        # 版本 id 仿 sdkman 命名:hotspot_17.0.20.1_1 → 17.0.20.1-1-tem(ver-build-tem)
        jdk_id="$(basename "$jdk_tar" | sed 's/^OpenJDK17U-jdk_x64_linux_hotspot_\(.*\)\.tar\.gz$/\1/; s/_/-/')-tem"
        if mkdir -p "$sdk_dir/candidates/java" &&
           rm -rf /tmp/jdk-extract && mkdir -p /tmp/jdk-extract &&
           tar -xzf "$jdk_tar" -C /tmp/jdk-extract &&
           jdk_root=$(find /tmp/jdk-extract -maxdepth 1 -mindepth 1 -type d | head -1) &&
           [ -n "$jdk_root" ]; then
            rm -rf "$sdk_dir/candidates/java/$jdk_id"
            mv "$jdk_root" "$sdk_dir/candidates/java/$jdk_id"
            rm -rf /tmp/jdk-extract
            # current 是 sdkman 的"默认版本"链接;sdk default java <id> 就是重指它
            ln -sfn "$jdk_id" "$sdk_dir/candidates/java/current"
            # 非交互桥:multipass exec 走 /usr/local/bin,穿过 current 自动跟随默认版本
            for b in java javac jar jshell; do ln -sfn "$sdk_dir/candidates/java/current/bin/$b" "/usr/local/bin/$b"; done
            printf '%s\n' "event=dev-java:JDK 预置为 SDKMAN 候选 $jdk_id(/usr/local/bin 走 current)" >> /run/claude-dev/events
        else
            rm -rf /tmp/jdk-extract
            echo 'WARN: JDK 离线预置失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 JDK:bundle/jdk 无 tarball(launch 将在线兜底)' >&2
    fi

    # --- Maven 预置(同构)---
    mvn_tar=$(find "$B/maven" -maxdepth 1 -name 'apache-maven-*-bin.tar.gz' 2>/dev/null | head -1)
    if [ -n "$mvn_tar" ]; then
        mvn_ver=$(basename "$mvn_tar" | sed 's/^apache-maven-\(.*\)-bin\.tar\.gz$/\1/')
        if mkdir -p "$sdk_dir/candidates/maven" &&
           rm -rf /tmp/mvn-extract && mkdir -p /tmp/mvn-extract &&
           tar -xzf "$mvn_tar" -C /tmp/mvn-extract &&
           mvn_root=$(find /tmp/mvn-extract -maxdepth 1 -mindepth 1 -type d | head -1) &&
           [ -n "$mvn_root" ]; then
            rm -rf "$sdk_dir/candidates/maven/$mvn_ver"
            mv "$mvn_root" "$sdk_dir/candidates/maven/$mvn_ver"
            rm -rf /tmp/mvn-extract
            ln -sfn "$mvn_ver" "$sdk_dir/candidates/maven/current"
            ln -sfn "$sdk_dir/candidates/maven/current/bin/mvn" /usr/local/bin/mvn
            printf '%s\n' "event=dev-java:Maven 预置为 SDKMAN 候选 $mvn_ver" >> /run/claude-dev/events
        else
            rm -rf /tmp/mvn-extract
            echo 'WARN: Maven 离线预置失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 Maven:bundle/maven 无 tarball(launch 将在线兜底)' >&2
    fi
    chown -R ubuntu:ubuntu "$U/.sdkman" 2>/dev/null || true
fi

if [ -n "$want_python" ]; then
    uv_whl=$(find "$B/uv" -maxdepth 1 -name 'uv-*.whl' 2>/dev/null | head -1)
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
    # --- nvm 本体(vendor 件:nvm-v*.sh 即整个 nvm)+ .bashrc hook ---
    nvm_sh=$(find "$B/nvm" -maxdepth 1 -name 'nvm-v*.sh' 2>/dev/null | head -1)
    if [ -n "$nvm_sh" ]; then
        if mkdir -p "$U/.nvm" && cp "$nvm_sh" "$U/.nvm/nvm.sh"; then
            # 幂等 hook:NVM_DIR + npmmirror 镜像(以后在线装其它版本走国内源)+ source
            grep -q 'NVM_DIR' "$U"/.bashrc 2>/dev/null || \
                printf '\n# cc-sandbox:nvm begin\nexport NVM_DIR="$HOME/.nvm"\nexport NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n# cc-sandbox:nvm end\n' >> "$U"/.bashrc
            printf '%s\n' 'event=dev-frontend:nvm 已离线安装(~/.nvm,镜像 npmmirror)' >> /run/claude-dev/events
        else
            echo 'WARN: nvm 离线安装失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 nvm:bundle/nvm 无 nvm-v*.sh(launch 将在线兜底)' >&2
    fi

    # --- Node 预置进 nvm versions(多版本并存;default 别名优先 20.x)---
    node_tarballs=$(find "$B/node" -maxdepth 1 -name 'node-v*-linux-x64.tar.xz' 2>/dev/null)
    if [ -n "$node_tarballs" ]; then
        ok=1
        for tarball in $node_tarballs; do
            ver=$(basename "$tarball" | sed 's/^node-\(v.*\)-linux-x64\.tar\.xz$/\1/')
            if mkdir -p "$U/.nvm/versions/node/$ver" &&
               tar -xJf "$tarball" -C "$U/.nvm/versions/node/$ver" --strip-components=1; then
                printf '%s\n' "event=dev-frontend:Node $ver 已预置进 nvm" >> /run/claude-dev/events
            else
                ok=0
                echo "WARN: Node $ver 解包失败" >&2
            fi
        done
        if [ "$ok" = 1 ]; then
            # default 别名:优先 20.x(锁定惯例),否则版本序最大
            def=$(ls "$U/.nvm/versions/node" 2>/dev/null | grep '^v20\.' | head -1)
            [ -n "$def" ] || def=$(ls "$U/.nvm/versions/node" | sort -V | tail -1)
            if [ -n "$def" ]; then
                mkdir -p "$U/.nvm/alias"
                echo "$def" > "$U/.nvm/alias/default"
                # 非交互桥:multipass exec 走 /usr/local/bin;nvm 无 current 链接,
                # 由 launch.ps1 每次 start 按默认别名重指(切版本后重跑 start 跟随)
                for b in node npm npx; do ln -sfn "$U/.nvm/versions/node/$def/bin/$b" "/usr/local/bin/$b"; done
                printf '%s\n' "event=dev-frontend:Node 默认版本 $def(/usr/local/bin 已桥接)" >> /run/claude-dev/events
            fi
        fi
    else
        echo '跳过 Node:bundle/node 无 tarball(launch 将在线兜底)' >&2
    fi
    chown -R ubuntu:ubuntu "$U/.nvm" 2>/dev/null || true

    # --- pnpm 独立二进制(自含运行时,与 node 版本解耦;项目内多版本 pnpm 自己管)---
    pnpm_tgz=$(find "$B/pnpm" -maxdepth 1 -name 'pnpm-linux-x64-*.tgz' 2>/dev/null | head -1)
    if [ -n "$pnpm_tgz" ]; then
        pnpm_ver=$(basename "$pnpm_tgz" | sed 's/^pnpm-linux-x64-\(.*\)\.tgz$/\1/')
        # 自检 pnpm -v:防"装上但跑不起来"
        if rm -rf /opt/tools/pnpm && mkdir -p /opt/tools/pnpm/"$pnpm_ver" &&
           tar -xzf "$pnpm_tgz" -C /opt/tools/pnpm/"$pnpm_ver" --strip-components=1 &&
           chmod 755 /opt/tools/pnpm/"$pnpm_ver"/pnpm &&
           ln -sfn /opt/tools/pnpm/"$pnpm_ver"/pnpm /usr/local/bin/pnpm &&
           pnpm --version >/dev/null 2>&1; then
            # npmmirror registry:pnpm 自切多版本(packageManager 字段)时从国内源拉
            sudo -u ubuntu pnpm config set --global registry https://registry.npmmirror.com 2>/dev/null || true
            printf '%s\n' "event=dev-frontend:pnpm $pnpm_ver 独立二进制已装(/opt/tools/pnpm)" >> /run/claude-dev/events
        else
            echo 'WARN: pnpm 独立二进制安装或自检失败(launch 将在线兜底)' >&2
        fi
    else
        echo '跳过 pnpm:bundle/pnpm 无 tgz(launch 将在线兜底)' >&2
    fi
fi

# 核心自检(node 不再核心:语言运行时归 dev-* 可选环境)
command -v claude && command -v opencode && command -v cc-pocket-daemon

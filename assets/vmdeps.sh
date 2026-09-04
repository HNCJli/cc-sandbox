#!/usr/bin/env bash
# vmdeps —— 共享盘 Node 项目的"依赖传送门"(cc-sandbox)
#
# 解决的问题:共享盘(sshfs 挂载)上的文件没有执行位且 chmod 存不住(Windows 磁盘记不了该标记),
# node_modules 里的工具二进制跑不起来。旧做法是把整个项目复制到 VM 本地盘再测,复制不跟源码
# 同步就会测到旧代码。vmdeps 改用 bind mount"传送门":项目内每个 package.json 的 node_modules
# 挂成指向 VM 本地盘 ~/deps 镜像目录的 bind 挂载——源码永远直接读共享盘(没有副本,不存在
# "测到旧代码"),依赖实际落在本地盘(可执行、快、不污染宿主机 Windows 侧;Windows 侧如有自己的
# node_modules 与 VM 侧互不可见,各用各的)。
#
# 用法:
#   vmdeps mount <项目名|路径>   建传送门(自动发现项目内全部 package.json,含 monorepo 子包)
#   vmdeps unmount <项目名|路径> 卸掉该项目全部传送门(~/deps 里的依赖保留,重新 mount 秒回)
#   vmdeps auto                 按注册表重挂全部传送门(开机自愈/手动补挂,幂等)
#   vmdeps status [项目]        查看注册的项目与传送门状态
#
# 说明:
# - 挂载点目录(共享盘上的空 node_modules/)会真实创建;卸载后它留在那,无害(空目录)
# - 依赖真身在 ~/deps/<workspace 相对路径>/<子包>/node_modules;彻底清理:rm -rf ~/deps/<...>
# - 传送门挂一次持续到 VM 停机/重启;launch.ps1 start 与开机 systemd(vmdeps.service)都会自动补挂
# - 非 Node 项目(无 package.json)无事可做,安全
set -u

U=/home/ubuntu                       # 目标用户家目录(root 经 systemd 跑时 $HOME 是 /root,必须显式)
WS_ROOT="$U/workspace"
DEPS_ROOT="$U/deps"
REGISTRY="$U/.config/vmdeps/registry"
FIND_MAXDEPTH=4                      # package.json 扫描深度(monorepo 子包足够;限深保 sshfs 扫描快)

# root/ubuntu 双身份:sudo 仅包 mount/umount(ubuntu 免密 sudo;systemd root 直跑)
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# ---- 项目定位:绝对/相对路径 > ~/workspace/<名> > ~/workspace/*/<名>(挂载子目录下的项目) ----
resolve_proj() {
    local arg=$1 p
    for p in "$arg" "$WS_ROOT/$arg"; do
        [ -d "$p" ] && { echo "$p"; return 0; }
    done
    p=$(find "$WS_ROOT" -mindepth 1 -maxdepth 2 -type d -name "$arg" 2>/dev/null | head -1)
    if [ -n "$p" ] && [ -d "$p" ]; then echo "$p"; return 0; fi
    return 1
}

# 依赖镜像目录:项目在 workspace 下的相对路径,原样镜像到 ~/deps 下(防不同挂载同名项目撞车)
deps_dir_of() {
    local proj=$1
    case "$proj" in
        "$WS_ROOT"/*) echo "$DEPS_ROOT/${proj#"$WS_ROOT"/}" ;;
        *)            echo "$DEPS_ROOT/$(basename "$proj")" ;;
    esac
}

# 发现项目内全部 package.json 相对路径(prune 掉 node_modules/.git 等:既免误收,更免扫描
# 进 Windows 侧遗留的巨型 node_modules——共享盘上大扫描极慢;mindepth 1 防 prune 剪掉起点自身)
find_packages() {
    local proj=$1
    (cd "$proj" 2>/dev/null || return 0
     find . -mindepth 1 -maxdepth $FIND_MAXDEPTH \
         \( -name node_modules -o -name '.*' \) -prune -o \
         -name package.json -printf '%h\n' 2>/dev/null | sed 's#^\./\?##' | sort -u)
}

is_mounted() { findmnt -n "$1" >/dev/null 2>&1; }

# ---- 单项目挂载(核心;mount 与 auto 共用)----
mount_project() {
    local proj=$1 quiet=$2 deps rel mp target mounted total pkgs
    proj=$(cd "$proj" 2>/dev/null && pwd) || { echo "vmdeps: 目录不存在: $proj" >&2; return 1; }
    deps=$(deps_dir_of "$proj")
    pkgs=$(find_packages "$proj")
    [ -z "$pkgs" ] && { [ "$quiet" != quiet ] && echo "vmdeps: $proj 未发现 package.json(非 Node 项目,无事可做)"; return 0; }

    total=0; mounted=0
    while IFS= read -r rel; do
        # 根包 rel 为 "." 或空 → 归一成空串,路径拼接统一走 "${rel:+$rel/}"
        rel=${rel#./}
        [ "$rel" = "." ] && rel=
        total=$((total + 1))
        mp="$proj/${rel:+$rel/}node_modules"
        target="$deps/${rel:+$rel/}node_modules"
        is_mounted "$mp" && { mounted=$((mounted + 1)); continue; }
        mkdir -p "$target" "$mp" || { echo "vmdeps: 建目录失败: $mp" >&2; continue; }
        if as_root mount --bind "$target" "$mp"; then
            mounted=$((mounted + 1))
            [ "$quiet" != quiet ] && echo "  传送门: ${rel:+$rel/}node_modules → $target"
        else
            echo "vmdeps: 挂载失败: $mp" >&2
        fi
    done <<< "$pkgs"

    [ "$quiet" != quiet ] && echo "vmdeps: $proj — $mounted/$total 个 node_modules 传送门就绪"
    register_project "$proj"
    [ "$mounted" = "$total" ] || return 1
    return 0
}

register_project() {
    local proj=$1
    mkdir -p "$(dirname "$REGISTRY")"
    touch "$REGISTRY"
    grep -qxF "$proj" "$REGISTRY" 2>/dev/null || echo "$proj" >> "$REGISTRY"
    chown -R ubuntu:ubuntu "$(dirname "$REGISTRY")" 2>/dev/null || true
}

unregister_project() {
    local proj=$1
    [ -f "$REGISTRY" ] || return 0
    # 注意不能用 && 链:grep -v 无输出行时退出码非零(如注册表仅剩此一项),会拦住 mv 导致删不掉
    grep -vx "$proj" "$REGISTRY" > "$REGISTRY.tmp" 2>/dev/null || true
    mv -f "$REGISTRY.tmp" "$REGISTRY"
    return 0
}

# ---- 单项目卸载:findmnt 找该项目下全部传送门挂载点,逐个 umount ----
unmount_project() {
    local proj=$1 mp n=0
    proj=$(cd "$proj" 2>/dev/null && pwd) || { echo "vmdeps: 目录不存在: $proj" >&2; return 1; }
    while IFS= read -r mp; do
        [ -z "$mp" ] && continue
        if as_root umount "$mp"; then n=$((n + 1)); echo "  已卸: $mp"; else echo "vmdeps: 卸载失败: $mp" >&2; fi
    done < <(findmnt -rn -o TARGET | grep -F "$proj/" 2>/dev/null)
    unregister_project "$proj"
    [ "$n" = 0 ] && echo "vmdeps: $proj 无传送门(依赖保留在 $(deps_dir_of "$proj"),可随时重新 mount)"
    return 0
}

# ---- auto:按注册表重挂(开机自愈;共享盘未挂载时跳过该项,下次再试) ----
auto_heal() {
    [ -f "$REGISTRY" ] || return 0
    local proj failed=0
    while IFS= read -r proj; do
        [ -z "$proj" ] && continue
        if [ ! -d "$proj" ]; then
            echo "vmdeps: $proj 当前不可达(共享盘未挂载?),跳过" >&2
            continue
        fi
        mount_project "$proj" quiet || failed=1
    done < "$REGISTRY"
    return $failed
}

show_status() {
    if [ ! -f "$REGISTRY" ] || ! grep -q '[^[:space:]]' "$REGISTRY" 2>/dev/null; then
        echo "vmdeps: 尚无注册项目(先跑 vmdeps mount <项目>)"
        return 0
    fi
    local proj deps mounted total rel
    printf '%-58s %-10s %s\n' '项目' '传送门' '依赖镜像'
    while IFS= read -r proj; do
        [ -z "$proj" ] && continue
        deps=$(deps_dir_of "$proj")
        total=0; mounted=0
        while IFS= read -r rel; do
            rel=${rel#./}
            [ "$rel" = "." ] && rel=
            total=$((total + 1))
            is_mounted "$proj/${rel:+$rel/}node_modules" && mounted=$((mounted + 1))
        done <<< "$(find_packages "$proj" 2>/dev/null)"
        if [ ! -d "$proj" ]; then
            printf '%-58s %-10s %s\n' "$proj" '不可达' "$deps"
        else
            printf '%-58s %-10s %s\n' "$proj" "$mounted/$total" "$deps"
        fi
    done < "$REGISTRY"
}

usage() {
    cat <<'EOF'
vmdeps —— 共享盘 Node 项目的依赖传送门(node_modules → VM 本地盘 ~/deps)

  vmdeps mount <项目名|路径>    建传送门后,直接在共享盘项目目录 pnpm install / pnpm test,
                               依赖实际落 ~/deps(可执行、不污染 Windows 侧);测试读到的
                               永远是共享盘最新源码,不存在旧副本。monorepo 自动覆盖全部子包
  vmdeps unmount <项目名|路径>  卸传送门(依赖保留,重新 mount 秒回)
  vmdeps auto                   按注册表重挂全部(start 自愈 + 开机 systemd 自动跑)
  vmdeps status [项目]          看注册项目与传送门状态
EOF
}

cmd=${1:-help}
case "$cmd" in
    mount)
        [ -n "${2:-}" ] || { echo 'vmdeps: 缺项目参数(名称或路径)' >&2; exit 1; }
        proj=$(resolve_proj "$2") || { echo "vmdeps: 找不到项目: $2(在 ~/workspace 下按名称搜)" >&2; exit 1; }
        mount_project "$proj" loud
        ;;
    unmount)
        [ -n "${2:-}" ] || { echo 'vmdeps: 缺项目参数' >&2; exit 1; }
        proj=$(resolve_proj "$2") || { echo "vmdeps: 找不到项目: $2" >&2; exit 1; }
        unmount_project "$proj"
        ;;
    auto)   auto_heal ;;
    status) show_status ;;
    help|-h|--help|'') usage ;;
    *) echo "vmdeps: 未知子命令: $cmd" >&2; usage; exit 1 ;;
esac

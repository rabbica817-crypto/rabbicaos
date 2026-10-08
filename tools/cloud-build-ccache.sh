#!/bin/bash
# ============================================================================
#  RabbicaOS — 云主机一键构建 ccache 缓存
#
#  作用: 在 64 核 Ubuntu 云主机上, 建 Debian 13 (trixie) chroot 环境 →
#        编译 Quickshell v0.3.0 + NextKde → 打包 ccache → 上传 GitHub Release。
#        之后 GitHub Actions 构建 ISO 时自动拉取该缓存, 编译瞬间完成。
#
#  用法:  sudo bash rabbica-build.sh
#
#  特性:  幂等设计 —— 任何步骤失败后可直接重跑, 已完成的步骤自动跳过。
#         全程无需人工干预 (除一次 GitHub 登录)。
# ============================================================================
set -u

# ── 配置区 ──────────────────────────────────────────────────────────────────
REPO="rabbica817-crypto/rabbicaos"
CHROOT=/opt/trixie-chroot
BUILD=/opt/rabbica-build          # chroot 内源码路径 (必须与 CI 一致, 保证 ccache 命中)
QS_TAG=v0.3.0
CCACHE_DIR=/home/user/.ccache     # chroot 内 ccache 路径
CCACHE_BAK=/opt/rbc-ccache        # 宿主侧 ccache 备份
OUT=/opt/rbc-out                  # 产物输出目录
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"     # 国内加速 (可改官方源)
# 并行度: 按内存自适应 —— 单个 cc1plus 峰值约 1.5-2GB (Qt/QML 重模板 TU 偏高),
# 且链接阶段 (LTO) 也会吃内存。经验系数: 内存GB/3 最稳, 留足余量。
#   16核/32G -> j10    64核/64G -> j21    8核/16G -> j5
# 宁可少开几个核 (编译慢一点), 也不要 OOM —— OOM 会让 cc1plus 被 SIGKILL,
# ninja 报错但原因隐蔽, 极难排查。
JOBS=$(nproc)
MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
MEM_JOBS=$(( MEM_GB / 3 ))
[ "$MEM_JOBS" -lt 2 ] && MEM_JOBS=2
[ "$JOBS" -gt "$MEM_JOBS" ] && JOBS="$MEM_JOBS"
[ "$JOBS" -lt 1 ] && JOBS=1
# ────────────────────────────────────────────────────────────────────────────

log() { echo -e "\n\033[1;36m[rbc] $*\033[0m"; }
ok()  { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err() { echo -e "\033[1;31m  ✗ $*\033[0m"; }

# 阶段标记: 记录已完成阶段, 支持断点续跑
STAMP=/opt/rbc-stage
done_stage() { grep -qx "$1" "$STAMP" 2>/dev/null; }
mark_stage() { echo "$1" >> "$STAMP"; }

echo "============================================================"
echo "  RabbicaOS 云主机 ccache 构建"
echo "  CPU: $(nproc) 核 | 内存: ${MEM_GB}GB"
echo "  并行度: -j${JOBS} (按内存自适应, 防 OOM)"
echo "  磁盘: $(df -h / | awk 'NR==2{print $4}') 可用"
echo "============================================================"

# ── 阶段 0: 前置检查 ────────────────────────────────────────────────────────
if [ "$(id -u)" != "0" ]; then err "请用 sudo 运行: sudo bash $0"; exit 1; fi
if [ "$(nproc)" -lt 4 ]; then err "CPU 核数过少 ($(nproc)), 建议 ≥8 核"; exit 1; fi
if [ "${MEM_GB:-0}" -lt 8 ]; then err "内存过少 (${MEM_GB}GB), 建议 ≥16GB"; exit 1; fi

# ── 阶段 1: 安装宿主依赖 ────────────────────────────────────────────────────
if ! done_stage "deps"; then
    log "阶段 1/7: 安装宿主依赖 (debootstrap / ccache / rsync / zstd)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq debootstrap ccache rsync zstd curl wget git ca-certificates \
        || { err "依赖安装失败"; exit 1; }
    # gh CLI (GitHub 官方源)
    if ! command -v gh >/dev/null 2>&1; then
        type -p curl >/dev/null || apt-get install -y -qq curl
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            > /etc/apt/sources.list.d/github-cli.list
        apt-get update -qq && apt-get install -y -qq gh
    fi
    ok "依赖就绪 (gh $(gh --version | head -1 | awk '{print $3}'))"
    mark_stage "deps"
else
    ok "阶段 1 已完成, 跳过"
fi

# ── 阶段 2: GitHub 登录 ─────────────────────────────────────────────────────
if ! done_stage "ghauth"; then
    log "阶段 2/7: GitHub 登录"
    if gh auth status >/dev/null 2>&1; then
        ok "已登录: $(gh api user -q .login 2>/dev/null)"
    else
        echo ""
        echo "需要登录 GitHub 以上传缓存到 Release。请按提示操作:"
        echo "  1) 选择 GitHub.com"
        echo "  2) 选择 HTTPS"
        echo "  3) 选择 'Login with a web browser' 或粘贴 Personal Access Token"
        echo "  (Token 需勾选 repo 权限)"
        echo ""
        gh auth login || { err "登录失败, 请重跑脚本"; exit 1; }
    fi
    mark_stage "ghauth"
else
    ok "阶段 2 已完成, 跳过"
fi

# ── 阶段 3: 建 trixie chroot ────────────────────────────────────────────────
if ! done_stage "chroot"; then
    log "阶段 3/7: 建 Debian 13 trixie chroot (与 CI 环境一致)"
    if [ ! -f "$CHROOT/etc/debian_version" ]; then
        mkdir -p "$CHROOT"
        # 安装签名钥匙环 (debootstrap 校验必需)
        apt-get install -y -qq debian-archive-keyring 2>/dev/null || true
        debootstrap --variant=minbase --include=systemd,systemd-sysv,dbus \
            trixie "$CHROOT" "$MIRROR" \
            || { err "debootstrap 失败"; exit 1; }
    fi
    echo "deb $MIRROR trixie main contrib non-free non-free-firmware
deb $MIRROR trixie-updates main contrib non-free non-free-firmware
deb $MIRROR trixie-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware" \
        > "$CHROOT/etc/apt/sources.list"
    # /dev 挂载 (ninja 必需)
    mountpoint -q "$CHROOT/dev" || mount --bind /dev "$CHROOT/dev"
    # 写 resolv.conf 保证 chroot 内联网
    cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" 2>/dev/null || true
    ok "chroot 就绪: $(chroot $CHROOT cat /etc/debian_version)"
    mark_stage "chroot"
else
    ok "阶段 3 已完成, 跳过"
    mountpoint -q "$CHROOT/dev" || mount --bind /dev "$CHROOT/dev"
fi

# ── 阶段 4: chroot 内装构建依赖 ─────────────────────────────────────────────
if ! done_stage "builddeps"; then
    log "阶段 4/7: chroot 内安装构建依赖 (Qt6/KWin/工具链, 约 3-5 分钟)"
    chroot "$CHROOT" bash -c "export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq \
            build-essential cmake ninja-build git pkg-config ccache \
            qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev \
            qt6-quick3d-dev qt6-svg-dev qt6-svg-private-dev qt6-wayland-dev \
            qt6-wayland-private-dev qt6-multimedia-dev qt6-tools-dev \
            libqt6sql6-sqlite libpolkit-agent-1-dev libpam0g-dev \
            libwayland-dev wayland-protocols libwayland-protocols-staging \
            extra-cmake-modules libkf6coreaddons-dev \
            libglib2.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
            libtag1-dev libonnxruntime-dev libopencv-dev \
            golang-go python3 python3-jinja2 \
            libkwin6-dev kwin-dev 2>&1 | tail -5" \
        || { err "构建依赖安装失败"; exit 1; }
    ok "构建依赖就绪"
    mark_stage "builddeps"
else
    ok "阶段 4 已完成, 跳过"
fi

# ── 阶段 5: 克隆源码并打补丁 ────────────────────────────────────────────────
if ! done_stage "source"; then
    log "阶段 5/7: 克隆 Quickshell + NextKde 并应用 trixie 兼容补丁"

    # 与阶段 6 同样用 heredoc 生成内部脚本: 函数/clone 回退逻辑都在 chroot 内执行
    # (宿主定义的 shell 函数无法跨 chroot 边界)。
    cat > "$CHROOT/rbc-inner-source.sh" <<INNER
#!/bin/bash
set -e
BUILD=$BUILD
QS_TAG=$QS_TAG

# 克隆函数 (带镜像回退): 国内云主机访问 GitHub 常被重置 (curl (35) Connection
# reset by peer 实证), 故依次尝试 直连 → ghproxy 镜像 → gitee 镜像。
clone_repo() {
    _name="\$1"; _tag="\$2"
    _tagarg=""; [ -n "\$_tag" ] && _tagarg="--branch \$_tag"
    case "\$_name" in
        quickshell)
            _urls="https://git.outfoxxed.me/quickshell/quickshell.git
https://ghproxy.net/https://github.com/quickshell-mirror/quickshell.git" ;;
        NextKde)
            _urls="https://github.com/SuceV587/NextKde.git
https://ghproxy.net/https://github.com/SuceV587/NextKde.git
https://gitee.com/mirrors/NextKde.git" ;;
    esac
    for _u in \$_urls; do
        echo "  尝试 \$_name <- \$_u"
        rm -rf "\$BUILD/\$_name"
        if git clone --depth 1 \$_tagarg "\$_u" "\$BUILD/\$_name" 2>&1 | tail -2; then
            [ -d "\$BUILD/\$_name/.git" ] && { echo "  ✓ \$_name 克隆成功"; return 0; }
        fi
    done
    echo "  ✗ \$_name 全部镜像失败"; return 1
}

id user >/dev/null 2>&1 || useradd -m -s /bin/bash user
mkdir -p \$BUILD
[ -d \$BUILD/quickshell ] || clone_repo quickshell \$QS_TAG
[ -d \$BUILD/NextKde ]    || clone_repo NextKde ""

# 补丁 A: surface-shape 的 find_package(GuiPrivate) 是 Qt6.9+ 机制
sed -i 's/COMPONENTS Core Gui GuiPrivate Qml Quick WaylandClient/COMPONENTS Core Gui Qml Quick WaylandClient/' \
    \$BUILD/NextKde/shell/native/surface-shape/CMakeLists.txt

# 补丁 B: background_effect 需 wayland-protocols>=1.45 (trixie=1.44)
sed -i -e '/^add_subdirectory(background_effect)\$/d' \
       -e '/^list(APPEND WAYLAND_MODULES Quickshell.Wayland._BackgroundEffect)\$/d' \
    \$BUILD/quickshell/src/wayland/CMakeLists.txt

# 补丁 C/D: install-apps.sh / verify-apps-install.sh 的运行时 systemd 调用
sed -i \
    -e 's#^systemctl --user enable --now kos-data\.service\$#systemctl --user enable kos-data.service#' \
    -e 's#^systemctl --user restart kos-data\.service\$#& || true#' \
    -e 's#^    org\.freedesktop\.DBus ReloadConfig >/dev/null\$#& || true#' \
    \$BUILD/NextKde/tools/install-apps.sh
sed -i \
    -e 's@^systemctl --user is-enabled kos-data.service >/dev/null || failed=1\$@: skipped@' \
    -e 's@^systemctl --user is-active kos-data.service >/dev/null || failed=1\$@test -L "\${XDG_CONFIG_HOME:-\$HOME/.config}/systemd/user/graphical-session.target.wants/kos-data.service" || failed=1@' \
    \$BUILD/NextKde/tools/verify-apps-install.sh

chown -R user:user \$BUILD
echo '补丁已应用'
INNER

    chmod +x "$CHROOT/rbc-inner-source.sh"
    cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" 2>/dev/null || true
    chroot "$CHROOT" /rbc-inner-source.sh || { err "源码准备失败"; exit 1; }
    ok "源码与补丁就绪"
    mark_stage "source"
else
    ok "阶段 5 已完成, 跳过"
fi

# ── 阶段 6: 编译 (ccache 启用, 跨机器共享配置) ──────────────────────────────
if ! done_stage "build"; then
    log "阶段 6/7: 编译 Quickshell + NextKde ($JOBS 并行, ccache 加速)"

    # 用 heredoc 把内部脚本写到 chroot 内再执行 —— 避免多层引号嵌套导致的
    # 变量无法展开 (单引号内 $VAR 是字面量) 与转义错误。所有变量由 heredoc
    # 展开 (<<EOF 不加引号), 但脚本自身用到的命令行参数 ($1) 用 \$ 转义。
    cat > "$CHROOT/rbc-inner-build.sh" <<INNER
#!/bin/bash
set -e
export HOME=/home/user
export CCACHE_DIR=$CCACHE_DIR
export PATH=/usr/lib/ccache:\$PATH

mkdir -p $CCACHE_DIR
cat > $CCACHE_DIR/ccache.conf <<'CCEOF'
max_size = 3.0G
base_dir = $BUILD
hash_dir = false
sloppiness = include_file_ctime,include_file_mtime,time_macros
compiler_check = content
CCEOF
chown -R user:user $CCACHE_DIR

# --- Quickshell ---
echo "== 配置 Quickshell"
su - user -c "export CCACHE_DIR=$CCACHE_DIR; ccache -z >/dev/null 2>&1 || true; \\
  cmake -S $BUILD/quickshell -B $BUILD/quickshell/build -G Ninja \\
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \\
    -DCRASH_HANDLER=OFF \\
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
echo "== 编译 Quickshell (-j$JOBS)"
su - user -c "export CCACHE_DIR=$CCACHE_DIR; cmake --build $BUILD/quickshell/build -j$JOBS"
echo "Quickshell 编译完成"

# --- NextKde (KOS_BUILD_KWIN_PLUGINS=OFF, 空间引擎关闭以省时) ---
echo "== 编译 NextKde"
su - user -c "export CCACHE_DIR=$CCACHE_DIR; cd $BUILD/NextKde && \\
  SYSTEMD_OFFLINE=1 KOS_BUILD_SPATIAL=OFF KOS_BUILD_KWIN_PLUGINS=OFF \\
  GOROOT=\\\$(dirname \\\$(dirname \\\$(readlink -f /usr/bin/go))) \\
  ./tools/kosctl install" || echo "(NextKde install 运行时步骤报错可忽略)"
echo "NextKde 编译完成"

echo "== ccache 统计"
su - user -c "export CCACHE_DIR=$CCACHE_DIR; ccache -s | head -12"
INNER

    chmod +x "$CHROOT/rbc-inner-build.sh"
    cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" 2>/dev/null || true
    chroot "$CHROOT" /rbc-inner-build.sh || { err "编译失败"; exit 1; }
    ok "编译完成"
    mark_stage "build"
else
    ok "阶段 6 已完成, 跳过"
fi

# ── 阶段 7: 打包 ccache 并上传 Release ──────────────────────────────────────
if ! done_stage "upload"; then
    log "阶段 7/7: 打包 ccache 并上传 GitHub Release"
    mkdir -p "$CCACHE_BAK" "$OUT"
    # 从 chroot 内拷出 ccache (宿主路径可持久)
    cp -a "$CHROOT$CCACHE_DIR/." "$CCACHE_BAK/" 2>/dev/null || true
    echo "ccache 大小: $(du -sh $CCACHE_BAK | cut -f1)"

    if [ ! -f "$CCACHE_BAK/ccache.conf" ]; then
        err "ccache 为空, 编译可能未成功"; exit 1
    fi

    PKG="$OUT/ccache-$(date +%Y%m%d-%H%M).tar.zst"
    tar --use-compress-program="zstd -T0 -3" -cf "$PKG" -C "$CCACHE_BAK" .
    echo "打包完成: $(ls -lh $PKG | awk '{print $5}')"

    # 上传 (标签 kos-ccache-v1, 覆盖已有附件)
    gh release view kos-ccache-v1 --repo "$REPO" >/dev/null 2>&1 \
        || gh release create kos-ccache-v1 --repo "$REPO" \
             --title "KOS ccache (云主机预编译)" \
             --notes "Quickshell + NextKde 编译缓存, 供 CI 拉取以跳过编译。base_dir=/opt/rabbica-build, 跨机器可用。"
    gh release upload kos-ccache-v1 "$PKG" --repo "$REPO" --clobber \
        || { err "上传失败, 请检查 gh 登录与仓库权限"; exit 1; }
    ok "已上传: $PKG"
    mark_stage "upload"
else
    ok "阶段 7 已完成 (如需重传, 删除 $STAMP 中 upload 行后重跑)"
fi

# ── 完成 ────────────────────────────────────────────────────────────────────
cat <<EOF

============================================================
  ✅ 全部完成!

  ccache 已上传至 Release 标签: kos-ccache-v1
  仓库: https://github.com/$REPO/releases/tag/kos-ccache-v1

  下一步:
    在 GitHub 上触发 "Build RabbicaOS ISO" workflow
    (Actions 页面 → Run workflow, 或推送 rbc-v* 标签)
    CI 会自动下载该缓存, 编译阶段将大幅加速。
============================================================
EOF

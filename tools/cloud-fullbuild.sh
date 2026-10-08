#!/bin/bash
# ============================================================================
#  RabbicaOS — 云主机完整构建脚本 (64核 / 256G 级机器)
#
#  一条命令跑完: 装依赖 → 拉仓库 → live-build 全流程 → 产出可安装 ISO
#  额外产出: ccache 缓存包 (可上传 Release 供 CI 复用)
#
#  用法:  sudo bash rabbica-fullbuild.sh
#
#  设计要点:
#   - 幂等: 每阶段打标记 (/opt/rbc-full-stage), 失败可直接重跑续做
#   - 缓存复用: 复用 cache/packages (apt 包) 与 ccache, 二次构建省 45 分钟
#   - 中文镜像: 默认清华 TUNA, 装包速度远快于 Debian 官方源
#   - 内存自适应并行度: 防 OOM (64核/256G 可放心全开)
# ============================================================================
set -u

# ── 配置 ────────────────────────────────────────────────────────────────────
WORK=/opt/rbc-full                    # 工作目录
REPO_URL="https://github.com/rabbica817-crypto/rabbicaos.git"
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"
MIRROR_SEC="https://mirrors.tuna.tsinghua.edu.cn/debian-security"
OUT=/opt/rbc-out
STAMP=/opt/rbc-full-stage

# 并行度: 编译按 min(核数, 内存GB/3) —— 单 cc1plus 峰值约 2GB (Qt 重模板 TU)
NPROC=$(nproc)
MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
JOB_MEM=$(( MEM_GB / 3 ))
[ "$JOB_MEM" -lt 2 ] && JOB_MEM=2
BUILD_JOBS=$NPROC
[ "$BUILD_JOBS" -gt "$JOB_MEM" ] && BUILD_JOBS=$JOB_MEM
[ "$BUILD_JOBS" -lt 1 ] && BUILD_JOBS=1
# squashfs 压缩并行度: CPU 密集, 可全开核数
SQUASH_JOBS=$NPROC
# ────────────────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;36m[rbc] $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ! $*\033[0m"; }
err()  { echo -e "\033[1;31m  ✗ $*\033[0m"; }
done_stage() { grep -qx "$1" "$STAMP" 2>/dev/null; }
mark_stage() { echo "$1" >> "$STAMP"; }

cat <<BANNER
============================================================
  RabbicaOS 云主机完整构建
  CPU: ${NPROC} 核  内存: ${MEM_GB}GB  磁盘: $(df -h / | awk 'NR==2{print $4}') 可用
  编译并行: -j${BUILD_JOBS}   打包并行: -j${SQUASH_JOBS}
  镜像源: ${MIRROR}
============================================================
BANNER

[ "$(id -u)" != "0" ] && { err "请用 sudo 运行"; exit 1; }
[ "${MEM_GB:-0}" -lt 8 ] && { err "内存不足 (${MEM_GB}GB)"; exit 1; }

# ── 阶段 1: 宿主依赖 ────────────────────────────────────────────────────────
if ! done_stage "deps"; then
    log "阶段 1/6: 安装宿主依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        debootstrap cpio xorriso squashfs-tools \
        live-build git curl wget ca-certificates \
        debian-archive-keyring ccache zstd \
        || { err "依赖安装失败"; exit 1; }
    # live-build: Ubuntu 自带版本太老不认 trixie → 装 Debian 官方新版
    _lbver=$(lb --version 2>/dev/null || echo none)
    if [ "$_lbver" != "20250505+deb13u1" ]; then
        warn "live-build 版本 $_lbver 不适配 trixie, 安装 Debian 官方版"
        wget -q -O /tmp/lb.deb \
            https://deb.debian.org/debian/pool/main/l/live-build/live-build_20250505+deb13u1_all.deb \
            || { err "live-build 下载失败 (检查网络)"; exit 1; }
        dpkg -i /tmp/lb.deb || apt-get install -y -qq -f
    fi
    ok "依赖就绪 (live-build $(lb --version))"
    mark_stage "deps"
else
    ok "阶段 1 已完成, 跳过"
fi

# ── 阶段 2: 拉取仓库 ────────────────────────────────────────────────────────
if ! done_stage "repo"; then
    log "阶段 2/6: 拉取 RabbicaOS 仓库"
    mkdir -p "$WORK"
    if [ -d "$WORK/rabbicaos/.git" ]; then
        cd "$WORK/rabbicaos" && git pull --ff-only || warn "git pull 失败, 用现有副本继续"
    else
        git clone --depth 1 "$REPO_URL" "$WORK/rabbicaos" \
            || { err "仓库克隆失败"; exit 1; }
    fi
    cd "$WORK/rabbicaos"
    ok "仓库就绪: $(git log --oneline -1)"
    mark_stage "repo"
else
    ok "阶段 2 已完成, 跳过"
fi

cd "$WORK/rabbicaos/live-build" || { err "仓库结构异常"; exit 1; }
chmod +x auto/build auto/clean auto/config 2>/dev/null || true
chmod +x config/hooks/live/*.hook.chroot 2>/dev/null || true

# ── 阶段 3: 初始化 live-build 配置 (含缓存目录准备) ──────────────────────────
if ! done_stage "lbconfig"; then
    log "阶段 3/6: 初始化 live-build 配置"
    # 用中文镜像 (加速装包)
    export RBC_MIRROR="$MIRROR"
    export RBC_MIRROR_SECURITY="$MIRROR_SEC"
    ./auto/clean 2>/dev/null || true
    ./auto/config > /tmp/lbconfig.log 2>&1 || { err "lb config 失败"; tail -20 /tmp/lbconfig.log; exit 1; }
    # 关键: 显式启用包缓存与阶段缓存 (cache/packages, cache/stages)
    # live-build 默认 LB_CACHE_PACKAGES=true, 但显式写入 config/common 更稳妥
    if ! grep -q '^LB_CACHE=' config/common 2>/dev/null; then
        cat >> config/common <<'CEOF'

# RabbicaOS: 显式启用包缓存 (二次构建省下 1900+ 包的下载时间)
LB_CACHE="true"
LB_CACHE_PACKAGES="true"
LB_CACHE_STAGES="bootstrap"
CEOF
    fi
    mkdir -p cache
    ok "live-build 配置就绪 (缓存目录: $(pwd)/cache)"
    mark_stage "lbconfig"
else
    ok "阶段 3 已完成, 跳过"
    export RBC_MIRROR="$MIRROR"
    export RBC_MIRROR_SECURITY="$MIRROR_SEC"
fi

# ── 阶段 4: 构建 (核心) ─────────────────────────────────────────────────────
if ! done_stage "build"; then
    log "阶段 4/6: 执行 live-build 构建 (预计 25-40 分钟)"
    echo "  提示: 构建日志可另开终端 tail -f /tmp/rbc-lb-build.log"
    export RBC_MIRROR="$MIRROR"
    export RBC_MIRROR_SECURITY="$MIRROR_SEC"
    export RBC_BUILD_JOBS="$BUILD_JOBS"
    # 不用 --purge: 保留 cache/ (包缓存)
    ./auto/build > /tmp/rbc-lb-build.log 2>&1
    RC=$?
    if [ "$RC" -ne 0 ]; then
        err "构建失败 (exit $RC), 日志尾部:"
        tail -40 /tmp/rbc-lb-build.log
        echo ""
        echo "  完整日志: /tmp/rbc-lb-build.log"
        echo "  失败后可直接重跑本脚本 —— 已完成的阶段会跳过, 包缓存保留。"
        exit 1
    fi
    ok "构建完成"
    mark_stage "build"
else
    ok "阶段 4 已完成, 跳过"
fi

# ── 阶段 5: 收集产物 ────────────────────────────────────────────────────────
log "阶段 5/6: 收集 ISO 与 ccache"
mkdir -p "$OUT"
ISO=$(ls *.iso 2>/dev/null | head -1)
if [ -z "$ISO" ]; then
    err "未找到 ISO 文件"; ls -lh; exit 1
fi
ISO_OUT="$OUT/RabbicaOS-1.0-amd64-$(date +%Y%m%d).iso"
cp -f "$ISO" "$ISO_OUT"
sha256sum "$ISO_OUT" > "$ISO_OUT.sha256"
ok "ISO: $ISO_OUT ($(du -h "$ISO_OUT" | cut -f1))"
cat "$ISO_OUT.sha256"

# ccache 打包 (供 CI 复用)
CC_SRC="$WORK/rabbicaos/live-build/chroot/home/user/.ccache"
if [ -d "$CC_SRC" ] && [ "$(du -sm "$CC_SRC" 2>/dev/null | cut -f1)" -gt 20 ]; then
    CC_OUT="$OUT/ccache-$(date +%Y%m%d-%H%M).tar.zst"
    tar --use-compress-program="zstd -T0 -3" -cf "$CC_OUT" -C "$CC_SRC" . 2>/dev/null \
        && ok "ccache: $CC_OUT ($(du -h "$CC_OUT" | cut -f1))" \
        || warn "ccache 打包失败 (不影响 ISO)"
else
    warn "chroot 内 ccache 为空或过小, 跳过打包 (编译可能未走缓存)"
fi

# ── 阶段 6: 结果 ────────────────────────────────────────────────────────────
log "阶段 6/6: 完成"
cat <<EOF

============================================================
  ✅ 构建成功!

  ISO 文件:  $ISO_OUT
  校验文件:  $ISO_OUT.sha256
  产物目录:  $OUT

  下载 ISO 到本地 (在你自己的电脑上执行):
      scp <用户名>@<本机IP>:$ISO_OUT .

  校验 ISO 完整性:
      sha256sum -c RabbicaOS-1.0-amd64-$(date +%Y%m%d).iso.sha256

  写入 U 盘 (Linux, 把 /dev/sdX 换成你的 U 盘设备):
      sudo dd if=RabbicaOS-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
  Windows 用 Rufus 或 balenaEtcher 写入。

  提示: 若想再跑一次, 包缓存已在 cache/ 中保留, 第二次构建会快很多。
============================================================
EOF

#!/usr/bin/env bash
# ============================================================================
#  RabbicaOS (RbcOS) — 一键预置脚本
#  目标系统 : Debian 13 (trixie) + KDE Plasma 6 (Wayland)
#  功能     : 编译安装 Quickshell + KOS 完整版（含景深壁纸/锁屏/四件套），
#             品牌化为 RabbicaOS，中度预装中文支持/浏览器/解码器，装国产应用。
#
#  用法:
#     sudo ./rabbica-provision.sh              # 全量执行
#     sudo ./rabbica-provision.sh --stage kos  # 只执行某一阶段
#     ./rabbica-provision.sh --dry-run         # 只打印将做什么
#
#  阶段: env → deps → quickshell → kos → apps-cn → preload → brand
#  脚本幂等：可重复运行，已完成的步骤会自动跳过。
# ============================================================================
set -Eeuo pipefail

# ---------- 可调参数（环境变量可覆盖） ----------
RBC_NAME="RabbicaOS"
RBC_ID="rabbicaos"
RBC_VERSION="1.0"
RBC_CODENAME="rbc"
RBC_HOME_URL="https://github.com/SuceV587/NextKde"   # 上游 KOS 致谢链接

QUICKSHELL_REPO="https://git.outfoxxed.me/quickshell/quickshell.git"
QUICKSHELL_REF="v0.3.0"                              # KOS 要求 0.3.x
NEXTKDE_REPO="https://github.com/SuceV587/NextKde.git"
NEXTKDE_REF="main"

WORK_DIR="${RBC_WORK_DIR:-/opt/rabbica-build}"       # 源码与构建目录
APPS_CN_DIR="${RBC_APPS_CN_DIR:-$(cd "$(dirname "$0")/../apps-cn" 2>/dev/null && pwd || echo ./apps-cn)}"
BUILD_SPATIAL="${RBC_BUILD_SPATIAL:-ON}"             # 完整版=ON；低配机可 OFF
DRY_RUN=0
STAGE_FILTER=""

# ---------- 工具函数 ----------
c_info()  { printf '\033[1;36m[rbc]\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[1;32m[rbc ok]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[1;33m[rbc warn]\033[0m %s\n' "$*"; }
c_err()   { printf '\033[1;31m[rbc err]\033[0m %s\n' "$*" >&2; }
run() { if (( DRY_RUN )); then c_info "DRY-RUN: $*"; else "$@"; fi; }

# Debian 13 包名清单 ----------------------------------------------------------
# A) 编译 KOS（对照上游 README 的 Ubuntu 26.04 清单，Debian trixie 包名基本一致）
DEPS_BUILD=(
  git cmake ninja-build g++ golang-go patchelf curl ca-certificates gettext
  qt6-base-dev qt6-declarative-dev qt6-quick3d-dev qt6-wayland-dev
  libqt6svg6 qt6-wayland qt6-image-formats-plugins
  qml6-module-qt5compat-graphicaleffects qml6-module-qtquick
  qml6-module-qtquick-controls qml6-module-qtquick-layouts
  qml6-module-qtquick-dialogs qml6-module-qtquick-window
  qml6-module-qtquick-effects qml6-module-qtqml-models
  qml6-module-qtqml-workerscript
  libopencv-dev
  libkf6windowsystem-dev libkf6iconthemes-dev libkf6globalaccel-dev
  extra-cmake-modules kwin-dev libkf6config-dev libkf6i18n-dev
  libkf6guiaddons-dev libkf6kcmutils-dev libkf6coreaddons-dev
  libkdecorations3-dev libvulkan-dev libplasma-dev
  libkf6kio-dev libkf6calendarcore-dev
  libxcb1-dev libxcb-composite0-dev libxcb-randr0-dev libxcb-res0-dev
  libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev libxcb-damage0-dev
  libxcb-render0-dev libxcb-shape0-dev libxcb-cursor-dev
  libxcb-keysyms1-dev libxcb-icccm4-dev libxcb-image0-dev
  libxcb-util-dev libxkbcommon-x11-dev
)
# B) Quickshell 0.3.x 编译依赖（映射自 AUR makedepends）
DEPS_QUICKSHELL=(
  qt6-base-dev qt6-declarative-dev qt6-svg-dev qt6-wayland-dev
  qt6-shadertools-dev libdrm-dev libpipewire-0.3-dev
  libxcb1-dev wayland-protocols libcli11-dev libjemalloc-dev
  spirv-tools vulkan-headers pkg-config
)
# C) 运行时集成（可选但推荐）
DEPS_RUNTIME=(
  network-manager wireplumber bluez brightnessctl
  wl-clipboard cliphist xdg-utils kde-spectacle
  libglib2.0-0 libqt6sql6-sqlite
)
# D) 中度预装：中文 + 浏览器 + 解码器（用户选定的「中度」边界）
DEPS_PRELOAD=(
  task-chinese-s fcitx5 fcitx5-chinese-addons fcitx5-frontend-qt5
  fcitx5-frontend-qt6 fcitx5-frontend-gtk3 fcitx5-config-qt
  fonts-noto-cjk fonts-noto-cjk-extra
  firefox-esr firefox-esr-l10n-zh-cn
  libavcodec-extra vlc
  plasma-desktop kde-standard dbus-x11
)
# E) 基础开发工具（轻量，不预装大型 IDE）
DEPS_DEV=(
  build-essential dkms linux-headers-amd64
  htop fastfetch unzip p7zip-full
)

# ---------- 阶段 0：环境检测 ----------
stage_env() {
  c_info "── 阶段 env：环境检测 ──"
  [[ "$(id -u)" -eq 0 ]] || { c_err "请用 sudo/root 运行"; exit 1; }

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [[ "$codename" != "trixie" ]]; then
    c_err "本脚本面向 Debian 13 (trixie)，当前 codename: ${codename:-未知}"
    c_err "请先安装 Debian 13 trixie 再运行。安装时选择 KDE Plasma 桌面任务。"
    exit 1
  fi
  c_ok "Debian 13 (trixie) 确认"

  if ! dpkg -s plasma-desktop >/dev/null 2>&1; then
    c_warn "未检测到 KDE Plasma，将在 deps 阶段随预装清单一并安装"
  fi
  command -v systemctl >/dev/null || { c_err "需要 systemd"; exit 1; }
  c_ok "环境检测通过"
}

# ---------- 阶段 1：依赖安装 ----------
stage_deps() {
  c_info "── 阶段 deps：安装编译与运行依赖（约 1-2 GB，耐心等待）──"
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends \
      "${DEPS_BUILD[@]}" "${DEPS_QUICKSHELL[@]}" "${DEPS_RUNTIME[@]}"
  c_ok "依赖安装完成"
}

# ---------- 阶段 2：源码编译 Quickshell ----------
stage_quickshell() {
  c_info "── 阶段 quickshell：源码编译 Quickshell ${QUICKSHELL_REF} ──"
  if command -v qs >/dev/null 2>&1 && qs --version 2>/dev/null | grep -q "0\.3"; then
    c_ok "Quickshell 0.3.x 已存在，跳过编译"
    return 0
  fi
  mkdir -p "$WORK_DIR"
  if [[ ! -d "$WORK_DIR/quickshell" ]]; then
    run git clone --depth 1 --branch "$QUICKSHELL_REF" \
        "$QUICKSHELL_REPO" "$WORK_DIR/quickshell"
  fi
  run cmake -S "$WORK_DIR/quickshell" -B "$WORK_DIR/quickshell/build" \
      -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local
  run cmake --build "$WORK_DIR/quickshell/build"
  run cmake --install "$WORK_DIR/quickshell/build"
  run ldconfig
  command -v qs >/dev/null 2>&1 \
    && c_ok "Quickshell 安装完成: $(qs --version 2>/dev/null || echo qs)" \
    || { c_err "Quickshell 编译安装失败"; exit 1; }
}

# ---------- 阶段 3：编译并安装 KOS ----------
stage_kos() {
  c_info "── 阶段 kos：克隆并编译 KOS（完整版，SPATIAL=${BUILD_SPATIAL}）──"
  mkdir -p "$WORK_DIR"
  if [[ ! -d "$WORK_DIR/NextKde" ]]; then
    run git clone --depth 1 --branch "$NEXTKDE_REF" \
        "$NEXTKDE_REPO" "$WORK_DIR/NextKde"
  fi
  # kosctl install 会编译 + 部署 ~/.local + sudo 装 KWin 插件 + 写 kwinrc
  # 提示: 非交互环境(chroot/CI)下以 root 运行不会询问密码
  run env KOS_BUILD_SPATIAL="$BUILD_SPATIAL" \
      "$WORK_DIR/NextKde/tools/kosctl" install
  run env "$WORK_DIR/NextKde/tools/kosctl" install lockscreen
  run env "$WORK_DIR/NextKde/tools/kosctl" install apps
  c_ok "KOS 安装完成（特效将在下次登录时加载）"
}

# ---------- 阶段 4：国产应用（官方原生 deb） ----------
stage_apps_cn() {
  c_info "── 阶段 apps-cn：安装国产应用官方原生包 ──"
  mkdir -p "$APPS_CN_DIR"
  local installed_any=0 pkg

  # 约定: 把下载好的官方 deb 放入 apps-cn/ 目录，文件名包含关键字即可
  #   微信:    linux.weixin.cn          → wechat-*.deb
  #   QQ NT:   im.qq.com/linuxqq        → linuxqq_*.deb
  #   钉钉:    钉钉官网 Linux 页        → dingtalk-*.deb
  #   WPS:     linux.wps.cn             → wps-office_*.deb
  for pkg in "$APPS_CN_DIR"/*.deb; do
    [[ -e "$pkg" ]] || { c_warn "$APPS_CN_DIR 下没有 deb 包，跳过（见 README 下载指引）"; break; }
    c_info "安装: $(basename "$pkg")"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || {
      c_warn "安装失败（依赖缺失？），跳过: $(basename "$pkg")"
      continue
    }
    installed_any=1
  done
  (( installed_any )) && c_ok "国产应用安装完成" || c_warn "未安装任何国产应用"
}

# ---------- 阶段 5：中度预装 + 系统调优 ----------
stage_preload() {
  c_info "── 阶段 preload：中度预装（中文/浏览器/解码器/基础工具）──"
  run env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends \
      "${DEPS_PRELOAD[@]}" "${DEPS_DEV[@]}"

  # Fcitx5 设为默认输入法框架（全局 + GTK/Qt 环境变量，写入 /etc 级别）
  run im-config -n fcitx5 2>/dev/null || true
  run tee /etc/environment.d/90-rabbica-input.conf >/dev/null <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
GLFW_IM_MODULE=ibus
EOF
  c_ok "预装与输入法配置完成"
}

# ---------- 阶段 6：RabbicaOS 品牌化 ----------
stage_brand() {
  c_info "── 阶段 brand：写入 RabbicaOS 品牌标识 ──"
  # os-release（保持 Debian 兼容字段，便于 apt 与第三方识别底座）
  run tee /etc/os-release >/dev/null <<EOF
PRETTY_NAME="${RBC_NAME} ${RBC_VERSION} (${RBC_CODENAME})"
NAME="${RBC_NAME}"
VERSION_ID="${RBC_VERSION}"
VERSION="${RBC_VERSION} (${RBC_CODENAME})"
VERSION_CODENAME=${RBC_CODENAME}
ID=${RBC_ID}
ID_LIKE=debian
HOME_URL="${RBC_HOME_URL}"
SUPPORT_URL="${RBC_HOME_URL}"
DEBIAN_VERSION="13"
DEBIAN_CODENAME=trixie
EOF
  run tee /etc/lsb-release >/dev/null <<EOF
DISTRIB_ID=${RBC_NAME}
DISTRIB_RELEASE=${RBC_VERSION}
DISTRIB_CODENAME=${RBC_CODENAME}
DISTRIB_DESCRIPTION="${RBC_NAME} ${RBC_VERSION}"
EOF
  # 主机名（安装后首次可改）
  grep -qx "rabbica" /etc/hostname 2>/dev/null || run bash -c 'echo rabbica > /etc/hostname'
  grep -q "rabbica" /etc/hosts 2>/dev/null || run bash -c 'echo "127.0.1.1 rabbica" >> /etc/hosts'

  # motd / fastfetch 欢迎信息
  run tee /etc/motd >/dev/null <<'EOF'
  ____       ____ _   _    _    ___
 |  _ \ __ _/ ___| | | |  / \  / __)   RabbicaOS (RbcOS)
 | |_) / _` | |   | |_| | / _ \ \__ \  基于 Debian 13 + KDE Plasma 6 + KOS
 |  _ < (_| | |___|  _  |/ ___ \ ( /    Have a cup of coffee & code.
 |_| \_\__,_|\____|_| |_/_/   \_\___)
EOF
  c_ok "品牌化完成：os-release / hostname / motd"
}

# ---------- 主流程 ----------
main() {
  local stages=(env deps quickshell kos apps-cn preload brand)
  # 解析参数
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=1 ;;
      --stage)     STAGE_FILTER="${2:-}"; shift ;;
      --spatial)   BUILD_SPATIAL="$2"; shift ;;
      *) c_err "未知参数: $1"; exit 1 ;;
    esac
    shift
  done

  c_info "=============================================="
  c_info "  ${RBC_NAME} ${RBC_VERSION} 预置开始"
  c_info "  构建目录: $WORK_DIR"
  c_info "  景深壁纸: $BUILD_SPATIAL   国产应用目录: $APPS_CN_DIR"
  c_info "=============================================="

  local s
  for s in "${stages[@]}"; do
    if [[ -n "$STAGE_FILTER" && "$s" != "$STAGE_FILTER" ]]; then continue; fi
    "stage_${s//-/_}"
  done

  c_info "=============================================="
  c_ok "全部完成！注销并重新登录（或重启）后，KOS 桌面生效。"
  c_ok "首次登录请在 系统设置 ▸ 窗口装饰 中选择 kos_decoration，"
  c_ok "窗口上的三个圆点与液态玻璃特效就会出现。"
  c_info "=============================================="
}

main "$@"

#!/usr/bin/env bash
# ============================================================================
#  RabbicaOS 构建总入口
#
#  模式 A（验证路线，推荐先走）:
#     ./build.sh provision
#     → 在已装好 Debian 13 + KDE 的机器上执行预置脚本，跑通整个系统
#
#  模式 B（ISO 路线，验证通过后）:
#     ./build.sh iso
#     → 用 live-build 在当前 Debian 13 机器上构建可分发安装 ISO
#       （构建需要 root、约 20GB 磁盘空间、良好的网络）
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

c_info() { printf '\033[1;36m[rbc]\033[0m %s\n' "$*"; }

MODE="${1:-help}"

case "$MODE" in
  provision)
    c_info "模式 A：预置现有 Debian 13 + KDE 系统"
    exec sudo bash provision/rabbica-provision.sh "${@:2}"
    ;;
  iso)
    c_info "模式 B：构建 RabbicaOS 安装 ISO"
    [[ "$(id -u)" -eq 0 ]] || { echo "ISO 构建需要 root：sudo ./build.sh iso"; exit 1; }
    command -v lb >/dev/null 2>&1 || {
      echo "安装 live-build: apt install live-build"; exit 1;
    }
    cd live-build
    ./auto/clean --purge >/dev/null 2>&1 || true
    ./auto/build
    c_info "构建完成: live-build/ 下的 *.iso"
    c_info "用 dd 或 balenaEtcher 写入 U 盘即可安装分发"
    ;;
  *)
    cat <<'EOF'
RabbicaOS 构建工具

  用法: ./build.sh <模式>

  模式:
    provision   在现有 Debian 13 + KDE 机器上执行完整预置（推荐先做）
    iso         从零构建可分发的安装 ISO（需要 Debian 13 宿主机）

  示例:
    sudo ./build.sh provision              # 全量预置
    sudo ./build.sh provision --stage kos  # 只执行 KOS 阶段
    sudo ./build.sh provision --spatial OFF # 低配机关闭景深壁纸
    sudo ./build.sh iso                    # 构建 ISO
EOF
    ;;
esac

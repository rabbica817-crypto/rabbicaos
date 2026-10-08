# RabbicaOS (RbcOS)

> 类 macOS 开箱即用的 Linux 发行版 · 基于 **Debian 13 (trixie) + KDE Plasma 6 + KOS Desktop Shell**
> 内置微信 / QQ / 钉钉 / WPS 官方原生版 · x86_64

## 项目结构

```
rabbicaos/
├── build.sh                      # 总入口：provision（预置）/ iso（构建镜像）
├── provision/
│   └── rabbica-provision.sh      # 核心预置脚本（幂等，可分阶段执行）
├── apps-cn/                      # 放置国产应用官方 deb 包
│   ├── wechat-*.deb              #   微信   ← linux.weixin.cn
│   ├── linuxqq_*.deb             #   QQ NT  ← im.qq.com/linuxqq
│   ├── dingtalk-*.deb            #   钉钉   ← 官网 Linux 下载页
│   └── wps-office_*.deb          #   WPS    ← linux.wps.cn
└── live-build/                   # ISO 构建配置（Step 3b 完成）
```

## 快速开始（路线 A：验证现有机器）

### 0. 前置要求
- 一台 x86_64 电脑（物理机或虚拟机，建议 ≥4 核 / 16GB 内存 / 60GB 磁盘）
- 已安装 **Debian 13 (trixie)**，安装时勾选 **KDE Plasma** 桌面任务
- 能联网（国内建议先换清华/中科大 Debian 镜像源）

### 1. 执行预置
```bash
cd rabbicaos
sudo ./build.sh provision
```

脚本会依次执行 7 个阶段（全程约 40-90 分钟，取决于网速与机器）：

| 阶段 | 内容 | 耗时参考 |
|---|---|---|
| env | 环境检测（必须是 trixie） | 秒级 |
| deps | 安装编译依赖（约 1-2 GB） | 10-30 min |
| quickshell | 源码编译 Quickshell 0.3.x | 5-15 min |
| kos | 克隆并编译 KOS 完整版（含景深壁纸 OpenCV+ONNX） | 15-40 min |
| apps-cn | 安装 apps-cn/ 下的国产应用 deb | 分钟级 |
| preload | 中度预装：中文/Fcitx5 拼音/Firefox/解码器/基础工具 | 5-10 min |
| brand | 写入 RabbicaOS 品牌标识（os-release/hostname/motd） | 秒级 |

### 2. 常用变体
```bash
sudo ./build.sh provision --spatial OFF        # 低配机关闭景深壁纸（省 1GB+ 构建依赖）
sudo ./build.sh provision --stage kos          # 只重跑 KOS 阶段
sudo ./build.sh provision --dry-run            # 只打印动作，不实际执行
```

### 3. 完成后
1. **注销并重新登录**（KWin 特效插件要新会话才加载）
2. 打开 **系统设置 ▸ 窗口装饰**，选中 **kos_decoration** —— 窗口三个圆点出现
3. 若 Dock/顶栏没起来，运行：
   ```bash
   systemctl --user status kos-shell kos-platform kos-data
   journalctl --user -u kos-shell.service -f
   ```

## 国产应用下载指引

脚本**不代下载**（官网有风控/版本变动），请手动下载后放入 `apps-cn/`：

| 应用 | 下载地址 | 文件名匹配 |
|---|---|---|
| 微信 | https://linux.weixin.cn | `wechat-*.deb` |
| QQ (NT) | https://im.qq.com/linuxqq/index.shtml | `linuxqq_*.deb` |
| 钉钉 | https://www.dingtalk.com（Linux 下载页） | `dingtalk-*.deb` |
| WPS Office | https://linux.wps.cn | `wps-office_*.deb` |

> 放好 deb 后重跑 `sudo ./build.sh provision --stage apps-cn` 即可。

## 路线 B：构建可分发 ISO

前置：在 **Debian 13 宿主机**（或干净虚拟机）上，磁盘 ≥20GB 空余。

```bash
sudo apt install live-build
sudo ./build.sh iso
```

产物为 `live-build/` 下的 `.iso`，用 Ventoy / balenaEtcher / dd 写入 U 盘即可分发安装。

### ISO 技术方案（全部经 trixie 实证）

| 决策 | 结论 | 实证方式 |
|---|---|---|
| 安装器 | **Calamares**（非 d-i live-installer） | trixie 仓库已移除 `live-installer`；`calamares-settings-debian 13.0.13` 由 Debian 官方维护，其 `unpackfs.conf` 源路径就是 live-build 标准产物路径，安装=完整复制定制系统 |
| 构建验证 | `lb config` 于 trixie live-build 1:20250505 实跑通过 | 真实 trixie chroot 内执行 `auto/config` exit 0 |
| 包清单 | 103+ 个包全部可解析 | trixie chroot 内 `apt-get -s install` 零错误 |
| KOS 完整版 | chroot 内编译（Quickshell 0.3.x + KOS + OpenCV/ONNX） | 编译依赖清单=上游 README Ubuntu 26.04 验证清单的 Debian 映射 |
| 品牌 | Calamares 欢迎页/侧栏/幻灯片已 RabbicaOS 化 | `branding: debian` 精准 sed 替换（保留上游序列完整性） |
| 瘦身 | 源码/构建目录/临时 sudoers 构建后清除 | 9000-cleanup 钩子，日志归档至 /usr/share/doc/rabbicaos |

> ⚠️ 首次 `lb build` 约需 1-2 小时（含 Quickshell+KOS 编译），属正常现象；构建日志在 ISO 内 `/usr/share/doc/rabbicaos/build.log` 可查。

## 路线 C：GitHub Actions 云端构建（无需本地设备）

仓库内置 `.github/workflows/build-iso.yml`，两种触发方式：

| 方式 | 操作 | 产出 |
|---|---|---|
| **手动触发** | GitHub 仓库页 → Actions → "Build RabbicaOS ISO" → Run workflow | Artifact: `rabbicaos-iso`（保留 14 天） |
| **标签发布** | `git tag rbc-v1.0 && git push origin rbc-v1.0` | 自动创建 GitHub Release，附 ISO + sha256 |

### 首次推送步骤

```bash
cd rabbicaos
gh auth login                    # 或配置 SSH key 后 git remote add
gh repo create rabbicaos --public --source=. --push
# 推完到 Actions 页手动 Run workflow 即可
```

### CI 构建要点（已内置处理）

| 环节 | 处理 |
|---|---|
| 磁盘空间 | runner 仅 ~14GB 可用，workflow 先清理 Android SDK/dotnet/ghc 腾出 ~25GB |
| 镜像源 | CI 在海外自动用 deb.debian.org（本地构建默认清华 TUNA，`RBC_MIRROR` 可覆盖） |
| 构建加速 | actions/cache 缓存 debootstrap/apt 包（二次构建提速约 40 分钟） |
| 失败排查 | 构建失败自动打印 chroot 内 KOS 编译日志 |
| 耗时 | 首次约 90-150 分钟；job 上限 350 分钟 |

## 故障排查

| 症状 | 处理 |
|---|---|
| `qs: command not found` | Quickshell 编译失败，看 deps 阶段日志；重跑 `--stage quickshell` |
| Dock 无窗口预览 | 确认在 Plasma **Wayland** 会话（不是 X11） |
| 通知中心空白 | 检查是否装了 dunst/mako 等第三方通知守护并停用 |
| 景深壁纸开关灰色 | 用 `--spatial OFF` 跳过属正常；完整版需首次联网下载模型 |
| 服务无限重启 | `journalctl --user -u kos-platform -e` 看具体报错 |

## 致谢与许可

- [NextKde / KOS Desktop Shell](https://github.com/SuceV587/NextKde)（上游 Shell）
- [Quickshell](https://quickshell.org/)（QML Shell 运行时）
- [Debian](https://www.debian.org/) / [KDE Plasma](https://kde.org/)

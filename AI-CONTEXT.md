# RabbicaOS 构建状态快照（供新会话恢复上下文用）
> 更新: 2026-10-08 16:41 CST | 维护者: rabbida817-crypto <rabbica817@gmail.com>（git 身份已修正）

## 项目一句话
Debian 13 (trixie) + KDE Plasma 6.3 + KOS Desktop Shell（Quickshell 0.3.x）自制发行版，
GitHub Actions 云端构建可安装 ISO。仓库: https://github.com/rabbica817-crypto/rabbicaos

## 当前进行中
- **CI Run 7**（ID 37749988829，2026-10-08 08:27 UTC 触发）构建中，全部修复代码已含
- 查状态: `gh run view 37749988829 --repo rabbica817-crypto/rabbicaos`
- 成功 → 验证 artifact（rabbicaos-iso + sha256）；打 `rbc-v1.0` tag 可发 Release

## 六轮 CI 迭代史（全部有实证依据）
| Run | 失败点 | 根因与修复 |
|-----|--------|-----------|
| 1 | live-build 不识别 trixie | 从 Debian pool 装 live-build_20250505+deb13u1 |
| 2 | debootstrap 签名校验 | 装 debian-archive-keyring |
| 3 | 脚本执行位丢失 | chmod +x 工作区实体文件（update-index 只改索引） |
| 4 | Quickshell configure 失败 | 缺 cpptrace（trixie 无包）→ CRASH_HANDLER=OFF |
| 5 | ninja 缺 wayland 协议 | ext-background-effect-v1 需 wayland-protocols>=1.45，trixie=1.44 → 补丁禁用模块（KOS 无 import，无损）|
| 5 | PAM 头缺失 | 清单补 libpam0g-dev |
| 6 | 误触发（旧代码） | 已取消 |
| 7 | 构建中 | —— |

## 已固化进仓库的关键决策
1. **KOS_BUILD_KWIN_PLUGINS=OFF**：上游 KWin 插件用 6.4 API（KWin::Region/drawWindow 新签名/
   a11ykeyboardmonitor.h），trixie kwin-dev 6.3.6 编译失败（kos-bridge 等 4 插件，-k 0 实证）；
   README 官方支持此开关；window-bridge.js 是 KWin 脚本不受影响，桌面接管链路保留。
   → 待 Debian 升级 KWin 6.4 后重开
2. **CRASH_HANDLER=OFF**：cpptrace trixie 无包；仅崩溃上报功能，无损
3. **GOROOT 显式设置**：trixie go 为 trimmed 构建必须显式 GOROOT（hook 动态推导）
4. **GuiPrivate 补丁**：find_package(FooPrivate) 是 Qt6.9+ 机制（qtbase ad7b94e1），6.8 由
   加载 Gui 副作用创建 → sed 移除组件名（surface-shape 一处，全仓唯一）
5. Quickshell 需要 qt6-{base,declarative,quick3d,svg,wayland}-private-dev + libpolkit-agent-1-dev
   + libpam0g-dev（Debian 拆分包，编译期才暴露）

## 本地实证记录（/opt/trixie-chroot，保留勿删）
- debootstrap minbase + 全量构建依赖（63+9 包）已装齐
- **Quickshell v0.3.0 全量编译 513/513 通过**（补丁后）
- NextKde KOS_BUILD_KWIN_PLUGINS=OFF 模式全量编译通过（spatial=ON、apps 四件套、Go data-service）
- 注意：chroot 已 mount --bind /dev；本地跑 go 需 env GOROOT=/usr/lib/go-1.24；沙箱宿主
  预置 GOROOT=/usr/local/go 会被 chroot 继承（假阳性陷阱）
- 教训：本地验证必须全量编译（configure 抓不到裸 include 与协议缺失）

## 待办
- [ ] 等 Run 7 出结果并验证 ISO artifact
- [ ] 国产应用 deb（微信/QQ/钉钉/WPS 官方包）尚未放入 apps-cn/，放入后重新构建
- [ ] 可选优化: CI 加 ccache（二次构建提速 50-70%）
- [ ] 可选视觉: Plymouth 开机动画、GRUB 主题、KOS 默认壁纸
- [ ] KWin 6.4 重开插件层（跟踪 Debian 升级）

## 环境备忘
- gh 已登录 rabbica817-crypto（workflow scope 已授权）；git 身份 rabbica817@gmail.com 已固化
- 沙箱到 github.com 的 443 间歇断连：push 失败就重试（曾遇 2 次，重试即恢复）
- 沙箱会休眠杀后台任务：长编译用前台限时（timeout 550 ninja -j6）分块跑
- workflow 步骤: 清磁盘 → 装 live-build(deb13u1)+archive-keyring → cache(lb-cache-v1) →
  lb build → 失败打印 KOS 日志 → 改名+sha256 → upload-artifact → rbc-v* tag 发 Release

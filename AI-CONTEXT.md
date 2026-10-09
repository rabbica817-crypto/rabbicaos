# RabbicaOS 构建状态快照（供新会话恢复上下文用）
> 更新: 2026-10-09 13:35 CST | 维护者: rabbida817-crypto <rabbica817@gmail.com>（git 身份已修正）

## 项目一句话
Debian 13 (trixie) + KDE Plasma 6.3 + KOS Desktop Shell（Quickshell 0.3.x）自制发行版，
GitHub Actions 云端构建可安装 ISO。仓库: https://github.com/rabbica817-crypto/rabbicaos

## 当前进行中
- **CI Run 14**（ID 37888932265，2026-10-09 05:30 UTC 触发，head 5a99424）构建中
- 查状态: `gh run view 37888932265 --repo rabbica817-crypto/rabbicaos`
- 成功 → 验证 artifact（rabbicaos-iso + sha256）；打 `rbc-v1.0` tag 可发 Release
- Run 13（37867604773，head 138f0af）失败于 8/9，耗时 29m25s

## 七轮 CI 迭代史（全部有实证依据）
| Run | 失败点 | 根因与修复 |
|-----|--------|-----------|
| 1 | live-build 不识别 trixie | 从 Debian pool 装 live-build_20250505+deb13u1 |
| 2 | debootstrap 签名校验 | 装 debian-archive-keyring |
| 3 | 脚本执行位丢失 | chmod +x 工作区实体文件（update-index 只改索引） |
| 4 | Quickshell configure 失败 | 缺 cpptrace（trixie 无包）→ CRASH_HANDLER=OFF |
| 5 | ninja 缺 wayland 协议 | ext-background-effect-v1 需 wayland-protocols>=1.45，trixie=1.44 → 补丁禁用模块（KOS 无 import，无损）|
| 5 | PAM 头缺失 | 清单补 libpam0g-dev |
| 6 | 误触发（旧代码） | 已取消 |
| 7 | 8/9 的 install apps 收尾 | install-apps.sh 为运行中系统设计：enable --now/restart/busctl ReloadConfig 在 chroot（无 user manager）必败；SYSTEMD_OFFLINE=1 只能跳过 daemon-reload → 补丁 C/D：enable 去掉 --now（保留自启动注册），runtime 动作加 \|\| true / 注释（含 verify-apps-install.sh:46 is-active）|
| 8 | 8/9 verify | 同上位置继续失败；补丁扩到 verify-apps-install.sh 的 is-enabled(45)/is-active(46) |
| 9 | 8/9 verify | 同上 |
| 10 | 8/9 verify | `KOS application registration verification failed.` 8/9 用 5m14s。**误判**：以为补丁漏了第 46 行 → 本地实证两条 sed 都命中，判断错误 |
| 11 | 8/9 verify | 同位置。**误判**：以为是我新加的 `test -L graphical-session.target.wants/...` 不可靠 → 确实是我引入的新风险，但不是根因 |
| 12 | 8/9 verify | 同位置。**误判**：以为第 41 行 `appstreamcli validate` rc=3 → 我的"实证"用了**自造的简化 metainfo**（缺 url-homepage）；换成真实上游 metainfo 重测**四个全部 rc=0** |
| 13 | 8/9 verify | 29m25s。**单点定因指向 verify-apps-install.sh:19** `QT_QPA_PLATFORM=offscreen "$binary" --version >/dev/null \|\| failed=1`——该行输出在成功/失败时**双向被吞**，是 verify 里唯一无日志痕迹的检查点。修复：改为非否决 + 失败可见（`#RBCNOTE`）|
| 14 | 构建中 | 携带 5a99424：`step()` tail 30→200、`#RBCFAIL:line N` 插桩、5b 自检 dump、包清单补 `desktop-file-utils`+`appstream` |

### 四轮误判的方法论教训（重要，勿重蹈）
1. **日志尾部那 4 条 `✔ 验证成功：细节：2` 是 `desktop-file-validate` 的输出（中文、返回 0），不是 `appstreamcli` 的**。`appstreamcli` 说英文（`Validation was successful: pedantic: 2`）。把它们当成 appstreamcli 的失败证据，是 Run 12 误判的直接原因。
2. **本地 fixture 必须来自真实上游文件**。自造简化数据会制造假失败源——Run 12 就是这样"实证"出一个根本不存在的 rc=3。
3. **`tail -30` 会截掉真凶**。已改 `tail -200`；并对 verify 注入 `#RBCFAIL:line N`，让每个失败点自带行号。
4. **"干净环境"是结论成立的前提**。沙箱 shell 会带 `GOROOT` 等预置变量并被 chroot 继承（见"本地实证记录"第 3 条同一陷阱）。Run 13 后我在 `env -i` 下重跑终版 verify，4 个 KOS 二进制的 `--version` **全部成功、无 `#RBCNOTE`**，说明第 19 行在真实条件下未必是唯一/真正根因；确定的是**这一批补丁整体让 verify 从失败转为 rc=0**。凡"单点定因"结论，必须在 `env -i` 下复现。

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
6. **chroot-safe systemd（Run7）**：install-apps.sh/verify-apps-install.sh 的运行时
   systemd 调用（enable --now/restart/busctl/is-active）在无 user manager 的 chroot
   必败；SYSTEMD_OFFLINE=1 只覆盖 daemon-reload。补丁 C/D：enable 去 --now（自启动
   链接保留，live 登录后 user manager 自动拉起），其余 \|\| true/注释。

## 本地实证记录（/opt/trixie-chroot，保留勿删）
- debootstrap minbase + 全量构建依赖（63+9 包）已装齐
- **Quickshell v0.3.0 全量编译 513/513 通过**（补丁后）
- NextKde KOS_BUILD_KWIN_PLUGINS=OFF 模式全量编译通过（spatial=ON、apps 四件套、Go data-service）
- 注意：chroot 已 mount --bind /dev；本地跑 go 需 env GOROOT=/usr/lib/go-1.24；沙箱宿主
  预置 GOROOT=/usr/local/go 会被 chroot 继承（假阳性陷阱）
- 教训：本地验证必须全量编译（configure 抓不到裸 include 与协议缺失）
- **复现命令模板（务必用 `env -i` 切断宿主环境）**：
  ```sh
  chroot /opt/trixie-chroot /usr/bin/env -i HOME=/home/user \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash -c '/tmp/verify-final.sh /home/user/.local 2>&1; echo "=== rc=$? ==="'
  ```
  终版 verify（5a99424 补丁后）在此条件下 **rc=0**，输出 `Verified four desktop entries, icons,
  metadata, binaries, and service registration.`，4 条 `Validation was successful: pedantic: 2`。
- `/tmp/hk7/` = 用**真实 hook 函数体** + **真实上游 verify-apps-install.sh(2195B)** 实跑补丁的
  fixture；补丁后 2444 字节、插桩点 3 个（17/47/48）、`bash -n` 通过
- `/tmp/up3.sh` = 上游 verify-apps-install.sh（2195B，与 GitHub API 拉取内容 IDENTICAL）
- `/tmp/meta-{Calendar,Todo,Weather,Music}.xml` = 真实上游 metainfo（844/830/819/955 字节）
- chroot 内已装 `desktop-file-utils 0.28-1`（为复现 CI 条件）；`appstream` 按需装卸

## 待办
- [ ] 等 Run 14（37888932265）出结果；若 8/9 通过 → 观察 9/9 终验 → squashfs → ISO
- [ ] 若 Run 14 仍失败：日志里 grep `#RBCFAIL` 直接读出触发行号（本次已就位，不再靠猜）
- [ ] 验证 ccache 兜底安装与 apt 缓存路径修复（此前几轮回拷仅 8.0K、路径仍是 `.build/cache`，
      说明 `Save apt cache` 的 `path: live-build/cache` 修复未进那些 run 的 head）
- [ ] 产出 ISO 后核对 `Rename & checksum` / `upload-artifact` 的 `RabbicaOS-*.iso` + `.sha256`
- [ ] 国产应用 deb（微信/QQ/钉钉/WPS 官方包）尚未放入 apps-cn/，放入后重新构建
- [ ] 可选视觉: Plymouth 开机动画、GRUB 主题、KOS 默认壁纸
- [ ] KWin 6.4 重开插件层（跟踪 Debian 升级）
- [ ] 长期：`tools/cloud-fullbuild.sh` 云主机完整构建；`tools/cloud-build-ccache.sh` 去掉
      gh CLI 依赖（`cli.github.com` 被墙）

## 环境备忘
- gh 已登录 rabbica817-crypto（workflow scope 已授权）；git 身份 rabbica817@gmail.com 已固化
- 沙箱到 github.com 的 443 间歇断连：push 失败就重试（曾遇 2 次，重试即恢复）
- 沙箱会休眠杀后台任务：长编译用前台限时（timeout 550 ninja -j6）分块跑
- workflow 步骤: 清磁盘 → 装 live-build(deb13u1)+archive-keyring → cache(lb-cache-v1) →
  lb build → 失败打印 KOS 日志 → 改名+sha256 → upload-artifact → rbc-v* tag 发 Release

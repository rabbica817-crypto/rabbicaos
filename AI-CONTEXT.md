# RabbicaOS 构建状态快照（供新会话恢复上下文用）
> 更新: 2026-10-09 13:35 CST | 维护者: rabbida817-crypto <rabbica817@gmail.com>（git 身份已修正）

## 项目一句话
Debian 13 (trixie) + KDE Plasma 6.3 + KOS Desktop Shell（Quickshell 0.3.x）自制发行版，
GitHub Actions 云端构建可安装 ISO。仓库: https://github.com/rabbica817-crypto/rabbicaos

## 当前进行中
- **Run 16**（ID 37908421523，head 1df9df3，2026-10-09 09:00 UTC 触发）构建中 —— **上游版本锁定后的验证**
- 策略：用户选定「先 C 再 B」—— 先锁定上游 commit 拿到可发布的 v1.0，再从容适配新版
- Run 15（37902928438，head 3261d27，tag `rbc-v1.0` 触发的 push run）**失败于 8/9**

### ⚠️ 上游破坏性变更事件（2026-10-09，本仓最大的一次外部风险）
| 时间（UTC） | 事件 |
|---|---|
| 06:11 | ✅ **Run 14 成功**（当时上游是旧版） |
| 07:13–08:31 | 上游连合 6 个提交：`4e1715b` 修可选应用安装 → **`ed6d7a9` 用 ListenFree 替换 kos-music** → **`ad062fa` 自动准备 ListenFree 依赖** → `29fff63`(PR#166) / `7b1ffdd`(PR#164) |
| 08:07 | Run 15 开始（**clone 到的已是新版**） |
| 08:41 | ❌ Run 15 失败（33m45s） |

**失败三重根因（全部源于上游，非本仓代码问题）**：
1. **`tools/install-apps.sh:54` 由 `enable kos-data.service` 改回 `enable --now kos-data.service`**（第 55 行 `restart` 也去掉了 `|| true`）。步骤 5/9 的 chroot-safe sed 按旧文本精确匹配 → **全部失配**；脚本头是 `set -eu` + 无 user manager 的 chroot → **该行必败，脚本在 verify 之前就死掉**。这就是 `#RBCFAIL` 插桩**一个都没触发**的原因（脚本根本没走到 verify）。
2. **`tools/verify-apps-install.sh` 2195B → 2954B**，`|| failed=1` 点 **3 → 7**；新增 listenfree 检查（22-33 行）、kos-music 退休检查（34-37 行）、settings import 目标检查（45-53 行）。
3. **`kos-music` 被 ListenFree 取代**，而 ListenFree 构建链（`tools/prepare-listenfree-sdk.sh`）要求 **`Qt6Core >= 6.10`**（`tools/check-apps-dependencies.py:24` 实证），且需**联网下载 quickjs-0.16.2 + qmmp-2.4.1 源码编译**；**trixie 只有 Qt 6.8.2** —— 版本鸿沟，当前基线不可能满足。

### 应对：上游版本锁定（v5）
`NEXTKDE_REF=e5304daa0a0162527b7507935ebeccd647d18e39`（2026-10-09 04:27:43Z，Run 14 所用版本）
- 可复现性实证：该 ref 下 `verify-apps-install.sh` **2195B / md5 `3a10a1c10c9659a16f050ad79891d234`**、`install-apps.sh` **3789B**，与 Run 14 构建时所用逐字节一致
- 实现：`git init` + `git fetch --depth 1 origin <SHA>` + `git checkout FETCH_HEAD`（不用 `clone --depth 1 <url>` 因为无法指定 SHA）
- **踩坑实证：必须用完整 40 位 SHA**。短 SHA 被 uploadpack 拒绝：`fatal: couldn't find remote ref e5304da`；完整 SHA fetch **rc=0**（本地实测）
- 方案 B（适配新版）待办：① 补 `enable --now` 的 chroot-safe sed ② 包清单加 Qt6WebEngine/libav*/libsecret/icu/quickjs+qmmp 依赖 ③ 解决 Qt6Core>=6.10 门槛（或向上游反馈 trixie 6.8 支持）

## CI 迭代史（全部有实证依据）
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
| 14 | ✅ **成功** | 40m11s。九步全过，8/9 `ok`（2m51s）。5b 自检实证补丁落地形态与本地 fixture 完全一致（verify 补丁后 **2444 字节**、appstreamcli 已 rc 白名单、is-enabled/is-active 已注释、插桩点 47/48 就位）。产出 ISO + sha256 并上传 artifact |
| 15 | 8/9（tag push run） | 33m45s。**非本仓代码问题** —— 上游 main 在 Run 14 成功后 1 小时内做了破坏性变更（详见「上游破坏性变更事件」）。`#RBCFAIL` 零触发 = install-apps.sh 在 verify 之前就被 `set -eu` 杀掉 |
| 16 | 构建中 | 上游锁定 `e5304da` 后的验证 |

### 八轮失败的最终归因（诚实版）
- **确定**：`5a99424` 的**补丁集整体**让 verify 由失败转为 rc=0。由 5b 自检（CI 内实测 2444 字节 + 逐行 dump）与本地 `env -i` 全链路 rc=0 双向印证。
- **不确定**：**未能在本地复现 CI 的原始失败**，故"第 19 行是唯一真凶"这一单点定因**已被本地实证推翻**（CI 等效 machine-id 条件下，4 个 `offscreen --version` 全 rc=0）。真实成因最可能是**多点共同作用**，或 CI 独有因素（`/proc` 已挂载 vs 本地未挂、`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` 全缺失、dbus 因空 machine-id 而 abort）。
- **教训**：无法复现的失败，不要强行归因于单点。应优先**把不确定性消灭掉**（本轮做法：把每个"环境依赖的断言"逐个改成 chroot-safe 或非否决），而不是"找到真凶再修"。

### 四轮误判的方法论教训（重要，勿重蹈）
1. **日志尾部那 4 条 `✔ 验证成功：细节：2` 是 `desktop-file-validate` 的输出（中文、返回 0），不是 `appstreamcli` 的**。`appstreamcli` 说英文（`Validation was successful: pedantic: 2`）。把它们当成 appstreamcli 的失败证据，是 Run 12 误判的直接原因。
2. **本地 fixture 必须来自真实上游文件**。自造简化数据会制造假失败源——Run 12 就是这样"实证"出一个根本不存在的 rc=3。
3. **`tail -30` 会截掉真凶**。已改 `tail -200`；并对 verify 注入 `#RBCFAIL:line N`，让每个失败点自带行号。
4. **"干净环境"是结论成立的前提**。沙箱 shell 会带 `GOROOT` 等预置变量并被 chroot 继承（见"本地实证记录"第 3 条同一陷阱）。Run 13 后我在 `env -i` 下重跑终版 verify，4 个 KOS 二进制的 `--version` **全部成功、无 `#RBCNOTE`**，说明第 19 行在真实条件下未必是唯一/真正根因；确定的是**这一批补丁整体让 verify 从失败转为 rc=0**。凡"单点定因"结论，必须在 `env -i` 下复现。
5. **单点定因被本地实证推翻（Run 13 结论修正）**：把本地 chroot 精确置为 CI 等效（`/etc/machine-id` 置空 0 字节、删除 `/var/lib/dbus/machine-id`、`env -i`）后，逐个测 `QT_QPA_PLATFORM=offscreen kos-{calendar,todo,weather,music} --version` → **4 个全部 rc=0**。故「第 19 行 = 唯一根因」**不成立**，本地无法复现 CI 的失败。
6. **Run 13 日志的最终证据链（可排除 appstreamcli）**：
   ```
   ...dbus[...] Aborted (core dumped) ×4...
   ✔ 验证成功：细节：2      ← desktop-file-validate ×4（第一个循环 4 个 app 各一条）
   ✔ 验证成功：细节：2
   ✔ 验证成功：细节：2
   ✔ 验证成功：细节：2
   KOS application registration verification failed.   ← 紧接失败，零中间输出
   ```
   `desktop-file-validate` 在 app 循环内、`appstreamcli` 在其后的独立循环内。**日志里没有英文 `Validation was successful`，也没有任何 appstreamcli 报错** → appstreamcli 段整段静默（`command -v` 判定或输出被吞），`failed=1` 只能来自 app 循环内**唯一静默的那个检查点**（第 19 行）。这是"为什么四轮都只看到 desktop-file-validate 输出"的结构性原因。
7. **`install-apps.sh` 的 dbus/systemd 调用全景（真实上游行号）**：
   | 行 | 内容 | chroot 实际行为 |
   |---|---|---|
   | 39 | `systemctl --user daemon-reload` | `Running in chroot, ignoring` → rc=0 |
   | 41 | `systemctl --user enable kos-data.service` | 本地无 `/proc` 时 rc=0；CI（`/proc` 已挂）行为待证 |
   | 42 | `systemctl --user restart ... \|\| true` | rc=0 |
   | 47 | `systemctl --user disable --now ... \|\| true` | rc=0 |
   | 48 | `pim_pid=$(busctl --user status ...)` | dbus 报 `Failed to set bus address`；在 `$()` 内，`set -e` 不触发 |
   | 69 | `busctl --user call ... \|\| true` | rc=0 |
   脚本头是 `#!/bin/sh` + **`set -eu`**；第 41 行是唯一无保护的非零可能点。CI 日志中**未见**该行报错，故 install-apps.sh 本身存活，失败发生在它调用的 verify 内（第 88 行）。
8. **CI `/etc/machine-id` 为空是既定事实**（日志原文：`UUID file '/etc/machine-id' should contain a hex string of length 32, not length 0`；`Failed to open "/var/lib/dbus/machine-id"`）。dbus 因此 `Aborted (core dumped)`。这是独立于 verify 的真实缺陷，建议在 hook 里 `systemd-machine-id-setup`（或 `dbus-uuidgen --ensure`）补齐——可消除 `gtk-update-icon-cache`/`kbuildsycoca6`/`busctl` 一族的噪声。

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
- [x] ✅ Run 14 成功；ISO 已验证（`P: Build completed successfully` + 3.1G `live-image-amd64.hybrid.iso`）
- [ ] 打 `rbc-v1.0` tag 触发 Release（workflow 的 Release step 会自动发；本轮因无 tag 而 skipped）
- [ ] ISO 全量校验需下载 3.05 GiB —— 沙箱带宽仅 ~46 KB/s（21 分钟仅 58 MB），**不要在沙箱下载**；
      改用本地网络或 `gh release download`（比 artifact 快）
- [x] ✅ ccache 兜底已生效：本轮回拷 **38M**（此前几轮仅 8.0K），命中率 24.41%（576/2360）
- [x] ✅ apt 缓存路径已修复为 `live-build/cache`（key `lb-apt-v2-...`）
- [ ] ISO 内 `desktop-file-utils` 未出现在 `Setting up`（基系统自带）；`appstream` 已装
- [ ] 建议在 hook 里补 `systemd-machine-id-setup`：CI 的 `/etc/machine-id` 为 0 字节，
      导致 dbus `Aborted (core dumped)`，是 `gtk-update-icon-cache`/`kbuildsycoca6`/`busctl` 一族噪声源
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

# MultiDock — 项目交接说明（Agent 入口）

> **本文件是入口与当前状态**；细节按主题分流：
> 设计与规格 → `docs/PLAN.md`；实验数据 → `docs/spikes.md`；环境事实 → `docs/facts.md`；
> 工程约定与防回归 → `docs/rules.md`；会话史 → `docs/sessions.md`。
> 旧文档里"见 §4 / §5 / §8"的引用分别指向 facts / rules / sessions（本文件保留对应编号小节作路标）。

---

## 0. 每次对话结束前必须做的两件事（用户明确要求）

1. **更新文档，让状态与事实一致**：
   - 本文件「§3 当前状态」「§6 未决问题」——新增/解决的要标掉；
   - 新实测 → `docs/facts.md`；新坑/约定 → `docs/rules.md`；新实验 → `docs/spikes.md`；
   - 设计有变化 → 同步 `docs/PLAN.md`；
   - **会话总结 → `docs/sessions.md` 追加一条（append-only，最新在最上面）。**
2. **`git commit` 一次**，提交信息说清"这次做了什么"。

**提交签名走 1Password**（本机 `commit.gpgsign = true` + `op-ssh-sign`）。两个坑：

| 报错 | 原因 | 修法 |
| --- | --- | --- |
| `1Password: Could not connect to socket` | 1Password 没启动 | `open -a 1Password` |
| `1Password: failed to fill whole buffer` | **在跑但金库锁着**（`ssh-add -l` 能列密钥 ≠ 能签名），或 `SSH_AUTH_SOCK` 指错 | 解锁 1Password；用下面修法 |

**`op-ssh-sign` 只认 `SSH_AUTH_SOCK`，不走 `~/.ssh/config`**（launchd 默认 socket 里没有身份）：

```bash
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" git commit ...
```

自查用 `... ssh-add -l`。**不要用 `--no-gpg-sign` 绕过**，也不要改 `gpg.ssh.program`。`git log --show-signature` 报 `allowedSignersFile` 只是"无法验证"；验真看 `git cat-file -p HEAD | grep '^gpgsig'`。

---

## 1. 这是什么

macOS 多桌面（Space）工具：为每个桌面绑定一套**原生 Dock** 配置，切换桌面时自动把 Dock 切换成对应配置。菜单栏常驻一个图标，单击切下一个桌面，`⇧`+单击切上一个。

- 用户：个人自用，本地运行，**不做公证、不上 Mac App Store、不签名**（ad-hoc 即可）。
- 语言：界面中文，代码与标识符英文。不替换原生 Dock，不自己画 Dock 栏。

---

## 2. 硬约束（用户明确要求，不要擅自推翻）

1. **无痕原则**：App 绝不永久改变用户的 Dock。首次运行把当时的 `com.apple.dock` 全量存为**基准快照**；退出时还原到该基准；被强杀或崩溃则下次启动检测并还原。安装后不做任何配置时，Dock 必须与安装前完全一致。
2. **用原生 Dock**：不实现替代品，只改写 Dock 偏好 + 触发重载。
3. **菜单栏交互**：左键单击 = 切到下一个桌面（循环）；**⇧+左键 = 切到上一个桌面**；右键 / ⌥+左键 = 下拉菜单（桌面列表 + 上一个/下一个 + 设置 + 退出）。左键行为可在设置里改成"打开菜单"（此时 ⇧+左键也一并打开菜单，不留隐形的第二行为）。**切桌面过程本身没有动画，且做不到**（`docs/spikes.md` 实验 7，别再试）。
4. **设置窗口两个 Tab**：通用（默认 Dock：可拖入拖出的图标条、Finder 与 Launchpad 固定、大小、位置）与桌面（列出所有桌面，每个桌面单独设置 Dock 位置/大小与图标，或沿用默认）。
5. **不需要任何系统权限**：不用辅助功能、屏幕录制、root。若某方案开始要求这些权限，先回来和用户确认。
6. **桌面命名 + 切换提示**：设置 → 桌面里可以给每个桌面起名，**最长 10 个字符**（仅存本地，macOS 15 没有系统接口）；**切换桌面后在屏幕中上部弹一条 toast 显示该名字，1 秒后自动消失**。toast 不抢焦点、不挡点击、不需要权限。规格见 `docs/PLAN.md` §3.10。

### 决策演变（一句话版；细节在 `docs/PLAN.md` 与 `docs/spikes.md`）

v1/v2（废弃）→ **v3** 加无痕原则 → **v3.1** P0 三修正（无 notifyd 热重载 / 切桌面靠 300 ms 轮询 / Finder 无表示）→ **v3.2** 桌面命名 + toast（P2.5）→ **v3.3** 节流错开 + PID 身份闸门 + 预应用"同一拍" + `DockEditTarget` 统一入口 → **v3.4** 自愈债务继承 + 备份只恢复白名单键 + `mru-spaces` 唯一写例外 → **v3.5** 退出单开窄路 + 「带上限的等」必须轮询可观察标志 + 测试隔离用户日志 → **实验 17（2026-10-03/04）**：CoreDock 通道结案——外观 setter 可用但语义未定，条目键无第三方通道（B15），主路径维持 SIGHUP。

---

## 3. 当前状态（2026-10-04）

**P0（实验）、P1、P2.5、P2、P3、P4、P5、P5+、P5++ 全部完成并实测通过。** 代码会真改用户 Dock；无痕原则由 `LifecycleController` 退出还原 + 会话标记兜底。UI 已对齐 Apple 原生设计（2026-10-04）。

- **A6 / A7 已销账**（用户真机日志确认）：退出还原 53–54 s → **0.01 s**；切桌面正常路径稳定 **35–126 ms**。
- **A8（偶发慢重启）**：修法「不等，催」已落地（26–31 s → ~1–3.5 s）；**成因未直接观测**，七个假说已证伪——**别再按它们改代码**，`minimumSpacing` 保持 1 s、`dockPID()` 的 LS 优先不要动。下次偶发按 `docs/spikes.md` 实验 15/16.4 的判定规则读 `multidock.log`（先看 `最长间隔 M ms`），**别主动复现**。
- **A9 / A10 已结案**：默认 Dock 的 3 个图标是用户有意配的；两条 override **不能清成沿用默认**（orientation 不同 + 整体替换语义），`config.json` 原样保留。
- **实验 17 / B15 已结案**：CoreDock 外观 setter（`SetTileSize`）对第三方可用（语义未定）；**条目键无第三方通道**——Dock 按发送方放行 Apple 二进制（Finder 同参数可用而我们被拒）。主路径维持 SIGHUP。
- 取证仪表（实验 15）已装：慢重启日志自带 `慢重启取证` 与 `轮询 N 次，最长间隔 M ms`。
- **环境变更（2026-10-04）**：macOS 更新到 **15.8.1 (24H32)**（原 15.7.9）。真机 Dock 验收重跑 **9/9 绿**——GUID 回填判据在 15.8.1 失效，已按系统版本条件化（`docs/spikes.md` 实验 19）。B7 通知观测在更新后系统上完成，结论不受影响。
- **用户日志停在 09-19**：实验 15/16 的取证仪表与之后的全部改动（含 UI 原生化）尚无真实使用数据——下次启动 App 后以 `multidock.log` 为准观察。

### 已完成

| 项 | 位置 | 状态 |
| --- | --- | --- |
| SwiftPM 包 | `Package.swift` | 执行目标 `MultiDock` + **测试目标 `MultiDockTests`**，`platforms: [.macOS(.v14)]` |
| 程序入口 | `Sources/MultiDock/MultiDockApp.swift` | `@main` + `NSApplication`（**不是** SwiftUI `App`，原因见下） |
| App 委托 | `App/AppDelegate.swift` | 组装状态、菜单栏、窗口；接线 toast、`onDockApplied`、`restoreHandler` |
| 全局状态 | `App/AppState.swift` | `@MainActor @Observable`，空间值转发给 observer（不复制）；**依赖全部可注入**（`DockController` / 两个 Store），所以按钮路径能单测 |
| 日志落盘 | `App/FileLogSink.swift` | 追加写 `multidock.log`，512 KB 上限 |
| 生命周期 | `App/LifecycleController.swift` | 启动自检 + 会话标记 + **退出还原（已接线）**；**只在本次会话可能让 Dock 变脏时才还原**（`appliedFingerprint` 或继承来的 `needsSelfHeal`）；还原前先 `prepareForTermination()` 等待办清空；**还原失败保留标记**交给下次自愈 |
| Dock 存活监视 | `Dock/DockPresenceMonitor.swift` | 轮询 `dockPID()`，连续缺失达阈值就 `kickstart` 拉回；归位后记恢复次数；**持续拉不回来（默认 12 轮 ≈ 6 秒）回调 `onPersistentlyDown` 一次 → UI 报警**，回来时 `onRevived`。**纯逻辑 + 注入式进程控制**，可脱离真实 Dock 单测 |
| 登录启动 | `App/LoginItem.swift` | `SMAppService.mainApp` 为主，失败退回写 `~/Library/LaunchAgents/local.multidock.loginitem.plist`；**非 `.app` 环境明确报"不可用"**，不做假开关 |
| SkyLight 桥 | `Spaces/SkyLightBridge.swift` | `dlopen` + `dlsym`，符号缺失即降级 |
| 桌面枚举 | `Spaces/SpaceProvider.swift` | 协议 + 私有 API 实现 + 降级实现 |
| 桌面观察 | `Spaces/SpaceObserver.swift` | **300 ms 轮询为主 + 通知为辅**，`type != 0` 过滤，按桌面身份去重 |
| 桌面切换 | `Spaces/SpaceSwitcher.swift` | 同显示器内循环取下一个/上一个，两端循环 |
| 配置模型 | `Dock/DockConfig.swift` | `PlistValue` / `DockTile` / `DockAppearance` / `DockConfig` / `DesktopBinding` / `AppSettings`（`AppSettings` 手写解码，见下） |
| 图标条规则 | `Dock/DockStripRules.swift` | 启动台必须在首位（已有则原样保留，不覆盖 `GUID`/`book`）、Finder 只是幻影、从 `.app` 造条目、取图标 |
| Dock 偏好 | `Dock/DockPreferences.swift` | 白名单 + 全量域读 + 原子写；**写路径已接线** |
| Dock 重载 | `Dock/DockReloader.swift` | `DockProcessControlling` 协议 + 真实实现；SIGHUP 主路径 → SIGTERM → `launchctl kickstart` 三级降级；**重启节流错开**（`minimumSpacing`）；**发信号前的安全闸门**（见 §4 的 `-1` 陷阱） |
| 应用流水线 | `Dock/DockController.swift` | **双重短路**（内容与上次写下去的一致 / **真实 Dock 已经就是这份内容**）→ 备份 → 读全量域 → 只覆盖白名单键 → 原子写 → 重启 → 读回校验（**不一致重试一次**）；`request()` 带防抖合并；`comparableFingerprint` / `adoptLiveDockAsApplied` / `isApplying` |
| 手动改动回存 | `Dock/DockWatcher.swift` | 轮询真实域的可比指纹，识别用户手动改动 → 回存到当前桌面的绑定（受开关控制）；**纯逻辑 + 注入式读写**，可脱离真实 Dock 单测 |
| 回存撤销栈 | `Dock/DockEditHistory.swift` | 回存前的旧配置暂存（**内存**，每目标 5 层），供电桌面页/通用页的「撤销自动回存」。刻意不落盘，理由见 §3 的 P5 第 6 条 |
| 全屏过滤回归脚本 | `scripts/check-fullscreen-filter.swift` | 把本进程自己的窗口切成全屏 → SkyLight 多出 `type=4` 空间 → 真机验证过滤。**零权限** |
| 配置持久化 | `Store/ConfigStore.swift` | 原子写 `config.json` |
| 基准快照 | `Store/BaselineStore.swift` | 基准 + 会话标记 + 备份轮转（保留 20 份） |
| 菜单栏 | `UI/MenuBarController.swift` | `NSStatusItem`，区分左右键，标题显示当前桌面序号；下拉含桌面列表 / 下一个桌面 / **用当前 Dock 重置本桌面配置** / 刷新 / **立即还原到原始 Dock** / 调试面板 / 设置 / **退出并还原 Dock** |
| 图标条编辑器 | `UI/DockStripEditor.swift` | 拖入/拖出/排序、从访达拖 `.app` 进来、垃圾桶移除、从当前 Dock 抓取；**Finder 与启动台锁在最前** |
| 外观编辑器 | `UI/DockAppearanceEditor.swift` | 位置/大小/放大/自动隐藏/最小化特效/最小化到应用图标/运行指示点；**本机不支持的键禁用并说明原因**；`onCommit` 只在**松手/值变化**时提交，不逐帧落盘 |
| 桌面列表页 | `UI/DesktopListView.swift` | 左列表（改名输入框 + 独立/沿用徽标 + 当前桌面标记）+ 右详情（沿用开关 / 完整图标条 + 外观 / 立即应用 / 抓取 / 重置为默认） |
| 调试面板 | `UI/DebugPanelView.swift` | 当前 spaceUUID/id64/type、桌面列表、实时日志、「测试 toast」按钮 |
| 设置窗口 | `UI/SettingsView.swift` | **顶部报警横幅**（Dock 拉不回来 / 桌面切换不可用）+ 通用（默认 Dock 编辑条 + 外观 + 立即应用 / 立即还原 / 设为新基准 + 本机不支持）/ 桌面（`DesktopListView`）两个 Tab |
| 桌面命名 | `Spaces/DesktopNaming.swift` | 归一化（≤10 字素簇）、显示名解析、改名/改 override 规则；**纯函数，全部有单测** |
| toast 调度 / 窗口 | `UI/ToastPresenter.swift`、`UI/DesktopNameToast.swift` | 纯逻辑调度 + 无边框窗口；跨空间、不抢焦点、零权限 |
| toast 验收工具 | `scripts/check-toast-window.sh` | 用 `CGWindowListCopyWindowInfo` 读窗口元数据（零权限），`--watch` 报告出现/消失时刻 |
| UI 离屏快照验收 | `Tests/MultiDockTests/UISnapshotTests.swift` | `MULTIDOCK_UI_SNAPSHOT=1` 开启：用 `SettingsWindowFactory` 装配**真窗口**离屏渲染，出亮/暗 × 通用/桌面 四张 PNG（零权限），UI 视觉验收用。**快照与 App 共用一份窗口装配，不许另拼** |
| toast 外观预览器 | `scripts/preview-toast.swift` | 在假壁纸上画亮/深色胶囊并输出 PNG（`cacheDisplay` 抓自己的视图，**零权限**）。⚠️ 它是 `DesktopNameToast.swift` 的**副本**，改了那边要同步这里，否则预览骗人 |
| P0 实验脚本 | `scripts/spike-*.{sh,swift}` | 重载策略 / 切桌面 / 停机时长 / 探测（含显示器 UUID 映射） |
| LS 滞后测量脚本 | `scripts/measure-launchservices-lag.swift` | 定向测量 `NSRunningApplication` 在 Dock 重启窗口里**抱着旧 PID 多久**（1 ms 采样、两路同问）。**只读 + 发 SIGHUP**，用来证伪 A8 的第六个假说，见 `docs/spikes.md` 实验 15.3 |
| launchd 退避测量脚本 | `scripts/measure-launchd-backoff.swift` | 把 Dock 存活时间压到 1 s 以内、**轮间不等待**连打 N 轮，测 launchd 的归位延迟会不会累积；超 3 s 自动催一发 `kickstart`。**只读 + 发 SIGHUP + kickstart**，见 `docs/spikes.md` 实验 16.2 |
| 打包脚本 | `scripts/build-app.sh` | 编译 → 组装 `.app` → ad-hoc 签名 |
| 显示器名解析 | `Spaces/ScreenNaming.swift` | `displayUUID → NSScreen.localizedName`；**纯解析可单测**，映射不到时如实说"未识别"而不回落成错的屏。桌面页据此按显示器分组 |
| 其他项（文件夹/堆栈）编辑 | `Dock/DockStripRules.swift`、`UI/DockStripEditor.swift` | **只搬不造**：显示 / 排序 / 移除；拖入文件夹时明确拒绝并给替代做法（`DockItemRejection`）。**不能新建**的实测依据见 `docs/spikes.md` 实验 8 |
| 测试 | `Tests/MultiDockTests/` | **327 个测试，全绿**（其中 9 个真实 Dock 验收默认跳过，需显式开启） |
| 设计文档 | `docs/PLAN.md` | 已按 P0 结论修订 |
| 实验结论 | `docs/spikes.md` | **16 个实验**的原始数据与决定（**实验 5 是 P3 挖出的两个要命发现；实验 8 是"其他项不能新建"；实验 9 是"切一次桌面黑屏几分钟"的根因；实验 10 是"每次退出都卡住"—— 同一条链，外加一个让所有"上限"静默失效的写法；实验 11 是用户真机日志复盘；实验 12–14 把"uptime 门槛"等四个假说逐个证伪；实验 15 给未解故障装取证仪表，15.2 是仪表自己的 bug（协议见证位协变陷阱），15.3 把第六个假说也证伪，15.4 补上"我没在看"这个洞；实验 16 落地 A8 修法 —— 不等、催，代价 26–31 s → ~1–3.5 s，并实测 launchd 那 ~1 s 是硬顶不累积**） |


> 上表各阶段的「实现要点（改动时别踩）」已迁至 `docs/rules.md`。
### 未完成

**代码层面：计划里已定义的功能全部落地，但 2026-09-20 的真机日志复盘挖出一条必须再修的。** 剩下的分三类：

- ⚠️ **A8：Dock 重启偶发慢到 26–31 秒，根因未定**（`spikes.md` 实验 11.6 与 12–15）。
  **五个假说已被实测逐个推翻**（uptime 门槛 / 探测路径分叉 / 连发退避 / 写偏好诱因 / **LS 滞后**），
  **不要按任何一个去改代码**；`minimumSpacing` 保持 1 s，`dockPID()` 的 LS 优先也不要动。
  ✅ **已装取证仪表**（2026-09-20，实验 15）：慢重启（> 1 s）时 `DockReloader` 会采样
  `pidProbe()` 的两条路径答案并写进那一行 `Dock 应用成功` 日志（正常路径零开销）。
  下次复现时读 `慢重启取证：…` 就能区分「探测分叉（我们的 bug）」与「Dock 真的没回来（launchd）」。
  **判定规则见 `docs/spikes.md` 实验 15。别为了复现去反复折腾用户的 Dock。**
  ⚠️ **已试过第五次复现并失败**（实验 15.1）：真机验收 20 轮连切（Dock 年龄正好 ~1 s，与故障同构）
  **最坏 74 ms、慢重启 0 次**。→ 成因不在"连续重启"这个形状里，只在真实 App 的完整上下文里。
  ⚠️ **仪表本身曾整个是死的**（实验 15.2，已修）：非可选返回类型撞上协议见证位协变陷阱 →
  通过协议调用永远拿 nil。**已由真机验收测试 + 走 `any` 协议的守卫测试覆盖。**
  ⚠️ **"我们没在看"这个洞已补**（实验 15.4）：`elapsed` 是墙钟、轮询跑在 `@MainActor` 上，
  主线程被冻住时我们会把"没观察"记成"Dock 慢"。现在跟着慢重启日志一起记
  **`轮询 N 次，最长间隔 M ms`** —— M 秒级就是观察窗口断了，不是 Dock 的事。
  ⚠️ **最后一个"我们的 bug"候选（LS 滞后）已证伪**（实验 15.3）：危险窗口 6/6 = 0 ms。
  剩下只有 launchd / Dock 归位本身。**别再顺着这条线改探测代码。**
- ✅ **A9 已结案（2026-09-20）**：用户确认默认 Dock 的 3 个图标（启动台 / FlClash / WorkBuddy AI，
  `orientation = right`）是**他有意配的**。`config.json` **原样保留、一个字节没动**。
  ⚠️ 两条 override（`计划 任务` / `密码 邮件`）的 `appearance.orientation` 是 `"bottom"`，
  与默认的 `"right"` **不同** —— 所以它们**不是**默认的精确副本，**不能"清成沿用默认"**
  （`effectiveConfig(for:)` 是整体替换，不是逐字段合并，清掉会让那两个桌面的 Dock 跑到屏幕右侧）。
  详见 §6.3 A9 与 `docs/spikes.md` 11.4。
- **多显示器热插拔的真机实测**（§6.3 B5）：映射键、插拔后自动刷新、toast 定位、桌面页的显示器名分组都已实现，
  但**本机只有一台显示器，必须用户插一台外接屏才能验**。
- **真人手测 5 条**（§6.3 A 组）：改名输入框、两个按钮、图标条拖拽、菜单栏连击，外加
  **真人把一个文件夹拖进 Dock**（新的「其他项」回存路径最贴切的检验）。
- **注销/关机还原**（B9）、**LaunchAgent 退回**（B10）要真注销 / 重登录一次。

**已完成、可以销账的**：

- ✅ **A6（切桌面黑屏）** 与 **A7（退出卡住）** 的实验 9 / 10 修复**已被用户真机日志覆盖**：
  退出还原 **53–54 s → 0.01 s**；切桌面的最坏值 **60–126 s → 26–31 s**（残余部分转为 A8）。

**明确"不做"的（都有实测依据，别再试）**：

- Dock 里**新建**文件夹 / 普通文件条目 —— Dock 不认领自拼的目录条目，坏形状会让它 SIGABRT（实验 8）。
- 切桌面的左右滑动动画（实验 7）。

**原先的两处"做了但没做全"已在 2026-09-18 补掉**（设置窗口顶部报警横幅，见 §3 的「已完成：P5+」）：
Dock 拉不回来时会红字报警并给「再试一次拉回 / 立即还原到原始 Dock」；`spaceProviderWarning` 会在同一处显示橙色横幅。

### 下一步：P5 已做完，只剩多显示器真机实测

P5 的三条都已落地（README ✅、全屏过滤真机回归 ✅、多显示器加固 ✅），详见 §3 的「已完成：P5」。
剩下的只有一条，而且**只能用户动手**：

1. **多显示器 / 热插拔实测**（§6.3 B5）：`(displayUUID, spaceUUID)` 映射在插拔外接显示器后不能串。
   本机是单显示器，**这条只能靠用户插一台外接屏实测**，别硬编造结论。
   核对手段已备好：调试面板显示「显示器数量」和每个桌面的 `displayUUID` 前 8 位；
   插拔后 App 会自动刷新桌面列表并记一条 `显示器配置变化：桌面列表已刷新（N → M 个）`。

### 用户必须手测的 5 条（无法脚本化，见 §6.3 A 组）

A4 的**逻辑侧已自动化**（`DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop`），
真人拖拽降级为"建议补一次"；剩下 A1–A3 / A5 仍只有单测覆盖，等用户手点。

---

---

## 4. 已验证的环境事实

> **已整体迁至 `docs/facts.md`**（~70 条实测结论，逐条含判据与脚本指针）。
> 动 Dock 相关代码前必读：「launchd 重启节流」「节流窗口判据」「`-1` PID 陷阱」
> 「查 Dock PID 的代价」「`launchctl kickstart` 会阻塞几十秒」「配置损坏会自我固化」。

---

## 5. 工程约定与致命陷阱

> **全文已迁至 `docs/rules.md`**（构建/测试命令详解、代码约定、各阶段"改动时别踩"、已解决问题台账）。

### 常用命令

```bash
swift build -c release --disable-sandbox   # 编译（--disable-sandbox 必须加）
swift test --disable-sandbox               # 328 个测试（9 个真实 Dock 验收 + 1 个 UI 快照默认跳过）
./scripts/build-app.sh                     # 组装 build/MultiDock.app（ad-hoc 签名）
open build/MultiDock.app                   # 运行（必须在 .app 里跑，菜单栏图标才正常）
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests  # 真机 Dock 验收（先备份！）
MULTIDOCK_UI_SNAPSHOT=1 swift test --disable-sandbox --filter UISnapshotTests          # UI 离屏快照（零权限）
```

### 致命陷阱速查（全文在 `docs/rules.md`；每一条都真实踩过）

1. `swift build/test` **必须加 `--disable-sandbox`**——SwiftPM 沙箱在本机直接失败。
2. **协议要求的返回类型必须逐字照抄**：要求 `-> T?` 写成 `-> T`，生产路径静默失效而替身单测全绿（实验 15.2）。有默认实现的协议要求必须补"走 `any 协议`"的守卫测试。
3. **`AppSettings` 加字段必须同时补手写 `init(from:)` 的 `decodeIfPresent`**，否则旧配置解码失败、静默回默认。
4. **只写域里已有的白名单键，绝不整域替换**；其他项（文件夹/堆栈）**只搬不造**——自拼条目 Dock 不认领，坏形状 SIGABRT 崩溃循环（实验 8）。
5. **`launchctl kickstart` 绝不能 `waitUntilExit()`**（退避时冻死主线程几十秒）；催办**别带 `-k`**。
6. **发信号前必须确认 PID 身份**——`NSRunningApplication` 在 Dock 重启窗口会返回 `-1`，`kill(-1,…)` 杀当前用户全部进程。
7. **「带上限的等」必须轮询可观察标志**；`withTaskGroup`+`await task.value` 赛跑返回值对、墙钟错（实验 10）。守卫必须断言墙钟。
8. **测试构造 `AppState` 必须传 `makeTestFileLog()`**——用户的 `multidock.log` 是唯一真机凭据，别污染。
9. **切桌面无动画且做不到**（实验 7 四条路全断）；硬切 0–6 ms。
10. **预应用 = "同一拍发起"，不是"切空间前完成重启"**（物理上做不到），别按字面"修正"。
11. **BSD `grep` 无 `\|` 交替、模式含非 ASCII 一律返回 0**——搜代码用 `rg`，搜二进制用字节级搜索。
12. **核对 `config.json` 先打印真实键名**（`pinnedApps`/`otherItems`）——一个字段名写错足以伪造"数据损坏"。
### 6.1 等用户回答（会阻塞后续阶段）

| # | 问题 | 阻塞谁 | 现状 |
| --- | --- | --- | --- |
| 1 | ~~「桌面」页里每个桌面的"位置"指什么？~~ | ~~P3 桌面页~~ | ✅ **已解决（2026-09-18）**：用户确认 = **Dock 屏幕位置 + 大小**，与「通用」页同一套含义，未设置时继承默认 |
| 2 | toast 在桌面**没有自定义名**时显示「桌面 N」还是不显示？ | 不阻塞 | ✅ P2.5 已按"显示「桌面 N」"实现，等用户点头 |
| 3 | "屏幕中上部"的具体位置（定在距可见区顶部 80 pt、水平居中） | 不阻塞 | ✅ P2.5 已按 80 pt 实现（实测 `y=80`），等用户点头 |
| 4 | 10 个字符按**字素簇**还是按**视觉宽度**（中文 2 / 英文 1）算？ | 不阻塞 | ✅ P2.5 已按字素簇实现，等用户点头 |
| 5 | **默认 Dock 为空时要不要自动抓取？** 现在**不自动抓**（避免首启就写盘/意外清空 Dock），改为在设置页显示橙色警告并把「立即应用」禁用掉，让用户先点「从当前 Dock 抓取」 | 不阻塞 | ✅ **用户已确认「保持现在这样」**（2026-09-18） |
| 6 | **重启节流导致的"切换延迟"要不要再优化？** 现在一次切换的**应用总耗时约 1 秒**（Dock 本身只消失 45–90 ms）。要缩短总耗时就得在 1 秒节流窗口内硬重启，代价是 Dock 消失一秒多 | 不阻塞 | ⏳ 按"宁等不闪"处理，等用户体感后反馈 |
| 7 | **自愈还原要不要弹 toast 告知？** 现在启动时会弹一条「已自动还原上次未还原的 Dock」，**不受**「切换桌面时显示桌面名称」开关控制（`ToastPresenter.announce`） | 不阻塞 | ⏳ 等用户体感：如果不想要，可以改成只记日志 |
| 8 | **登录启动要不要默认打开？** 现在是默认关闭、用户在设置里自己开 | 不阻塞 | ⏳ 等用户拍板 |
| 9 | **其他项（文件夹 / 堆栈）不能在 App 里新建**（实测所限，见 `docs/spikes.md` 实验 8）：编辑器里只能**排序 / 移除**已有的，要加文件夹必须先去访达自己拖一次。这个折中接受吗？ | 不阻塞 | ⏳ 2026-09-18 已按"**只搬不造 + UI 里写明替代做法**"实现，等用户点头 |

### 6.2 已解决（留档，别重复问）

- ~~是否 `git init` 并提交首个 commit~~ → **已解决**：用户 2026-09-18 明确要求每次对话后 commit，仓库已初始化。
- ~~P0 三个实验的结果未知~~ → 已解决，见 `docs/spikes.md`。
- ~~Dock 是否有热重载 / 能否主动切桌面 / Finder 怎么钉住~~ → 已解决，见 `docs/spikes.md`。
- ~~「桌面」页里"位置"指什么~~ → 已解决，见 §6.1 第 1 条。

### 6.3 未解决的技术项（不阻塞，但要知道）

| # | 事项 | 影响 | 何时处理 |
| --- | --- | --- | --- |
| **A. 待用户手测（脚本化不了，只能人点）** | | | |
| A1 | **改名输入框没被点过**（本机无屏幕录制、菜单栏自动隐藏，无法脚本点击 UI） | 万一 SwiftUI 绑定写错，改完名字没生效 | 请手动：设置 → 桌面 → 改个名字 → 回车 → 切桌面看 toast。逻辑侧已由 `config.json` 注入 + 单测覆盖 |
| A2 | **「立即应用」「立即还原到原始 Dock」按钮没被点过** | 按钮到 `AppState` 之间只有一行 SwiftUI action | 请手动点一次。逻辑侧由 `AppStateDockTests`（43 个用例）+ `DockAcceptanceTests` 覆盖 |
| A3 | **图标条的拖拽（排序 / 拖出移除 / 从访达拖 `.app` 进来）没被真人拖过** | `onDrag` / `dropDestination` 的真机手感与边界未验证 | 请手动拖一次。排序逻辑由 `DockStripRulesTests` + `AppStateDockTests` 覆盖 |
| A4 | **P3 验收里"在真实 Dock 手动拖入一个图标，切走再切回仍在"**（真人拖拽是纯 UI 操作，脚本化要辅助功能权限，与硬约束冲突） | 这条是 `DockWatcher` **回存路径的唯一真实检验** | ✅ **逻辑侧已自动化（2026-09-18）**：`DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop` 用 `defaults write` + 真实 `DockReloader().reload()` 复现"外部改动"，走**真实 2 秒轮询**（不手动 `tick()`），两种落点（默认 Dock / 逐桌面 override）都覆盖，并断言回存期间 **Dock PID 不变**。真人拖一次仍建议做（验证拖拽 UI 本身），但已不再是唯一检验 |
| A5 | **「连切 5 次只显示最终名字」只做了单测**，没做真机连击 | 真机是否闪烁未实测 | 单测 `testRapidSwitchKeepsOnlyLatestTextAndHidesOnce` 覆盖调度逻辑；真机需手动快速点菜单栏 |
| A6 | **「切桌面不再黑屏几分钟」还没真机复验**（实验 9 的修复只过了单测） | 这是用户报的最严重故障之一，没复验等于没确认修好 | ⚠️ **2026-09-20 复盘用户真机日志：大部分通过。** 05:02 打包的二进制（**晚于**实验 9 / 10 两个 commit）跑出 6 次真实 apply：**正常路径全是 50–126 ms**（57 / 126 / 84 / 50 ms）。但另两次是 **26 046 ms 与 31 039 ms**。⚠️ **那两次的"原因"一度被归到 `minimumSpacing` 上，已被实验 12–14 证伪**（见 A8）。结论：**60–126 s 那一档没了，26–31 s 这一档偶发、根因未定。** 复核口径：连切十次桌面后，`Dock 不可用` 应稳定在 100 ms 量级 |
| A7 | **「退出不再卡住几分钟」没做真机复验**（实验 10 的修复只过了单测） | 用户报的最严重故障，且是**每次**退出都中招 | ✅ **2026-09-20 复盘用户真机日志：通过。** `05:58:46.001 退出还原流程结束，用时 0.01s`（旧版 **53.12 s / 54.05 s**），整条退出约 2 s，其中 2 s 是 `prepareForTermination` 的等待窗口、**不是 Dock 缺失**。唯一尾巴：这次走了 `!settled` 分支（`还原未完成（退出时还有一次应用没落地），已留下标记`）→ `session.state` 留 `needsSelfHeal = true, pid = 0`，属预期兜底；但**副作用见 A8 第 2 条** |
| A8 | **Dock 重启偶发慢到 26–31 秒**（2026-09-20 真机日志挖出） | 偶发；正常路径稳定 35–126 ms | ⚠️ **七个假说/检查已被逐个推翻，别按它们改代码**（`spikes.md` 实验 11.6 / 12–14 / 15.3 / **16.2**）：① ~~launchd 有 10 s uptime 门槛~~ → 实验 12：uptime 6/12/20/60 s **全 37–68 ms**；② ~~`NSRunningApplication` 返回陈旧实例~~ → 实验 13：两条路径 41–116 ms 同量级、无分叉；③ ~~连续快速重启累积退避~~ → 实验 13 是用「间隔 2 s」测的，**根本没构成违规**（`ThrottleInterval` = 1 s）；**实验 16.2 用零间隔重打 10 轮才算真证伪**：延迟恒 ~1016 ms、**不累积**；④ ~~写偏好是诱因~~ → 实验 14：幂等写 + SIGHUP 5 轮 35–46 ms；⑤ ~~LS 抱着旧 PID 不放~~ → 实验 15.3：危险窗口 **6/6 = 0 ms**；⑥ ~~Dock 崩溃循环~~ → 实验 16.5：`DiagnosticReports` 里**没有** Dock 的崩溃报告；⑦ ~~系统日志能给出 launchd 的原话~~ → 实验 16.5：沙箱里 `log show` 一律拒绝，**脱离沙箱也一样**。**→ `minimumSpacing` 保持 1 s、`dockPID()` 的 LS 优先都不要动。**
| **✅ A8 修法已落地**（2026-09-20，`spikes.md` 实验 16）：**不等、催** | — | 关键线索是真机日志里一直没被当回事的半截 —— `05:33:16` 那次 **SIGHUP 等满 30 s 没等到，紧接着一发 `kickstart` 只用 0.5 s 就把它拉回来了**。于是：新增 `nudgeAfter`（**500 ms** 到点就催一发 `kickstart`；`nudgeInterval` 1 s 重复，但受 `LaunchctlParking` 闸门限制、**尽力而为**）、`timeout` **30 s → 3 s**、新增 `kickstartTimeout` 30 s、**加了 PID 守卫**（原来会对「刚归位的新 Dock」补 SIGTERM，把它再杀一次）、失败路径的取证改成三段拼接（原来把主路径那段丢了）。**代价从 26–31 s 压到 ~1–3.5 s**（安全性前提实测过：`kickstart` 不带 `-k` 时对活着的 Dock 是无害 no-op）。
| A8 的**机制推断**（未直接观测） | — | `KeepAlive = {AfterInitialDemand: 1, SuccessfulExit: 0}` → 只有**异常退出**（被信号杀死）才自动拉起；Dock 若**干净退出**（exit 0），launchd 就**不再调度**它，直到有东西**显式要求** —— `kickstart` 正是那个要求。**下一次复现的读法（顺序重要）**：① 先看 `轮询 N 次，最长间隔 M ms`，**M 秒级 = 我们没在看**（实验 15.4），后面都不用看；② 看时间线里有没有 `催 kickstart #n`；③ `launchctl print gui/501/com.apple.Dock.agent \| grep -E "state\|last terminating"` —— **`last terminating signal` 缺失 = 干净退出 = 推断成立**；仍是 `Hangup: 1` 就说明还有第三个成因。⚠️ **别为了复现反复折腾用户的 Dock** —— 那天 6 次中 2 次，等它自己出现。 |
| A9 | ~~两条桌面 override 与默认 Dock 的图标相同 = 坏数据~~ | ~~切过去会得到 3 图标的 Dock~~ | ✅ **已结案（2026-09-20）**：**用户确认默认 Dock 那 3 个图标（启动台 / FlClash / WorkBuddy AI）+ `orientation = right` 是他有意配的** → "图标相同"不再构成损坏证据，他完全可能给那两条也配了同一组。⚠️ **而且它们不能清成「沿用默认」**：override 的 `orientation = "bottom"`，默认是 `"right"`，而 `effectiveConfig(for:)` 是**整体替换**（`binding(for:)?.override ?? settings.defaultDock`）→ 清掉会让那两个桌面的 Dock **跑到屏幕右侧**，是可见的行为改变。**结论：`config.json` 原样保留，要改由用户在 UI 里自己改。** ⚠️ 本节数字在 2026-09-20 被更正过两次，第一次是我读取脚本用错 JSON 键名（`apps`/`others` ≠ 真实键 `pinnedApps`/`otherItems`）读出的假象 —— 见 §5 那条约定 |
| A10 | ~~`session.state` 的假欠账会在下次启动抹掉用户自己加的 Qoder CN~~ | ~~用户的 Dock 改动被无声回退~~ | ✅ **已解决（2026-09-20）**：那笔债是假的 —— 日志里 `05:58:45.991 开始还原到原始 Dock：15 个图标` 之后 Dock 确实回到了基准态，`needsSelfHeal` 只是 `prepareForTermination` 发现"有排队中的 apply 没落地"留下的兜底标记。已备份后移除 `session.state`（`session.state.bak-20260920-044624`）。**注意 `impliesDirtyDock` 是 `appliedFingerprint != nil \|\| needsSelfHeal == true`，只清 `needsSelfHeal` 不够** |
| **B. 待做的功能（已排期）** | | | |
| B5 | **多显示器仍未真机实测**（P5 唯一剩下的）：映射键、插拔后自动刷新、toast 的 `displayUUID → NSScreen` 定位都实现了，但本机只有一台显示器 | 插外接显示器后映射可能串 | **只能靠用户插一台外接屏实测**。调试面板已加「显示器数量」与每个桌面的 `displayUUID` 前 8 位，核对时用 |
| B6 | ~~全屏 App 空间的过滤只有单测覆盖~~ | 每次进全屏可能误切 Dock | ✅ **已解决（2026-09-18）**：真机回归通过，见 §4 的「全屏过滤的真机回归」与 `scripts/check-fullscreen-filter.swift` |
| B7 | ~~用户手动切桌面时 `activeSpaceDidChange` 通知是否触发~~ | ~~跟随延迟~~ | ✅ **已结案（2026-10-04，实验 18）**：**5/5 次手势切换全部触发**，通知比 50 ms 轮询早 2–30 ms——`SpaceObserver` 的通知快速通道实测有效，**手势切换跟随延迟 ≈0，零代码改动**；程序化切换仍靠轮询。工具：`scripts/spike-space-notify-watch.swift` |
| B8 | **手动移除 Finder 是否落键**未验证 | 若有新键需纳入白名单 | 可选，30 秒，风险低。脚本已备好：`scripts/check-finder-removal.sh`（**只读**观察：快照 → 真人取消勾选「在 Dock 中保留」→ diff 报告新键 → 提醒拖回 Finder） |
| B9 | **注销/关机路径只能尽力还原**（系统不给等待时间） | 关机瞬间可能来不及写完基准 | 已按"先留债务标记、下次启动自愈"处理，见 §3 的 P4 第 9 条。真要验证得注销一次机器 |
| B10 | **登录启动的 LaunchAgent 退回方案没在真机跑过**（本机 SMAppService 那条路没触发过退回） | 未签名场景下可能开了没用 | 需要真的重登录一次验证。逻辑侧只有 plist 内容有单测 |
| B11 | ~~README 还停在 P1 状态~~ | 用户照 README 操作会得到错误信息 | ✅ **已解决（2026-09-18，P5）**：整篇重写，含完全卸载三步与整域还原命令 |
| B12 | ~~编辑条竖排未实现~~ | 位置改成左/右后，编辑条与实际 Dock 长得不一样 | ✅ **已解决（2026-09-18，P5）**：`DockStripEditor.isVertical` + `SlotSizing` |
| B13 | ~~孤儿绑定不清理也不提示~~ | 配置越积越多、看不出哪些还有效 | ✅ **已解决（2026-09-18，P5）**：桌面页横幅 + 「清理」按钮 + 二次确认。**绝不自动删**（拔外接屏会误伤） |
| B14 | ~~`DockWatcher` 回存前不存历史版本~~ | 用户手改被误判时，旧配置找不回来 | ✅ **已解决（2026-09-18，P5）**：改成内存撤销栈 `DockEditHistory` + UI 上的「撤销自动回存」。**刻意不落盘** —— 落盘一堆没有恢复入口的文件是花架子 |
| B15 | ~~Dock 图标热替换通道未打通~~ | ~~"不重启换图标"做不了~~ | ✅ **已结案为「不做」（2026-10-04，实验 17.6/17.7）**：Finder 的 `cmdAddToDock:` 反汇编实锤用法 `(NSURL, 0)` 与我们逐参数相同却能用 ⇒ **Dock 按发送方放行 Apple 二进制**（第三方所有携带对象的 MIG 消息要么报错 -4956、要么无声忽略；RegisterClient 是接收端注册，排除）。不做发送方伪造。外观键 `SetTileSize` 对第三方可用但语义未定；系统设置实际走 SkyLight 协调通知（未展开）。**主路径维持 SIGHUP** |
| **C. 参数与取舍（记录在案）** | | | |
| C1 | **`DockWatcher` 轮询周期 2 s 是拍的**，没有实测依据 | 用户手动改 Dock 后最长 2 s 才被回存 | 按用户体感调 |
| C2 | **一次切换的应用总耗时约 1 秒**（其中 Dock 只消失 45–90 ms，其余是主动错开节流的等待） | 切桌面后 Dock 配置生效有一秒延迟，但期间 Dock 可用 | 按"宁等不闪"处理，见 §6.1 第 6 条 |
| C3 | **「立即还原」与退出还原都只比白名单键**，`mod-count` / `recent-apps` 不会被还原 | 这两个是 Dock 自己的计数器，还原它们没意义 | 有意为之 |
| C4 | **`DockWatcher` 只在"本次运行写过 Dock"后才回存**（`appliedFingerprint != nil`） | 启动后没应用过任何配置时，用户手动改 Dock 不会被回存 | 有意为之：否则会把用户原来的 Dock 当成"该回存的改动" |
| C5 | **节流窗口按 Dock 进程年龄算**（`proc_pidinfo`），不再只依赖内存里的 `lastRestartAt` | 拿不到进程年龄时会退回内存记忆，那种情况下"别人刚重启过 Dock"仍可能让我们吃一次 1 秒节流 | 有意为之：进程年龄是事实，内存是猜测。见 §4 的"节流窗口判据" |
| C6 | **自愈在启动后异步执行**，不阻塞启动 | 启动瞬间 Dock 可能还是脏的，约 1 秒后恢复 | 有意为之：阻塞启动比晚一秒更糟 |
| C7 | **其他项（文件夹 / 堆栈）只能排序 / 移除，不能新建**（`spikes.md` 实验 8） | 用户没法在 App 里给 Dock 加文件夹，只能先去访达拖一次 | 有意为之：Dock 不认领自拼的目录条目，做了就是假开关；字段不全的形状还会让它 SIGABRT。替代做法已写进 UI 文案 |
| C8 | **显示器名解析不到时不回落成主屏名** | 极端情况下列表标题显示"未识别显示器（UUID 前 8 位…）" | 有意为之：显示一个错的屏比显示"未识别"更糟（toast 那边仍按"回落主屏"处理，因为提示必须弹出来） |

> **D 组（已解决台账 D1–D26）已迁至 `docs/rules.md` 末尾**；旧引用"§6.3 Dx"指向那里。

---

## 7. 给下一个 session 的建议顺序

1. 读本入口 → 需要设计细节读 `docs/PLAN.md`（§3 机制、§3.10 命名与 toast、§3.11 无痕与自愈）；动实验读 `docs/spikes.md`（17 个实验，多数结论推翻过计划的原始假设）。
2. 跑基线：`swift build -c release --disable-sandbox && swift test --disable-sandbox && ./scripts/build-app.sh`，应 **328 全绿、零警告**。
3. **动 Dock 代码前把 §5 的 12 条致命陷阱过一遍**，并查 `docs/facts.md` 对应行。踩节流 → Dock 消失一秒多；踩 `-1` → 杀掉用户全部进程；踩同步 kickstart → 冻住两分钟；踩任务组坑 → 一堆"假上限"等待；踩见证位坑 → 功能静默不接线而单测全绿。**别把"等 30 秒"当耐心**——A8 的教训是"等"换不到东西、"催"才行（实验 16）。
4. 动 Dock 的验收：`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`；**先 `defaults export com.apple.dock` 备份，中途别手动改 Dock**。退出码非 0 可能只是 SwiftPM 沙箱消息，判据看 `Executed N tests, with 0 failures`。UI 改动的验收：`MULTIDOCK_UI_SNAPSHOT=1 ... --filter UISnapshotTests` 出 PNG 人工核对。
5. 剩余待办（按顺序）：**B5 多显示器**（等用户插外接屏）→ **A1–A3/A5 真人手测** → **B9/B10**（注销/重登录）→ **B7/B8** 小实测 → **A8** 只等复现（读日志，别折腾）。
6. 改了代码必须重新 `./scripts/build-app.sh` 才算装上去（A6 被"修复前二进制"骗过一次）；复验前先转走旧日志。
7. **工程提醒：同一个文件不要在同一条消息里发两个编辑**——实测会静默丢掉其中一个。一个文件一次改一处。

---

## 8. 会话记录

> **已整体迁至 `docs/sessions.md`**（29 条完整记录，append-only，最新在最上面）。本文件不再存会话史。

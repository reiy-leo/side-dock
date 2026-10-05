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

macOS 多桌面（Space）工具。**当前产品形态（2026-10-04 起，用户两次明确修订后的形态）**：

- **原生 Dock 全桌面一致**（「冻结原生 Dock 逐桌面切换」**默认开**）：切桌面**零写入、零重启**，
  原生 Dock 固定为「通用页那套默认 Dock」。
- **每个桌面的差异由「次级 Dock 条」呈现**：贴在原生 Dock 内侧的自绘图标条，随桌面秒换图标，
  默认半露、hover 全出，**不替换、不改写**原生 Dock。
- 菜单栏常驻图标：单击切下一个桌面、`⇧`+单击切上一个、右键/⌥+左键打开菜单；
  切换后中上部弹 1 秒 toast 显示桌面名。
- 可选项：关掉冻结开关即回到「逐桌面原生 Dock」老模式（届时切桌面才重启原生 Dock，走无闪烁三明治）。

- 用户：个人自用，本地运行，**不做公证、不上 Mac App Store、不签名**（ad-hoc 即可）。
- 语言：界面中文，代码与标识符英文。

---

## 2. 硬约束（用户明确要求，不要擅自推翻）

1. **无痕原则**：App 绝不永久改变用户的 Dock。首次运行把当时的 `com.apple.dock` 全量存为**基准快照**；退出时还原到该基准；被强杀或崩溃则下次启动检测并还原。安装后不做任何配置时，Dock 必须与安装前完全一致。
2. **用原生 Dock**：不实现替代品，只改写 Dock 偏好 + 触发重载。
   **（2026-10-04 用户修订）**新增批准例外：**次级 Dock 条**——贴在原生 Dock 内侧的自绘
   图标条，随桌面秒换内容、默认半露 hover 全出，**不替换、不改写**原生 Dock 的偏好与地位
   （纯 App UI，零权限、无痕）。**「冻结原生 Dock 逐桌面切换」自同日起默认开**（用户明确：
   原生 Dock 全桌面一致、切桌面不写不重启，差异全由次级条呈现；原生固定在「默认 Dock」这套
   配置上，由启动对齐 + 开关两方向共同保证）。规格见 `docs/PLAN.md` §3.12，实测见
   `docs/spikes.md` 实验 21/22。
3. **菜单栏交互**：左键单击 = 切到下一个桌面（循环）；**⇧+左键 = 切到上一个桌面**；右键 / ⌥+左键 = 下拉菜单（桌面列表 + 上一个/下一个 + 设置 + 退出）。左键行为可在设置里改成"打开菜单"（此时 ⇧+左键也一并打开菜单，不留隐形的第二行为）。**切桌面过程本身没有动画，且做不到**（`docs/spikes.md` 实验 7，别再试）。
4. **设置窗口两个 Tab**（macOS 原生工具栏标签页风格）：通用（默认 Dock：图标条 + 外观 + 应用/还原/基准 + 次级条与冻结开关等）与桌面（列出所有桌面，每个桌面单独设置 Dock 与图标，或沿用默认）。
5. **桌面命名 + 切换提示**：设置 → 桌面里可以给每个桌面起名，**最长 10 个字符**（仅存本地，macOS 15 没有系统接口）；**切换桌面后在屏幕中上部弹一条 toast 显示该名字，1 秒后自动消失**。toast 不抢焦点、不挡点击、不需要权限。规格见 `docs/PLAN.md` §3.10。

   > **已解除的约束（2026-10-05，用户指令）**：原第 5 条「不需要任何系统权限（辅助功能/屏幕录制/root），方案要权限先回来确认」——辅助功能等系统权限不再一票否决，**按功能收益逐案评估**后可用（例如 Dockset 式全局手势切换）。**现行实现仍是零权限**：没有具体功能承载前，代码不引入任何权限请求。注意这不改变实验 24 的结论：**权限解决不了「条随桌面滑」**（钉住特权来自进程身份，不是权限）。

### 决策演变（一句话版；细节在 `docs/PLAN.md` 与 `docs/spikes.md`）

v1/v2（废弃）→ **v3** 加无痕原则 → **v3.1** P0 三修正（无 notifyd 热重载 / 切桌面靠 300 ms 轮询 / Finder 无表示）→ **v3.2** 桌面命名 + toast（P2.5）→ **v3.3** 节流错开 + PID 身份闸门 + 预应用"同一拍" + `DockEditTarget` 统一入口 → **v3.4** 自愈债务继承 + 备份只恢复白名单键 + `mru-spaces` 唯一写例外 → **v3.5** 退出单开窄路 + 「带上限的等」必须轮询可观察标志 + 测试隔离用户日志 → **实验 17（2026-10-03/04）**：CoreDock 通道结案——外观 setter 可用但语义未定，条目键无第三方通道（B15），主路径维持 SIGHUP → **实验 20（2026-10-04）**：自动隐藏三明治——重启藏进「滑走 → 隐形重启 → 滑回」，切桌面无黑屏闪烁 → **v3.6（2026-10-04）**：次级 Dock 条（硬约束 2 修订批准的自绘例外；几何源 = `visibleFrame` 内缩，实验 21）→ **v3.6.1（2026-10-04 同日）**：冻结原生切换**转正为默认**（原生 Dock 全桌面一致、切桌面零重启）→ **v3.6.2（2026-10-04 同日）**：次级条 sticky 固定几何 + 与原生 Dock 同步显隐（实验 22）→ **实验 23→24（2026-10-04 同日晚间）**：「切桌面时次级条不随桌面滑」在零权限下**无解**（窗口层级 / Dock tags / `CGSSetWindowWorkspace`（已不存在）/ 多窗全证伪；硬限制 = 特权来自进程身份），唯一不滑的折中是 `.moveToActiveSpace`「切换瞬间消失、到位再出现」→ **v3.6.3（2026-10-05）**：用户拍板方案 ②——次级条切 `.moveToActiveSpace` 单空间配方，切换回调 `pullToActiveSpace()` 拉回当前空间 + 0.18 s 淡入，「滑动 vs 消失再出现」销账 → **约束修订（2026-10-05）**：解除硬约束「零权限」——权限不再一票否决、按功能收益逐案评估（现行实现不变、仍零权限；权限也解决不了实验 24 的窗口钉住问题）→ **实验 25（2026-10-05）**：「随幅度渐进沉入原生 Dock」（v3.7）spike 证伪——过渡期间改 frame 无视觉效果、空间 ID 翻转只在过渡结束后（16 ms 轮询也抢不到）；**采纳其可感知残余**：拉回出场从「0.18 s 原地淡入」改为「沉没位置位 + 0.12 s 升起 + 同步淡显」（切换后总感知 ≈ 0.14 s），见 `docs/spikes.md` 实验 25。→ **条宽修订（2026-10-05）**：次级条废弃 v3.6.2 的固定槽位（`sizingSlots` = 各桌面最大条目数），**条宽随该桌面内容撑开**——方案 ② 下切桌面条必经「沉没位再升起」，宽度变化静默发生在沉没位，固定槽位「防跳变」的理由不复存在。

---

## 3. 当前状态（2026-10-05）

**计划里的功能全部落地并实测通过**（P0–P5++ + 实验 17–24 的后续演进）。代码会真改用户 Dock；
无痕原则由 `LifecycleController` 退出还原 + 会话标记兜底。**369 个测试全绿**；真机 Dock 验收 **9/9 绿**。

**现行行为（均有真机日志/验收实证）**：

- **切桌面**：冻结模式下零写入零重启（日志 `原生 Dock 已冻结：跳过「切到 …」`）；次级条换图标、窗口不动。
- **启动**：自愈（若有欠账）→ 冻结对齐（把原生 Dock 对齐到默认 Dock，内容一致时指纹短路不重启）。
  退出时还原基准 → 下次启动再对齐（一次约 0.4 s 的隐形重启，若内容已一致则完全不动）。
- **次级条**：贴在原生 Dock 内侧、层级 19 半露 / hover 全出；**条宽随该桌面内容撑开**（2026-10-05
  用户修订，废弃 v3.6.2 固定槽位——方案 ② 下切桌面条必经「沉没位再升起」，宽度变化静默发生在
  沉没位，无可见跳变；图标尺寸冻结模式取默认 Dock / 未冻结取该桌面配置）；与原生 Dock 同步显隐
  （原生挂起/隐藏时条也藏，碰边显出时条同步出来）。
  **空间归属 = 方案 ②（v3.6.3，实验 24 折中，2026-10-05 用户拍板）**：窗口用 `.moveToActiveSpace`
  单空间配方——手势切换瞬间**条留在旧空间（随过渡渐隐）**，切换回调 `pullToActiveSpace()` 拉回当前空间，
  **沉没位置位 + 0.12 s 升回原位并同步淡显**（切换后总感知 ≈ 0.14 s，实验 25 用户规格 ≤ 0.15 s）；
  连切时复位任务自取消，同一空间重复事件不重复拉。真机手感待 A11 手测。
- **Dock 重启**（仅未冻结模式、手动应用、启动对齐会走到）：SIGHUP 主路径 + 自动隐藏三明治（无黑屏）；`kickstart` 催办兜底。
- **A8（偶发慢重启）**：修法「不等，催」已落地（26–31 s → ~1–3.5 s）；**成因未直接观测**，七个假说已证伪——**别再按它们改代码**，`minimumSpacing` 保持 1 s、`dockPID()` 的 LS 优先不要动。下次偶发按 `docs/spikes.md` 实验 15/16.4 判定规则读 `multidock.log`（先看 `最长间隔 M ms`），**别主动复现**。冻结默认后此风险实际暴露面大幅缩小（切桌面不再重启）。
- **A6 / A7 已销账**：退出还原 53–54 s → **0.01 s**；正常路径重启 35–126 ms（已被用户真机日志确认）。
- **A9 / A10 已结案**：`config.json` 里默认与各 override 都是用户有意配置（现行：默认 15 图标、3 条绑定全独立、全 `bottom`）。
- **实验 17 / B15 已结案**：条目键无第三方通道（Dock 按发送方放行 Apple 二进制），主路径维持 SIGHUP；`CoreDockSetTileSize` 可用但语义未定。
- **环境（2026-10-04）**：macOS **15.8.1 (24H32)**；GUID 回填判据在该版本失效、验收已按系统版本条件化（实验 19）。
- **日志**：`~/Library/Application Support/MultiDock/multidock.log` 是核对真机行为的唯一凭据（无屏幕录制、`log show` 沙箱里读不到）。测试必须传 `makeTestFileLog()`，别污染它。

### 模块地图（改动先看这里，再查 `docs/rules.md` 对应节）

| 区域 | 文件 | 职责与现状 |
| --- | --- | --- |
| 入口 / 委托 | `MultiDockApp.swift`、`App/AppDelegate.swift` | `@main` + `NSApplication`（不用 `MenuBarExtra`，要区分左右键）；组装状态、菜单栏、窗口、toast、次级条接线 |
| 全局状态 | `App/AppState.swift` | `@MainActor @Observable`；空间值转发给 observer；依赖全部可注入；冻结闸门 + 启动对齐（`reestablishFrozenDockIfNeeded` / `setFreezeNativeDockSwitching`）+ 次级条内容（含固定几何槽位） |
| 生命周期 | `App/LifecycleController.swift` | 启动自检 + 会话标记 + 退出还原（只在本次会话可能让 Dock 变脏时才还原；等不干净就留标记给下次自愈） |
| 日志 | `App/FileLogSink.swift`、`App/LoginItem.swift` | 落盘日志（512 KB 上限、可注入）；登录启动（SMAppService 主 + LaunchAgent 退） |
| Dock 应用流水线 | `Dock/DockController.swift`、`Dock/DockPreferences.swift`、`Dock/DockConfig.swift`、`Dock/DockStripRules.swift` | 双重指纹短路 → 备份 → 读全量域 → 只覆盖白名单键 → 原子写 → 重启 → 读回校验（重试一次）；白名单 + `mru-spaces` 唯一写例外；模型与手写解码；启动台/Finder/造条目规则 |
| Dock 重载 | `Dock/DockReloader.swift`、`Dock/DockAutoHide.swift` | SIGHUP → SIGTERM → kickstart 三级降级；节流错开（`minimumSpacing` 1 s）；PID 身份闸门；「不等，催」（nudge 500 ms）；自动隐藏三明治（无闪烁重启） |
| 手动改动回存 | `Dock/DockWatcher.swift`、`Dock/DockEditHistory.swift` | 可比指纹变化才回存（Dock 不在时不采样）；回存落点 = 当前桌面 override / 默认 Dock（冻结时一律默认 Dock）；内存撤销栈（每目标 5 层） |
| Dock 存活监视 | `Dock/DockPresenceMonitor.swift` | 连续缺失 8 轮（4 s）才 kickstart，60 轮报警；纯逻辑 + 注入可单测 |
| 次级 Dock 条 | `Dock/SecondaryDockLayout.swift`、`Dock/DockFaceProviding.swift`、`UI/SecondaryDock{StripView,Window,Controller}.swift` | 几何源 `visibleFrame` 内缩（**Dock 条不是独立 CG 窗口**）；层级 19 半露 / hover 全出；**条宽随本桌面内容撑开**（图标尺寸冻结取默认 Dock）；同步显隐（face + 显出带 + 400 ms 宽限，200 ms 轮询）；空间拉回 = 方案 ②（`.moveToActiveSpace` 单空间配方 + `pullToActiveSpace()` 沉没位置位后 0.12 s 升起，实验 25）；依赖全注入可单测 |
| 桌面（Space） | `Spaces/SkyLightBridge.swift`、`SpaceProvider.swift`、`SpaceObserver.swift`、`SpaceSwitcher.swift`、`DesktopNaming.swift`、`ScreenNaming.swift` | dlopen 私有 API + 降级；300 ms 轮询 + 通知快速通道；循环切换；命名（≤10 字素簇）；显示器名解析 |
| 持久化 | `Store/ConfigStore.swift`、`Store/BaselineStore.swift` | 原子写 `config.json`；基准快照 + 会话标记 + 备份轮转（20 份） |
| 菜单栏 / 设置 UI | `UI/MenuBarController.swift`、`UI/SettingsView.swift`、`UI/DesktopListView.swift`、`UI/DockStripEditor.swift`、`UI/DockAppearanceEditor.swift`、`UI/DebugPanelView.swift` | 原生风格工具栏标签页；顶部报警横幅；拖拽编辑条（Finder/启动台锁最前）；其他项只搬不造 |
| toast | `UI/ToastPresenter.swift`、`UI/DesktopNameToast.swift` | 纯逻辑调度 + 无边框窗口；跨空间、不抢焦点、零权限 |
| 脚本 | `scripts/build-app.sh`、`check-toast-window.sh`、`check-fullscreen-filter.swift`、`preview-toast.swift`、`spike-*.swift`、`measure-*.swift`、`spike-secondary-dock-sync.swift` | 打包；零权限验收工具；各实验复现脚本 |
| 测试 | `Tests/MultiDockTests/` | **369 个测试，全绿**（其中 9 个真实 Dock 验收 + 2 个 UI 快照默认跳过，需显式开启） |
| 文档 | `docs/PLAN.md`（设计）、`docs/spikes.md`（24 个实验）、`docs/facts.md`（环境事实）、`docs/rules.md`（约定与陷阱台账） | 本文件为入口 |

### 未完成 / 待办（全部只剩"等人"或"等复现"）

**必须用户手测（脚本化不了，见 §6.3 A 组）**：

- A1–A3：改名输入框、两个应用/还原按钮、图标条拖拽（逻辑侧均有单测/验收覆盖，只差真人点一次）。
- A5：菜单栏连击（连切 5 次只显示最终名字）。
- A11：**次级条手感**——hover 滑出/收回、点击图标启动、半露观感（亮/暗）、
  **自动隐藏下碰边 Dock 与条是否同步显出/收回**、**方案 ② 切桌面观感**（手势切换「消失再升起」
  ——渐隐时机由系统过渡决定（≈0.25 倍屏宽，实验 25），切换结束后条从原生 Dock 底部
  0.12 s 升起回位；菜单栏点击切换应无感知；连击不闪）。（「钉在原地」「随幅度沉入」已被
  实验 24/25 证伪；用户 2026-10-05 拍板方案 ② + 升起编排并已实现，剩真机手感核对。）

**等条件**：

- **B5 多显示器 / 热插拔**：代码就绪（映射键、自动刷新、toast 定位、分组），**只能用户插一台外接屏实测**。
  核对：调试面板「显示器数量」+ 各桌面 `displayUUID` 前 8 位；插拔后日志出现 `显示器配置变化：桌面列表已刷新（N → M 个）`。
- **B8**：Finder 手动移除是否落新键（脚本已备好：`scripts/check-finder-removal.sh`，只读，30 秒）。
- **B9 / B10**：注销/关机还原、LaunchAgent 退回 —— 要真注销 / 重登录一次。
- **A8**：只等复现（读日志，别折腾）。冻结默认后正常使用已几乎不会走到这条路径。

---

## 4. 已验证的环境事实

> **已整体迁至 `docs/facts.md`**（~80 条实测结论，逐条含判据与脚本指针）。
> 动 Dock 相关代码前必读：「launchd 重启节流」「节流窗口判据」「`-1` PID 陷阱」
> 「查 Dock PID 的代价」「`launchctl kickstart` 会阻塞几十秒」「配置损坏会自我固化」
> 「Dock 实际显隐没有零权限直读信号（实验 22）」「协议见证位陷阱」。

---

## 5. 工程约定与致命陷阱

> **全文已迁至 `docs/rules.md`**（构建/测试命令详解、代码约定、各模块"改动时别踩"、已解决问题台账 D1–D26）。

### 常用命令

```bash
swift build -c release --disable-sandbox   # 编译（--disable-sandbox 必须加）
swift test --disable-sandbox               # 369 个测试（9 个真实 Dock 验收 + 2 个 UI 快照默认跳过）
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
13. **Dock 实际显隐没有零权限直读信号**（实验 22）：`CoreDockSetAutoHideEnabled` 只翻旗标、**不改 work area**；探针 `occlusionState` 与 CGWindowList 都不可用。同步显隐只能用「face（`visibleFrame` 内缩）+ 光标显出带」启发式。
14. **冻结模式的「原生 Dock = 默认 Dock」语义靠三处合力**：启动对齐（**必须排在自愈之后**）+ 开关两个方向（`setFreezeNativeDockSwitching`）。删任意一处，原生 Dock 与次级条会各显一套。
15. **第三方窗口「跨空间可见且过渡不滑动」零权限下做不到**（实验 24）：窗口层级 / 复制 Dock tags / `CGSSetWindowWorkspace`（15.8.1 已不存在）/ 每空间独立窗口，全试遍照样滑——特权来自**进程身份**，不是窗口属性。且 `CGWindowList`「在屏」是切换后的快照，**证明不了动画期间不滑动**（实验 23 就栽在这）；「钉不钉」只能真人手势实测。别再在窗口属性上找配方。

## 6. 未决问题

### 6.1 等用户回答（不阻塞）

| # | 问题 | 现状 |
| --- | --- | --- |
| 1 | **自愈还原要不要弹 toast 告知？** 现在启动时会弹一条「已自动还原上次未还原的 Dock」，不受「切换桌面显示名字」开关控制 | ⏳ 等用户体感：不想要可改成只记日志 |
| 2 | **登录启动要不要默认打开？** 现在是默认关、用户在设置里自己开 | ⏳ 等用户拍板 |
| 3 | **其他项（文件夹 / 堆栈）不能在 App 里新建**（实测所限，实验 8）：编辑器里只能排序 / 移除 | ⏳ 折中已按"只搬不造 + UI 写替代做法"实现，等用户点头 |

> 历史遗留的确认项（「位置」含义、toast 回落「桌面 N」、80 pt、字素簇、默认 Dock 空时不自动抓取、切换延迟要不要再优化）**均已按现行实现长期使用，视为已确认**。

### 6.2 已解决（留档，别重复问）

- ~~是否 `git init` 并提交首个 commit~~ → 已解决：每次对话后 commit，仓库已初始化。
- ~~P0 三个实验的结果未知~~、~~Dock 热重载 / 主动切桌面 / Finder 钉住~~ → 见 `docs/spikes.md` 实验 1–3。
- ~~次级 Dock 条里放什么内容~~ → 已解决：用户选定「随桌面 + 冻结开关」，且 2026-10-04 冻结转正为默认。
- ~~手势切换时次级条「滑动 vs 消失再出现」~~ → 已解决（2026-10-05）：用户拍板方案 ②（`.moveToActiveSpace`），已实现「切换回调拉回 + 0.18 s 淡入」（v3.6.3），见 `docs/sessions.md` 第 39 次。真机手感归 A11。
- ~~「位置」/toast 细节 / 默认 Dock 空交互~~ → 均按现行实现长期使用。

### 6.3 未解决的技术项（不阻塞，但要知道）

| # | 事项 | 影响 | 何时处理 |
| --- | --- | --- | --- |
| **A. 待用户手测（只能人点）** | | | |
| A1 | 改名输入框没被真人点过 | 万一绑定写错，改完名字不生效 | 请手动：设置 → 桌面 → 改名 → 切桌面看 toast。逻辑侧已覆盖 |
| A2 | 「立即应用」「立即还原到原始 Dock」按钮没被真人点过 | 按钮到 AppState 只有一行 SwiftUI action | 请手动点一次。逻辑侧 43 用例 + 真机验收覆盖 |
| A3 | 图标条拖拽没被真人拖过 | `onDrag`/`dropDestination` 手感与边界未验证 | 请手动拖一次。逻辑侧覆盖 |
| A5 | 「连切 5 次只显示最终名字」没做真机连击 | 真机是否闪烁未实测 | 单测已覆盖调度；真机需手动快速点菜单栏 |
| A11 | **次级条手感**（2026-10-05 更新）：① hover 滑出/收回（含防抖）；② 点击图标启动/激活；③ 半露观感（亮/暗）；④ 点击能否到达条（推断可达）；⑤ **方案 ② 切桌面观感**——手势切换「消失再淡入」的节奏与空窗感知、菜单栏点击切换应无感知、连击不闪；⑥ 自动隐藏下碰边同步显出/收回 | 若点击不通，备选是升层级（牺牲半露遮挡）；若淡入节奏不顺手，调 `pullFadeDuration`（0.18 s，与 hover 同款）或 16 ms 复位延迟 | 请手动逐条试。满意后冻结模式已是默认 |
| A8 | **Dock 重启偶发慢到 26–31 秒**（成因未定，七个假说已证伪） | 偶发；正常 35–126 ms | **只等复现**。判定规则见 `docs/spikes.md` 实验 15/16.4：先看 `轮询 N 次，最长间隔 M ms`（M 秒级 = 我们没在看），再看 `催 kickstart #n`，最后 `launchctl print … \| grep last terminating`。**别再按旧假说改代码；别主动复现。** 冻结默认后切桌面不再走这条路 |
| **B. 待做（等条件）** | | | |
| B5 | 多显示器热插拔未真机实测 | 插屏后映射可能串 | **只能用户插外接屏**。调试面板已备好核对项 |
| B8 | 手动移除 Finder 是否落键未验证 | 有新键需纳入白名单 | 可选，30 秒。脚本 `scripts/check-finder-removal.sh`（只读） |
| B9 | 注销/关机路径只能尽力还原 | 关机瞬间可能来不及写完基准 | 已按"留债务标记、下次启动自愈"处理；验证要真注销一次 |
| B10 | 登录启动 LaunchAgent 退回未真机跑过 | 未签名场景可能开了没用 | 需要重登录一次验证。逻辑侧仅 plist 内容有单测 |
| **C. 参数与取舍（记录在案）** | | | |
| C1 | `DockWatcher` 轮询周期 2 s 是拍的 | 手改 Dock 后最长 2 s 回存 | 按用户体感调 |
| C2 | 一次应用总耗时约 1 秒（Dock 只消失 45–90 ms，其余是错开节流的等待） | 配置生效有一秒延迟 | **冻结默认下切桌面不再触发**；仅未冻结模式/手动应用/启动对齐会遇到。按"宁等不闪"处理 |
| C3 | 「立即还原」与退出还原只比白名单键 | `mod-count`/`recent-apps` 不还原 | 有意为之 |
| C4 | `DockWatcher` 只在"本次运行写过 Dock"后才回存 | 启动后没应用过时，手改 Dock 不回存 | 有意为之：否则会把用户原 Dock 当成该回存的改动 |
| C5 | 节流窗口按 Dock 进程年龄算（`proc_pidinfo`） | 拿不到年龄时退回内存记忆 | 有意为之：进程年龄是事实，内存是猜测 |
| C6 | 自愈在启动后异步执行 | 启动瞬间 Dock 可能还是脏的 | 有意为之：阻塞启动比晚一秒更糟 |
| C7 | 其他项只能排序/移除，不能新建（实验 8） | 加文件夹须去访达拖 | 有意为之：自拼条目是假开关，坏形状会崩 Dock |
| C8 | 显示器名解析不到时不回落主屏名 | 显示"未识别显示器" | 有意为之：显示错的屏比"未识别"更糟 |

> **已结案的历史问题**（A6/A7/A9/A10/B6/B7/B11–B15 等）见 `docs/rules.md` 末尾的 D 台账（D1–D26，留档别重复查）与 `docs/sessions.md`。

---

## 7. 给下一个 session 的建议顺序

1. 读本入口 → 需要设计细节读 `docs/PLAN.md`（§3 机制、§3.10 命名与 toast、§3.12 次级条）；动实验读 `docs/spikes.md`（**24 个实验**，多数结论推翻过计划的原始假设）。
2. 跑基线：`swift build -c release --disable-sandbox && swift test --disable-sandbox && ./scripts/build-app.sh`，应 **369 全绿、零警告**。
3. **动 Dock 代码前把 §5 的 15 条致命陷阱过一遍**，并查 `docs/facts.md` 对应行。踩节流 → Dock 消失一秒多；踩 `-1` → 杀掉用户全部进程；踩同步 kickstart → 冻住两分钟；踩任务组坑 → 一堆"假上限"等待；踩见证位坑 → 功能静默不接线而单测全绿。**别把"等 30 秒"当耐心**——A8 的教训是"等"换不到东西、"催"才行（实验 16）。
4. 动 Dock 的验收：`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`；**先 `defaults export com.apple.dock` 备份，中途别手动改 Dock**。退出码非 0 可能只是 SwiftPM 沙箱消息，判据看 `Executed N tests, with 0 failures`。UI 改动的验收：`MULTIDOCK_UI_SNAPSHOT=1 ... --filter UISnapshotTests` 出 PNG 人工核对。
5. 剩余待办（按顺序）：**A11 次级条手感手测**（含方案 ② 切桌面观感——手势「消失再淡入」、菜单栏点击无感知、连击不闪，当前最紧）→ **A1–A3/A5** 回归手测 → **B5 多显示器**（等用户插外接屏）→ **B9/B10**（注销/重登录）→ **B8** 小实测 → **A8** 只等复现（读日志，别折腾）。
6. 改了代码必须重新 `./scripts/build-app.sh` 才算装上去（A6 被"修复前二进制"骗过一次）；复验前先转走旧日志。
7. **工程提醒：同一个文件不要在同一条消息里发两个编辑**——实测会静默丢掉其中一个。一个文件一次改一处。

---

## 8. 会话记录

> **已整体迁至 `docs/sessions.md`**（36 条完整记录，append-only，最新在最上面）。本文件不再存会话史。

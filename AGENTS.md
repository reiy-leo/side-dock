# MultiDock — 项目交接说明

> 这份文件是给下一个接手本项目的 agent 读的。**先读完这里，再读 `docs/PLAN.md`。**
> 本文件描述"现在是什么状态、怎么干活、下一步做什么"；`docs/PLAN.md` 描述"要造成什么样、为什么"；
> `docs/spikes.md` 是 P0 实验的实测结论，**里面有几条结论推翻了 `PLAN.md` 的原始假设**，动架构细节前必读。

---

## 0. 每次对话结束前必须做的两件事（用户明确要求）

1. **更新本文档**，让状态与事实一致：
   - §3 当前进度 —— 已完成 / 未完成 / 下一步
   - §6 待确认问题与未解决的问题 —— 新增、已解决的要标掉
   - §4 已验证的环境事实 —— 有新实测就补
   - §8 会话记录 —— 追加一条本次对话的总结（**append-only，最新在最上面**）
   - 设计若有变化，同步改 `docs/PLAN.md`；有新的实测结论写进 `docs/spikes.md`
2. **`git commit` 一次**，提交信息说清"这次做了什么"。

> 目的：任何其他 agent 读完本文件就能拿到完整项目信息、当前进度和未解决的问题，直接接着干。

**提交前先确认 1Password 的 SSH agent 能被找到。** 本机 git 全局配置了 `commit.gpgsign = true`，
`gpg.format = ssh`、`gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign`，
签名密钥由 1Password 托管。

**症状与修法（2026-09-18 实测确认）**：

| 报错 | 原因 | 修法 |
| --- | --- | --- |
| `error: 1Password: Could not connect to socket. Is the agent running?` | 1Password 没启动 | `open -a 1Password` |
| `error: 1Password: failed to fill whole buffer` / `fatal: failed to write commit object` | **1Password 在跑但锁着**，或 `SSH_AUTH_SOCK` 指错了 socket | 见下 |

**关键点：`op-ssh-sign` 读的是 `SSH_AUTH_SOCK`，不会走 `~/.ssh/config` 里的 `IdentityAgent`。**
本机 `SSH_AUTH_SOCK` 默认是 launchd 那个（`/private/tmp/com.apple.launchd.*/Listeners`，**里面没有任何身份**，
`ssh-add -l` 会报 `The agent has no identities`），而 1Password 的 agent 在
`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`（`~/.ssh/config` 里配了 `IdentityAgent` 指向它，
所以 `ssh` / `ssh-keygen -Y sign` 正常，**只有 git 提交会失败**）。

**修法（不改任何全局配置）**：

```bash
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" git commit ...
```

自查：`SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh-add -l`
应当列出密钥。**不要用 `--no-gpg-sign` 绕过签名**，也不要为此去改 `gpg.ssh.program`。

> 附带：`git log --show-signature` 会报 `gpg.ssh.allowedSignersFile needs to be configured` 并显示
> "No signature" —— 那只是**无法验证**，不代表没签名。判断是否真签了看原始对象：
> `git cat-file -p HEAD | grep '^gpgsig'`，有输出即已签名。

---

## 1. 这是什么

macOS 多桌面（Space）工具：为每个桌面绑定一套**原生 Dock** 配置，切换桌面时自动把 Dock 切换成对应配置。菜单栏常驻一个图标，单击即切到下一个桌面。

- 用户：个人自用，本地运行，**不做公证、不上 Mac App Store、不签名**（ad-hoc 签名即可）。
- 语言：界面中文，代码与标识符英文。
- 不替换原生 Dock，不自己画 Dock 栏。

---

## 2. 硬约束（用户明确要求，不要擅自推翻）

1. **无痕原则**：App 绝不永久改变用户的 Dock。首次运行把当时的 `com.apple.dock` 全量存为**基准快照**；退出时还原到该基准；被强杀或崩溃则下次启动检测并还原。安装后不做任何配置时，Dock 必须与安装前完全一致。
2. **用原生 Dock**：不实现替代品，只改写 Dock 偏好 + 触发重载。
3. **菜单栏交互**：左键单击 = 切到下一个桌面（循环）；右键 / ⌥+左键 = 下拉菜单（桌面列表 + 设置 + 退出）。左键行为可在设置里改成"打开菜单"。
4. **设置窗口两个 Tab**：通用（默认 Dock：可拖入拖出的图标条、Finder 与 Launchpad 固定、大小、位置）与桌面（列出所有桌面，每个桌面单独设置 Dock 位置/大小与图标，或沿用默认）。
5. **不需要任何系统权限**：不用辅助功能、屏幕录制、root。若某方案开始要求这些权限，先回来和用户确认。
6. **桌面命名 + 切换提示**：设置 → 桌面里可以给每个桌面起名，**最长 10 个字符**（仅存本地，macOS 15 没有系统接口）；**切换桌面后在屏幕中上部弹一条 toast 显示该名字，1 秒后自动消失**。toast 不抢焦点、不挡点击、不需要权限。规格见 `docs/PLAN.md` §3.10。

### 决策演变（避免回退到旧方案）

- v1（已废弃）：被动跟随桌面变化 + 抽象"配置列表"UI。
- v2（已废弃）：改为主动切换桌面 + 按桌面的可视化 Dock 编辑器。
- **v3（当前）**：在 v2 基础上增加"无痕原则"——退出还原 + 强杀自愈。
- **v3.1（P0 实测后修正）**：三处假设被证伪并已改设计 —— ① Dock 没有热重载；② 程序化切桌面不触发空间变化通知；③ Finder 在 plist 中无表示。详见 `docs/spikes.md`。
- **v3.2（2026-09-18）**：新增**桌面命名（≤10 字符，仅本地）**与**切换桌面的中上部 toast（1 秒自动消失，零权限）**。因为完全不碰 Dock，单列为 P2.5 —— **已完成并实测通过**，规格见 `docs/PLAN.md` §3.10。
- **v3.3（当前，2026-09-18，P3 实测后修正）**：四处修正 ——
  ① **Dock 重启要错开 launchd 的节流窗口**（间隔 < 1 s 时归位要 1070 ms，≥ 1 s 只要 70 ms），`DockReloader.minimumSpacing` 负责；
  ② **发信号前必须确认 PID 身份**（`NSRunningApplication` 会返回 `-1`，`kill(-1, …)` 会杀掉当前用户全部进程）；
  ③ **"预应用"的措辞从"先 apply 再切空间"改为"发起应用与切空间同一拍、不等轮询"**（切空间前完成重启物理上做不到）；
  ④ **默认 Dock 与逐桌面 override 统一走 `DockEditTarget` 一套读写入口**，编辑器一律"只改内存 + 一次提交"。
  详见 `docs/spikes.md` 实验 5 与 `docs/PLAN.md` §3.4 / §3.7。
- **v3.4（当前，2026-09-18，P4 实测后修正）**：五处修正 ——
  ① **退出还原前必须先等排队的应用跑完**（`request()` 是异步排队的，否则那笔待办会在还原**之后**落地，把 Dock 又弄脏）；
  ② **还原失败时会话标记必须留下**，并标成"非活动会话"（`pid = 0`）—— 清掉标记等于把下次启动的自愈能力一起扔了；
  ③ **自愈债务要能跨会话继承**（`SessionMarker.needsSelfHeal`）：自愈是异步的，还原途中再崩一次不能让债务丢掉；
  ④ **备份恢复只写白名单键**，不做整域替换 —— 我们自己从来只碰白名单键，整域替换会把用户后来改的热角等设置冲回旧值；
  ⑤ **`mru-spaces` 是白名单之外的唯一写入例外**，只给它一个专用窄方法，不开放通用的"随便写某个键"口子。
  详见 `docs/PLAN.md` §3.11 与 §5。

---

## 3. 当前进度

**P0（实验）、P1（骨架 + 识别 + 菜单栏）、P2.5（桌面命名 + 切换 toast）、P2（编辑条 + 应用）、P3（桌面页 + 自动切换）、P4（无痕与自愈）已完成并实测通过。下一步是 P5（收尾）。**

> ⚠️ **从 P2 起，代码真的会改用户的 Dock 了。** 写路径已接线：设置页「立即应用」→ `DockController` → 写偏好 + 重启 Dock。无痕原则靠 `LifecycleController` 的退出还原 + 会话标记兜底（见 §3 的 P2 小节）。

### 已完成

| 项 | 位置 | 状态 |
| --- | --- | --- |
| SwiftPM 包 | `Package.swift` | 执行目标 `MultiDock` + **测试目标 `MultiDockTests`**，`platforms: [.macOS(.v14)]` |
| 程序入口 | `Sources/MultiDock/MultiDockApp.swift` | `@main` + `NSApplication`（**不是** SwiftUI `App`，原因见下） |
| App 委托 | `App/AppDelegate.swift` | 组装状态、菜单栏、窗口；接线 toast、`onDockApplied`、`restoreHandler` |
| 全局状态 | `App/AppState.swift` | `@MainActor @Observable`，空间值转发给 observer（不复制）；**依赖全部可注入**（`DockController` / 两个 Store），所以按钮路径能单测 |
| 日志落盘 | `App/FileLogSink.swift` | 追加写 `multidock.log`，512 KB 上限 |
| 生命周期 | `App/LifecycleController.swift` | 启动自检 + 会话标记 + **退出还原（已接线）**；**只在本次会话可能让 Dock 变脏时才还原**（`appliedFingerprint` 或继承来的 `needsSelfHeal`）；还原前先 `prepareForTermination()` 等待办清空；**还原失败保留标记**交给下次自愈 |
| Dock 存活监视 | `Dock/DockPresenceMonitor.swift` | 轮询 `dockPID()`，连续缺失达阈值就 `kickstart` 拉回；归位后记恢复次数。**纯逻辑 + 注入式进程控制**，可脱离真实 Dock 单测 |
| 登录启动 | `App/LoginItem.swift` | `SMAppService.mainApp` 为主，失败退回写 `~/Library/LaunchAgents/local.multidock.loginitem.plist`；**非 `.app` 环境明确报"不可用"**，不做假开关 |
| SkyLight 桥 | `Spaces/SkyLightBridge.swift` | `dlopen` + `dlsym`，符号缺失即降级 |
| 桌面枚举 | `Spaces/SpaceProvider.swift` | 协议 + 私有 API 实现 + 降级实现 |
| 桌面观察 | `Spaces/SpaceObserver.swift` | **300 ms 轮询为主 + 通知为辅**，`type != 0` 过滤，按桌面身份去重 |
| 桌面切换 | `Spaces/SpaceSwitcher.swift` | 同显示器内循环取下一个/上一个，两端循环 |
| 配置模型 | `Dock/DockConfig.swift` | `PlistValue` / `DockTile` / `DockAppearance` / `DockConfig` / `DesktopBinding` / `AppSettings`（`AppSettings` 手写解码，见下） |
| 图标条规则 | `Dock/DockStripRules.swift` | 启动台必须在首位（已有则原样保留，不覆盖 `GUID`/`book`）、Finder 只是幻影、从 `.app` 造条目、取图标 |
| Dock 偏好 | `Dock/DockPreferences.swift` | 白名单 + 全量域读 + 原子写；**写路径已接线** |
| Dock 重载 | `Dock/DockReloader.swift` | `DockProcessControlling` 协议 + 真实实现；SIGHUP 主路径 → SIGTERM → `launchctl kickstart` 三级降级；**重启节流错开**（`minimumSpacing`）；**发信号前的安全闸门**（见 §4 的 `-1` 陷阱） |
| 应用流水线 | `Dock/DockController.swift` | 指纹短路 → 备份 → 读全量域 → 只覆盖白名单键 → 原子写 → 重启 → 读回校验（**不一致重试一次**）；`request()` 带防抖合并；`comparableFingerprint` / `adoptLiveDockAsApplied` / `isApplying` |
| 手动改动回存 | `Dock/DockWatcher.swift` | 轮询真实域的可比指纹，识别用户手动改动 → 回存到当前桌面的绑定（受开关控制）；**纯逻辑 + 注入式读写**，可脱离真实 Dock 单测 |
| 配置持久化 | `Store/ConfigStore.swift` | 原子写 `config.json` |
| 基准快照 | `Store/BaselineStore.swift` | 基准 + 会话标记 + 备份轮转（保留 20 份） |
| 菜单栏 | `UI/MenuBarController.swift` | `NSStatusItem`，区分左右键，标题显示当前桌面序号；下拉含桌面列表 / 下一个桌面 / **用当前 Dock 重置本桌面配置** / 刷新 / **立即还原到原始 Dock** / 调试面板 / 设置 / **退出并还原 Dock** |
| 图标条编辑器 | `UI/DockStripEditor.swift` | 拖入/拖出/排序、从访达拖 `.app` 进来、垃圾桶移除、从当前 Dock 抓取；**Finder 与启动台锁在最前** |
| 外观编辑器 | `UI/DockAppearanceEditor.swift` | 位置/大小/放大/自动隐藏/最小化特效/最小化到应用图标/运行指示点；**本机不支持的键禁用并说明原因**；`onCommit` 只在**松手/值变化**时提交，不逐帧落盘 |
| 桌面列表页 | `UI/DesktopListView.swift` | 左列表（改名输入框 + 独立/沿用徽标 + 当前桌面标记）+ 右详情（沿用开关 / 完整图标条 + 外观 / 立即应用 / 抓取 / 重置为默认） |
| 调试面板 | `UI/DebugPanelView.swift` | 当前 spaceUUID/id64/type、桌面列表、实时日志、「测试 toast」按钮 |
| 设置窗口 | `UI/SettingsView.swift` | 通用（默认 Dock 编辑条 + 外观 + 立即应用 / 立即还原 / 设为新基准 + 本机不支持）/ 桌面（`DesktopListView`）两个 Tab |
| 桌面命名 | `Spaces/DesktopNaming.swift` | 归一化（≤10 字素簇）、显示名解析、改名/改 override 规则；**纯函数，全部有单测** |
| toast 调度 / 窗口 | `UI/ToastPresenter.swift`、`UI/DesktopNameToast.swift` | 纯逻辑调度 + 无边框窗口；跨空间、不抢焦点、零权限 |
| toast 验收工具 | `scripts/check-toast-window.sh` | 用 `CGWindowListCopyWindowInfo` 读窗口元数据（零权限），`--watch` 报告出现/消失时刻 |
| P0 实验脚本 | `scripts/spike-*.{sh,swift}` | 重载策略 / 切桌面 / 停机时长 / 探测（含显示器 UUID 映射） |
| 打包脚本 | `scripts/build-app.sh` | 编译 → 组装 `.app` → ad-hoc 签名 |
| 测试 | `Tests/MultiDockTests/` | **239 个测试，全绿**（其中 4 个真实 Dock 验收默认跳过，需显式开启） |
| 设计文档 | `docs/PLAN.md` | 已按 P0 结论修订 |
| 实验结论 | `docs/spikes.md` | 5 个实验的原始数据与决定（**实验 5 是 P3 挖出的两个要命发现**） |

### 已完成：P2（编辑条 + 应用）✅ 2026-09-18

**这是本项目第一次真的写 `com.apple.dock`。** 规格见 `docs/PLAN.md` §3.4–§3.7，验收证据见 §8 第 5 次记录。

**实现要点（改动时别踩）**：

1. **`DockController` 的顺序不能改**：指纹短路 → 备份（失败只记 `note`，不阻断）→ 读全量域 → `entries(for:restrictedTo:)` 只挑**域里真实存在**的键 → 单次原子写 → 重启 Dock → 读回校验；不一致**最多重试一次**（`for attempt in 1...2`）。校验只比**实际写进去的那些键**（`comparableKeys`），把本机缺失的键算进去会产生假阴性。
2. **绝不写当前域里不存在的键**。本机 34 个键里只有 `show-process-indicators` 是白名单中缺失的（`autohide-delay` / `autohide-time-modifier` 读回来是 nil，压根不进 `domainEntries`）。`DockAppearance.unavailableKeys(in:)` 负责报告，UI 据此禁用控件，不做"能改但没反应"的假开关。
3. **启动台条目原样保留**：`DockStripRules.normalizedApps` 优先复用数组里已有的启动台条目（连 `GUID` / `book` / `file-mod-date` 一起），只有域里没有时才 `makeLaunchpadTile()` 现造。早先版本无条件覆盖它，每次编辑都会抹掉真实域里那几个字段。
4. **`.app` 的 URL 要带尾斜杠**（`file:///Applications/X.app/`）：`URL.absoluteString` 不带，与真实域和 P0 的写入实验都不一致。统一走 `DockTile.directoryURLString(for:)`。
5. **用户 App 的 `dock-extra` 是 `true`**，启动台是 `false`（本机实测）。`makeFileTile` 默认 `true`。
6. **拖拽排序只在 `performDrop` 时落盘 + 应用一次**。`dropEntered` 会连续触发，所以 `AppState.setDefaultDock` 只改内存、`dockConfigEdited` 才落盘。否则拖过一个图标就写一次 `config.json` 并重启一次 Dock。
7. **退出还原有门槛**：`LifecycleController.shouldTerminate` 只在 `sessionChangedDock`（会话标记里的 `appliedFingerprint != nil`）时才还原。**不能无条件还原** —— 用户可能在运行期间自己拖了图标，写回基准会把他的改动一起抹掉。另外 `AppState.restoreToBaseline` 会比一次白名单键，已经与基准一致就跳过（省掉一次没必要的 Dock 重启）。
8. **`DockController.onOutcome` 是 `var` 而不是 `let`**：`AppState.init` 里要先构造 controller 再挂回调（闭包要捕获 `self`），`let` 做不到。

### 已完成：P3（桌面页 + 自动切换）✅ 2026-09-18

规格见 `docs/PLAN.md` §3.7 / §3.8，验收证据见 §8 第 6 次记录，两个要命发现见 `docs/spikes.md` 实验 5。

**实现要点（改动时别踩）**：

1. **预应用 = "同一拍发起"，不是"切空间前完成重启"**。`switchToNextDesktop()` / `switchTo(_:)` 先 `switcher.target(_:)` 算目标 → `applyConfigForDesktop(target)` → 再 `switcher.switchTo(target)`。**切空间前完成重启物理上做不到**：重启约 101 ms > `setCurrentSpace` 约 20 ms。真实保证是"不等 300 ms 轮询"。别按字面去"修正"这个顺序。
2. **`DockReloader.minimumSpacing`（默认 1 s）不能去掉**。实测距上次重启不足约 1 s 时再重启，Dock 要 **约 1070 ms** 才归位；间隔满 1 s 只要约 70 ms。等待期间 Dock **可用**，所以"等"严格优于"立刻重启"。实测把 Dock 不可用时长从约 1030 ms 压到 **45–90 ms**。`ReloadOutcome.elapsed` 只算不可用时间，`spacingWait` 单独记。
3. **`RealDockProcessControl.signal(_:_:)` 的安全闸门不能去掉**。`NSRunningApplication` 在 Dock 重启窗口里会返回 `processIdentifier == -1`（**实测复现**），而 `kill(-1, SIGTERM)` 会杀掉**当前用户的所有进程**。三道防线：`dockPID()` 过滤 `> 0`、`signal()` 拒绝 `pid <= 0` 且用 `proc_name` 确认进程名、`waitForRestart` 只接受 `pid > 0`。测试在 `DockProcessSafetyTests`（全部用**信号 0** 断言，闸门坏了是测试失败而不是打死测试进程）。
4. **查 Dock PID 不要用 `pgrep` 子进程**（单次约 110 ms）。用 `proc_listpids` + `proc_name`（**0.02 ms**）。`DockProcessSafetyTests` 有测试守平均耗时 < 20 ms。
5. **编辑器的读写要分开**：`AppState.setDockConfigInMemory` / `setDockAppearanceInMemory` 只改内存，`dockEdited(_:reason:)` 才落盘 + 按开关应用。`DockAppearanceEditor` 的 `onCommit` 只在**滑杆松手 / 开关值变化**时触发 —— 逐帧落盘会让拖一次滑杆重启几十次 Dock。
6. **`DockEditTarget` 是默认 Dock 与逐桌面 override 的统一入口**（`dockConfig(for:)` / `setDockConfigInMemory(_:for:)` / `dockEdited(_:reason:)`）。通用页与桌面页共用一套，别各写一遍。
7. **`DesktopBinding.updating(_:for:_:)` 是绑定列表的唯一改法**：改一条（不存在就插入），改完若「既无名字又无 override」就删掉。改名与改 override 共用它，避免一边删空绑定一边不删。
8. **`DockWatcher` 的判据是"可比指纹变了、且不等于我们写下去的那份"**。`appliedFingerprint == nil`（本次运行还没写过）时**一律不动**，否则会把用户原来的 Dock 当成"该回存的改动"。`handleDockOutcome` 在 `.applied` 时会 `acknowledge` 一次，回存期间也会停 watcher —— 都是为了不把自己的写入当成用户改动。
9. **`DockController.isApplying`** 是给"预应用"做断言用的：`request()` 同步建任务，所以 `switchToNextDesktop()` 返回后立刻读它必须是 `true`。

### 已完成：P4（无痕与自愈）✅ 2026-09-18

规格见 `docs/PLAN.md` §3.11 / §5，验收证据见 §8 第 7 次记录。

**实现要点（改动时别踩）**：

1. **退出还原前必须先 `await state.prepareForTermination()`**。它做三件事：停 `DockWatcher`、停存活监视器、`await dockController.waitForIdle()`。**最后一件不能省** —— `DockController.request` 是异步排队的，如果还原之前还有一笔待办没落地，它会在还原**之后**才写进去，用户看到的结果是"退出时还原了，Dock 却还是错的"。自愈任务也要一起等（`waitForSelfHeal()`），否则两笔写入互相覆盖。
2. **还原失败时会话标记必须留下**（`LifecycleController.keepMarkerAndFinish`）。清掉标记 = 把下次启动的自愈能力一起扔了。留下时还要 `marker.pid = 0` —— `detectInterruptedSession()` 会用 `kill(pid, 0)` 判断"标记是不是另一个还活着的实例"，pid 为 0 时它跳过这个检查。**这两件事缺一不可**，只留标记不改 pid 的话，下次启动会因为"进程还活着"把它忽略掉（实测踩过）。
3. **自愈债务要能跨会话继承**（`SessionMarker.needsSelfHeal`）。自愈是异步的，还原途中再崩一次不能让债务丢掉：`beginSession()` 会看 `state.hasPendingSelfHeal` 把债务写进新标记。字段是**可选类型** —— 老版本写的 `session.state` 里没有它，用非可选会让解码失败，而解码失败等于"没有残留标记"，会静默丢掉自愈能力。
4. **`sessionChangedDock` 的判据是 `marker.impliesDirtyDock`**（`appliedFingerprint != nil` **或** `needsSelfHeal == true`），不只是"本次运行写过没有" —— 上次没还完的债务也算。
5. **节流窗口按 Dock 进程的年龄算，不按我们的记忆算**。见 §4 的"节流窗口判据"一条。这是 P4 验收逼出来的修正。
6. **备份恢复只写白名单键**，不做整域替换。我们自己从来只碰白名单键，备份里白名单之外的键与我们无关；整域替换反而会把用户后来改的热角、启动台网格冲回旧值 —— 那才是真的破坏。需要整域恢复的场景（Dock 被别的东西改坏了）README 里给 `defaults import` 的做法。
7. **`mru-spaces` 是白名单之外的唯一写入例外**，只给它一个窄方法（`DockPreferences.writeMRUSpaces(_:)`），**不开放**通用的"写某个键"口子。写完之后它**不在** `DockController.apply` 的管辖范围内，必须单独 `dockController.reloadOnly()` 重启一次 Dock 才生效。
8. **登录启动的状态属于系统**（`SMAppService` / LaunchAgent plist），**不存进 `config.json`** —— 本地再存一份迟早和系统不一致。非 `.app` 环境（`swift test`）里 `SMAppService.mainApp` 拿不到有效句柄，所以 `LoginItem.isAvailable` 先看 bundle，不可用就如实显示原因。
9. **注销/关机这条路系统不给等待时间**，只能尽力：先把债务写进标记，再发起一次还原并等它跑完；没跑完的由下次启动自愈接手。**不要**改成"同步阻塞等还原"，那会拖住关机。

### 未完成（计划里已定义、代码里还没有）

**P5（整段未开始）**

- 多显示器 / 热插拔回归、全屏过滤回归、**README 重写**（含完全卸载与还原步骤）。

**散落在计划各处、代码里确实没有的（2026-09-18 全量核对得出，见 §6.3 B11–B14）**

| # | 缺什么 | 计划出处 |
| --- | --- | --- |
| B11 | **README 仍停在 P1 状态** —— 写着"P0 与 P1 已完成""还不能改 Dock"，卸载节自认"P5 再补"。与代码严重脱节 | `docs/PLAN.md` §2 文件树注释、§4 P5 |
| B12 | **编辑条竖排**：`orientation` 改成 left/right 后图标条仍固定横排 | `docs/PLAN.md` §3.6 第 5 条 |
| B13 | **孤儿绑定**：桌面被系统删除/重排后，绑定既不清理也不提示，会一直堆在 `config.json` | `docs/PLAN.md` §5 最后一行 |
| B14 | **`DockWatcher` 回存前不存历史版本**，直接覆盖（备份轮转只覆盖写 Dock 那一刻，回存只改 config 不写 Dock，兜不住） | `docs/PLAN.md` §3.8 结尾、§5 |

**另两处"做了但没做全"（优先级低）**

- **Dock 拉不回时没有 UI 提示**：`DockPresenceMonitor` 拉回失败只记日志「会继续重试」，计划要求"仍异常则提示从备份恢复"。见 `docs/PLAN.md` §3.9 第 3 条。
- **降级报警只进日志和调试面板**：`AppState.spaceProviderWarning` 没有在设置窗口顶部显示横幅。计划要求"在 UI 明确报警"。见 `docs/PLAN.md` §3.1 末段。

### 下一步：P5（收尾）

`docs/PLAN.md` §4 的 P5 行只有两条，但建议按这个顺序做：

1. **README**（最该先做）：完整安装、使用、**完全卸载与还原**三步。用户要能把 Dock 彻底恢复原样 ——
   `./scripts/build-app.sh` 装了什么、`defaults import com.apple.dock /tmp/…` 怎么还原、`~/Library/Application Support/MultiDock/` 删什么。
2. **多显示器 / 热插拔回归**：`(displayUUID, spaceUUID)` 映射在插拔外接显示器后不能串。
   本机是单显示器，**这条只能靠用户插拔外接屏实测**，别硬编造结论。toast 的 `displayUUID` → `NSScreen` 映射已有回落 `NSScreen.main`。
3. **全屏过滤回归**：全屏 App 空间不触发 Dock 切换（`type != 0` 过滤），P1 单测覆盖过，P5 用真实全屏 App 再走一遍。

### 用户必须手测的 5 条（无法脚本化，见 §6.3 A 组）

**A4 是 `DockWatcher` 回存路径唯一的真实验证** —— 其余都有自动化覆盖。

---
### 已完成：P2.5（桌面命名 + 切换 toast，不写 Dock）✅ 2026-09-18

用户已明确要的功能，且完全不碰 Dock，所以插在 P2 之前做掉了。规格与验收证据见 `docs/PLAN.md` §3.10 / §4。

**实现要点（改动时别踩）**：

1. `DesktopNaming`（`Spaces/`）是**唯一的命名入口**：`normalize`（CRLF/换行折空格 → 去首尾空白 → 按字素簇截到 10）、`displayName(for:bindings:)`、`updatingBindings`（改名只动 `customName`，**不碰 `override`**；名字清空且无 override 时删掉整条绑定）。
2. **所有 UI 都必须走 `AppState.displayName(for:)`**，不要再直接用 `space.displayName`（那是纯序号名「桌面 N」）。已替换：菜单栏下拉、日志、设置页、调试面板。
3. **改名输入框不做即时截断**：中文输入法组字期间改写绑定值会打断候选词。草稿放 SwiftUI 本地 `@State`，回车/失焦时提交归一化，计数实时显示 `n/10`。
4. **`AppSettings` 改成了手写 `init(from:)`**，每个字段 `decodeIfPresent` 兜默认值。原因：合成的解码器遇到旧配置文件里缺的新键会抛错，而 `ConfigStore.load()` 失败时返回**整份默认配置** → 用户已有设置会被静默清空。**以后每加一个设置字段，必须在这里补一行。**
5. toast 触发点只有 `SpaceObserver.onActiveSpaceChanged` 一个；`ToastPresenter` 用 `lastDesktop` 记账，**全屏空间（nil）会把它清成 nil**，于是「启动首次采样」和「从全屏退回桌面」都不弹。开关关闭时**仍要记账**（否则打开开关会补弹一次）。
6. `DesktopNameToastWindow` 的窗口属性是硬约束：`collectionBehavior` 必须含 `.canJoinAllSpaces` + `.fullScreenAuxiliary`（少了就只在自己所在空间显示，切过去反而看不见）、`canBecomeKey`/`canBecomeMain` = false、`ignoresMouseEvents` = true、`level = .statusBar`、用 `orderFrontRegardless()` 显示。

---

## 4. 已验证的环境事实（别再重复探测）

开发机：**macOS 15.7.9 (24G830)、x86_64、单显示器、Xcode 26.3、Swift 6.2.4**。换机器需重新验证。

| 项 | 结论 |
| --- | --- |
| 桌面切换通知 | `NSWorkspaceActiveSpaceDidChangeNotification` 是公开 API，但**程序化切桌面时根本不触发**（对照实验已排除环境因素：同进程能正常收到 `didActivateApplication`）→ 事件源必须是轮询 |
| 枚举桌面 | `dlopen` SkyLight 成功，`CGSCopyManagedDisplaySpaces` / `CGSGetActiveSpace` / `CGSMainConnectionID` 可用 |
| 空间字典字段 | 键是 **`uuid`** / `ManagedSpaceID` / `id64` / `type` / `WindowManagerInfo`（**不是** `ManagedSpaceUUID`）；display 字典另有 `Current Space` 可直取当前空间。**无名称字段** → App 内命名只能存本地 |
| **displayUUID → `NSScreen` 映射** | ✅ **实测一致**（2026-09-18）：`CGDisplayCreateUUIDFromDisplayID(NSScreen.deviceDescription["NSScreenNumber"])` = `AB24BB32-C5EC-D10A-6F9D-F01F35552F60`，与 SkyLight 的 `Display Identifier` 逐字符相同 → 能把 toast 放到正确的显示器上。探测脚本 `scripts/spike-probe.swift`（已加 `screens` 段，文本与 `--json` 两种输出都有） |
| 屏幕几何 | 主屏 `frame` = (0,0,1920,1200)，`visibleFrame` = (0,53,1920,1147)（Dock 在底部未自动隐藏）。toast 定位用 `visibleFrame`，天然避开菜单栏与 Dock |
| **toast 窗口几何（实测）** | 距可见区顶部 80 pt、水平居中时窗口落在 `x=916 y=80 w=87 h=39`（名字「桌面 2」）与 `x=863 y=80 w=193 h=39`（10 个中文）→ 窗口中心 959.5 ≈ 主屏 midX 960 ✅。`layer=25`、`alpha=1.00` |
| **`orderOut` 后窗口会在 CG 窗口列表里滞留** | 窗口被 `orderOut` 后 `kCGWindowIsOnscreen` 立刻变 false，但那条记录**还会在列表里留好几秒**才真正消失。用窗口元数据核对「消失」时刻时**必须滤掉 `onscreen == false`**，否则时长会晚报 |
| **`CGWindowListCopyWindowInfo` 读元数据零权限** | 实测在无屏幕录制权限下能读到 `kCGWindowLayer` / `kCGWindowAlpha` / `kCGWindowBounds` / `kCGWindowIsOnscreen`（**读不到 `kCGWindowName`**，那是被系统抹掉的）。所以窗口类验收完全不需要权限 |
| 菜单栏图标（补充） | 自动隐藏菜单栏时状态栏窗口在 `y=-24`、`onscreen=false`、约 51×24 —— 与 toast（`y=80`、高 39、水平居中）天然可区分 |
| 主动切桌面 | `CGSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID)` **可用**，约 **20 ms** 生效，带系统自带动画；无动画时长控制符号 |
| Dock 热重载 | **不存在**。post `com.apple.dock.prefchanged`（darwin 与分布式两种都试过）完全无效 |
| Dock 重启 | `kill -HUP`：进程消失于 +13 ms、归位 +101 ms（**总不可用约 101 ms**）。`kill -TERM`：Dock 先做约 255 ms 清理，总不可用 **约 367–395 ms**。**主路径选 SIGHUP** |
| **launchd 的重启节流**（P3 实测，`spikes.md` 实验 5） | 距上一次重启**不足约 1 秒**时再次重启，Dock 要 **约 1070 ms** 才归位；间隔 **≥ 1 秒**只要 **约 70 ms**。阈值在 0.6–1.0 s 之间。`com.apple.Dock.plist` 里**没有** `ThrottleInterval`，是 launchd 的隐式节流。→ `DockReloader.minimumSpacing` 默认 1 s 先等再重启（等待期间 Dock 可用），实测 Dock 不可用时长 **45–90 ms** |
| **节流窗口的判据是 Dock 进程的年龄，不是我们的记忆**（P4 实测修正） | 节流是**按服务**算的，与我们记不记得自己重启过无关。P4 验收里前一条用例刚重启完 Dock，紧接着新建的 `DockReloader`（`lastRestartAt` 为 nil）直接重启，被节流到 **1030 ms** —— 用户会看到 Dock 消失一秒多。→ 改成用 `proc_pidinfo(PROC_PIDTBSDINFO)` 读 `pbi_start_tvsec/tvusec` 算进程年龄（实测返回 **136 字节 = 结构体大小**，读得到）。改完 P3 第一轮从 **1030 ms → 45 ms**。拿不到年龄才退回内存记忆 |
| **`kill -9` 掉 Dock 后的恢复** | 实测 **1072 ms** 归位（`KeepAlive` 让 launchd 拉起它，但会先吃一次隐式节流，所以不是 100 ms 级）。判据：3 秒内必须出现**新的正数 PID**。`DockPresenceMonitor` 是兜底（连续缺失 2 次才动手，之后每 4 轮重试一次 `kickstart`） |
| **`NSRunningApplication` 会返回 `processIdentifier == -1`** | Dock 重启窗口里 `runningApplications(withBundleIdentifier: "com.apple.dock")` 会返回一个**正在退出**的实例，其 PID 是 **-1**（实测复现）。`kill(-1, sig)` = 发给**当前用户全部进程**，`kill(0, sig)` = 整个进程组。**必须过滤 `> 0`，并在发信号前用 `proc_name` 确认进程名是 `Dock`** |
| **查 Dock PID 的代价** | `NSRunningApplication` **0.6–1.4 ms**；`/usr/bin/pgrep -x Dock` **109–112 ms**（子进程，绝不能放进轮询热路径）；`proc_listpids(PROC_ALL_PIDS)` + `proc_name` **0.02 ms** |
| Dock 进程守护 | `/System/Library/LaunchAgents/com.apple.Dock.plist` 为 `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}` → 必须信号致死才会被拉起；**优雅退出（exit 0）不会重启，用户会当场失去 Dock** |
| **Dock 是否应用了写入** | 判据：写入的 tile 不带 `GUID`，Dock 真正读取并应用后会**补上 `GUID`**。实测正负两种情形都验证过。**回写是异步的**：P2 验收里 apply 返回后立刻读还是 `nil`，轮询 200 ms 内就出现了 → 判据要配轮询，别读完就断言 |
| **只写白名单键：已实测成立** | P2 验收（2026-09-18）：apply 一次（改 `tilesize` + `magnification` + 加一个 Calculator 条目）后与操作前全量域 diff，**变化只有 `magnification` / `persistent-apps` / `tilesize`**，白名单外的键一个都没动 |
| **写外观键真的生效** | `tilesize` 36 → 52、`magnification` 翻转，写入后域里的值就是新值，且 Dock 重启（PID 变化）。`persistent-apps` 的新条目被补上 `GUID`（实测 `i:1414651200` 等，每次不同）→ Dock 确实按新偏好重建了 Dock |
| **本机白名单键的可用性（逐键实测）** | **可用**：`persistent-apps` `persistent-others` `orientation` `tilesize` `magnification` `largesize` `autohide` `mineffect` `minimize-to-application`。**不存在**：`show-process-indicators`（域里没有）。`autohide-delay` / `autohide-time-modifier` 域里也没有，且 `DockAppearance.read` 读回来是 nil → 压根不进写入集合。结论：**只写"域里已有的键"这条规则就够了**，不需要额外黑名单 |
| **Dock 自己会改的键** | 重启一次 Dock，`mod-count` 就 +1；`recent-apps` 也会变。这两个**不在白名单里、我们从不写**，所以验收时"还原后仍有差异"是正常的。判据是：**差异只能落在白名单键或 `{mod-count, recent-apps, trash-full}` 上** |
| **SIGHUP 实测耗时（P2 复测）** | 连续多次 apply 都是 **125–138 ms**，与 P0 的 101 ms 同一量级。还原路径同样 136–138 ms |
| **`pgrep -x Dock` 可作 PID 兜底** | `NSRunningApplication.runningApplications(withBundleIdentifier:)` 在非 `.app` 进程（`swift test` 的 xctest runner）里可能查不到，`RealDockProcessControl.dockPID()` 用 `pgrep -x Dock` 兜底 |
| Finder | `persistent-apps` 里没有 Finder；**全量域 34 个键里没有任何 Finder 相关键或值** → 写偏好无法删除它，"钉住"天然成立，无需代码 |
| Dock 偏好域 | 34 个键；`persistent-apps` 15 项（首项 Launchpad，`file-type=169`、`dock-extra=false`、`bundle-identifier=com.apple.launchpad.launcher`）、`persistent-others` 1 项（下载文件夹）。用户 App 是 `file-type=41`、`dock-extra=true`。**没有** `show-process-indicators` / `autohide-delay` / `autohide-time-modifier` |
| **`.app` 的 `_CFURLString` 带尾斜杠** | 真实域里是 `file:///System/Applications/Launchpad.app/`。`URL(fileURLWithPath:).absoluteString` **不带**尾斜杠 → 必须自己补（`DockTile.directoryURLString(for:)`） |
| **写偏好会不会污染别的键：不会** | `CFPreferencesSetMultiple` + 全量域读回 + 只覆盖白名单键，实测 `mru-spaces` / `wvous-*` / `mod-count` / `recent-apps` 全部原样 |
| **`plutil -p` 比对长数组会错位** | 用 `diff` 比对 `plutil -p` 导出的文本时，数组元素行数不同会导致后面整体错位，产生**假差异**。要判断"成员/顺序变了"就抽出标签序列比，要判断"值变了"就用 `PlistValue` 结构比较（验收测试里 `differences(between:and:)` 就是这么做的） |
| **测试窗口期内别手动改 Dock** | 实测踩过：验收跑到一半 Dock 被外部改动（`persistent-others` 从 4 项变 1 项），"还原后仍有差异"报了假失败 |
| 多显示器空间 | `com.apple.spaces spans-displays` 不存在 → 默认"显示器各自独立空间"，映射键需 `(displayUUID, spaceUUID)` |
| **`SMAppService.mainApp` 只在 `.app` 里可用** | `swift test` / `swift run` 的进程不是 bundle（`Bundle.main.bundlePath` 不以 `.app` 结尾），拿不到有效的登录项句柄。所以 `LoginItem.isAvailable` 先看 bundle，不可用时 UI 直接显示原因 —— **不要**在非 bundle 环境里调 `SMAppService.mainApp.status` |
| **历史备份的命名** | `~/Library/Application Support/MultiDock/backups/dock-yyyyMMdd-HHmmss.plist`，最多 20 份。`BaselineStore.listBackups()` 从文件名解析时刻；解析不出来（用户改过名）就退回文件修改时间 |
| 风险项 | 本机 `mru-spaces = 1`（自动重排空间），会打乱桌面顺序、破坏"下一个桌面"直觉 → 设置页给显式开关，**用户主动点击才改** |
| 截图验证不可用 | 本机未授予屏幕录制权限，`screencapture` 只返回壁纸（无菜单栏、无窗口）。**验收请用 `multidock.log` 或调试面板，不要依赖截图** |
| `log show` 不可用 | 在沙箱环境下 `/usr/bin/log show` 报 `Cannot run while sandboxed` → 所以日志**同时落盘**到 `multidock.log` |
| 菜单栏图标 | 本机 `_HIHideMenuBar = 1`（自动隐藏菜单栏），所以状态栏窗口在 `y=-24`、`onscreen=false` 是正常的，不是 bug。可用 `CGWindowListCopyWindowInfo` 查 layer 25 的窗口来确认图标已创建 |
| Dock 窗口几何 | Dock 的窗口是**全屏容器**（1920×1200，layer 20），**不能**用来判断图标数量或 tilesize |

**复现私有 API 探测的方法**：见 `scripts/spike-probe.swift`（Swift 版，比 ctypes 干净）。
注意 plist 格式常量：XML=100、Binary=200、OpenStep=1（写错会 segfault）。

---

## 5. 工程约定

### 构建与运行

```bash
swift build -c release --disable-sandbox   # 编译
swift test --disable-sandbox               # 239 个测试（含 4 个默认跳过的真实 Dock 验收）
./scripts/build-app.sh                     # 组装 build/MultiDock.app（ad-hoc 签名）
open build/MultiDock.app                   # 运行（必须在 .app 里跑，菜单栏图标才正常）
./scripts/check-toast-window.sh --watch 12 # 客观验收 toast（零权限，读窗口元数据）

# 真实 Dock 验收：会真的改 com.apple.dock 并重启 Dock，跑完自动还原
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests
```

- ⚠️ **必须加 `--disable-sandbox`**（2026-09-18 起）。SwiftPM 自己的 `sandbox-exec` 在本机环境里会 `sandbox_apply: Operation not permitted`，manifest 编译直接失败，报 `error: 'multi-dock': Invalid manifest`。这不是代码问题，加了这个参数就好。
- **`swift test` 现在可用了**：`Package.swift` 已加 `MultiDockTests` 测试目标。（旧版这里写的"会报 no tests found"已过时。）
- **真实 Dock 验收默认跳过**（`DockAcceptanceTests`，靠环境变量开启）。它会写 `com.apple.dock` 并重启 Dock 几十次，跑完把操作前的全量域写回去；中间产物落在 `/tmp/multidock-acceptance-*.plist`。**跑的时候别手动改 Dock**，否则会报假失败。
- 想更保险就先手工备份：`defaults export com.apple.dock /tmp/dock-backup.plist`。
- **写 Swift 小工具时注意 stdout 缓冲**：重定向到文件时是块缓冲，观察类脚本要 `setvbuf(stdout, nil, _IONBF, 0)`，否则一行都看不到（`check-toast-window.sh` 已这么处理）。
- 反复调用的 Swift 探测工具要**编译一次缓存复用**（`swiftc -O -o /tmp/... `），别每次 `swift file.swift` —— 那是每次都完整编译，几十毫秒级轮询根本跑不动。
- **测 Dock 重启耗时别用 `pgrep` 轮询**：单次约 110 ms，会把测量结果整个污染掉（实测把 70 ms 测成 400 ms）。用 `NSRunningApplication`（0.6 ms）或 `proc_listpids`（0.02 ms）。
- 打包脚本用的是 `codesign --force --sign -`，不是计划原文写的 `--deep`（Apple 已废弃 `--deep`）。
- 也可以直接用 Xcode 打开 `Package.swift`，但**不要**手写 `.xcodeproj`。
- **仓库已初始化**（`git init -b main`，首个 commit `e3e359a`，见 §8）。提交签名走 1Password，**提交前先确认 1Password 在跑并且已解锁**（见 §0）。
- **不要用 `rm -rf .build/...` 清缓存**：本机有 safe-delete 保护会拦截。要全新构建请用
  `swift build -c release --disable-sandbox --build-path /tmp/multidock-build`。

### 代码约定

- `swift-tools-version: 6.0` → **Swift 6 语言模式、严格并发检查**已开启。当前构建**零警告零错误**，保持住。
- `@Observable` + `@MainActor` 用于状态类。**不要把空间状态在 `AppState` 里复制一份**——转发给 `SpaceObserver`，否则两份会不同步。
- `@convention(c)` 函数指针类型如果声明为 `private`，顶层 `let` 引用它时必须也标 `private`，否则报 "uses a private type"。
- 私有 API 一律用 `dlopen` + `dlsym` 运行时加载，**不要链接私有框架**。
- 写 Dock 偏好用 `CFPreferences` API，不要拼 `defaults` 命令行。写入策略：读**全量**域 → 只覆盖白名单键 → 单次原子写回，绝不整域替换。
- 代码不写解释性注释；只在"为什么"不显然时才写。
- 新增功能必须有对应的实测验证，不接受"编译通过就算完成"。
- **给 `AppSettings` 加字段时，必须同时在它手写的 `init(from:)` 里补一行 `decodeIfPresent`**，否则旧配置文件缺这个键会导致整份配置解码失败、静默退回默认值（`ConfigStore.load()` 的行为）。
- **可测性拆分**：跟 AppKit / 系统调用打交道的部分（窗口、私有 API、Dock 进程）单独放一个类型并抽成协议（`ToastPresenting`、`SpaceProviding`、`DockPreferenceAccessing`、`DockProcessControlling`），纯逻辑放另一个类型。这样行为能单测，剩下的才靠实测。
- **`AppState` 的依赖全部可注入**（`dockController` / `configStore` / `baselineStore` / `provider`），并且 **AppState 内部不要直接调 `DockPreferences.readDomain()` 这类静态入口** —— 那会绕过注入点，测试里会读到真实系统的偏好域。要读就走 `dockController.readDomain()` / `captureLiveConfig()`。（P2 踩过：`captureCurrentDockAsDefault` 就是直接调静态方法，导致三个单测读到真实 Dock。）`provider` 可注入是为了让"预应用先于切换"能写成断言。
- **测试里的替身类如果被 `@MainActor` 测试类嵌套，要显式标 `@MainActor`**：嵌套类型**不继承**外层的 actor 隔离，而 `DockWatcher` 的闭包都是 `@MainActor` 的，不标就报 `call to main actor-isolated initializer in a synchronous nonisolated context`。
- **发信号/杀进程的代码必须自带"只碰确认过的 PID"闸门**，别指望调用方传对。见 §4 的 `-1` 陷阱。
- **文件末尾的 `try` / `defer` 里不要阻塞主线程**：`@MainActor` 的异步测试里 `DispatchSemaphore.wait` 会死锁（`Task { @MainActor }` 永远排不上）。要在收尾还原，就写 `do { try await ... } catch { await cleanup(); throw error }` + 正常路径显式收尾。

### 与计划原文的两处刻意偏离（不要"改回去"）

1. **`UI/MenuBarController.swift` 取代计划里的 `UI/MenuBarView.swift`**，程序入口用 `NSApplication` 而非 SwiftUI `App` + `MenuBarExtra`。原因：硬约束要求区分左键/右键/⌥+左键，`MenuBarExtra` 的点击一律被它自己吃掉，做不到。设置窗口与调试面板仍是 SwiftUI（`NSHostingController` 承载）。
2. **`DockTile.raw` 的类型是 `[String: PlistValue]` 而不是计划写的 `[String: Any]`**。原因：`[String: Any]` 不满足 `Codable`，无法落盘到 `config.json`。`PlistValue` 是一个覆盖全部 plist 类型的枚举，并提供与 `Any` 的双向转换。

### 设计文档的维护

`docs/PLAN.md` 是设计与进度的权威副本；`docs/spikes.md` 是 P0 实测结论。实现中设计若有变化，**同步更新 `docs/PLAN.md`**，不要让文档和代码脱节。

---

## 6. 待确认问题与未解决的问题

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
| A4 | **P3 验收里"在真实 Dock 手动拖入一个图标，切走再切回仍在"**（拖拽是纯 UI 操作，脚本化要辅助功能权限，与硬约束冲突） | 这条是 `DockWatcher` **回存路径的唯一真实检验** | 请手动：拖一个图标进 Dock → 切到另一个桌面 → 切回来，看图标还在不在 |
| A5 | **「连切 5 次只显示最终名字」只做了单测**，没做真机连击 | 真机是否闪烁未实测 | 单测 `testRapidSwitchKeepsOnlyLatestTextAndHidesOnce` 覆盖调度逻辑；真机需手动快速点菜单栏 |
| **B. 待做的功能（已排期）** | | | |
| B5 | **多显示器**：本机单显示器，`(displayUUID, spaceUUID)` 映射键只写了没实测 | 插外接显示器后映射可能串 | P5，**只能靠用户插拔外接屏实测** |
| B6 | **全屏 App 空间的过滤**只有单测覆盖，没有真实全屏回归 | 每次进全屏可能误切 Dock | P5 |
| B7 | **用户手动切桌面时 `activeSpaceDidChange` 通知是否触发**未知 | 只影响"能否把跟随延迟从 300 ms 降到接近 0" | P5 顺手测 |
| B8 | **手动移除 Finder 是否落键**未验证 | 若有新键需纳入白名单 | 可选，30 秒。步骤见 `docs/spikes.md` 实验 3，风险低 |
| B9 | **注销/关机路径只能尽力还原**（系统不给等待时间） | 关机瞬间可能来不及写完基准 | 已按"先留债务标记、下次启动自愈"处理，见 §3 的 P4 第 9 条。真要验证得注销一次机器 |
| B10 | **登录启动的 LaunchAgent 退回方案没在真机跑过**（本机 SMAppService 那条路没触发过退回） | 未签名场景下可能开了没用 | 需要真的重登录一次验证。逻辑侧只有 plist 内容有单测 |
| B11 | **README 还停在 P1 状态**（2026-09-18 全量核对发现）：仍写"P0 与 P1 已完成""还不能改 Dock"，卸载节自认"P5 再补" | 用户照 README 操作会得到错误信息 | **P5 第一件事**。要写：完全卸载三步、用基准/备份还原 `com.apple.dock` 的精确命令、P2–P4 已有能力 |
| B12 | **编辑条竖排未实现**：`orientation` = left/right 时图标条仍固定横排 | 位置改成左/右后，编辑条与实际 Dock 长得不一样 | P5，纯 UI，改动局限在 `UI/DockStripEditor.swift` |
| B13 | **孤儿绑定不清理也不提示**：桌面被系统删除/重排后，`DesktopBinding` 永久留在 `config.json` | 配置越积越多、看不出哪些还有效 | P5。建议：设置页给"清理无效绑定"入口，或对当前桌面列表里不存在的绑定标灰 |
| B14 | **`DockWatcher` 回存前不存历史版本**：直接覆盖目标配置 | 用户手改被误判时，旧配置找不回来 | P5 或不做。备份轮转兜不住（回存只改 config、不写 Dock，不触发备份） |
| **C. 参数与取舍（记录在案）** | | | |
| C1 | **`DockWatcher` 轮询周期 2 s 是拍的**，没有实测依据 | 用户手动改 Dock 后最长 2 s 才被回存 | 按用户体感调 |
| C2 | **一次切换的应用总耗时约 1 秒**（其中 Dock 只消失 45–90 ms，其余是主动错开节流的等待） | 切桌面后 Dock 配置生效有一秒延迟，但期间 Dock 可用 | 按"宁等不闪"处理，见 §6.1 第 6 条 |
| C3 | **「立即还原」与退出还原都只比白名单键**，`mod-count` / `recent-apps` 不会被还原 | 这两个是 Dock 自己的计数器，还原它们没意义 | 有意为之 |
| C4 | **`DockWatcher` 只在"本次运行写过 Dock"后才回存**（`appliedFingerprint != nil`） | 启动后没应用过任何配置时，用户手动改 Dock 不会被回存 | 有意为之：否则会把用户原来的 Dock 当成"该回存的改动" |
| C5 | **节流窗口按 Dock 进程年龄算**（`proc_pidinfo`），不再只依赖内存里的 `lastRestartAt` | 拿不到进程年龄时会退回内存记忆，那种情况下"别人刚重启过 Dock"仍可能让我们吃一次 1 秒节流 | 有意为之：进程年龄是事实，内存是猜测。见 §4 的"节流窗口判据" |
| C6 | **自愈在启动后异步执行**，不阻塞启动 | 启动瞬间 Dock 可能还是脏的，约 1 秒后恢复 | 有意为之：阻塞启动比晚一秒更糟 |
| **D. 已解决（留档，别重复查）** | | | |
| D1 | ~~外观键 `show-process-indicators` / `autohide-delay` / `autohide-time-modifier` 本机不存在~~ | "设置页能改、Dock 没反应" | ✅ 只有 `show-process-indicators` 真缺失；另两个读回来是 nil、不进写入集合。UI 据此禁用控件 |
| D2 | ~~SIGTERM 有约 255 ms 退出清理窗口，Dock 可能回写覆盖我们的写入~~ | 应用不生效 | ✅ `DockController` 写完读回校验、不一致重试一次。实测主路径每次一次过（`verifyAttempts == 1`） |
| D3 | ~~`LifecycleController.restoreHandler` 是空实现~~ | 无痕原则无从实现 | ✅ P2 已接线，且只在 `sessionChangedDock` 时才还原 |
| D4 | ~~`Tests/` 要测"合并（防抖）、还原逻辑"~~ | 覆盖不全 | ✅ 防抖由 `testRapidRequestsCollapseIntoOneApply` 等覆盖；还原由 `AppStateDockTests` 覆盖 |
| D5 | ~~toast 窗口的 `ignoresMouseEvents` / `canBecomeKey = false` 未实测~~ | 抢焦点 | ✅ 已验证：连弹两次期间每 100 ms 采样 `lsappinfo front`，MultiDock 一次都没变前台 |
| D6 | ~~自定义名要替换所有 `displayName` 调用点~~ | 菜单栏与设置页名字不一致 | ✅ 已复查，UI 与日志全部走 `AppState.displayName(for:)` |
| D7 | ~~toast 距顶 80 pt 的观感未调~~ | 偏高/偏低 | ✅ 实测 `y=80`，观感由用户拍板 |
| D8 | ~~toast 在"用户手动切桌面"时是否也弹未实测~~ | 是否符合直觉 | ✅ 已验证：外部进程切桌面时 toast 照常弹 |
| D9 | ~~`DockWatcher` 会把自己的写入误判成用户改动~~ | 配置被污染 | ✅ **P3 实测 20 次来回切换，误判 0 次**（`DockAcceptanceTests`） |
| D10 | ~~预应用会不会导致 Dock 重启两次~~ | 切一次桌面闪两次 | ✅ 实测每次切换**只写一次**（`request()` 单槽位把预应用与 observer 回调合并） |
| D11 | ~~启动自愈还原（强杀/崩溃后写回基准）没做~~ | 用户强杀后 Dock 停在非原始状态 | ✅ P4 已做：残留标记 → 启动后自动还原 + toast 提示。**真实 Dock 验收连开三次幂等**（`testSelfHealIsIdempotentAcrossThreeLaunches`） |
| D12 | ~~人为杀掉 Dock 后没有自动拉回~~ | Dock 消失后要等系统处理 | ✅ P4 已做：`DockPresenceMonitor` 连续缺失达阈值就 `kickstart`。**实测 SIGKILL 后 1072 ms 归位**（上限 3 s） |
| D13 | ~~备份轮转保留 20 份但没有恢复 UI~~ | 用户无法从备份挑一份还原 | ✅ P4 已做：设置 → 通用 → 备份与还原，列最近 5 份 + 二次确认。**只写白名单键** |
| D14 | ~~`mru-spaces = 1` 打乱桌面顺序~~ | 切桌面顺序不符合直觉 | ✅ P4 已做：设置 → 通用 → 桌面行为，显式开关 + 自动重启 Dock 生效。**用户主动点击才改** |
| D15 | ~~退出还原可能被排队的应用覆盖~~ | 退出后 Dock 还是错的 | ✅ P4 已修：还原前 `await prepareForTermination()`（停 watcher/监视器 + 等自愈 + 等 `waitForIdle`） |
| D16 | ~~还原失败后自愈能力丢失~~ | 下次启动不再尝试还原 | ✅ P4 已修：失败保留标记 + `pid = 0` + `needsSelfHeal`，下次启动接着还。单测覆盖 |

---

## 7. 给下一个 session 的建议顺序

1. 读本文件 → `docs/PLAN.md`（§3 核心机制、§3.10 桌面命名与 toast、§3.11 无痕与自愈、§4 阶段与验收）→ `docs/spikes.md`（**6 个实验结论，含对计划的多处修正；实验 5 有两个要命发现，实验 6 是节流窗口的判据修正**）。
2. 跑一次基线：`swift build -c release --disable-sandbox && swift test --disable-sandbox && ./scripts/build-app.sh`，确认全绿（应为 **239 个测试通过、零警告**）。
3. **动 Dock 相关代码前先读 §4 的四条**："launchd 重启节流"、"节流窗口判据"、"`-1` PID 陷阱"、"查 Dock PID 的代价"。踩到节流会让 Dock 消失一秒多；踩到 `-1` 会杀掉用户的全部进程。
4. 需要动 Dock 的改动，验收用 `MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`；**跑之前先 `defaults export com.apple.dock` 备份，且中途别手动改 Dock**。
5. 顺手催一下 §6.3 的 A 组（A1–A5 只能人点）：改名、两个按钮、图标条拖拽、**A4 手动拖图标进 Dock 再切走切回**、菜单栏连击。
6. 做 P5：README（含完全卸载与还原步骤）→ 多显示器/热插拔回归（要用户插外接屏）→ 全屏过滤回归。
7. 收尾：按 §0 更新本文档 + `git commit`。

> ⚠️ **给写代码的 agent 的一条工程提醒**：同一个文件**不要在同一条消息里发两个编辑** ——
> 实测会静默丢掉其中一个（本次会话踩了三次，都是靠编译错误才发现）。一个文件一次改一处。

---

## 8. 会话记录

> append-only，**最新在最上面**。每条记录：这次做了什么 / 当前进度 / 未解决的事。

### 2026-09-18（第 8 次）— 全量核对「文档/计划 vs 代码」，列出未实现清单

**做了什么**（用户：「检查文档和计划中还有哪些没有实现的」）：

- **只读核对，没写业务代码**。把 `docs/PLAN.md` 与 `AGENTS.md` 的每一条承诺逐条对到代码上（`grep` + 读源文件），
  产出「未完成清单」，结论见 §3 的「未完成」段与 §6.3 的 **B11–B14**。
- 结论分四类：
  1. **P5 整段未开始**（README 重写 / 多显示器热插拔回归 / 全屏过滤回归）—— 与 §3 原有记录一致。
  2. **散落的 4 条实现缺口**（新发现，已补进 §6.3）：B11 README 停在 P1、B12 编辑条竖排、
     B13 孤儿绑定不清理不提示、B14 `DockWatcher` 回存不存历史版本。
  3. **两处"做了但没做全"**（已在 §3 记录）：Dock 拉不回时缺 UI 提示（PLAN §3.9 第 3 条）、
     降级报警没进设置页（PLAN §3.1 末段，现在只在日志 + 调试面板）。
  4. **已确认实现、不用再查的**：`NSOpenPanel`「添加到 Dock」、桌面页「复制默认到本桌面」/「重置为默认」/
     「从当前真实 Dock 抓取」/「刷新桌面列表」、备份恢复 UI、`mru-spaces` 开关、登录启动、
     `DockPresenceMonitor` 的 `kickstart` 拉回、toast 的 `displayUUID → NSScreen` 映射与回落。
- **文档错漏已修**：
  - 测试数 **233 → 239**（§3 表格与 §5 构建命令两处，实际 `grep func test` 就是 239）。
  - `docs/PLAN.md` §3.8 引用的「`AGENTS.md` §6.3 B3」**编号不存在**（B 组已从 B5 起）→ 改为 B14。
  - §3「未完成」段从一行扩成完整清单。

**未解决 / 交给下一个 session**：

- **P5 仍是空白**，且 **B11（README）是里面最该先做的** —— 现在 README 会误导用户。
- B12 / B13 / B14 三条要不要做、做到什么程度，等用户拍板（都不是阻塞项）。
- §6.3 **A 组 5 条手测（A1–A5）一次都没做过**，A4 是 `DockWatcher` 回存路径的唯一真实检验。
- B9（注销/关机）、B10（LaunchAgent 退回）需要真的注销/重登录一次。

### 2026-09-18（第 7 次）— 完成 P4：无痕与自愈（**顺带修正了节流窗口的判据**）

**做了什么**（用户：「按计划继续执行，直到计划中的所有阶段都实现（每个阶段实现后 git commit 一次）」）：

- 新增 2 个源文件：`Dock/DockPresenceMonitor.swift`（Dock 被外部弄死时拉回；连续缺失达阈值才动手，之后按间隔重试 `kickstart`）、`App/LoginItem.swift`（`SMAppService.mainApp` 为主，失败退回写 LaunchAgent plist；非 `.app` 环境如实报"不可用"）。
- 新增 3 个测试文件：`DockPresenceMonitorTests`（8）、`StartupSelfHealTests`（14，含自愈/退出标记留存/mru-spaces/备份恢复）、`LoginItemTests`（6）。`FakePreferences` 从 `AppStateDockTests` 内部搬到 `TestSupport.swift` 共用。
- 改了：`BaselineStore.swift`（`SessionMarker.needsSelfHeal` 可选字段 + `BackupEntry` / `listBackups` / `readBackup` / `date(fromBackupName:)`）、`DockReloader.swift`（**节流窗口改按 Dock 进程年龄算** + 协议加 `startTime(of:)`）、`DockController.swift`（`reloadOnly` + `readMRUSpaces` / `writeMRUSpaces` + 协议加 `writeMRUSpaces`）、`DockPreferences.swift`（`readMRUSpaces` / `writeMRUSpaces`，白名单之外的唯一窄口子）、`LifecycleController.swift`（**还原前 `prepareForTermination`**、**失败保留标记 `pid = 0` + `needsSelfHeal`**、`finishTermination` 可注入、`waitForTermination`、关机路径尽力还原）、`AppState.swift`（`pendingSelfHeal` / `performSelfHeal` / `waitForSelfHeal` / `prepareForTermination` / `setMRUSpaces` / `refreshBackups` / `restoreBackup` / `refreshLoginItemStatus` / `setLoginItemEnabled` + `presenceMonitor` 可注入）、`ToastPresenter.swift`（`announce` 无条件提示）、`SettingsView.swift`（新增「启动与自愈」「桌面行为」「备份与还原」三段）、`MenuBarController.swift`（加「立即还原到原始 Dock」）、`AppDelegate.swift`（`restoreHandler` 回传结果 + 设置窗口尺寸与 SwiftUI 对齐）。
- 文档：`docs/PLAN.md`（P4 标 ✅ + §3.11 P4 实现记录 + 5 条新风险行）、`docs/spikes.md`（**实验 6**：节流窗口的判据）、本文件 §2/§3/§4/§5/§6/§7。

**验收证据（真实 Dock，全部实测）**：

- `swift test --disable-sandbox` **239 个测试全绿、零警告**（4 个真实 Dock 验收默认跳过）。
- `MULTIDOCK_DOCK_ACCEPTANCE=1 ... --filter DockAcceptanceTests` **4 个验收全过**：
  - **P4 自愈幂等**：连开三次 → `[已自动还原, 已与原始状态一致, 已与原始状态一致]`，`mod-count` 三次都是 `22569`（第 2、3 次**没有白重启 Dock**）。
  - **P4 杀掉 Dock**：`SIGKILL` 后 **1072 ms 归位**（上限 3 s），恢复后白名单键与键集合都与杀之前一致。
  - **P2**：SIGHUP **51 ms**，变化的键只有 `["magnification", "persistent-apps", "tilesize"]`，新条目被补上 `GUID`（`i:3617337108`）。
  - **P3**：来回切 20 次全过，**Dock 不可用 45–84 ms（最坏 84 ms）**，总耗时 1002–1079 ms，`DockWatcher` 误判 0 次，内容相同短路 0 ms。
  - 三条还原路径结束后差异键都是 **`[]`**、键集合一致（34 键）。

**顺带修正（这次验收真正的收获）**：第一次跑验收时 **P3 第一轮报了 1030 ms 的 Dock 不可用**。根因不是 P3 的代码，而是
**节流窗口的判据错了** —— 原来只记在 `DockReloader.lastRestartAt` 里，而 launchd 的节流是**按服务**算的：
前一条用例刚重启完 Dock，紧接着 P3 新建的 reloader 以为"从没重启过"，于是直接重启、吃了整段节流。
改成按 **Dock 进程年龄**（`proc_pidinfo(PROC_PIDTBSDINFO)`）推算后，第一轮从 **1030 ms → 45 ms**。
这个 bug 在真实使用里对应"用户/别的 App 刚重启过 Dock，我们紧接着切桌面"—— 同样会让 Dock 消失一秒多。

**未解决 / 交给下一个 session**：

- **P5 未开始**：README（含完全卸载与还原步骤）、多显示器/热插拔回归（要用户插外接屏）、全屏过滤回归。
- **§6.3 A 组的 5 条手测还没做**，其中 **A4（手动拖图标进 Dock 再切走切回）是 `DockWatcher` 回存路径唯一的真实验证**。
- 新增两条待验证：**B9 注销/关机路径**（要真注销一次）、**B10 登录启动的 LaunchAgent 退回方案**（本机 SMAppService 没触发过退回，要真重登录一次）。
- 新增两个待用户拍板的问题：§6.1 第 7 条（自愈要不要弹 toast）、第 8 条（登录启动要不要默认打开）。

### 2026-09-18（第 6 次）— 完成 P3：桌面页 + 自动切换（**顺带挖出两个要命 bug**）

**做了什么**（用户：「按计划继续执行，直到计划中的所有阶段都实现（每个阶段实现后 git commit 一次）」）：

- 新增 4 个源文件：`Dock/DockWatcher.swift`（识别用户手动改动 → 回存；纯逻辑 + 注入式读写）、`UI/DockAppearanceEditor.swift`（外观控件，本机不支持的键禁用；`onCommit` 只在松手/值变化时提交）、`UI/DesktopListView.swift`（左列表改名 + 右详情独立 Dock）。
- 新增 3 个测试文件：`DockWatcherTests`（12）、`DockProcessSafetyTests`（7，**安全闸门**）；`DockAcceptanceTests` 加 `testSwitchingBetweenTwoDesktopConfigsIsStable`（真实 Dock 来回切 20 次）。
- 改了：`DockReloader.swift`（**`minimumSpacing` 错开 launchd 节流** + **发信号前的安全闸门** + `pgrep` → `proc_listpids`）、`DockController.swift`（`comparableFingerprint` / `currentComparableFingerprint` / `adoptLiveDockAsApplied` / `readDomain` / `captureLiveConfig` / `isApplying`）、`DockConfig.swift`（`DesktopBinding.updating` 唯一改法）、`DesktopNaming.swift`（override 变体）、`SpaceSwitcher.swift`（拆出 `target(_:)` 供预应用）、`AppState.swift`（**`DockEditTarget` 统一入口** + 逐桌面 override + 预应用 + watcher 接线 + `provider` 可注入 + `resetActiveDesktopConfigFromLiveDock`）、`SettingsView.swift`（删掉旧的 `DesktopsTab`，通用页补回外观控件）、`MenuBarController.swift`（补上计划 §3.7 要求的「用当前 Dock 重置本桌面配置」，退出项标题改成「退出并还原 Dock」）。
- 文档：`docs/spikes.md` **实验 5**（两个要命发现）、`docs/PLAN.md`（P3 标 ✅ + §3.4 第 8 条措辞修正 + §3.7 / §3.8 的 P3 实现记录 + 3 条新风险行）、本文件 §2/§3/§4/§5/§6/§7。

**验收证据（真实 Dock，全部实测）**：

- `swift build -c release --disable-sandbox` 零警告；`swift test --disable-sandbox` **195 个测试全绿**（2 个真实 Dock 验收默认跳过）。
- `MULTIDOCK_DOCK_ACCEPTANCE=1 ... --filter DockAcceptanceTests` 两个测试都过：
  - **P3 来回切 20 次全部成功**；**Dock 不可用时长 45–90 ms**（最坏 90 ms）；应用总耗时约 1050 ms（多出来的是主动错开节流的等待，期间 Dock 可用）。
  - 每次切换后真实域的 `tilesize` / `magnification` 都等于目标那份；`DockWatcher` **误判 0 次**。
  - 两桌面配置相同时 `.skippedIdentical` + `reload == nil` + `mod-count` 不变。
  - 还原后差异键 **`[]`**，图标顺序逐项一致，键集合一致（34 键）。
  - P2 的往返测试仍然通过，且 SIGHUP 耗时从 125–138 ms 降到 **55 ms**。

**两个要命发现（详见 `docs/spikes.md` 实验 5）**：

1. **launchd 重启节流**：距上次重启不足约 1 s 时再重启，Dock 要 **约 1070 ms** 才归位（间隔 ≥ 1 s 只要约 70 ms）。这是 P3 第一次跑出"每轮 1080 ms"的真因。→ `DockReloader.minimumSpacing` 先等再重启，**等待期间 Dock 可用**，把不可用时长压回 45–90 ms。
2. **`NSRunningApplication` 会返回 `processIdentifier == -1`**（Dock 重启窗口里，实测复现）。原实现的兜底路径会走到 **`kill(-1, SIGTERM)` = 杀掉当前用户的所有进程**。已加三道防线 + `DockProcessSafetyTests`（全部用**信号 0** 断言）。

**顺带修掉的浪费**：`pgrep` 子进程单次 **110 ms**，被放在 15 ms 轮询热路径里 → 换成 `proc_listpids` + `proc_name`（**0.02 ms**）。

**未解决的事**：

- §6.3 A 组（A1–A5）只能用户手测；**A4（手动拖图标进 Dock → 切走切回）是 `DockWatcher` 回存路径的唯一真实检验**。
- P4 未开始：启动自愈还原、退出前等重载完成、Dock 消失检测拉回、`mru-spaces` 开关、备份恢复 UI。
- §6.1 第 6 条：一次切换的应用总耗时约 1 秒（Dock 只消失 45–90 ms），要不要再优化等用户体感。

### 2026-09-18（第 5 次）— 完成 P2：编辑条 + 应用（**本项目第一次真的写 Dock**）

**做了什么**（用户：「按计划继续执行，直到计划中的所有阶段都实现（每个阶段实现后 git commit 一次）」）：

- 新增 5 个源文件：`Dock/DockReloader.swift`（`DockProcessControlling` 协议 + 真实实现 + 三级降级）、`Dock/DockController.swift`（应用流水线 + 防抖合并）、`Dock/DockStripRules.swift`（启动台/Finder 规则 + 从 `.app` 造条目）、`UI/DockStripEditor.swift`（拖拽排序/移除/拖入/抓取）。
- 新增 4 个测试文件：`DockReloaderTests`（10）、`DockControllerTests`（18）、`DockStripRulesTests`（22）、`AppStateDockTests`（18）、`DockAcceptanceTests`（1，默认跳过）、`TestSupport.swift`（共用替身）。
- 改了：`DockConfig.swift`（`AppSettings.defaultDock` + 手写解码补一行；`DockAppearance.domainEntries(restrictedTo:)` / `unavailableKeys(in:)`；`DockConfig.fingerprint(restrictedTo:)`；`DockTile.makeFileTile` 加 `dockExtra` + 尾斜杠 URL）、`AppState.swift`（`dockController` + 应用/还原/抓取/编辑方法，**依赖全部可注入**）、`SettingsView.swift`（通用 Tab 接上编辑条 + 三个按钮 + 本机不支持键的提示）、`AppDelegate.swift`（接线 `onDockApplied` 与 `restoreHandler`）、`LifecycleController.swift`（**只在改过 Dock 时才还原**；`baselineStore` 可注入）。
- `docs/PLAN.md`：§2 文件树、§3.4/§3.5/§3.6/§3.7 细则、§4 P2 标 ✅、§5 风险表、§6、§7 同步。

**验收证据（真实 Dock，全部实测）**：

- `swift build -c release` 零警告；`swift test` **142 个测试全绿**（1 个真实 Dock 验收默认跳过）。
- `MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests` 通过：
  - apply（`tilesize` 36→52、`magnification` 翻转、追加一个不带 `GUID` 的 Calculator 条目）：`SIGHUP 成功：PID 42542 → 44081，用时 132 ms；写入 9 个键`。
  - **与操作前全量域 diff，变化的键只有 `["magnification", "persistent-apps", "tilesize"]`** —— 白名单外的键一个都没动 ✅。
  - **Dock 给写入的条目补上了 `GUID`（`i:1414651200`）** → 写入真的被 Dock 读进去并重建了 Dock ✅。
  - 还原（`SIGHUP 138 ms`）后：图标顺序逐项回到原样，白名单键逐键一致，键集合一致（34 个键）；**仅剩差异 `["mod-count", "recent-apps"]`**，那是 Dock 自己每次重启都会动的计数器。
- App 级冒烟：`open build/MultiDock.app` 前后 `defaults export com.apple.dock` 逐键相同（默认 Dock 为空时不写任何东西）；日志正确报出 `本机 Dock 域里没有这些键…show-process-indicators`。
- 单测覆盖了：指纹短路（内容相同不写不重启）、只写白名单、缺键跳过不写、校验失败重试一次、两次都失败就报失败且不记指纹、读不到域直接失败、备份失败非致命、连击合并成一次、应用中新请求补跑、退出还原的三个门槛、还原与基准一致时跳过。

**关键手法 / 踩到的坑**：

1. **Dock 回写 `GUID` 是异步的**：apply 返回后立刻读还是 `nil`，轮询 200 ms 内出现。判据必须配轮询，否则会误判成"写入没生效"。
2. **`plutil -p` + `diff` 比对长数组会错位**，产生假差异。判断"成员/顺序"就抽标签序列比，判断"值"就用 `PlistValue` 结构比较。
3. **测试窗口期内别手动改 Dock**：有一次验收跑到一半 Dock 被外部改动（`persistent-others` 4 项→1 项），"还原后仍有差异"报了假失败。
4. **`DockStripRules.normalizedApps` 一开始无条件用合成条目覆盖启动台**，把真实域里的 `GUID` / `book` / `file-mod-date` 抹掉了。改成"优先复用已有的启动台条目"。
5. **`.app` 的 `_CFURLString` 必须带尾斜杠**（`file:///Applications/X.app/`），`URL.absoluteString` 不带，与真实域和 P0 写入实验都不一致。
6. **`AppState.captureCurrentDockAsDefault` 直接调了静态 `DockPreferences.readDomain()`**，绕过注入点 → 三个单测读到真实 Dock。加了 `DockController.readDomain()` / `captureLiveConfig()` 作为唯一入口。
7. **`@MainActor` 异步测试里用 `DispatchSemaphore.wait` 会死锁**（`Task { @MainActor }` 排不上）。改成 `do/catch` + 显式收尾。
8. **退出还原不能无条件做**：用户可能在运行期间自己拖了图标，写回基准会把他的改动一起抹掉。加了 `sessionChangedDock` 门槛 + "已与基准一致就跳过"。
9. **`onOutcome` 得是 `var`**：`AppState.init` 要先构造 controller 再挂回调（闭包捕获 `self`），`let` 做不到。
10. **非 `.app` 进程里 `NSRunningApplication.runningApplications(withBundleIdentifier:)` 可能查不到 Dock** → `dockPID()` 用 `pgrep -x Dock` 兜底。

**当前进度**：P0 ✅、P1 ✅、P2.5 ✅、**P2 ✅**。**写路径已接线，App 现在真的会改 Dock**；无痕靠退出还原 + 会话标记兜底。
**未解决**：§6.1 第 1 条（「位置」含义，**阻塞 P3**）、第 5 条（默认 Dock 为空的交互）；§6.3 第 3/4/11/12/13/14/16 条（其中 11/13/14 需要用户手动点/拖一次）。**1Password 处于锁定状态，本次的 commit 尚未落盘**（暂存区完好，解锁后重跑即可）。

### 2026-09-18（第 4 次）— 完成 P2.5：桌面命名 + 切换 toast

**做了什么**（用户：「把 P2.5 做掉」）：

- 新增 4 个源文件 / 2 个测试文件 / 1 个验收脚本：
  `Spaces/DesktopNaming.swift`、`UI/ToastPresenter.swift`、`UI/DesktopNameToast.swift`、`Tests/MultiDockTests/{DesktopNamingTests,ToastPresenterTests}.swift`、`scripts/check-toast-window.sh`。
- 改了 `AppState`（`displayName(for:)` / `customName(for:)` / `setCustomName` / `attachToastPresenter` / `showTestToast`、加载时归一化绑定）、`AppDelegate`（接线 toast）、`MenuBarController`、`SettingsView`、`DebugPanelView`、`DockConfig.swift`。
- **`AppSettings` 改成手写 `init(from:)`**：每个字段 `decodeIfPresent` 兜默认。原因：合成的解码器遇到旧配置缺新键会抛错，而 `ConfigStore.load()` 失败时返回**整份默认配置** → 用户已有设置会被静默清空。**以后加字段必须补一行。**
- 同步更新 `docs/PLAN.md`（§2 文件树、§3.10 的命名细则与验收、§4 P2.5 标 ✅、§5 风险表 3 行、§6 三条标"已实现"、§7 第 7 条）。

**验收证据（全部实测，无截图）**：

- `swift build -c release` 零警告；`swift test` **70 个测试全绿**（原 37 + 新增 33）。
- `scripts/check-toast-window.sh --watch` 实测 toast 窗口：`layer=25 alpha=1.00 onscreen=yes x=916 y=80 w=87 h=39`（名字「桌面 2」）与 `x=863 y=80 w=193 h=39`（10 个中文）→ 窗口中心 959.5 ≈ 主屏 midX 960 ✅，距可见区顶部 80 pt ✅；出现到消失 **983 / 987 ms**。
- 日志 `toast 显示` → `toast 隐藏` 间隔 **1.014 / 1.035 / 1.055 / 1.098 s**；启动时不弹（首次采样无 toast）；全屏空间不弹。
- 命名：手写 `config.json` 塞 12 字名字 → 加载后截到 10 字，toast 原样显示「一二三四五六七八九十」；无名字的桌面回落「桌面 1」；`"   "` 的空绑定被自动清理（日志有 WARNING）；`"settings": {}` 缺键也能正常解码（新解码器生效）。
- **切 4 次桌面（含 4 次 toast）前后 `defaults read com.apple.dock` 逐键相同**。另外确认代码里**只有 `DockPreferences.exportDomainData()` 这个读函数被调用**，写路径根本没接线。
- 不抢焦点：连弹两次 toast 期间每 100 ms 采样 `lsappinfo front`，前台始终是别的 App。

**关键手法 / 踩到的坑**：

1. **`orderOut` 后窗口会在 CG 窗口列表里滞留好几秒**（`kCGWindowIsOnscreen` 立刻变 false，但记录还在）。用窗口元数据核对「消失」时刻**必须滤 `onscreen`**，否则时长晚报。
2. **Swift 脚本的 stdout 重定向到文件时是块缓冲**，观察类工具必须 `setvbuf(stdout, nil, _IONBF, 0)`，否则一行都看不到。
3. **反复调用的探测工具要 `swiftc -O` 编译一次缓存复用**：每次 `swift file.swift` 都是完整编译，几十毫秒级轮询根本跑不动（我第一次的采样窗口就是被编译时间吃掉的，导致测试无效）。
4. **后台任务要放在同一条 Bash 调用里**（`cmd & ... wait`），跨调用后台进程会被清掉 —— 有一次验证因此白跑。
5. 用外部进程（`spike-switch`）切桌面是**验证 toast 的最佳手段**：它等价于"用户自己切桌面"，不需要点击 UI，也能顺带证明 toast 不抢焦点。

**当前进度**：P0 ✅、P1 ✅、**P2.5 ✅**。代码里仍未写入任何 Dock 设置。
**未解决**：§6.1 第 1 条（「位置」含义，阻塞 P3）；§6.3 第 11 条（**设置页改名输入框需要用户手动点一次**）、第 12 条（真机连击未测）、第 1–6 条（P2 相关）。

### 2026-09-18（第 3 次）— 计划新增：桌面命名 + 切换 toast

**做了什么**（用户需求：设置-桌面里给每个桌面起名，最长 10 字符；切换桌面后在屏幕中上部弹 toast 显示名字，1 秒自动消失）：

- **只改文档，没写业务代码**（用户说"更新计划"）。
- `docs/PLAN.md`：§0 目标加两条；§1 环境事实表加两行实测；§2 文件树加 4 个新文件；**新增 §3.10「桌面命名与切换提示」**（含命名规则、toast 触发点、窗口属性表、零权限说明、验收方法）；§3.7 桌面 Tab 与菜单栏下拉同步；§4 阶段表**新增 P2.5**（不写 Dock、可插队）；§5 风险表加 7 行；§6 从"一处"扩成"四处"待确认理解；§7 加第 7 条差异。
- `AGENTS.md`：§2 硬约束加第 6 条；§3 加「可选插队：P2.5」步骤清单；§4 环境事实加 2 行；§6.1 加 3 条待确认、§6.3 加 4 条未解决技术项；§7 顺序表插入 P2.5；修掉 §5 里"这个目录还不是 git 仓库"的过时说法。
- `scripts/spike-probe.swift` 增加 `screens` 段（`NSScreen` → `CGDirectDisplayID` → UUID + frame/visibleFrame），文本与 `--json` 两种输出都有，已跑通。

**本次新增的实测事实**：`CGDisplayCreateUUIDFromDisplayID(NSScreen.deviceDescription["NSScreenNumber"])` 与 SkyLight 的 `Display Identifier` **逐字符相同**（都是 `AB24BB32-C5EC-D10A-6F9D-F01F35552F60`）→ toast 能定位到正确的显示器，这条原本是未知项，现已消掉。主屏 `frame` 1920×1200、`visibleFrame` (0,53,1920,1147)。

**当前进度**：P0 ✅、P1 ✅，代码无变化。**未解决**：见 §6.1（4 条，第 1 条阻塞 P3）、§6.3（10 条，新增 7–10 全是 toast/命名相关）。

### 2026-09-18（第 2 次）— 建立文档与提交约定

**做了什么**：
- 把"每次对话后更新文档 + `git commit`"固化成 §0 的强制约定。
- 把原来的"待确认问题"扩成 §6：6.1 等用户回答（会阻塞）、6.2 已解决（留档）、6.3 未解决的技术项（6 条）。
- 新增 §8 会话记录区（append-only，最新在最上面）。
- **`git init -b main` 并提交首个 commit**（`e3e359a`，34 个文件 / 4107 行）。`.gitignore` 已排除 `.build/`（170 MB）与 `build/`。
- 记录了一个坑：本机 `commit.gpgsign = true` 且签名走 1Password 的 `op-ssh-sign`，**1Password 没运行时 commit 会失败**（见 §0）。

**当前进度**：P0 ✅、P1 ✅（见下条）。**未解决**：见 §6.1 / §6.3。

### 2026-09-18（第 1 次）— 完成 P0 实验 + P1 骨架

**做了什么**：
- **P0 三个实验全部实测完成**，结论写入 `docs/spikes.md`。三条结论推翻了 `PLAN.md` 的原始假设：① Dock **没有热重载**（post 通知完全无效），主路径定为 `kill -HUP`（约 101 ms 不可用），SIGTERM + kickstart 兜底（约 395 ms）；② 主动切桌面 **可用（20 ms）但不触发空间变化通知** → 事件源反转为 300 ms 轮询为主；③ **Finder 在 plist 中无任何表示** → 钉住无需代码。
- **P1 实现完成**：新增 14 个源文件（`App/` `Spaces/` `Dock/` `Store/` `UI/`）+ 4 个测试文件 + 4 个 P0 实验脚本；测试目标已加进 `Package.swift`，**37 个测试全绿**，全新构建**零警告**。
- 同步修订了 `docs/PLAN.md`（§1 键名、§2 文件树、§3.1 事件源、§3.2 模型、§3.5 重载策略、§4 P0/P1 行、§5 风险表、§7 差异）、重写 `AGENTS.md`、更新 `README.md`。

**验收证据**：
- 切桌面 10 次 → 日志记录 10 次变化，spaceUUID 全对、无漏报无重复。
- `baseline.plist` 与运行时 `com.apple.dock` **34 键逐键相同**。
- App 运行前后 Dock 除 `recent-apps`/`mod-count`（系统自管，已在排除清单）外**无任何差异** → P1「不改任何 Dock 设置」成立。
- 正常退出后 `session.state` 被正确删除。

**关键手法**（详见 `docs/spikes.md`）：本机无屏幕录制权限、`screencapture` 只返回壁纸，所以改用**零权限的客观判据** —— 写入的 tile 故意不带 `GUID`，Dock 真正应用后会补上（正负两种情形都验证过）。

**未解决**：见 §6.1（桌面页"位置"含义待用户回答）、§6.3（外观键名待实测、SIGTERM 竞态、Finder 手动验证、还原未接线等）。

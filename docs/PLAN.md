# MultiDock：每个桌面一套原生 Dock + 桌面切换器

## 0. 目标

菜单栏常驻一个图标，管理多桌面下的原生 Dock：

- **菜单栏**：单击图标 → 切到下一个桌面（循环）；右键 / ⌥+左键 → 下拉菜单，列出所有桌面（点选即切换）、进设置、退出。
- **设置 → 通用**：编辑「默认 Dock」——拖入/拖出应用、拖拽排序，Finder 与 Launchpad 固定不可移除；默认 Dock 的大小与位置。
- **设置 → 桌面**：列出所有桌面，每个桌面单独设置 Dock 位置/大小与 Dock 中的应用（同样可拖入拖出），或选择沿用默认 Dock；**每个桌面还可以起一个名字，最长 10 个字符**（仅存本地，见 §3.10）。
- **切换桌面提示（toast）**：切换到另一个桌面时，在屏幕**中上部**浮出一条提示显示该桌面的名字，**1 秒后自动消失**。不抢焦点、不挡点击、不需要任何权限（见 §3.10）。

切换桌面时自动把原生 Dock 更新为该桌面的配置。未单独设置的桌面（含新建桌面）使用默认 Dock。

**无痕原则（硬约束）**：App 绝不永久改变用户的 Dock。首次运行会把你当前的 Dock 完整存为**基准快照**，App 退出时自动还原到该基准；即使被强杀或崩溃，下次启动也会检测并还原。安装后什么都不做时，Dock 与装之前完全一致。

**不做**：不替换原生 Dock、不画自己的 Dock 栏、不新建/删除系统桌面（macOS 无公开接口，只列出系统已有的）、不改系统级或其他用户的配置、本期不做沙盒与公证。

---

## 1. 已验证的环境事实（本机实测，2026-09-18）

| 项 | 结论 |
| --- | --- |
| 系统 / 工具链 | macOS 15.7.9 (24G830)，x86_64，单显示器；Xcode 26.3、Swift 6.2.4 |
| 空间切换通知 | `NSWorkspaceActiveSpaceDidChangeNotification` 是**公开 API**（AppKit 10.6 起，`NSWorkspace.h:339`）。**但 P0 实测：程序化切桌面时它不触发**（对照实验已排除环境因素）→ 见 §3.1 |
| 枚举桌面 | `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")` 成功，`CGSCopyManagedDisplaySpaces` / `CGSGetActiveSpace` / `CGSMainConnectionID` 可用。实测返回 2 个桌面，各有**跨重启稳定的 UUID**、`id64`、`type=0`，`Spaces` 数组顺序即左右顺序 |
| **主动切桌面** | `CGSManagedDisplaySetCurrentSpace` **符号存在**（`CGSManagedDisplayGetCurrentSpace` 也在）→ 菜单栏"切下一个桌面"可实现。**尚无动画时长控制符号**（`CGSSetWorkspaceAnimationDuration` 等都不存在），切换会带系统自带的滑动动画 |
| 桌面命名 | 空间字典的键是 `uuid` / `ManagedSpaceID` / `id64` / `type` / `WindowManagerInfo`（P0 实测，**不是** `ManagedSpaceUUID`），**没有名称字段** → macOS 15 无桌面名接口，App 内的桌面命名只能存在本地，不会写回系统。display 字典另有 `Current Space` 键可直取当前空间 |
| **显示器 UUID 能否映射到 `NSScreen`** | ✅ **能，且完全一致**（2026-09-18 实测）：`CGDisplayCreateUUIDFromDisplayID(NSScreen.deviceDescription["NSScreenNumber"])` 得到 `AB24BB32-C5EC-D10A-6F9D-F01F35552F60`，与 SkyLight 的 `Display Identifier` 逐字符相同 → 由空间所在的 `displayUUID` 可以精确定位到显示器，toast 能显示在正确的屏幕上。探测脚本：`scripts/spike-probe.swift` |
| 屏幕几何（toast 定位用） | 主屏 `frame` = (0, 0, 1920, 1200)，`visibleFrame` = (0, 53, 1920, 1147)（Dock 在底部且未自动隐藏，底部让出 53 pt）。toast 定位用 `visibleFrame`，天然避开菜单栏与 Dock |
| Dock 偏好域 | `com.apple.dock` 34 个键；`persistent-apps` 15 项（首项是 Launchpad）、`persistent-others` 有「下载」 |
| **Finder 的表示方式** | `persistent-apps` 里**没有 Finder**，Finder 是 Dock 隐式固定项。Launchpad 则是普通条目 `file:///System/Applications/Launchpad.app/`（`com.apple.launchpad.launcher`），可通过写 plist 增删 |
| Dock 进程守护 | `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}` → **必须让 Dock 以信号致死方式退出**才会被 launchd 拉起；优雅退出（exit 0）不会重启 |
| Dock 热重载 | **P0 已证伪：不存在热重载**。写偏好后 post `com.apple.dock.prefchanged`（darwin 与分布式两种都试了）Dock 完全不响应；`kill -HUP` 会让 Dock 直接退出并由 launchd 拉起（是重启，不是重载）。重启后偏好全部生效 |
| 多显示器空间 | `com.apple.spaces spans-displays` 不存在 → 默认"显示器各自独立空间"开启，映射键需 `(displayUUID, spaceUUID)` |
| 当前风险项 | 本机 `mru-spaces = 1`（"根据最近使用自动重新排列空间"）。它会打乱桌面顺序，与"循环切下一个桌面"直接冲突 → 设置页提供**显式开关**（用户主动点击才改，不静默修改） |

**权限需求：无。** 不需要辅助功能、屏幕录制或 root——Dock 偏好与桌面切换都是用户级操作。

---

## 2. 工程形态

**SwiftPM 可执行包 + 打包脚本**（不手写 `.xcodeproj`：冗长易错，且不需要 storyboard/资源目录；Xcode 仍可直接打开 `Package.swift`）：

```
multi-dock/
├── Package.swift                       # platform .macOS(.v14)，含测试目标
├── Sources/MultiDock/
│   ├── MultiDockApp.swift              @main + NSApplication（不用 MenuBarExtra，见 §2 注）
│   ├── App/AppDelegate.swift           组装状态 / 菜单栏 / 窗口
│   ├── App/AppState.swift              全局状态、设置持久化
│   ├── App/FileLogSink.swift           日志落盘（multidock.log，上限 512 KB）
│   ├── App/LifecycleController.swift   启动自检、退出还原、异常退出检测
│   ├── Spaces/SkyLightBridge.swift     dlopen + dlsym 封装
│   ├── Spaces/SpaceProvider.swift      协议 + 私有 API 实现 + 降级实现
│   ├── Spaces/SpaceObserver.swift      轮询(300ms) + 通知(辅助) + 全屏过滤 + 去重
│   ├── Spaces/SpaceSwitcher.swift      切到下一个/指定桌面（循环）
│   ├── Spaces/DesktopNaming.swift      桌面命名：归一化(≤10 字素簇)、显示名解析、改名规则
│   ├── Dock/DockPreferences.swift      CFPreferences 读写 + 键白名单
│   ├── Dock/DockConfig.swift           模型、tile 构造、归一化指纹
│   ├── Dock/DockController.swift       应用流水线、防抖合并、内容相同则跳过（**P2 已实现**）
│   ├── Dock/DockReloader.swift         SIGHUP 为主 + SIGTERM/kickstart 兜底（**P2 已实现**）
│   ├── Dock/DockStripRules.swift       图标条规则：启动台固定在首位、Finder 幻影、从 .app 造条目（**P2 已实现**）
│   ├── Dock/DockWatcher.swift          识别用户在真实 Dock 上的手动改动并回存（**P3**）
│   ├── Store/ConfigStore.swift         原子读写 config.json
│   ├── Store/BaselineStore.swift       基准快照 + 会话标记 + 备份历史
│   ├── UI/MenuBarController.swift      NSStatusItem：桌面列表 + 切换 + 设置入口
│   ├── UI/SettingsView.swift           通用 / 桌面 两个 Tab
│   ├── UI/DockStripEditor.swift        Dock 可视化编辑条（拖入拖出排序，**P2 已实现**）
│   ├── UI/DesktopListView.swift        桌面列表、改名（≤10 字符）与绑定（**P3**）
│   ├── UI/ToastPresenter.swift         toast 协议 + 纯逻辑调度（1 s 计时、连击取消重启、只弹桌面→桌面）
│   ├── UI/DesktopNameToast.swift       中上部提示窗口（无边框、不抢焦点、跨空间、零权限）
│   └── UI/DebugPanelView.swift         当前 spaceUUID / id64 / type、应用日志、测试 toast 按钮
├── Tests/MultiDockTests/               指纹归一化、白名单写入、循环取下一个、基准/标记/备份、名字归一化、
│                                       toast 调度、Dock 重载降级、应用流水线、图标条规则、AppState 按钮路径
│   └── DockAcceptanceTests.swift       **真实 Dock 验收**（默认跳过，`MULTIDOCK_DOCK_ACCEPTANCE=1` 开启）
├── scripts/build-app.sh                组装 MultiDock.app（Info.plist + ad-hoc 签名）
├── scripts/spike-reload.sh             P0 实验：Dock 重载策略 A/B/C
├── scripts/spike-probe.swift           P0 实验：探测当前桌面 / Dock 进程 / Dock 窗口几何 / 显示器 UUID 映射
├── scripts/spike-switch.swift          P0 实验：主动切桌面 + 通知是否触发
├── scripts/spike-dock-downtime.swift   P0 实验：毫秒级测 Dock 停机时长
├── scripts/check-toast-window.sh       客观验收 toast：用 CGWindowListCopyWindowInfo 读窗口层/透明度/坐标（零权限）
├── docs/spikes.md                      P0 结论（含对本文档的三处修正）
└── README.md                           含"如何完全卸载并还原初始 Dock"
```

**注：菜单栏用 `NSStatusItem` 而不是 `MenuBarExtra`。** 硬约束 §2.3 要求区分「左键 / 右键 / ⌥+左键」三种点击，而 `MenuBarExtra` 的点击一律被它自己吃掉、无法区分左右键。设置窗口与调试面板仍是 SwiftUI，由 `NSHostingController` 承载。相应地，计划里原定的 `UI/MenuBarView.swift` 改名为 `UI/MenuBarController.swift`。

`build-app.sh`：`swift build -c release` → 组装 `build/MultiDock.app/Contents/{MacOS,Info.plist}`（`LSUIElement=1`、`CFBundleIdentifier=local.multidock`）→ `codesign --force --sign -`（**不是** `--deep`，Apple 已废弃）。**必须打包成 .app 再 `open`**：直接跑 `.build/release/MultiDock` 没有 bundle，菜单栏图标行为会异常。

验证命令：`swift build -c release && swift test && ./scripts/build-app.sh && open build/MultiDock.app`

动 Dock 的改动另跑真实验收（**会真的改 `com.apple.dock` 并重启 Dock，跑完自动还原**；跑之前先 `defaults export com.apple.dock` 备份，且中途别手动改 Dock）：

```bash
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests
```

---

## 3. 核心机制

### 3.1 桌面识别与切换

```swift
struct DesktopSpace: Hashable {
    let displayUUID: String   // "AB24BB32-…"
    let spaceUUID: String     // "4280475C-…"  ← 稳定主键
    let id64: UInt64
    let type: Int             // 0 = 用户桌面；4 = 全屏 App 空间；其他 = 系统空间
    let ordinal: Int          // 该显示器内的序号，用于显示"桌面 2"
}
```

- 主键 `spaceUUID`（跨重启稳定）；多显示器时映射键为 `(displayUUID, spaceUUID)`。
- **`type != 0` 的空间一律不参与**：不列入菜单、不参与循环、切换时不应用配置。否则每次进全屏 App 都会被当成切桌面（严重体验问题）。
- 切换目标 = 当前活动显示器上，按 `Spaces` 数组顺序取的下一个 / 上一个用户桌面，两端循环。
- 事件源（**P0 实测后反转了主次**）：**300 ms 轮询为主**，`NSWorkspaceActiveSpaceDidChangeNotification` 为辅。原因是实测发现程序化切桌面时该通知根本不触发（对照实验证明通知通道本身正常），所以通知只能当"用户主动切换时的快速通道"来降低延迟。两条路都进同一个幂等的 `handleActiveSpaceChanged()`，用 `(displayUUID, spaceUUID)` 去重。
- **我们自己发起的切换必须预应用**（§3.4 第 8 条）：切换后收不到任何通知，不能等通知回来才动 Dock。这条从"优化"升级为"必需"。
- `SpaceProvider` 协议隔离私有 API；失效时降级为"只能手动改 Dock、不能自动跟随与切换"，并在 UI 明确报警，而不是静默失效。

### 3.2 数据模型（用户看到的是"桌面"，不是"配置"）

```swift
// plist 值的可编码表示。计划原文写的是 [String: Any]，但它不满足 Codable、无法落盘，
// 所以改用这个覆盖全部 plist 类型的枚举，并提供与 Any 的双向转换。
enum PlistValue: Codable { case string, int, double, bool, data, date, array, dictionary }

struct DockTile: Codable { var raw: [String: PlistValue] }  // tile 字典原样保留

struct DockConfig: Codable {
    var pinnedApps: [DockTile]      // persistent-apps（不含 Finder，Finder 由系统隐式固定）
    var otherItems: [DockTile]      // persistent-others（文件夹 / 堆栈 / 下载）
    var appearance: DockAppearance  // 位置、大小、放大、自动隐藏等
}

struct DockAppearance: Codable {
    var orientation: String   // bottom / left / right
    var tilesize: Double
    var magnification: Bool
    var largesize: Double
    var autohide: Bool
    var autohideDelay: Double?
    var autohideTimeModifier: Double?
    var mineffect: String     // genie / scale
    var minimizeToApplication: Bool
    var showProcessIndicators: Bool
}

struct DesktopBinding: Codable {
    var displayUUID: String
    var spaceUUID: String
    var customName: String?     // 仅存本地，系统无桌面名接口
    var override: DockConfig?   // nil = 使用默认 Dock
}

struct AppSettings: Codable {
    var restoreOnQuit: Bool = true     // 退出还原（默认开）
    var clickAction: ClickAction = .nextDesktop   // 左键单击行为
    var autoApplyOnEdit: Bool = true
    var autoCaptureUserEdits: Bool = true
    var reloadStrategy: ReloadStrategy = .auto
}
```

- 存储：`~/Library/Application Support/MultiDock/config.json`（原子写：临时文件 + `rename`）。
- **参与读写比对的键白名单**：`persistent-apps`、`persistent-others`，加 appearance 对应键（`orientation`、`tilesize`、`magnification`、`largesize`、`autohide`、`autohide-delay`、`autohide-time-modifier`、`mineffect`、`minimize-to-application`、`show-process-indicators`）。
- **明确排除**：`mru-spaces`（另有显式开关）、`wvous-*`（屏幕角）、`springboard-rows/columns`（启动台网格）、`recent-apps`、`mod-count`、`version`、`loc`/`region`、`trash-full`、`ResetLaunchPad`。

### 3.3 基准快照与还原（无痕原则）

`BaselineStore` 负责三件事：

1. **基准快照 `baseline.plist`**：首次运行时把 `com.apple.dock` **全量域**导出保存，此后不覆盖。同时把「默认 Dock」初始化成这份快照的内容——所以刚装完 App，任何桌面都不会发生任何变化。
   - 提供「把当前 Dock 现状设为新基准」按钮（用户满意当前状态时重置基准）。
   - 用户可在设置里关闭退出还原；关闭时基准仍保留，仅作备份用。
2. **会话标记 `session.state`**：App 正常启动并开始接管 Dock 时写入（含 PID、启动时间、当前已应用指纹）；**正常退出还原成功后删除**。
   - 下次启动若发现标记仍存在 → 说明上次是被强杀/崩溃/断电，没有走完还原 → 启动时先**自动还原基准**，再按正常流程应用当前桌面的配置。UI 给一条一次性提示说明发生了什么。
   - 标记里存 PID 并校验进程是否还活着，避免多实例或误判。
3. **轮转备份**：每次写入真实 Dock 前，把当时的全量域另存一份到 `backups/`，保留最近 20 份，供"回滚到某个时间点"。

**正常退出流程**（`LifecycleController`）：

```
收到退出请求（菜单退出 / Cmd+Q / 系统注销关机）
  → NSApp.reply(toApplicationShouldTerminate: .terminateLater) 挂起退出
  → 若 restoreOnQuit：写入基准快照的白名单键（其余键保持不动）→ 触发 Dock 重载
  → 等待重载完成（Dock 归位确认，最长 5s）
  → 删除 session.state
  → NSApp.reply(toApplicationShouldTerminate: .terminateNow)
```
- 绝不在还原未完成前就退出进程，否则用户会看到"退出后 Dock 还是错的"。
- 系统关机/注销同样走这条路（`NSWorkspace.willPowerOffNotification` + `NSApp` 的终止委托），并放宽等待上限。
- 崩溃/强杀走不了钩子，由下次启动的 `session.state` 检测兜底——这是无痕原则的最后一道防线，必须有测试覆盖。

### 3.4 应用流水线（DockController）

1. 目标配置 = `binding.override ?? defaultConfig`。
2. **内容相同即短路**：归一化指纹与"当前已应用"一致 → 直接返回，**完全不重启 Dock**。两个桌面共用同一份 Dock 时，切桌面零开销、零闪烁。
3. 备份当前 `com.apple.dock` 全量域到 `backups/`。
4. 读当前**全量**域 → 用配置覆盖白名单键 → 其余键（热角、启动台等）原样保留 → `CFPreferencesSetMultiple(..., kCFPreferencesCurrentUser, kCFPreferencesAnyHost)` + `CFPreferencesAppSynchronize`。单次原子写，不用 `defaults` 逐条拼。
5. 触发 Dock 重载（见 3.5）。
6. 记录 `appliedFingerprint`、`appliedAt`、`reloadMethod`、耗时 → 调试面板可见。
7. **防抖合并**：连击切桌面时只对最终落点执行一次；应用进行中目标又变化 → 记 `pendingTarget`，本轮结束立即补跑。
8. **我们自己切桌面时预应用**：点击"下一个桌面"时已知目标，先 apply 再切空间，切换动画结束时 Dock 已是正确状态（不等通知回来才动）。

> **P2 实现记录（2026-09-18）** —— 第 1、2、7、8 条中，**1 已实现**（`AppState.applyDock(_:reason:)` 目前只喂 `settings.defaultDock`；`binding.override` 的选取属 P3）、**2 / 7 已实现**、**8 待 P3**（切桌面时预应用）。
>
> 实现上的几处具体化：
> - **校验只比"实际写进去的那些键"**。本机域里没有 `show-process-indicators`，把缺失的键算进比对会产生假阴性（"明明写成功却判定失败"）。`DockConfig.fingerprint(restrictedTo:)` 负责这件事。
> - **绝不写当前域里不存在的键**：`DockController.entries(for:restrictedTo:)` 只挑域里真实存在的白名单键，`DockAppearance.unavailableKeys(in:)` 把跳过的键报告给 UI（设置页显示「本机不支持」并禁用对应控件）。
> - **备份失败不阻断**：基准快照才是最后一道防线，备份失败只在 `Outcome.note` 里记一句。
> - **防抖合并**用"单槽位 + 排空循环"实现：`request()` 只保留最后一个目标，`drain()` 循环到 `pending` 清空；应用进行中来的新目标在本轮结束后立刻补跑。`waitForIdle()` 供测试与「立即应用」等待。
> - **实测**：SIGHUP 125–138 ms；变化只落在 `magnification` / `persistent-apps` / `tilesize`；新写入的 tile 被 Dock 补上 `GUID`（证明真的生效）。

### 3.5 Dock 重载策略（**P0 已完成，结论见 `docs/spikes.md`**）

| 方案 | 做法 | P0 实测结果 |
| --- | --- | --- |
| A. 通知 | 写偏好后 post `com.apple.dock.prefchanged` | ❌ **彻底无效**。darwin 通知与真·分布式通知都试过，Dock 完全不响应（PID 不变、tile 的 `GUID` 未被补全） |
| B. SIGHUP | `kill(dockPID, SIGHUP)` | ✅ **生效**，但**不是热重载而是进程重启**（PID 变化，launchd 立即拉回）。总不可用窗口仅 **约 101 ms** |
| C. SIGTERM | `kill(dockPID, SIGTERM)`，未归位则 `launchctl kickstart -k gui/$(id -u)/com.apple.Dock.agent` | ✅ 生效（重启）。Dock 会先做约 255 ms 退出清理，总不可用窗口 **约 367–395 ms** |

> **不存在热重载**。写偏好后必须重启 Dock 进程，没有零闪烁方案。

**决定：主路径 = B（SIGHUP），兜底 = C（SIGTERM + kickstart）。** SIGHUP 比 SIGTERM 快约 4 倍（101 ms vs 395 ms），因为 SIGTERM 会被捕获并触发 Dock 的退出清理。UI 与 README 的措辞为「切换桌面时 Dock 会刷新约 0.1 秒」。

**关键坑（已验证 launchd 配置）**：绝不能用"优雅退出"（AppleEvent quit）——`SuccessfulExit = 0` 意味着 exit 0 时 launchd **不会**拉回 Dock，用户会当场失去 Dock。只走信号路径 + kickstart 兜底。

**竞态风险（实现时必须处理）**：SIGTERM 前有约 255 ms 清理窗口，Dock 可能在退出前回写自己的状态从而覆盖我们的写入。实测未发生，但**不能假设永远安全**——应用后用指纹校验，不一致则重试一次。

**体验补偿**（仍然有效）：3.4 的"内容相同则跳过"让共用同一份 Dock 的桌面切换零开销、零闪烁；"预应用"让切换动画结束时 Dock 已正确。

> **P2 实现记录**：`DockReloader.reload(strategy:)` 按 **SIGHUP → SIGTERM → `launchctl kickstart`** 三级降级，每级都轮询等一个**不同于旧 PID** 的新 Dock 进程出现（判据是 PID 变化，不是"Dock 还在"）。超时默认 5 s，`fallbackGrace`（默认 500 ms）是发完 SIGTERM 后、动 kickstart 之前的宽限。实测 SIGHUP 每次一次过，`verifyAttempts == 1`。
>
> **P0 的竞态风险实测未发生**：多轮 apply 都是第一次校验就过。重试路径由单测 `testRetriesOnceWhenDockDidNotTakeTheWrite` 用"第一次写入被吞掉"的替身覆盖。
>
> **Dock 进程查找有兜底**：非 `.app` 进程（如 `swift test` 的 xctest runner）里 `NSRunningApplication.runningApplications(withBundleIdentifier:)` 可能查不到 Dock，`dockPID()` 退回 `pgrep -x Dock`。

### 3.6 Dock 编辑条（设置页核心控件）

一个 `DockStripEditor` 组件，通用页与每个桌面的详情页复用：

- 按 location 自动横/竖排布；每项渲染 `NSWorkspace.shared.icon(forFile:)` 真实图标。
- **拖入**：从 Finder 拖 .app / 文件夹 / 文件进来（SwiftUI `onDrop(of: [.fileURL])` 读 `NSItemProvider`）；另配「从应用程序选择…」按钮走 `NSOpenPanel`，覆盖不方便拖拽的场景。
- **拖出**：拖离编辑条即移除（配右键菜单「从 Dock 移除」）。
- **排序**：同一条内拖拽重排（`draggable`/`dropDestination`；若 SwiftUI 表现不稳则用 `NSViewRepresentable` 包 `NSCollectionView`）。
- **固定项**：编辑条最前面锁定渲染 Finder 与 Launchpad，带锁标识，不可拖出/删除。
  - Launchpad 是普通 `persistent-apps` 条目，直接保证它存在于列表首项即可钉住。
  - Finder 不在 plist 里（系统隐式渲染），"钉住"天然成立。**P0 已确认**：全量域 34 个键里没有任何 Finder 相关键或值，`persistent-apps` 中也无 Finder → **写偏好无法删除它，无需任何代码**。推论：不要给 Finder 加拖拽手柄（它永远在最前，无法排序），也不需要为它新增白名单键。（唯一残留未知：手动把 Finder 拖出 Dock 是否落键——需一次手动验证，风险低，见 `docs/spikes.md`）
- 新建 tile 时按 Dock 的格式合成（不给 `GUID`，让 Dock 自己分配）：
  ```json
  {"tile-type":"file-tile","tile-data":{
     "file-data":{"_CFURLString":"file:///Applications/X.app/","_CFURLStringType":15},
     "file-label":"X","bundle-identifier":"com.example.x","dock-extra":0,"file-type":41}}
  ```
- 编辑即时落在 App 的内存模型 + 落盘配置；是否立刻推给真实 Dock 由 "编辑后立即应用"（默认开）控制，也提供「立即应用」按钮。

> **P2 实现记录（`UI/DockStripEditor.swift` + `Dock/DockStripRules.swift`）** —— 上面几条里 **排序 / 拖入 / 拖出 / 固定项 / 合成格式 均已实现**，与计划的差异如下：
>
> 1. **`dock-extra` 用 `true`**（用户自己拖进来的 App），启动台用 `false`。计划示例写的是 `0`（P0 的写入实验也用 0，功能上都能生效），但真实域里用户 App 是 `1`、启动台是 `0`，所以按真实域来。
> 2. **`_CFURLString` 必须带尾斜杠**：`file:///Applications/X.app/`。`URL(fileURLWithPath:).absoluteString` 不带尾斜杠，与真实域和 P0 写入实验都不一致。统一走 `DockTile.directoryURLString(for:)`。
> 3. **启动台条目原样复用**：`DockStripRules.normalizedApps` 优先取数组里已有的启动台条目（连 `GUID` / `book` / `file-mod-date` 一起），只有域里没有时才 `makeLaunchpadTile()` 现造。早先版本无条件覆盖，每次编辑都会抹掉真实域里那几个字段（功能上能跑，但没必要动人家的数据）。
> 4. **拖拽排序只在 `performDrop` 时落盘 + 应用一次**：`dropEntered` 会连续触发，所以 `AppState.setDefaultDock` 只改内存、`dockConfigEdited` 才落盘并触发应用。否则拖过一个图标就写一次 `config.json` 并重启一次 Dock。
> 5. **竖排（left/right）暂未实现**：编辑条固定横排。`location` 自动横/竖排布等 P3/P5 一起做。
> 6. **「拖出即移除」用显式的垃圾桶投放区**（拖到编辑条外无法被检测到）。另配右键菜单「从 Dock 移除」。
> 7. **排序/拖拽的真人手感未验证**（本机无法用脚本点 UI）—— 逻辑由 `DockStripRulesTests` + `AppStateDockTests` 覆盖，真机拖拽需要用户手动试一次。

### 3.7 设置窗口

**通用 Tab**
- 「默认 Dock」编辑条（Finder、Launchpad 固定）
- 位置：下 / 左 / 右（分段控件）
- 大小：`tilesize` 滑杆 16–128；放大 `magnification` 开关 + `largesize` 滑杆
- 自动隐藏、最小化特效（genie/scale）、最小化到应用图标、显示运行指示
- **退出行为**：「退出 App 时还原为原始 Dock」开关（默认开）+ 「把当前 Dock 设为新基准」+「立即还原到原始 Dock」按钮
- 底部：Dock 重载方式说明（P0 结论）、`mru-spaces` 显式开关 + 一句解释（**保持用户主动点击才改**）

**桌面 Tab**
- 桌面列表：显示器名 + 名字（**可就地改名，最长 10 个字符**，输入框旁显示 `n/10`；未命名时占位符为「桌面 N」）+ 当前绑定状态（默认 Dock / 独立设置）
  - 改名只写 `DesktopBinding.customName`，**不动 Dock override**（§3.10）。
- 选中某桌面后：
  - 「沿用默认 Dock」开关（打开则 override = nil）
  - 关闭时显示该桌面自己的编辑条 + 位置/大小
  - 「从当前真实 Dock 抓取」按钮（把此刻 Dock 现状存成该桌面的配置，首次配置最省事）
  - 「重置为默认」「复制默认到本桌面」
- 「刷新桌面列表」（显示器插拔后）

**菜单栏下拉**
- 桌面列表（当前项打勾，点选即切换；显示解析后的名字：自定义名或「桌面 N」）
- 「下一个桌面」（循环）
- 「用当前 Dock 重置本桌面配置」
- 分隔线 → 「设置…」「退出并还原 Dock」
- **交互**：左键单击 = 切下一个桌面；右键 / ⌥+左键 = 下拉菜单。设置里可把左键改为"打开菜单"（照顾不习惯的人）。
- 菜单栏图标显示当前桌面序号（如 `2`）便于一眼确认。

> **P2 实现记录** —— 通用 Tab 已接上：**默认 Dock 编辑条 + 「立即应用」+「立即还原到原始 Dock」+「把当前 Dock 设为新基准」+ 本机不支持键的提示**。`mru-spaces` 开关、位置/大小控件、`largesize` 等属 P3/P4。
>
> - **默认 Dock 为空时不自动抓取**：避免首启就写盘、更避免"用户没配过就点应用 → Dock 被清空"。改为显示橙色警告 + 禁用「立即应用」，引导用户先点「从当前 Dock 抓取」。这是与计划原文的一处**有意加严**（见 §6）。
> - **退出还原只在"本次运行改过 Dock"时才执行**（`LifecycleController.sessionChangedDock`）。不能无条件还原——用户可能在运行期间自己拖了图标，写回基准会把他的改动一起抹掉。另外还原前会比一次白名单键，已经与基准一致就跳过，省掉一次没必要的 Dock 重启。
> - **`AppState` 的依赖全部可注入**（`dockController` / `configStore` / `baselineStore`），且 AppState 内部**不直接调 `DockPreferences.readDomain()` 这类静态入口**——那会绕过注入点，测试里会读到真实系统的偏好域。要读就走 `DockController.readDomain()` / `captureLiveConfig()`。

### 3.8 手动改动的自动回存（DockWatcher）

- 每 2 秒读白名单键，比对**归一化指纹**：tile 用"规范化 URL + file-label + bundle-identifier + tile-type 的有序序列"，外观用键值字典。
- 归一化**必须剔除** Dock 每次重载都会重算的字段：`GUID`、`file-mod-date`、`parent-mod-date`、`book`（Data blob）。
- 指纹变化且不在 3 秒保护窗口内（我们自己刚写完）→ 判定为用户在真实 Dock 上手动改动 → 覆盖当前桌面的配置（用默认 Dock 的桌面则更新默认 Dock），覆盖前存一份历史版本。
- 可在设置里关闭自动回存；关闭后只认 App 内的编辑。
- **与还原的边界**：还原期间（退出流程中）Watcher 必须停止，否则会把还原动作误判成用户改动写进配置。

### 3.9 登录启动与自愈

- 登录项优先 `SMAppService.mainApp`；未签名构建下注册失败则退回 `~/Library/LaunchAgents/local.multidock.plist`（`RunAtLoad`）。
- 启动顺序固定为：**检测残留 session.state → 必要时还原基准 → 应用当前桌面配置 → 建立会话标记**。
- Dock 重启后 3 秒未归位 → `launchctl kickstart -k` 兜底；仍异常则提示从备份恢复。

### 3.10 桌面命名与切换提示（toast）

#### 命名

- 名字存在 `DesktopBinding.customName`（§3.2 已定义），**只存本地** `config.json`：§1 已实测空间字典里没有名称字段，写不回系统。
- **上限 10 个字符，按字素簇计数**（`String.count`）——中文算 1 个、`👍🏽` 也算 1 个。理由：用户说的"字符"就是眼里看到的字，不是 UTF-8 字节也不是 UTF-16 码元。
- **两层防线**：输入框显示 `n/10` 计数（超长时变橙）+ **模型层归一化**（`DesktopNaming.normalize`：CRLF/换行折成空格 → 去首尾空白 → 按字素簇截断）。归一化在**两个时刻**发生：输入框提交（回车/失焦）时、以及 `ConfigStore.load()` 之后。这样手改 `config.json` 塞进超长名也撑不破设置页和 toast 的布局。
  - ⚠️ **输入框不做"每次击键即时截断"**（与本文档早期写法不同）：中文输入法组字（marked text）期间改写绑定值会打断候选词。所以草稿留在 SwiftUI 本地 `@State`，提交时才归一化。计数照常实时显示。
  - 归一化是纯函数，可单测（空串、纯空白、11 个中文、emoji、换行、首尾空白、正好 10）。
- **空名字 = 没有自定义名** → 回落到「桌面 N」。
- **改名不创建 Dock override**：`customName` 与 `override` 互不影响，可以只改名不设 Dock。名字清空**且** `override == nil` 时删掉这条绑定，不留空行。
- **解析入口统一为 `AppState.displayName(for: DesktopSpace)`**：有自定义名用自定义名，否则回落 `DesktopSpace.displayName`（"桌面 N"）。菜单栏标题、下拉菜单、桌面页列表、toast **全部**改用它；`DesktopSpace.displayName` 降级为纯序号名，只在拿不到配置的地方用。

#### toast

**触发点只有一个：`SpaceObserver.onActiveSpaceChanged`。** 它是单一事实源——轮询每 300 ms 读活动空间，与切换来源无关，所以**用户自己用触控板/快捷键/Mission Control 切桌面也会弹 toast**，不只是 App 发起的切换。App 自己发起的切换在切换后立刻 `observer.refreshNow()`（必要时 50 ms 再补一次）把延迟压到最低，轮询兜底最坏 300 ms。

**只在「用户桌面 → 另一个用户桌面」时弹**：要求上一次通知值也是非 nil 的桌面。这一条同时干掉两个噪音源：① App 刚启动的首次采样；② 从全屏 App 空间退回桌面（`activeSpace` 先变 nil 再变回，会被误判成切桌面）。

- 内容：该桌面的名字（自定义名或「桌面 N」）。
- 位置：**所在显示器的中上部**——`visibleFrame.maxY - 80`、水平居中。显示器由 `displayUUID` 映射到 `NSScreen`（§1 已实测可行）；映射失败回落 `NSScreen.main`。
- 停留 **1 秒**自动消失。1 秒内又切桌面 → **取消上一次计时，直接换文字并重新计时**（既不排队弹两条，也不会被旧计时器提前收走）。
- 计时/去重逻辑放在纯逻辑的 `ToastPresenter`（协议 + 可注入时钟），AppKit 部分单独放 `DesktopNameToast`，这样行为可以单测——和 `SpaceProviding` 隔离私有 API 是同一套路。

**窗口属性（缺一条都会出问题）**：

| 属性 | 值 | 为什么 |
| --- | --- | --- |
| `styleMask` | `.borderless` | 不要标题栏 |
| `isOpaque` / `backgroundColor` | `false` / `.clear` | 圆角胶囊靠自绘，不能用不透明底 |
| `hasShadow` | `false` | 阴影自绘 |
| `level` | `.statusBar`（25） | 高于普通窗口，但不压系统弹窗 |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` | **少了 `.canJoinAllSpaces` 就只在自己所在的空间显示**——切过去反而看不见，功能等于失效 |
| `ignoresMouseEvents` | `true` | 绝不挡住点击 |
| `canBecomeKey` / `canBecomeMain` | `false` | **绝不抢焦点**，否则用户切过去正要打字，字打进 toast |
| 显示 / 隐藏 | `orderFrontRegardless()` / `orderOut(nil)` | 不用 `makeKeyAndOrderFront`（会抢焦点） |

- **零权限**（硬约束 §2.5）：这就是本 App 自己的一个窗口，不涉及辅助功能、屏幕录制、root。
- 设置页给一个开关「切换桌面时显示桌面名称」（**默认开**）。不想要的人能关掉。

**验收（本机不能截图，见 `AGENTS.md` §4）**：

1. 纯逻辑单测覆盖：1 秒到期消失、1 秒内连击取消重启、启动首次不弹、全屏返回不弹、无自定义名回落「桌面 N」、开关关闭时不弹但记账仍更新。
2. 窗口本身用 **`CGWindowListCopyWindowInfo`** 客观验证（`scripts/check-toast-window.sh`，支持 `--watch`）：MultiDock 的 toast 窗口会出现，`layer == 25`、`alpha == 1`、bounds 水平居中且贴近屏幕顶部；1 秒后该窗口消失。**读窗口元数据不需要屏幕录制权限**（只有抓图 `kCGWindowImage` 才需要）——与 P1 验证菜单栏图标（layer 25）同一手法。
   - ⚠️ 判别式必须带 **`onscreen == true`**：`orderOut` 之后窗口在 CG 窗口列表里**还会滞留好几秒**（实测），不滤掉的话「消失」时刻会晚报，1 秒时长就核对不准。
3. 调试面板加「测试 toast」按钮，手动触发；`multidock.log` 记 `toast 显示「X」` / `toast 隐藏` 两行带时间戳，可直接核对 1 秒。

---

## 4. 实施阶段与验收

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| **P0 实验（✅ 已完成 2026-09-18）** | ① Dock 重载 A/B/C 实测 ② `CGSManagedDisplaySetCurrentSpace` 实测 ③ Finder 表示方式 | ✅ 产出 `docs/spikes.md`。**结论**：① 无热重载，主路径 = SIGHUP（约 101 ms 不可用）② 切桌面可用（20 ms）但不触发通知 → 事件源改为轮询为主 ③ Finder 无需处理 |
| **P1 骨架 + 识别 + 菜单栏（✅ 已完成 2026-09-18）** | SwiftPM 包、`build-app.sh`、SkyLightBridge、SpaceObserver、SpaceSwitcher、菜单栏下拉与单击切换、调试面板、基准快照 + 会话标记骨架。**不改任何 Dock 设置** | ✅ 全部达成：`swift build` / `swift test`（37 个测试全绿）/ `build-app.sh` 通过；**切桌面 10 次全部被记录、spaceUUID 全对、无漏报无重复**；菜单栏图标已创建（layer 25）；全屏空间不触发切换（单元测试覆盖）；`baseline.plist` 与运行时 `com.apple.dock` **34 键逐键相同**；运行前后 Dock 除 `recent-apps`/`mod-count`（系统自管，已在排除清单）外无任何差异 |
| **P2 编辑条 + 应用（✅ 已完成 2026-09-18）** | DockPreferences 读写、ConfigStore、备份轮转、`DockReloader`、`DockController`、`DockStripRules`、`DockStripEditor`、通用 Tab、手动「立即应用」、**「立即还原到原始 Dock」按钮** | ✅ **全部达成**（`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests`，真实 Dock）：apply 后与操作前全量域 diff，**变化的键只有 `["magnification","persistent-apps","tilesize"]`**（全部在白名单内，白名单外的键一个没动）；**Dock 给新写入的条目补上了 `GUID`（`i:1414651200`）** → 写入真的被读进去并重建了 Dock；还原后图标顺序逐项回到原样、白名单键逐键一致、键集合一致（34 键），**仅剩 `["mod-count","recent-apps"]`**（Dock 自己的计数器）。SIGHUP **125–138 ms**。Finder/Launchpad 无法被拖出（编辑条里没有拖拽手柄 + `DockStripRules` 保证启动台在首位）。**142 个测试全绿、零警告** |
| **P2.5 桌面命名 + 切换 toast（不写 Dock）✅ 已完成 2026-09-18** | `DesktopNaming`（归一化 + 显示名解析 + 改名规则）、`AppState.displayName(for:)` 并替换所有调用点、桌面页改名输入框、`ToastPresenter`（纯逻辑）、`DesktopNameToastWindow`（AppKit 窗口）、设置开关、调试面板「测试 toast」、`scripts/check-toast-window.sh` | ✅ 全部达成：**70 个测试全绿**、零警告；`check-toast-window.sh --watch` 实测窗口 `layer=25 alpha=1.00 x=916 y=80 w=87 h=39`（中心 959.5 = 主屏 midX 960，距可见区顶部 80 pt），出现到消失 **983 / 987 ms**；日志 `toast 显示` → `toast 隐藏` 间隔 **1.014–1.098 s**；改 12 字名字 → 加载后截到 10 字并原样显示在 toast 里（`toast 显示「一二三四五六七八九十」`）；无名字的桌面回落「桌面 1」；空绑定行被自动清理；**切 4 次桌面（含 4 次 toast）前后 `defaults read com.apple.dock` 逐键相同** |
| **P3 桌面页 + 自动切换** | 桌面 Tab 的 Dock 部分（绑定与 override）、切换时自动应用、防抖合并、内容相同跳过、预应用、自动回存 | 桌面 1 与桌面 2 配置不同，来回切 20 次结果稳定（脚本断言）；两桌面配置相同时切换无 Dock 刷新；在真实 Dock 手动拖入一个图标，切走再切回仍在；还原期间不产生误回存 |
| **P4 无痕与自愈** | 退出还原全链路（菜单退出 / Cmd+Q / 注销关机）、退出前等待重载完成、`session.state` 残留检测、登录启动、Dock 未归位兜底、备份恢复 UI、`mru-spaces` 开关 | ① 正常退出后 `com.apple.dock` 逐键等于 baseline；② `kill -9` 强杀后重启 App，自动还原 baseline 并给出提示；③ 注销/重启后 Dock 为 baseline；④ 人为杀掉 Dock 后 3 秒内自动恢复；⑤ 连开三次 App 并每次还原，结果稳定幂等 |
| **P5 收尾** | 多显示器与热插拔、全屏过滤回归、README（含完全卸载与还原步骤） | 插拔外接显示器后映射不串；README 还原步骤实测可让 Dock 回到初始状态 |

---

## 5. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 主动切桌面的私有 API 失效 | 菜单栏切换不可用 | ✅ P0 已验证可用（20 ms）。仍保留 `SpaceProvider`/`SpaceSwitcher` 协议隔离，失效时降级为"仅跟随 + 手动改 Dock"并在 UI 报警 |
| **切桌面后收不到空间变化通知** | 跟随滞后或漏更新 | ✅ P0 已确认（程序化切换不触发通知）→ 事件源改为 **300 ms 轮询为主**；自己发起的切换一律**预应用**，不等通知 |
| 无热重载，切桌面必然重启 Dock | 切桌面 Dock 闪一下 | ✅ P0 实测仅 **约 101 ms**（SIGHUP）。内容相同直接跳过；连击合并；预应用；UI/README 明示"约 0.1 秒" |
| **SIGTERM 的 255 ms 清理窗口覆盖我们的写入** | 应用不生效 | ✅ 已实现：应用后读回校验，不一致重试一次（SIGTERM 仅作 SIGHUP 的兜底）。P2 实测 SIGHUP 路径每次一次过，重试由单测覆盖 |
| **Dock 回写 `GUID` 是异步的** | 拿"GUID 是否被补全"当判据时会误判成"写入没生效" | 判据必须配轮询（P2 实测 apply 返回后立刻读还是 nil，200 ms 内出现） |
| **验收窗口期内用户手动改 Dock** | 验收报假失败（实测踩过一次） | 验收测试开头 dump 全量域、结尾比对；判据放宽成"差异只能落在白名单键或 `{mod-count, recent-apps, trash-full}` 上"；文档明示别在跑的时候改 Dock |
| **`plutil -p` + `diff` 比对长数组会错位** | 产生假差异，误导判断 | 判断"成员/顺序"抽标签序列比；判断"值"用 `PlistValue` 结构比较 |
| **无条件退出还原会抹掉用户自己拖的图标** | 用户手动改动被吞 | `LifecycleController` 只在 `sessionChangedDock`（本次运行改过 Dock）时才还原；另外还原前比一次白名单键，已与基准一致就跳过 |
| **默认 Dock 为空时误点「立即应用」会清空 Dock** | 用户 Dock 被清空 | 空配置直接拒绝应用并记 WARNING；UI 上禁用按钮 + 橙色警告引导先「从当前 Dock 抓取」 |
| **规范化启动台条目会抹掉真实域里的 `GUID`/`book`** | 每次编辑都逼 Dock 重新推导，无谓改动用户数据 | `DockStripRules.normalizedApps` 优先复用已有的启动台条目，只有域里没有时才现造 |
| **`.app` 的 `_CFURLString` 少了尾斜杠** | 与真实域格式不一致 | 统一走 `DockTile.directoryURLString(for:)` 补尾斜杠，单测覆盖 |
| **拖拽排序过程中连续落盘 + 重启 Dock** | 拖过一个图标写一次盘、重启一次 Dock | `dropEntered` 只改内存（`AppState.setDefaultDock`），`performDrop` 才落盘 + 应用一次 |
| **强杀/崩溃时来不及还原** | 用户退出后 Dock 停留在非原始状态 | `session.state` 标记 + 下次启动自动还原；P4 专门验收 `kill -9` 场景 |
| **还原等待不充分就退出进程** | 用户看到"Dock 没还原" | `terminateLater` 挂起退出，等 Dock 归位确认（上限 5s）后才真正退出 |
| 还原动作被自动回存逻辑误记 | 配置被污染 | 还原期间停止 DockWatcher（3.8 边界约定） |
| 空间切换带动画、无可调时长 | 切换到"下一个桌面"不是瞬时 | 接受系统动画；预应用让切换结束时 Dock 已正确 |
| `mru-spaces = 1`（本机会命中） | 桌面顺序被系统重排，"下一个"不符合直觉 | 设置页显式开关，用户主动关闭；不静默修改 |
| 写坏 Dock 配置 | 用户 Dock 损坏 | 首次写前全量基准 + 每轮备份；只覆盖白名单键；单次原子写；一键还原；README 给出 `defaults import` 还原步骤 |
| 与用户在真实 Dock 上的手动改动互相覆盖 | 改动被吞 | 3 秒保护窗口 + 归一化指纹 + 自动回存 + 历史版本 + 可关闭 |
| 全屏 App 空间混入 | 每次全屏都切 Dock | `type != 0` 过滤 |
| **toast 抢焦点** | 用户切过去正要打字，字打进 toast | `canBecomeKey` / `canBecomeMain` = false，用 `orderFrontRegardless()` 显示 |
| **toast 挡住点击** | 1 秒内点不到下面的东西 | `ignoresMouseEvents = true` |
| **toast 只在自己所在的空间显示** | 切过去反而看不见，功能像失效 | `collectionBehavior` 必须含 `.canJoinAllSpaces` + `.fullScreenAuxiliary` |
| 连击切桌面时 toast 串台 / 闪烁 | 显示旧名字，或被旧计时器提前收走 | 单一 `ToastPresenter`：换文字 + 重置计时，绝不并发多个计时器 |
| 从全屏 App 空间退回桌面误弹 toast | 噪音 | 只在「用户桌面 → 用户桌面」时弹（要求上一次通知值也非 nil） |
| 名字超长 / 手改 `config.json` 塞超长名 | 设置页与 toast 布局被撑破 | 输入框计数 + 模型层 `DesktopNaming.normalize` 归一化，两层防线，单测覆盖 |
| **输入框边打字边截断会打断中文输入法组字** | 拼音打不出字 | 输入框不做即时截断，只在回车/失焦时归一化（草稿留本地 `@State`） |
| **`orderOut` 后窗口在 CG 窗口列表里滞留数秒** | 用窗口元数据验收会把「消失」时刻判晚 | 判别式带 `onscreen == true`；`check-toast-window.sh` 已按此实现 |
| 显示器插拔后 `displayUUID` 映射不到 `NSScreen` | toast 出现在错误的屏幕 | 回落 `NSScreen.main`；P5 多显示器阶段回归 |
| Dock tile 的 `book` blob 过期 | 图标显示异常 | 比对时剔除该字段；若实测异常，写入时剥离 `book`/`file-mod-date` 让 Dock 重建（备选开关） |
| 未签名登录项注册失败 | 开机不自动跑 | SMAppService 失败即退回 LaunchAgent |
| 桌面被系统删除/重排后映射错位 | 配置串桌面 | 以 `spaceUUID` 为键；失效绑定标记为孤儿并在设置页提示"重新绑定/清理" |

---

## 6. 需要你确认的几处理解

> **状态（2026-09-18）：第 1 条仍未回答。** 它会阻塞 P3（桌面页），做之前必须问清。
> 第 2–5 条已在 P2.5 / P2 按下面的理解实现（不合意随时改，改动量都在一处）。
> 其余未解决事项见 `AGENTS.md` §6。

**1（阻塞 P3）**：「桌面」页里每个桌面的**"位置"**，我理解为 **Dock 在屏幕上的位置（下/左/右）与大小**，与「通用」页的默认 Dock 设置同一套含义；每个桌面未单独设置时继承默认值。

如果你指的是别的意思（例如桌面在列表里的排序、或桌面壁纸相关），告诉我，我改。

**2（不阻塞，已实现）**：toast 在桌面**没有自定义名**时显示「桌面 N」，而不是什么都不显示。理由：切换后总有反馈，不会时有时无。如果你只想在起过名的桌面上显示，说一声。

**3（不阻塞，已实现）**："屏幕中上部"实现为 **距显示器可见区顶部 80 pt、水平居中**（实测窗口 `y=80`、中心 959.5 ≈ 主屏 midX 960）。觉得太高或太低给个数值即可。

**4（不阻塞，已实现）**：10 个字符按**字素簇**计——中文算 1 个、emoji 算 1 个。若你想按**视觉宽度**算（中文 2、英文 1），说一声。

**5（P2 新增，不阻塞，已实现）**：**默认 Dock 为空时不自动抓取，也不允许应用。** 首次打开设置页，「默认 Dock」编辑条是空的，会显示橙色警告并禁用「立即应用」，需要先点「从当前 Dock 抓取」。
- 为什么不自动抓：一是避免首启就写盘（§2 的无痕原则）；二是更重要的——如果自动抓了却抓失败/抓到空的，用户点「立即应用」就会把 Dock 清空。宁可多一步手动，也不要一个可能清空 Dock 的路径。
- 如果你更希望"首次运行自动把当前 Dock 存为默认"，说一声，改动很小。

---

## 7. 与上一版的差异

1. 增加了**主动切换桌面**（菜单栏单击循环、菜单点选），依赖 `CGSManagedDisplaySetCurrentSpace`。**P0 已实测：可用，20 ms 生效，但不触发空间变化通知**（详见 `docs/spikes.md`）。
2. UI 从"配置列表"改为**按桌面的可视化 Dock 编辑器**（通用页 = 默认 Dock，桌面页 = 各桌面 Dock），面向桌面而非抽象配置。
3. 增加了 Finder / Launchpad 固定、从 Finder 拖入拖出、Dock 大小与位置的图形化编辑。
4. `mru-spaces` 由"完全不碰"改为"设置页显式开关"，因为它会直接破坏循环切换的直觉。
5. **新增无痕原则**：基准快照 + 退出还原 + 强杀后的启动自愈，确保 App 不永久改变用户 Dock（默认 Dock 初始化为基准，因此刚装完不做任何事时 Dock 分毫不动）。
6. **P0 实测后修正了三处设计假设**（详见 `docs/spikes.md`）：① 不存在 Dock 热重载，主路径从"通知/信号热重载"改为"SIGHUP 重启，约 101 ms"；② 程序化切桌面不触发空间变化通知，事件源主次从"通知为主"反转为"300 ms 轮询为主"；③ Finder 在 plist 中无任何表示，钉住无需代码。
7. **新增桌面命名与切换提示**（§3.10）：桌面页可为每个桌面起名（**≤10 字符**，仅存本地，macOS 15 无系统接口）；切换桌面时在屏幕中上部弹一条 **1 秒**的 toast 显示该名字。实测确认 `displayUUID` 可映射到 `NSScreen`，且整条链路**零系统权限**。这一步不写 Dock，因此单列为 P2.5、可插队先做 —— **已于 2026-09-18 完成并实测通过**（见 §4）。
8. **P2 落地后补了几条实现约定**（都与计划原文有意不同，理由见 §3.4–§3.7 的「P2 实现记录」）：① 校验指纹只比**实际写进去的键**（本机缺失的外观键算进去会产生假阴性）；② **绝不写当前域里不存在的键**，缺失的键报告给 UI 并禁用对应控件；③ `.app` 的 `_CFURLString` 必须**带尾斜杠**，用户 App 的 `dock-extra` 用 `true`；④ **启动台条目原样复用**已有的（保住 `GUID`/`book`），不无条件重建；⑤ **退出还原有门槛**（只在本次运行改过 Dock 时才还原），并且"已与基准一致就跳过"；⑥ **默认 Dock 为空时拒绝应用**（见 §6 第 5 条）。

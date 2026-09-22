# MultiDock：每个桌面一套原生 Dock + 桌面切换器

## 0. 目标

菜单栏常驻一个图标，管理多桌面下的原生 Dock：

- **菜单栏**：单击图标 → 切到下一个桌面（循环）；`⇧`+单击 → 切到上一个桌面（循环）；右键 / ⌥+左键 → 下拉菜单，列出所有桌面（点选即切换）、进设置、退出。
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
| **主动切桌面** | `CGSManagedDisplaySetCurrentSpace` **符号存在**（`CGSManagedDisplayGetCurrentSpace` 也在）→ 菜单栏"切下一个桌面"可实现。**实测 0–6 ms 生效 —— 瞬时硬切，没有过渡动画**。⚠️ 这里原先写的是"约 20 ms、带系统自带的滑动动画"，**2026-09-18 复核证伪**：那 20 ms 是 P0 用 1 s 轮询粒度测出来的粗值。想加动画的四条路全走死，见 `docs/spikes.md` 实验 7 |
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
│   ├── Spaces/ScreenNaming.swift       显示器名：displayUUID → NSScreen.localizedName（桌面页按显示器分组）
│   ├── Dock/DockPreferences.swift      CFPreferences 读写 + 键白名单
│   ├── Dock/DockConfig.swift           模型、tile 构造、归一化指纹
│   ├── Dock/DockController.swift       应用流水线、防抖合并、内容相同则跳过（**P2 已实现**）
│   ├── Dock/DockReloader.swift         SIGHUP 为主 + SIGTERM/kickstart 兜底（**P2 已实现**）
│   ├── Dock/DockStripRules.swift       图标条规则：启动台固定在首位、Finder 幻影、从 .app 造条目、其他项只搬不造（**P2 / P5++**）
│   ├── Dock/DockWatcher.swift          识别用户在真实 Dock 上的手动改动并回存（**P3**）
│   ├── Dock/DockEditHistory.swift      回存的旧配置暂存（内存撤销栈），供电「撤销自动回存」（**P5**）
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
├── scripts/preview-toast.swift         离线预览 toast 外观：假壁纸上画亮/深两颗胶囊出 PNG（cacheDisplay 抓自己的视图，零权限）
├── scripts/check-fullscreen-filter.swift  真机回归全屏过滤：把本进程窗口切成全屏造出 type=4 空间（零权限）
├── scripts/spike-symbols.swift         枚举 SkyLight 导出符号（内存内解析 Mach-O，零权限，查"有没有对应私有 API"）
├── docs/spikes.md                      P0 结论（含对本文档的多处修正）
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
- **切桌面的过程本身没有动画**（**不做，别再试**）。程序化 `CGSManagedDisplaySetCurrentSpace` 是**瞬时提交**（实测 0–6 ms），
  SkyLight 不暴露"带过渡地切到某空间"的入口；唯一像入口的会话级开关 `SLSSetSessionSwitchCubeAnimation`
  **写后读不回**（无 getter、偏好域里也没有），改了就还原不回去 → 违反无痕原则；
  `SLSWillSwitchSpaces` 签名未知、猜错会直接把进程打死在 SkyLight 内部。
  真正的过渡动画由 WindowServer 的 `Transition*Metal` 内部类驱动，只服务于**用户手势**（触控板横扫 / `Ctrl+←`）。
  完整证据见 `docs/spikes.md` 实验 7。**切桌面时 Dock 该闪还是会闪（约 101 ms），这是重载 Dock 的代价，不是动画。**
- 事件源（**P0 实测后反转了主次**）：**300 ms 轮询为主**，`NSWorkspaceActiveSpaceDidChangeNotification` 为辅。原因是实测发现程序化切桌面时该通知根本不触发（对照实验证明通知通道本身正常），所以通知只能当"用户主动切换时的快速通道"来降低延迟。两条路都进同一个幂等的 `handleActiveSpaceChanged()`，用 `(displayUUID, spaceUUID)` 去重。
- **我们自己发起的切换必须预应用**（§3.4 第 8 条）：切换后收不到任何通知，不能等通知回来才动 Dock。这条从"优化"升级为"必需"。
- `SpaceProvider` 协议隔离私有 API；失效时降级为"只能手动改 Dock、不能自动跟随与切换"，并在 UI 明确报警，而不是静默失效。
  ✅ **已落地（2026-09-18）**：设置窗口顶部的 `WarningBanner` 读 `AppState.spaceProviderWarning`，
  显示橙色的「桌面切换不可用」+ 具体原因。原先只写日志和调试面板 —— **用户不看日志，等于没报警**。

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

**正常退出流程**（`LifecycleController`，2026-09-19 按 `docs/spikes.md` **实验 10** 重写）：

```
收到退出请求（菜单退出 / Cmd+Q）
  → NSApp.reply(toApplicationShouldTerminate: .terminateLater) 挂起退出
  → state.prepareForTermination(settleLimit: 2s)
        停 DockWatcher → 停存活监视器 → dropPendingRequests()（没起跑的待办直接丢）
        → 带上限地等自愈（轮询 selfHealFinished）→ 带上限地等在飞的应用（轮询 drainTask）
  → 写入基准快照的白名单键（其余键不动）→ reloadForQuit()：一发信号 + 最多 1.5 s 看一眼
        不等重启节流、不升级到 SIGTERM、不 launchctl kickstart、校验不一致也不重试
  → 成功且退出前真的干净 → 删除 session.state；否则保留标记（needsSelfHeal + pid = 0）
  → NSApp.reply(toApplicationShouldTerminate: .terminateNow)
```

- **绝不在还原未完成前就退出进程**，否则用户会看到"退出后 Dock 还是错的"。
- **但也不能等满**：退出场景等 Dock 归位换不到任何**可行动**的信息（偏好是原子写的，
  Dock 下次启动自然读到基准；唯一能纠正"升级也没用"的手段是下次启动的自检，而它不看这次等了多久）。
  旧写法（复用完整降级链）实测每次退出 **53–54 秒**没有 Dock、没有壁纸、触控板手势失效。
- **所有"带上限的等待"必须轮询可观察标志**，不能用 `withTaskGroup` 与 `await task.value` 赛跑：
  任务组闭包返回时会等所有子任务收尾，而那种子任务不响应取消 —— 上限会**静默失效**
  （返回值看着是对的，墙钟是错的）。回归守卫因此断言**墙钟**，不只断言 Bool。
- **等不到干净时必须留标记**（`!settled` → `keepMarkerAndFinish`）：那笔在飞的写入可能落在还原**之后**。
- 系统关机/注销同样走这条路（`NSWorkspace.willPowerOffNotification`），但**系统不给等待时间**，
  只能尽力：先把债务写进标记，再发起还原；没跑完的由下次启动自愈接手。
- 崩溃/强杀走不了钩子，由下次启动的 `session.state` 检测兜底——这是无痕原则的最后一道防线，必须有测试覆盖。

### 3.4 应用流水线（DockController）

1. 目标配置 = `binding.override ?? defaultConfig`。
2. **内容相同即短路（两条，缺一不可）**：① 归一化指纹与"当前已应用"一致；② **真实 Dock 已经就是这份内容**（读回口径逐键相同）。任一命中 → 直接返回，**不写、不备份、不重启 Dock**。两个桌面共用同一份 Dock 时，切桌面零开销、零闪烁。
   - 只有 ① 是不够的：它比的是"**我们上次写下去的那份**"，一旦发生过**外部改动**（用户手拖图标、别的 App 改、或 `DockWatcher` 刚回存的那份）它就**过期**了，再应用一份与真实 Dock 完全相同的配置会白写一遍 + 白重启一次 Dock。
   - ② 的判据**必须复用写入校验（第 6 条）的同一套比较** —— 这样"跳过"与"写下去之后立刻验过"**严格等价**，不会出现"以为不用写、其实该写"的漏写。
   - 短路时同时把"此刻真实 Dock"记成已应用状态（`adoptLiveDockAsApplied()`），顺带打开 `DockWatcher` 的回存闸门；**但不设 `appliedAt`** —— 那不是我们写的。
   - 实测代价：逐桌面 Dock 的桌面在回存时原来会白重启一次（`PID 68667 → 68672`，约 50 ms 闪烁），补上 ② 之后为 `68995 → 68995`。详见 `AGENTS.md` §6.3 D24。
3. 备份当前 `com.apple.dock` 全量域到 `backups/`。
4. 读当前**全量**域 → 用配置覆盖白名单键 → 其余键（热角、启动台等）原样保留 → `CFPreferencesSetMultiple(..., kCFPreferencesCurrentUser, kCFPreferencesAnyHost)` + `CFPreferencesAppSynchronize`。单次原子写，不用 `defaults` 逐条拼。
5. 触发 Dock 重载（见 3.5）。
6. 记录 `appliedFingerprint`、`appliedAt`、`reloadMethod`、耗时 → 调试面板可见。
7. **防抖合并**：连击切桌面时只对最终落点执行一次；应用进行中目标又变化 → 记 `pendingTarget`，本轮结束立即补跑。
8. **我们自己切桌面时预应用**：点击"下一个桌面"时已知目标，先 apply 再切空间，切换动画结束时 Dock 已是正确状态（不等通知回来才动）。

> **P3 实现记录（2026-09-18）—— 第 8 条的准确含义（实测后修正措辞）**
>
> 原文"先 apply 再切空间"容易被读成"切空间之前 Dock 已经重启完"，**那物理上做不到**：
> 一次应用要先写偏好、再重启 Dock，而 Dock 重启本身约 **101 ms**（SIGHUP，P0 实测），
> 比 `CGSManagedDisplaySetCurrentSpace` 返回（实测 0–6 ms）慢一个量级。任何实现都无法在切空间前完成重启。
>
> 第 8 条真正要保证的是：**发起**应用与切空间在同一拍，**不等 300 ms 轮询**发现变化才动。
> 代码里 `AppState.switchToNextDesktop()` / `switchTo(_:)` 先调 `switcher.target(_:)` 算出目标、
> `applyConfigForDesktop(target)`（同步建好 `DockController` 的 drain 任务），再调 `switcher.switchTo(target)`。
> 于是写偏好 + 重启 Dock 与系统切换动画（约 300 ms）重叠，动画结束时 Dock 已经是对的。
>
> 验证方式：`DockController.isApplying` 在 `switchToNextDesktop()` 返回后立刻为 `true`
> （`request()` 同步建任务），且**整个切换过程只写一次** ——
> 预应用与"切完后 observer 回调"两次请求被 `request()` 的单槽位合并成一次，不会重启两次 Dock。
> 单测：`testPreApplyAppliesTheTargetDockWithoutWaitingForThePoll`。

> **P2 实现记录（2026-09-18）** —— 第 1、2、7、8 条中，**1 已实现**（`AppState.applyDock(_:reason:)` 目前只喂 `settings.defaultDock`；`binding.override` 的选取属 P3）、**2 / 7 已实现**、**8 已实现**（P3 的预应用：发起应用与切空间同一拍，见 §3.4 的 P3 实现记录）。
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
| C. SIGTERM | `kill(dockPID, SIGTERM)`，未归位则 `launchctl kickstart` ⚠️ **P0 实验当时带 `-k`；实现已去掉 `-k`**（实验 9：带上会把 launchd 正要拉起的 Dock 再杀一次） | ✅ 生效（重启）。Dock 会先做约 255 ms 退出清理，总不可用窗口 **约 367–395 ms** |

> **不存在热重载**。写偏好后必须重启 Dock 进程，没有零闪烁方案。

**决定：主路径 = B（SIGHUP），兜底 = C（SIGTERM + kickstart）。** SIGHUP 比 SIGTERM 快约 4 倍（101 ms vs 395 ms），因为 SIGTERM 会被捕获并触发 Dock 的退出清理。UI 与 README 的措辞为「切换桌面时 Dock 会刷新约 0.1 秒」。

**关键坑（已验证 launchd 配置）**：绝不能用"优雅退出"（AppleEvent quit）——`SuccessfulExit = 0` 意味着 exit 0 时 launchd **不会**拉回 Dock，用户会当场失去 Dock。只走信号路径 + kickstart 兜底。

**竞态风险（实现时必须处理）**：SIGTERM 前有约 255 ms 清理窗口，Dock 可能在退出前回写自己的状态从而覆盖我们的写入。实测未发生，但**不能假设永远安全**——应用后用指纹校验，不一致则重试一次。

**体验补偿**（仍然有效）：3.4 的"内容相同则跳过"让共用同一份 Dock 的桌面切换零开销、零闪烁；"预应用"让切换动画结束时 Dock 已正确。

> **P2 实现记录**：`DockReloader.reload(strategy:)` 按 **SIGHUP → SIGTERM → `launchctl kickstart`** 三级降级，每级都轮询等一个**不同于旧 PID** 的新 Dock 进程出现（判据是 PID 变化，不是"Dock 还在"）。`fallbackGrace`（默认 500 ms）是发完 SIGTERM 后、动 kickstart 之前的宽限。实测 SIGHUP 每次一次过，`verifyAttempts == 1`。
>
> **2026-09-19 两处修正**（真机"切一次桌面黑屏几分钟"，见 `docs/spikes.md` 实验 9）：
> ① 每级的超时从 5 s 提到 **30 s**。5 s 短于 launchd 的退避尺度（实测几十秒），于是一次正常的慢拉起
> 被误判成"SIGHUP 失败"，紧接着升级到 `SIGTERM` + `kickstart -k` —— 那一发 `-k` 把 launchd 正要拉起的
> Dock 又杀一次，退避被自己续上，缺失从 1 秒滚到 119 秒。
> ② **`kickstart()` 绝不能 `waitUntilExit()`**：launchd 在退避时这条命令会阻塞几十秒（实测 54 / 60 / 64 s），
> 而它跑在 `@MainActor` 上，整个 App 连带冻住（存活监视器本该每 2 秒一行日志，那两分钟里只有一行）。
> 现在发完就走、子进程由 `LaunchctlParking` 持有到退出，且**在飞的不叠加**（重复 `-k` 正是退避的成因）。
>
> **P0 的竞态风险实测未发生**：多轮 apply 都是第一次校验就过。重试路径由单测 `testRetriesOnceWhenDockDidNotTakeTheWrite` 用"第一次写入被吞掉"的替身覆盖。
>
> **Dock 进程查找有兜底**：非 `.app` 进程（如 `swift test` 的 xctest runner）里 `NSRunningApplication.runningApplications(withBundleIdentifier:)` 可能查不到 Dock，`dockPID()` 退回 `proc_listpids(PROC_ALL_PIDS)` + `proc_name` 扫进程表（**0.02 ms**）。
> ⚠️ 早期版本用的是 `pgrep -x Dock`（单次 **110 ms**），**早已换掉** —— 别照旧文档改回去。
>
> **2026-09-20 加取证**（真机偶发慢重启 26–31 秒，见 `docs/spikes.md` 实验 11.6 与实验 15）：
> 四个假说已被实验 12–14 逐个证伪，剩下的两种病因（**探测分叉** vs **Dock 真的没回来**）旧日志分不出来 ——
> 因为重载期间 `DockPresenceMonitor` 刻意静默、`waitForRestart` 只记结果不记过程。
> 所以给它加了 `DockPIDProbe` / `probeTimeline`：等待 **> 1 秒**才采样两条探测路径的答案，
> **只在答案变化时记一条**（首尾强制各一条，封顶 24 条），写进**已有的那一行** `Dock 应用成功` 日志。
> **正常路径一次都不调用 `pidProbe()`**（`testFastRestartDoesNotProbeAtAll` 守着），零开销。
> 判定规则见实验 15。**这不是行为改动，只是观测。**
>
> **2026-09-20 又补两处观测**（同一轮排查的收尾，见 `docs/spikes.md` 15.3 / 15.4）：
> ① **`waitPolls` / `waitLongestGapMS`** —— `waitForRestart` 的 `elapsed` 是墙钟，而轮询跑在 `@MainActor` 上：
> 主线程被冻住时我们**根本没在看**，却照样把整段时间记成"Dock 不可用 26046 ms"。
> 现在慢重启那一行日志会带 `轮询 N 次，最长间隔 M ms`。**判据先看 M**：M 秒级 = 观察窗口断了（我们的 bug），
> 不是 launchd 的事；次数 ≈ `elapsed / 15 ms` = 一直在看（Dock 真的不在）。只在 `elapsed > 1` 时记，快路径日志一个字节不变。
> ② `dockPID()` 的 **LS 优先已被定向测量证明安全**（6/6 轮"危险窗口 = 0 ms"），**别改它的路径选择**。
>
> **2026-09-20 A8 修法落地：别等，催**（真机偶发慢重启 26–31 秒，见 `docs/spikes.md` 实验 16）。
> 线索是真机日志里一直被忽略的半截：`05:33:16` 那次 **SIGHUP 等满 30 s 没等到，紧接着一发 `kickstart` 0.5 s 就拉回来了** ——
> 也就是说**我们手里本来就有一条能立刻拿到 Dock 的通道，只是被排在了 30 秒之后**。改动：
>
> | 改动 | 值 | 为什么 |
> | --- | --- | --- |
> | 新增 `nudgeAfter` | **500 ms** | 等待超过它还没见到新 Dock 就催一发 `kickstart`。正常路径 35–126 ms，永不触发 |
> | 新增 `nudgeInterval` | **1 s** | 重复催（⚠️ 尽力而为：`LaunchctlParking` 闸门会吞掉叠发的） |
> | `timeout` | **30 s → 3 s** | ⚠️ **这条修正了上面 2026-09-19 那条"提到 30 s"** —— 实验 16.2 实测 launchd 的节流尺度是 **1 s 硬顶、不累积**，"退避是几十秒"的前提不成立；3 s ≈ 正常值的 24 倍，够宽容 |
> | 新增 `kickstartTimeout` | **30 s** | 真正需要耐心的那一段挪到**催完之后** |
> | **PID 守卫** | 新增 | 兜底原本对 `dyingPID` 发 SIGTERM，若 launchd 已把 Dock 拉回来，读到的是**新** PID → 会把刚恢复的 Dock **再杀一次** |
> | 失败取证 | 修 | 三段拼接并标段名（原来把最有用的主路径那段丢了，催办记录就在里面） |
>
> 安全性前提是**实测**的：`kickstart` **不带 `-k`** 对运行中的 Dock 是无害 no-op（PID 未变、退出码 0），所以"催早了"不构成风险。
> 代价：**26–31 s → ~1–3.5 s**。⚠️ **修好的是代价，不是成因** —— `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}`
> 下"launchd 偶尔根本不调度那次重新拉起"仍未直接观测，预测与下次复现的读法见实验 16.4 / 16.8。

### 3.6 Dock 编辑条（设置页核心控件）

一个 `DockStripEditor` 组件，通用页与每个桌面的详情页复用：

- 按 location 自动横/竖排布；每项渲染 `NSWorkspace.shared.icon(forFile:)` 真实图标。
- **拖入**：从 Finder 拖 `.app` 进来（SwiftUI `onDrop(of: [.fileURL])` 读 `NSItemProvider`）；另配「从应用程序选择…」按钮走 `NSOpenPanel`，覆盖不方便拖拽的场景。⚠️ **原文这里写的是"`.app` / 文件夹 / 文件"，P5++ 已按实测收窄为只接受 `.app`** —— 理由见下方 P5++ 实现记录与 `docs/spikes.md` 实验 8。
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
> 5. ~~**竖排（left/right）暂未实现**~~ → ✅ **P5 已实现**：`orientation != "bottom"` 时 `DockStripEditor`
>    自动切成 `ScrollView(.vertical)` + `VStack`，格子改定高（`SlotSizing`）。之前位置改成左/右后编辑条仍是横的，排序会看反。
> 6. **「拖出即移除」用显式的垃圾桶投放区**（拖到编辑条外无法被检测到）。另配右键菜单「从 Dock 移除」。
> 7. **排序/拖拽的真人手感未验证**（本机无法用脚本点 UI）—— 逻辑由 `DockStripRulesTests` + `AppStateDockTests` 覆盖，真机拖拽需要用户手动试一次。
>
> **P5++ 实现记录（2026-09-18）：其他项（`persistent-others`）补上编辑入口，且刻意只"搬"不"造"。**
>
> 原文第 1 条（拖入）要求接受「.app / **文件夹** / 文件」，这一条**被实测推翻了**，改成只接受 `.app`：
>
> - **实测结论（`docs/spikes.md` 实验 8）**：自己拼的 `directory-tile` **不会被 Dock 认领**（Dock 不补
>   `GUID`/`book`，补全展示字段、甚至自己用 `URL.bookmarkData()` 生成 `book` 都不行）；
>   而**字段不全的形状会让 Dock 直接 SIGABRT**，launchd 把它拉起来又崩，形成崩溃循环 —— 用户会当场失去 Dock。
> - **所以**：拖文件夹 / 普通文件进来时**明确拒绝并说明替代做法**（在访达里自己拖到 Dock 上，
>   Dock 会写完整条目，随后 `DockWatcher` 回存进配置），不留"拖了没反应"的静默失败。
>   文案在 `DockItemRejection.message`；`NSOpenPanel` 只让选 `.app`。
> - **其他项仍然可编辑**：编辑条下方多一条「其他项（文件夹 / 堆栈）」，可**排序**（`OthersReorderDropDelegate`）、
>   可**移除**（右键菜单或共用垃圾桶），写回去的就是 Dock 自己写的 dict（`GUID`/`book` 原样保留）。
>   `DockStripRules.normalizedOthers` 只去重、**不插固定项**（与 `normalizedApps` 的区别）。
> - 域里没有 `persistent-others` 时，这一条整体禁用并写明原因（不做假开关）。
> - **回归守卫**：`DockStripRulesTests.testDockItemRejectionClosesTheFolderAndFilePaths` 钉住"这条路是关着的"；
>   真机验收 `DockAcceptanceTests.testOtherItemsRemovalAndReapplyKeepsDockHealthy` 钉住"移除后 Dock 仍存活、
>   `GUID`/`book` 一个不丢"。

### 3.7 设置窗口

> **P5++ 实现记录（2026-09-18）**：应用摘要现在**也进调试面板**（§3.4 第 6 条要求"调试面板可见"，早先只在设置页）。
> 调试面板新增「最近一次应用」一组：`结果摘要`（含重载方式与耗时）+ `内容指纹`（前两行 + 总长度，便于对照日志）+
> `写入时刻`（绝对时间 + 距今秒数）+ `本次运行改过 Dock` + `回存闸门`。

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
- 「上一个桌面」+ 一条禁用提示「（⇧+左键点菜单栏图标同效）」
- 「用当前 Dock 重置本桌面配置」
- 分隔线 → 「设置…」「退出并还原 Dock」
- **交互**：左键单击 = 切下一个桌面；**`⇧`+左键 = 切上一个桌面**；右键 / ⌥+左键 = 下拉菜单。
  设置里可把左键改为"打开菜单"（照顾不习惯的人）——**改成"打开菜单"后 `⇧`+左键也一并走菜单**，避免留一个隐形的第二行为。
- 菜单栏图标显示当前桌面序号（如 `2`）便于一眼确认。
- tooltip 写清三种点击：`左键切下一个桌面，⇧+左键切上一个，右键打开菜单`。

> **P2 实现记录** —— 通用 Tab 已接上：**默认 Dock 编辑条 + 「立即应用」+「立即还原到原始 Dock」+「把当前 Dock 设为新基准」+ 本机不支持键的提示**。`mru-spaces` 开关、位置/大小控件、`largesize` 等属 P3/P4。
>
> - **默认 Dock 为空时不自动抓取**：避免首启就写盘、更避免"用户没配过就点应用 → Dock 被清空"。改为显示橙色警告 + 禁用「立即应用」，引导用户先点「从当前 Dock 抓取」。这是与计划原文的一处**有意加严**（见 §6）。
> - **退出还原只在"本次运行改过 Dock"时才执行**（`LifecycleController.sessionChangedDock`）。不能无条件还原——用户可能在运行期间自己拖了图标，写回基准会把他的改动一起抹掉。另外还原前会比一次白名单键，已经与基准一致就跳过，省掉一次没必要的 Dock 重启。
> - **`AppState` 的依赖全部可注入**（`dockController` / `configStore` / `baselineStore`），且 AppState 内部**不直接调 `DockPreferences.readDomain()` 这类静态入口**——那会绕过注入点，测试里会读到真实系统的偏好域。要读就走 `DockController.readDomain()` / `captureLiveDockConfig()`。
>
> **P3 实现记录（2026-09-18）** —— 两个 Tab 的形状与计划一致，具体落地如下：
>
> - **通用 Tab**：默认 Dock 编辑条 + **其他项（文件夹 / 堆栈）**一条 + **默认 Dock 的外观**（`DockAppearanceEditor`）+ 应用区（立即应用 / 立即还原到原始 Dock / 把当前 Dock 设为新基准 / 撤销自动回存 + 应用摘要）+ 菜单栏交互 + 桌面切换 toast 开关 + 退出行为 + **启动与自愈** + **桌面行为（`mru-spaces`）** + **备份与还原** + Dock 应用开关（编辑后立即应用 / 识别手动改动并回存 / 重载方式）+ 本机不支持键。（`mru-spaces` 已在 P4 落地 —— 这里原先写着"仍未做"，已过时。）
> - **桌面 Tab**：由 `UI/DesktopListView.swift` 承载 —— 左侧桌面列表（就地改名 + `n/10` 计数 + 「独立 Dock / 沿用默认」徽标 + 当前桌面标记 + 刷新按钮），右侧详情（沿用默认开关 → 无 override 时给「复制默认 Dock 到本桌面」提示，有 override 时给完整图标条 + 外观编辑器 + 「立即应用」/「从当前真实 Dock 抓取」/「重置为默认」）。**「位置」= Dock 屏幕位置 + 大小**（用户已确认，见 §6）。
> - **菜单栏下拉**：桌面列表（当前项打勾，点选即切）→「下一个桌面」→**「上一个桌面」**（附禁用提示「（⇧+左键点菜单栏图标同效）」）→**「用当前 Dock 重置本桌面配置」**→「刷新桌面列表」→ 调试面板… / 设置… → **「退出并还原 Dock」**（标题写清会还原，避免误解）。
>   - **`⇧`+左键 = 切上一个桌面**（2026-09-18 加）。走的是与「下一个桌面」**完全对称**的一条链路：同一个 `switcher.target(.previous)`、同一次 `applyConfigForDesktop` 预应用，两端循环。单测 `testPreviousDesktopPreAppliesItsOwnDock` 断言"预应用真的发生 + 目标是对面那个桌面的 Dock + 只写一次"。
>   - 「用当前 Dock 重置本桌面配置」的语义是**不新增绑定**：当前桌面有独立 Dock 就覆盖它，没有就覆盖**默认 Dock**（凭空造 override 会让该桌面悄悄脱离默认）。
> - **编辑器的读写必须分开**：`AppState.setDockConfigInMemory` / `setDockAppearanceInMemory` 只改内存，`dockEdited(_:reason:)` 才落盘 + 按开关应用；默认 Dock 与逐桌面 override 共用 `DockEditTarget`（`.defaultDock` / `.desktop(space)`）一套入口。`DockAppearanceEditor.onCommit` 只在**滑杆松手 / 开关值变化**时提交 —— 逐帧落盘会让拖一次滑杆重启几十次 Dock。
>
> **P5++ 实现记录（2026-09-18）—— 桌面列表的「显示器名」，以及通用页的「其他项」一条：**
>
> - **桌面列表按显示器分组**：原文要求"显示器名 + 名字 + 当前绑定状态"。落地方式是
>   `List` 里按 `displayUUID` 分组、`Section` 标题就是显示器名（`Spaces/ScreenNaming.swift`：
>   `CGDisplayCreateUUIDFromDisplayID` 与 SkyLight 的 `Display Identifier` 实测逐字符相同），
>   详情页另加一行「显示器：…」（tooltip 给完整 `displayUUID`）。
>   **映射不到时不回落成某台真实显示器的名字** —— 显示"未识别显示器（UUID 前 8 位…）"，
>   因为显示一个错的屏比显示"未识别"更糟。屏幕插拔时随 `didChangeScreenParametersNotification` 一起刷新。
> - **通用页与桌面页的编辑条下方都多了「其他项（文件夹 / 堆栈）」一条**：只显示 / 排序 / 移除，
>   **不新建**（规格与实测依据见 §3.6 的 P5++ 记录与 `docs/spikes.md` 实验 8）。
> - **拖入被拒时的文案在 UI 里说清**（`DockItemRejection.message` + 「知道了」按钮）：
>   早先版本拖文件夹进来是静默失败。

### 3.8 手动改动的自动回存（DockWatcher）

- 每 2 秒读白名单键，比对**归一化指纹**：tile 用"规范化 URL + file-label + bundle-identifier + tile-type 的有序序列"，外观用键值字典。
- 归一化**必须剔除** Dock 每次重载都会重算的字段：`GUID`、`file-mod-date`、`parent-mod-date`、`book`（Data blob）。
- 指纹变化且不在 3 秒保护窗口内（我们自己刚写完）→ 判定为用户在真实 Dock 上手动改动 → 覆盖当前桌面的配置（用默认 Dock 的桌面则更新默认 Dock），覆盖前存一份历史版本。
- 可在设置里关闭自动回存；关闭后只认 App 内的编辑。
- **与还原的边界**：还原期间（退出流程中）Watcher 必须停止，否则会把还原动作误判成用户改动写进配置。
- **与 Dock 存活的边界**（2026-09-19 加，`isDockPresent` 闸门）：**Dock 进程不在时一律不采样**。
  那个窗口里偏好域读回来是残缺的 —— 真机实测读到「3 个图标、0 个其他项」（真实 Dock 是 15 + 1），
  被当成用户改动回存，把两个桌面的 override 写坏了。Dock 回来之后的第一次读只用来**对齐基线**
  （`needsRebaseline`），不补一次回存 —— 中间态本来就无法和用户改动区分。

> **P3 实现记录（2026-09-18）—— 判据与计划原文不同，以这里为准**
>
> 计划原文写的是"3 秒保护窗口"，实现时改成了**更准的判据**：不比时间，比**内容**。
>
> 每轮取当前真实 Dock 的**可比指纹**（`DockController.currentComparableFingerprint()` —— 与写入校验同一口径：只算白名单里**当前域中真实存在**的键），与上一轮比：
>
> | 情形 | 处理 |
> | --- | --- |
> | 没变 | 什么都不做 |
> | 变了，且等于 `appliedComparableFingerprint`（我们上次写下去的那份） | **我们自己的写入**，忽略 |
> | 变了，且不等于 | **用户改的** → 回存 |
> | 本次运行还没写过任何东西（`appliedComparableFingerprint == nil`） | **一律不动** |
>
> 为什么放弃"时间窗口"：Dock 重启后会把我们写下去的内容**规范化回写**（补 `GUID` 等），指纹必然变化；用时间猜"这是不是我造成的"不可靠，用内容比则确定。实测 20 次来回切换**误判 0 次**。
>
> 另外两处保护：`AppState.handleDockOutcome` 在 `.applied` 时 `acknowledge` 一次；`handleUserDockEdit` 回存期间**停掉 watcher**，写完再开。都是为了避免把自己的写入当成用户改动。
>
> **回存落点**：当前桌面有 override → 覆盖它；没有 → 覆盖**默认 Dock**（不凭空造 override）。当前不在用户桌面上（例如正处在全屏 App 里）→ 覆盖默认 Dock。
>
> **P5 实现记录（2026-09-18）** —— "覆盖前存一份历史版本"做成了**内存撤销栈**，不是落盘的文件堆：
>
> - `Dock/DockEditHistory.swift`：回存覆盖前把旧配置压栈，每个目标保留 5 层；桌面页与通用页各有一个
>   「撤销自动回存」按钮（没得可撤时禁用）。
> - **为什么不落盘**：落盘一堆没有恢复入口的文件是花架子，用户翻到 `history/` 也用不上。
>   回存要防的风险只有一个 —— "误判一次，把用户在真实 Dock 上的改动写坏了配置"，一步撤销就够。
>   真正要长期保命的是 `baseline.plist` 与 `backups/`，那两个一直在落盘。
> - **撤销后 watcher 不会立刻再触发**：它只在**真实 Dock 的指纹变化**时才回调，撤销改的是配置、没动 Dock。
> - 回存落点与 `handleUserDockEdit` 同一口径：活动桌面有独立 Dock → 撤到该桌面；否则 → 撤到默认 Dock。
>   API 因此**不收参数**（`undoLastAutoCapture()`），落点一律按当前活动桌面算。

### 3.9 登录启动与自愈

- 登录项优先 `SMAppService.mainApp`；未签名构建下注册失败则退回 `~/Library/LaunchAgents/local.multidock.loginitem.plist`（`RunAtLoad`，**刻意不设 `KeepAlive`**：这是登录启动项不是守护进程，退出 App 后不该被反复拉起）。
- 启动顺序固定为：**检测残留 session.state → 必要时还原基准 → 应用当前桌面配置 → 建立会话标记**。
- Dock 重启后未归位 → 先**等**，等满了才 `launchctl kickstart`（⚠️ **不带 `-k`** —— 带上会把 launchd 刚拉活的 Dock 再杀一次并加深退避）兜底；仍异常则提示从备份恢复。
  ✅ **已落地（2026-09-18），阈值 2026-09-19 重定过**：`DockPresenceMonitor` 连续缺失达到
  `missThreshold`（默认 8 轮 × 500 ms = **4 秒**）才动手，之后每 `kickstartEvery`（60 轮 = **30 秒**）
  才催一发；缺失满 `persistentFailureThreshold`（120 轮 = **60 秒**）→ 回调 `onPersistentlyDown` 一次 →
  `AppState.dockFailureWarning` → 设置窗口顶部**红色**横幅，带「再试一次拉回」与
  「立即还原到原始 Dock」两个按钮；Dock 回来后自动撤报警并弹一条 toast。
  判据刻意用**缺失轮数**而不是 `kickstart()` 的返回值 —— 那个返回值只说明 `launchctl`
  命令跑起来了，不说明 Dock 回来了。
  ⚠️ 原来的「1 秒就动手 + 每 2 秒催一发」会把一次正常的慢恢复**自我放大成 60–126 秒的 Dock 死亡**，
  而且当时 `kickstart` 是同步 `waitUntilExit`，主线程连带冻住 —— 见 §3.5 末与 `docs/spikes.md` 实验 9。

> **P4 实现记录（2026-09-18）** —— 本节已全部落地。几处与原文不同、且不能"改回去"的地方：
>
> 1. **自愈是启动后异步跑的，不阻塞启动**。`runStartupSelfCheck` 只把残留标记记进 `pendingSelfHeal`，
>    真正的还原由 `scheduleSelfHealIfNeeded` 在观察器/监视器就位后发起（`AppState.performSelfHeal`）。
>    还原会写偏好 + 重启 Dock，放在启动路径里同步等会让 App 启动卡一秒。
> 2. **自愈债务要跨会话继承**（`SessionMarker.needsSelfHeal`）。自愈是异步的，还原途中再崩一次不能让债务丢掉：
>    `beginSession()` 会把 `state.hasPendingSelfHeal` 写进新标记。字段是**可选**的 ——
>    老版本写的 `session.state` 里没有它，用非可选会让解码失败，而解码失败等于"没有残留标记"，
>    会静默丢掉自愈能力。
> 3. **退出还原失败时标记必须留下，并标成"非活动会话"**（`keepMarkerAndFinish`：`needsSelfHeal = true` + `pid = 0`）。
>    清掉标记等于把下次启动的自愈能力一起扔了；只留标记不改 `pid` 也不行 ——
>    `detectInterruptedSession()` 会用 `kill(pid, 0)` 判断"标记是不是另一个还活着的实例"，
>    pid 为 0 时它才会跳过这个检查。
> 4. **还原前必须先 `await state.prepareForTermination()`**：停 watcher、停存活监视器、
>    `dropPendingRequests()`、带上限地等自愈、带上限地等在飞的应用。
>    等这一步不能省 —— `request()` 是异步排队的，漏掉的话那笔待办会在还原**之后**落地，
>    用户看到的结果是"退出时还原了，Dock 却还是错的"。
>    ⚠️ **但上限必须是真上限**（2026-09-19 实验 10 的修正）：原先两条等待都用
>    `withTaskGroup` 把 `await task.value` 和 `Task.sleep` 赛跑，而任务组闭包返回时会等**所有**
>    子任务收尾、`await task.value` 又不响应取消 —— 于是 2 秒上限实测成了 224–625 ms（替身）
>    乃至几十秒（真机 launchd 退避）。改成**轮询可观察标志**（`drainTask` / `selfHealFinished`）。
>    等不到干净时**返回 `false`，调用方必须留标记**。
> 4b. **退出路径不复用 `reload()`**：`DockReloader.reloadForQuit()` 只发一发信号、最多看 1.5 秒，
>    不等节流、不升级、不 `kickstart`；`DockController.apply(..., forQuit: true)` 只写一次、验一次、不重试。
>    存活监视器在此期间由 `isReloading` 闸门闭嘴（我们自己重启 Dock 不是故障）。
> 5. **注销/关机这条路系统不给等待时间**，只能尽力：先把债务写进标记，再发起还原并等它跑完；
>    没跑完的由下次启动自愈接手。**不要**改成同步阻塞等还原，那会拖住关机。
> 6. **Dock 存活监视的判据**：连续缺失 `missThreshold`（2026-09-19 实验 9 后是 **8 轮 = 4 s**）才算
>    "真的不在"，之后每 `kickstartEvery`（**60 轮 = 30 s**）才催一发，满 **60 s** 才报"拉不回来"。
>    原先的 1 s / 2 s / 6 s 会**每次正常慢恢复都动手 + 每次都误报红横幅**，而那时那一发还带 `-k`
>    —— 它会把 launchd 刚拉回来的 Dock 再杀一次、给它续退避（`-k` 已随实验 9 一起去掉）。
> 7. **备份恢复只写白名单键**，不做整域替换：我们自己从来只碰白名单键，整域替换会把用户后来改的
>    热角、启动台网格冲回旧值。需要整域恢复的场景在 README 里给 `defaults import` 的做法。
> 8. **`mru-spaces` 是白名单之外的唯一写入例外**，只给它一个窄方法（`DockPreferences.writeMRUSpaces(_:)`），
>    不开放通用的"写某个键"口子。它**不在** `apply` 的管辖范围内，写完要单独 `reloadOnly()` 重启一次 Dock。
> 9. **登录启动的状态属于系统**，不存进 `config.json`。非 `.app` 环境（`swift test`）里
>    `SMAppService.mainApp` 拿不到有效句柄 → `LoginItem.isAvailable` 先看 bundle，不可用就如实显示原因。

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

#### 外观（2026-09-19 改版：跟随亮/深色的原生 HUD 胶囊）

原先是"固定黑底 `black 0.78` + 白色 15 pt medium，圆角 12，内边距 20/10"。文件里当时的理由是
"要浮在任意背景上，固定深色底比跟随外观更可控" —— **这个理由被推翻**：`.popover` 材质配
`blendingMode = .behindWindow` 正是为"压在任意内容之上仍可读"而生的，它模糊的是**身后真实的内容**。
固定黑底是在逃避这个问题，代价是亮/深色下都是同一块死黑、而且厚重得像别的系统贴过来的色块。

| 维度 | 规格 | 为什么 |
| --- | --- | --- |
| 底 | `NSVisualEffectView`，`material = .popover`、`blendingMode = .behindWindow`、`state = .active` | 自动跟随亮/深色；`.active` 是必需的 —— 本 App 是 `LSUIElement`，窗口永远不会 key，不指定就会走灰掉的 inactive 呈现 |
| 形状 | **定高胶囊**：高 32、圆角 16；宽 = 文字宽 + 2×14，**下限 76** | 定高：高度若随文字变化，名字长短会让每次切换都看到一次跳动。下限：单字名字不能缩成一颗圆 |
| 圆角怎么来 | `maskImage`，**每次 show 按当前宽度现画一张 1:1 的图** | `NSVisualEffectView` **没有** `cornerRadius`（那是 UIKit）；而遮罩会被拉伸到视图边界，复用固定尺寸的图会把两端小圆角扯成椭圆 |
| 描边 | 1 px 内描边，动态色：亮色 `black 0.12` / 深色 `white 0.16` | 亮色下材质接近纯白，压在浅色壁纸上会和背景糊在一起，这条边是唯一把它撑出来的东西 |
| 文字 | `labelColor`，14 pt semibold | `labelColor` 在 vibrancy 视图里跟着材质走；semibold 是为了压在忙背景上仍读得清 |
| 位置 | 不变：水平居中、顶边距 `visibleFrame` 顶部 80 pt | §6 第 3 条已按 80 pt 实现 |
| 动效 | **无**（`animationBehavior = .none`） | 提示只活 1 秒，淡入淡出会吃掉可感知的停留时间，也让 `check-toast-window.sh` 的计时核对变糊。要做的话做在**内容层透明度**上，别动 `window.alphaValue`（脚本断言 `kCGWindowAlpha == 1`） |

**验收（本机不能截图，见 `AGENTS.md` §4）**：

- **纯逻辑单测**覆盖：1 秒到期消失、1 秒内连击取消重启、启动首次不弹、全屏返回不弹、无自定义名回落「桌面 N」、开关关闭时不弹但记账仍更新。**这次改版一行测试都不用改** —— 调度在 `ToastPresenter`（纯逻辑），外观在 `DesktopNameToastWindow`，两者本来就分开。
1. 外观本身用 **`scripts/preview-toast.swift`** 出图：`cacheDisplay(in:to:)` 抓**自己窗口**的视图内容
   **不需要屏幕录制权限**（拍整屏的 `screencapture` 才需要），在假壁纸上输出亮/深两张 PNG 自检材质、
   圆角、描边、字号。⚠️ 它用 `.withinWindow`（模糊窗口内的假壁纸），真机用 `.behindWindow`（模糊屏幕内容）——
   **色调/圆角/描边/字体一致，模糊到的实际画面不一致**，所以它不替代真机那一眼。
   另：该脚本是 `DesktopNameToast.swift` 的**代码副本**，改那边要同步这边。
2. 几何与窗口属性仍由 **`CGWindowListCopyWindowInfo`** 客观验证（`scripts/check-toast-window.sh`，支持 `--watch`）：MultiDock 的 toast 窗口会出现，`layer == 25`、`alpha == 1`、bounds 水平居中且贴近屏幕顶部；1 秒后该窗口消失。**读窗口元数据不需要屏幕录制权限**（只有抓图 `kCGWindowImage` 才需要）——与 P1 验证菜单栏图标（layer 25）同一手法。
   - 判别式里的 `height >= 30` 在改版后（高 32）仍然命中，**不需要为了迁就脚本保留旧的 39**。
   - ⚠️ 判别式必须带 **`onscreen == true`**：`orderOut` 之后窗口在 CG 窗口列表里**还会滞留好几秒**（实测），不滤掉的话「消失」时刻会晚报，1 秒时长就核对不准。
3. 调试面板加「测试 toast」按钮，手动触发；`multidock.log` 记 `toast 显示「X」` / `toast 隐藏` 两行带时间戳，可直接核对 1 秒。
4. ⚠️ **真机一眼仍待用户在亮色 / 深色各看一次**（切一次桌面即可）。上面的预览器能定"形状和颜色"，定不了"模糊到真实桌面之后的观感"。

---

## 4. 实施阶段与验收

| 阶段 | 内容 | 验收标准 |
| --- | --- | --- |
| **P0 实验（✅ 已完成 2026-09-18）** | ① Dock 重载 A/B/C 实测 ② `CGSManagedDisplaySetCurrentSpace` 实测 ③ Finder 表示方式 | ✅ 产出 `docs/spikes.md`。**结论**：① 无热重载，主路径 = SIGHUP（约 101 ms 不可用）② 切桌面可用（**当时测为 20 ms，后经实验 7 精测修正为 0–6 ms；无动画**）但不触发通知 → 事件源改为轮询为主 ③ Finder 无需处理 |
| **P1 骨架 + 识别 + 菜单栏（✅ 已完成 2026-09-18）** | SwiftPM 包、`build-app.sh`、SkyLightBridge、SpaceObserver、SpaceSwitcher、菜单栏下拉与单击切换、调试面板、基准快照 + 会话标记骨架。**不改任何 Dock 设置** | ✅ 全部达成：`swift build` / `swift test`（37 个测试全绿）/ `build-app.sh` 通过；**切桌面 10 次全部被记录、spaceUUID 全对、无漏报无重复**；菜单栏图标已创建（layer 25）；全屏空间不触发切换（单元测试覆盖）；`baseline.plist` 与运行时 `com.apple.dock` **34 键逐键相同**；运行前后 Dock 除 `recent-apps`/`mod-count`（系统自管，已在排除清单）外无任何差异 |
| **P2 编辑条 + 应用（✅ 已完成 2026-09-18）** | DockPreferences 读写、ConfigStore、备份轮转、`DockReloader`、`DockController`、`DockStripRules`、`DockStripEditor`、通用 Tab、手动「立即应用」、**「立即还原到原始 Dock」按钮** | ✅ **全部达成**（`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests`，真实 Dock）：apply 后与操作前全量域 diff，**变化的键只有 `["magnification","persistent-apps","tilesize"]`**（全部在白名单内，白名单外的键一个没动）；**Dock 给新写入的条目补上了 `GUID`（`i:1414651200`）** → 写入真的被读进去并重建了 Dock；还原后图标顺序逐项回到原样、白名单键逐键一致、键集合一致（34 键），**仅剩 `["mod-count","recent-apps"]`**（Dock 自己的计数器）。SIGHUP **125–138 ms**。Finder/Launchpad 无法被拖出（编辑条里没有拖拽手柄 + `DockStripRules` 保证启动台在首位）。**142 个测试全绿、零警告** |
| **P2.5 桌面命名 + 切换 toast（不写 Dock）✅ 已完成 2026-09-18** | `DesktopNaming`（归一化 + 显示名解析 + 改名规则）、`AppState.displayName(for:)` 并替换所有调用点、桌面页改名输入框、`ToastPresenter`（纯逻辑）、`DesktopNameToastWindow`（AppKit 窗口）、设置开关、调试面板「测试 toast」、`scripts/check-toast-window.sh` | ✅ 全部达成：**70 个测试全绿**、零警告；`check-toast-window.sh --watch` 实测窗口 `layer=25 alpha=1.00 x=916 y=80 w=87 h=39`（中心 959.5 = 主屏 midX 960，距可见区顶部 80 pt），出现到消失 **983 / 987 ms**；日志 `toast 显示` → `toast 隐藏` 间隔 **1.014–1.098 s**；改 12 字名字 → 加载后截到 10 字并原样显示在 toast 里（`toast 显示「一二三四五六七八九十」`）；无名字的桌面回落「桌面 1」；空绑定行被自动清理；**切 4 次桌面（含 4 次 toast）前后 `defaults read com.apple.dock` 逐键相同** |
| **P3 桌面页 + 自动切换（✅ 已完成 2026-09-18）** | 桌面 Tab 的 Dock 部分（绑定与 override）、切换时自动应用、防抖合并、内容相同跳过、预应用、自动回存 | ✅ **全部达成**（`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests`，真实 Dock）：两个桌面两套配置**来回切 20 次全部成功**，每次真实域的 `tilesize`/`magnification` 都等于目标那份；**Dock 不可用时长 45–90 ms**（最坏 90 ms，见 `spikes.md` 实验 5 的节流修复）；两桌面配置相同时 `.skippedIdentical` + `reload == nil` + `mod-count` 不变（确实没重启 Dock）；`DockWatcher` **误判 0 次**；还原后差异键 **`[]`**、图标顺序逐项一致、键集合一致（34 键）。**195 个测试全绿、零警告** |
| **P4 无痕与自愈（✅ 已完成 2026-09-18，③ 待用户注销实测）** | 退出还原全链路（菜单退出 / Cmd+Q / 注销关机）、退出前等待重载完成、`session.state` 残留检测、登录启动、Dock 未归位兜底、备份恢复 UI、`mru-spaces` 开关 | ① ✅ 还原链路由 P2 验收 + `testSuccessfulRestoreClearsMarker` 覆盖（逐键等于 baseline）。② ✅ `testSelfHealIsIdempotentAcrossThreeLaunches`（真实 Dock）：连开三次 → `[已自动还原, 已与原始状态一致, 已与原始状态一致]`，`mod-count` 三次都是 22569（第 2、3 次没有白重启 Dock），每轮之后白名单键都等于基准。③ ⚠️ **未实测**（要真注销/重启一次机器）：代码路径是"先写债务标记 + 尽力还原，没跑完的由下次启动自愈接手"。④ ✅ `testKillingDockRecoversWithinThreeSeconds`（真实 Dock）：`SIGKILL` 后 **1072 ms** 归位（上限 3 s），恢复后白名单键与键集合都与杀之前一致。⑤ ✅ 同 ②。**239 个测试全绿、零警告** |
| **P5 收尾（✅ 已完成 2026-09-18，仅多显示器实测待用户插屏）** | README（含完全卸载与还原步骤）、多显示器与热插拔加固、全屏过滤回归、编辑条竖排、孤儿绑定、回存撤销 | ① ✅ README 整篇重写：完全卸载三步（退出还原 → 关登录项 → 删数据目录）+ `defaults import baseline.plist` 的整域还原（并写明它会把热角一起回退）。② ✅ **全屏过滤真机回归通过**：`scripts/check-fullscreen-filter.swift` 把自己的窗口切成全屏 → 造出真实 `type=4` 空间（id64=537），实测它没被算进用户桌面、活动空间不再命中任何用户桌面、退出后一切复原；MultiDock 日志同步记录「活动空间不是用户桌面…不触发切换」，且从全屏退回**没有**弹 toast。③ ✅ 多显示器加固：插拔外接屏（接 `NSApplication.didChangeScreenParametersNotification`）自动重读桌面列表，调试面板显示显示器数量与各桌面 `displayUUID` 前 8 位；**真机实测仍需用户插屏**（本机单显示器）。④ ✅ 编辑条竖排。⑤ ✅ 孤儿绑定只提示、不自动删（拔外接屏会误伤）。⑥ ✅ 回存撤销栈（内存，刻意不落盘）。**257 个测试全绿、零警告** |
| **P5+ 菜单栏交互补完（✅ 已完成 2026-09-18）** | `⇧`+左键切上一个桌面；把"切桌面动画"查清并定性为不做 | ① ✅ `AppState.switchToPreviousDesktop()` 与 `switchToNextDesktop()` 完全对称（同一条预应用链路、两端循环）；下拉菜单加「上一个桌面」+ 等价提示；`clickAction == .openMenu` 时 `⇧`+左键一并走菜单。单测 `testPreviousDesktopPreAppliesItsOwnDock`。② ✅ **动画：不做**。四条路全走死（瞬时硬切 0–6 ms / 粘滞状态位 / 会话开关写后读不回 / `SLSWillSwitchSpaces` 段错误 / 合成事件被拦），见 `docs/spikes.md` 实验 7。③ ✅ 新增 `scripts/spike-symbols.swift`（从 dyld 共享缓存枚举私有框架符号）。**258 个测试全绿、零警告** |

---

| **P5++ 计划缺口收口（✅ 已完成 2026-09-18）** | ① 其他项（`persistent-others`）补编辑入口（**只搬不造**）② 桌面列表带显示器名（按显示器分组）③ 应用摘要进调试面板 ④ 修掉三处过时文档 | ① ✅ `DockStripRules.normalizedOthers` / `rejectionReason(for:)` / `DockItemRejection` + 编辑条「其他项」一条（排序 / 右键移除 / 共用垃圾桶）；拖文件夹**明确拒绝并给替代做法**。真机验收 `testOtherItemsRemovalAndReapplyKeepsDockHealthy`：移除后 Dock 仍存活、`GUID`/`book` 一个不丢。**实测写死了"不能新建"**：自拼目录条目 Dock 不认领（不补 `GUID`），字段不全时让 Dock SIGABRT 进崩溃循环 —— 见 `docs/spikes.md` 实验 8 ② ✅ `ScreenNaming` + 列表按 `displayUUID` 分组（`Section` 标题 = 显示器名）、详情加「显示器：…」；映射不到显示"未识别显示器（UUID 前 8 位…）"，不回落成错的屏 ③ ✅ 调试面板新增「最近一次应用」：结果摘要 / 内容指纹 / 写入时刻 / 本次运行改过 Dock / 回存闸门 ④ ✅ 修掉 §3.6「8 待 P3」、§3.7「`mru-spaces` 仍未做」、§6「第 1 条仍未回答」三处过时行，README 的「已知未做」也补上 UI 报警已做与文件夹结论。**290 个测试全绿（7 个真机验收默认跳过）、零警告** |

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 主动切桌面的私有 API 失效 | 菜单栏切换不可用 | ✅ P0 已验证可用（**0–6 ms**，无动画）。仍保留 `SpaceProvider`/`SpaceSwitcher` 协议隔离，失效时降级为"仅跟随 + 手动改 Dock"并在 UI 报警 |
| **切桌面后收不到空间变化通知** | 跟随滞后或漏更新 | ✅ P0 已确认（程序化切换不触发通知）→ 事件源改为 **300 ms 轮询为主**；自己发起的切换一律**预应用**，不等通知 |
| 无热重载，切桌面必然重启 Dock | 切桌面 Dock 闪一下 | ✅ P0 实测仅 **约 101 ms**（SIGHUP）。内容相同直接跳过；连击合并；预应用；UI/README 明示"约 0.1 秒" |
| **launchd 的重启节流**：距上次重启不足约 1 s 时再重启，Dock 要 **约 1070 ms** 才归位（`spikes.md` 实验 5） | 连续切桌面时 Dock 消失一秒多 | ✅ 已实现 `DockReloader.minimumSpacing`（默认 1 s）：先等满窗口再重启，**等待期间 Dock 可用**。实测把 Dock 不可用时长压到 **45–90 ms**；`ReloadOutcome` 把 `elapsed`（不可用）与 `spacingWait`（可用等待）分开记 |
| **`NSRunningApplication` 在 Dock 重启窗口返回 `processIdentifier == -1`** | ① 误判"Dock 已回来"；② `kill(-1, SIGTERM)` = **杀掉当前用户的所有进程** | ✅ 三道防线：`dockPID()` 过滤 `> 0`；`signal()` 拒绝 `pid <= 0` 且用 `proc_name` 确认身份；`waitForRestart` 只接受 `pid > 0`。测试在 `DockProcessSafetyTests`，全部用**信号 0** 断言（闸门坏了是测试失败，不会打死测试进程） |
| **节流窗口的判据错了**（P4 验收实测）：原以为"记在自己内存里"就够，但 launchd 的节流是**按服务**算的 | 别人（用户 / 别的 App / 我们的存活监视器）刚重启过 Dock 时，我们紧接着重启会吃满整段节流，Dock 消失一秒多 | ✅ 改成按 **Dock 进程年龄**（`proc_pidinfo(PROC_PIDTBSDINFO)` 的 `pbi_start_tvsec/tvusec`）推算窗口，拿不到年龄才退回内存记忆。实测 P3 第一轮从 **1030 ms → 45 ms**。见 `spikes.md` 实验 6 |
| **退出还原被排队的应用覆盖** | 退出后 Dock 还是错的（用户以为已还原） | ✅ 还原前 `await state.prepareForTermination(settleLimit:)`：停 watcher / 停监视器 / **丢掉没起跑的待办** / 带上限等自愈 / 带上限等在飞的应用；等不到干净就**留标记**交给下次自愈 |
| **"带上限的等待"其实是无上限的**（`withTaskGroup` 与不可取消的 `await task.value` 赛跑） | 每次退出实测卡 53–54 秒：没有 Dock、没有壁纸、触控板手势失效（= 用户以为机器死了） | 上限一律改成**轮询可观察标志**（`drainTask` / `selfHealFinished`）；退出路径另走 `reloadForQuit()`（一发信号 + 1.5 s 看一眼，不升级不 `kickstart`）。回归守卫**断言墙钟**，不只断言返回值 —— 见 `docs/spikes.md` 实验 10 |
| **还原失败后自愈能力丢失** | 下次启动不再尝试还原，Dock 永久停在非基准状态 | ✅ 失败保留标记 + `needsSelfHeal = true` + `pid = 0`；`beginSession` 把债务继承给下一次启动 |
| **备份恢复越界写白名单之外的键** | 用户后来改的热角、启动台网格被冲回旧值 | ✅ 备份恢复只走 `DockConfig.read` + `apply`（白名单键），**不做整域替换**；单测断言 `wvous-br-corner` / `mod-count` 不被覆盖 |
| **`mru-spaces` 变成"随便写某个键"的通用口子** | 迟早被误用到热角等键上 | ✅ 只给一个窄方法 `DockPreferences.writeMRUSpaces(_:)`，且不在 `apply` 管辖内（写完单独 `reloadOnly()`） |
| **`SMAppService` 在非 `.app` 环境不可用** | 登录启动开关点了没反应 | ✅ `LoginItem.isAvailable` 先看 bundle，不可用就在设置页显示原因；`enable()` 抛 `LoginItemError.notInAppBundle` |
| **注销/关机时来不及还原** | 关机后 Dock 停在非基准状态 | ⚠️ 系统不给等待时间，只能尽力：先写债务标记再发起还原。**未实测**（要真注销一次），见 `AGENTS.md` §6.3 B9 |
| `pgrep` 子进程单次约 **110 ms**，被放进 15 ms 轮询热路径 | 每次重启判定被拖慢一个量级 | ✅ 改用 `proc_listpids` + `proc_name`（**0.02 ms**），不再起子进程；`DockProcessSafetyTests` 有测试守平均耗时 |
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
| 空间切换**没有**动画（程序化切换是瞬时提交） | 点菜单栏切桌面时是硬切，没有"左右滑动"的过渡 | **明确不做**，零权限 + 无痕下无解：程序化切空间实测 0–6 ms；会话级开关 `SLSSetSessionSwitchCubeAnimation` 写后读不回（改了就还原不回去）；`SLSWillSwitchSpaces` 签名未知、猜错会段错误。见 `spikes.md` 实验 7。**别再试** |
| `mru-spaces = 1`（本机会命中） | 桌面顺序被系统重排，"下一个"不符合直觉 | 设置页显式开关，用户主动关闭；不静默修改 |
| 写坏 Dock 配置 | 用户 Dock 损坏 | 首次写前全量基准 + 每轮备份；只覆盖白名单键；单次原子写；一键还原；README 给出 `defaults import` 还原步骤 |
| 与用户在真实 Dock 上的手动改动互相覆盖 | 改动被吞 | 3 秒保护窗口 + 归一化指纹 + 自动回存 + 历史版本 + 可关闭 |
| **短路只比"我们上次写下去的那份"，外部改动后判据过期** | 逐桌面 Dock 的桌面**回存**时白写一遍 + 白重启一次 Dock（约 50 ms 闪烁），而这是本 App 的常态用法 | ✅ 加短路第 2 条"真实 Dock 已经就是这份内容"（判据复用写入校验的同一套比较）。真机实测 `68667 → 68672` 修成 `68995 → 68995`。见 §3.4 第 2 条与 `AGENTS.md` §6.3 D24 |
| 全屏 App 空间混入 | 每次全屏都切 Dock | `type != 0` 过滤。**P5 已真机回归**：把自己的窗口切成全屏造出真实 `type=4` 空间（零权限），实测过滤成立，见 §4 P5 行与 `scripts/check-fullscreen-filter.swift` |
| **toast 抢焦点** | 用户切过去正要打字，字打进 toast | `canBecomeKey` / `canBecomeMain` = false，用 `orderFrontRegardless()` 显示 |
| **toast 挡住点击** | 1 秒内点不到下面的东西 | `ignoresMouseEvents = true` |
| **toast 只在自己所在的空间显示** | 切过去反而看不见，功能像失效 | `collectionBehavior` 必须含 `.canJoinAllSpaces` + `.fullScreenAuxiliary` |
| 连击切桌面时 toast 串台 / 闪烁 | 显示旧名字，或被旧计时器提前收走 | 单一 `ToastPresenter`：换文字 + 重置计时，绝不并发多个计时器 |
| 从全屏 App 空间退回桌面误弹 toast | 噪音 | 只在「用户桌面 → 用户桌面」时弹（要求上一次通知值也非 nil） |
| 名字超长 / 手改 `config.json` 塞超长名 | 设置页与 toast 布局被撑破 | 输入框计数 + 模型层 `DesktopNaming.normalize` 归一化，两层防线，单测覆盖 |
| **输入框边打字边截断会打断中文输入法组字** | 拼音打不出字 | 输入框不做即时截断，只在回车/失焦时归一化（草稿留本地 `@State`） |
| **`orderOut` 后窗口在 CG 窗口列表里滞留数秒** | 用窗口元数据验收会把「消失」时刻判晚 | 判别式带 `onscreen == true`；`check-toast-window.sh` 已按此实现 |
| 显示器插拔后 `displayUUID` 映射不到 `NSScreen` / 桌面列表不刷新 | toast 出现在错误的屏幕；桌面串号 | 回落 `NSScreen.main`；✅ P5 已接 `NSApplication.didChangeScreenParametersNotification` → 插拔后自动重读桌面列表。**真机实测仍需用户插一台外接屏**（本机单显示器） |
| Dock tile 的 `book` blob 过期 | 图标显示异常 | 比对时剔除该字段；若实测异常，写入时剥离 `book`/`file-mod-date` 让 Dock 重建（备选开关） |
| 未签名登录项注册失败 | 开机不自动跑 | SMAppService 失败即退回 LaunchAgent |
| 桌面被系统删除/重排后映射错位 | 配置串桌面 | 以 `spaceUUID` 为键；✅ P5 已做：失效绑定在桌面页列为孤儿并给「清理」+ 二次确认。**绝不自动删** —— 外接显示器被拔掉时那台显示器上的桌面整体消失，绑定看着就是孤儿，插回去还要用 |

---

## 6. 需要你确认的几处理解

> **状态（2026-09-18）：第 1 条已确认**（用户确认 = Dock 屏幕位置 + 大小），P3 已按此实现：桌面页的「位置」与「通用」页同一套含义，未单独设置时继承默认。
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

1. 增加了**主动切换桌面**（菜单栏单击循环 / `⇧`+单击反向、菜单点选），依赖 `CGSManagedDisplaySetCurrentSpace`。**P0 已实测：可用，但不触发空间变化通知**（详见 `docs/spikes.md`；切换耗时后经实验 7 精测修正为 **0–6 ms，无动画**）。
2. UI 从"配置列表"改为**按桌面的可视化 Dock 编辑器**（通用页 = 默认 Dock，桌面页 = 各桌面 Dock），面向桌面而非抽象配置。
3. 增加了 Finder / Launchpad 固定、从 Finder 拖入拖出、Dock 大小与位置的图形化编辑。
4. `mru-spaces` 由"完全不碰"改为"设置页显式开关"，因为它会直接破坏循环切换的直觉。
5. **新增无痕原则**：基准快照 + 退出还原 + 强杀后的启动自愈，确保 App 不永久改变用户 Dock（默认 Dock 初始化为基准，因此刚装完不做任何事时 Dock 分毫不动）。
6. **P0 实测后修正了三处设计假设**（详见 `docs/spikes.md`）：① 不存在 Dock 热重载，主路径从"通知/信号热重载"改为"SIGHUP 重启，约 101 ms"；② 程序化切桌面不触发空间变化通知，事件源主次从"通知为主"反转为"300 ms 轮询为主"；③ Finder 在 plist 中无任何表示，钉住无需代码。
7. **新增桌面命名与切换提示**（§3.10）：桌面页可为每个桌面起名（**≤10 字符**，仅存本地，macOS 15 无系统接口）；切换桌面时在屏幕中上部弹一条 **1 秒**的 toast 显示该名字。实测确认 `displayUUID` 可映射到 `NSScreen`，且整条链路**零系统权限**。这一步不写 Dock，因此单列为 P2.5、可插队先做 —— **已于 2026-09-18 完成并实测通过**（见 §4）。
8. **P2 落地后补了几条实现约定**（都与计划原文有意不同，理由见 §3.4–§3.7 的「P2 实现记录」）：① 校验指纹只比**实际写进去的键**（本机缺失的外观键算进去会产生假阴性）；② **绝不写当前域里不存在的键**，缺失的键报告给 UI 并禁用对应控件；③ `.app` 的 `_CFURLString` 必须**带尾斜杠**，用户 App 的 `dock-extra` 用 `true`；④ **启动台条目原样复用**已有的（保住 `GUID`/`book`），不无条件重建；⑤ **退出还原有门槛**（只在本次运行改过 Dock 时才还原），并且"已与基准一致就跳过"；⑥ **默认 Dock 为空时拒绝应用**（见 §6 第 5 条）。

# MultiDock：每个桌面一套原生 Dock + 桌面切换器

## 0. 目标（**2026-10-04 起的产品形态**）

菜单栏常驻一个图标。多个桌面下，原生 Dock 怎么跟着桌面变，归它管：

- **默认形态（冻结模式，默认开）**：原生 Dock **在所有桌面上都一样**，固定成「通用页那套默认 Dock」，
  切桌面时**不写偏好、不重启 Dock**。各桌面的差别交给**次级 Dock 条**来显示：这是一条自己画的条，贴在原生 Dock 内侧，
  切桌面时图标秒换，条宽跟着内容走，和原生 Dock 一起显示、一起隐藏（见 §3.12）。
- **可选的老形态（关掉「冻结原生 Dock 的逐桌面切换」）**：每个桌面一套原生 Dock，切过去时自动把原生 Dock
  换成这个桌面的配置（走 SIGHUP + 自动隐藏三明治，用户看不到重启）。没单独设置的桌面（包括新建的桌面）用默认 Dock。
- **菜单栏**：单击图标 → 切到下一个桌面（循环）；`⇧`+单击 → 切到上一个桌面（循环）；右键 / ⌥+左键 → 弹出下拉菜单，里面列出所有桌面（点哪个切到哪个），还有设置和退出。
- **设置 → 通用**：编辑「默认 Dock」：拖进拖出应用、拖动排序，Finder 和 Launchpad 固定在上面，删不掉；
  还有默认 Dock 的大小和位置、次级条和冻结开关、应用和还原。
- **设置 → 桌面**：列出所有桌面。每个桌面可以单独设 Dock 的位置、大小和里面的应用（一样能拖进拖出），也可以选沿用默认 Dock；**每个桌面还能起个名字，最多 10 个字符**（只存在本地，见 §3.10）。
- **切换桌面提示（toast）**：切到另一个桌面时，屏幕上显示这个桌面的名字，**1 秒后自己消失**。2026-10-06 起，样式是**磨砂玻璃面板上的 64 pt 粗体大字**（字重 800），面板**宽度随名字长短变化**；位置可选顶部、中部、底部（默认顶部）。它不抢焦点、不挡点击，也不要任何权限（见 §3.10）。

**无痕原则（硬约束）**：App 绝不能永久改掉用户的 Dock。第一次运行时，它把你当前的 Dock 完整存成**基准快照**，退出时自动还原回去；就算被强杀或崩溃，下次启动也会发现并还原。装上以后什么都不做，Dock 就和装之前一模一样。

**不做**：不替换原生 Dock；不画自己的 Dock 栏（**例外**是次级条，用户 2026-10-04 修订时批准了）；不新建、不删除系统桌面（macOS 没有公开接口，只列系统已有的）；不改系统级配置，也不改别的用户的配置；这一期不做沙盒和公证。

---

## 1. 已验证的环境事实（设计依据摘要）

> 完整清单（~80 条，每条都写了判据和脚本位置）在 **`docs/facts.md`**；这张表只留直接影响设计决定的几条。
> 开发机现在的环境：**macOS 15.8.1 (24H32)、x86_64、单显示器、Xcode 26.3、Swift 6.2.4**
> （实验 1–16 在 15.7.9 上做，实验 17–22 在 15.8.1 上做，见 `docs/spikes.md`）。

| 项 | 结论 |
| --- | --- |
| 系统 / 工具链 | macOS **15.8.1 (24H32)**；GUID 回填判据在这个版本上失效了（实验 19），真机验收已经按系统版本分情况处理 |
| 空间切换通知 | `NSWorkspaceActiveSpaceDidChangeNotification` 是**公开 API**（AppKit 10.6 起就有，`NSWorkspace.h:339`）。**但 P0 实测发现：用程序切桌面时它不触发**（对照实验已经排除了环境因素）→ 见 §3.1 |
| 枚举桌面 | `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")` 成功，`CGSCopyManagedDisplaySpaces` / `CGSGetActiveSpace` / `CGSMainConnectionID` 都能用。实测拿到 2 个桌面，每个都有**重启后不变的 UUID**、`id64`、`type=0`；`Spaces` 数组的顺序就是左右顺序 |
| **主动切桌面** | `CGSManagedDisplaySetCurrentSpace` **符号存在**（`CGSManagedDisplayGetCurrentSpace` 也在）→ 菜单栏的"切下一个桌面"做得出来。**实测 0–6 ms 生效，是瞬间硬切，没有过渡动画**。⚠️ 这里原来写的是"约 20 ms、带系统自带的滑动动画"，**2026-09-18 复核时发现是错的**：那 20 ms 是 P0 用 1 s 的轮询间隔测出的粗略值。想加动画试过四条路，全走不通，见 `docs/spikes.md` 实验 7 |
| 桌面命名 | 空间字典里的键是 `uuid` / `ManagedSpaceID` / `id64` / `type` / `WindowManagerInfo`（P0 实测，**不是** `ManagedSpaceUUID`），**没有名称字段** → macOS 15 没有桌面名接口，App 里给桌面起的名字只能存在本地，写不回系统。display 字典另有 `Current Space` 键，能直接拿到当前空间 |
| **显示器 UUID 能不能对应到 `NSScreen`** | ✅ **能，而且完全一致**（2026-09-18 实测）：`CGDisplayCreateUUIDFromDisplayID(NSScreen.deviceDescription["NSScreenNumber"])` 得到 `AB24BB32-C5EC-D10A-6F9D-F01F35552F60`，和 SkyLight 的 `Display Identifier` 每个字符都一样 → 从空间所在的 `displayUUID` 能准确找到显示器，toast 就能显示在对的屏幕上。探测脚本：`scripts/spike-probe.swift` |
| 屏幕几何（给 toast 定位用） | 主屏 `frame` = (0, 0, 1920, 1200)，`visibleFrame` = (0, 53, 1920, 1147)（Dock 在底部、没开自动隐藏，底部让出 53 pt）。toast 按 `visibleFrame` 定位，自然就躲开了菜单栏和 Dock |
| Dock 偏好域 | `com.apple.dock` 有 34 个键；`persistent-apps` 有 15 项（第一项是 Launchpad），`persistent-others` 里有「下载」 |
| **Finder 怎么表示** | `persistent-apps` 里**没有 Finder**，Finder 是 Dock 默认固定、不写出来的一项。Launchpad 则是普通条目 `file:///System/Applications/Launchpad.app/`（`com.apple.launchpad.launcher`），写 plist 就能加、能删 |
| Dock 进程守护 | `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}` → **Dock 必须是被信号杀掉的**，launchd 才会把它拉起来；正常退出（exit 0）不会重启 |
| Dock 热重载 | **P0 已经证明 notifyd 热重载不行**。写完偏好再 post `com.apple.dock.prefchanged`（darwin 和分布式两种都试了），Dock 毫无反应；`kill -HUP` 会让 Dock 直接退出，再由 launchd 拉起来（这是重启，不是重载）。重启后偏好全部生效。⚠️ **2026-10-03 实验 17 修正了一部分**：还有一条 **MIG 通道**（HIServices 的 `CoreDock*` 函数 → `com.apple.dock.server` 端点）。外观键实测能当场生效（`CoreDockSetTileSize` 不重启就改了偏好域，也存下来了），**条目热替换没打通**（三种载荷都被悄悄拒了）；主路径还是 SIGHUP，见 `docs/spikes.md` 实验 17 |
| 多显示器空间 | `com.apple.spaces spans-displays` 不存在 → 默认开着"每台显示器有各自的空间"，映射键得用 `(displayUUID, spaceUUID)` |
| 当前风险 | 本机 `mru-spaces = 1`（"根据最近使用自动重新排列空间"）。它会打乱桌面顺序，和"循环切下一个桌面"正面冲突 → 设置页给一个**明确的开关**（用户自己点了才改，不偷偷改） |

**权限需求：目前没有。** 原来的硬约束「零权限」，用户在 2026-10-05 放开了：辅助功能这类系统权限，按功能带来的好处**一个个评估**，值得就用（比如 Dockset 那样的全局手势切换）；没有具体功能需要时，还是零权限。改 Dock 偏好和切桌面本身都是用户级操作，不用权限。

---

## 2. 工程形态

**用 SwiftPM 可执行包 + 打包脚本**。不手写 `.xcodeproj`：太啰嗦、容易错，我们也用不上 storyboard 和资源目录；想用 Xcode，照样能直接打开 `Package.swift`：

```
multi-dock/
├── Package.swift                       # platform .macOS(.v14)，含测试目标
├── Sources/MultiDock/
│   ├── MultiDockApp.swift              @main + NSApplication（不用 MenuBarExtra，见 §2 注）
│   ├── App/AppDelegate.swift           组装状态 / 菜单栏 / 窗口 / toast 与次级条接线
│   ├── App/AppState.swift              全局状态、设置持久化、冻结语义（启动对齐 + 开关两方向）、次级条内容
│   ├── App/FileLogSink.swift           日志落盘（multidock.log，上限 512 KB，可注入）
│   ├── App/LifecycleController.swift   启动自检、退出还原、异常退出检测
│   ├── App/LoginItem.swift             登录启动（SMAppService 主 + LaunchAgent 退）
│   ├── Spaces/SkyLightBridge.swift     dlopen + dlsym 封装
│   ├── Spaces/SpaceProvider.swift      协议 + 私有 API 实现 + 降级实现
│   ├── Spaces/SpaceObserver.swift      轮询(300ms) + 通知(快速通道) + 全屏过滤 + 去重
│   ├── Spaces/SpaceSwitcher.swift      切到下一个/指定桌面（循环）
│   ├── Spaces/DesktopNaming.swift      桌面命名：归一化(≤10 字素簇)、显示名解析、改名规则
│   ├── Spaces/ScreenNaming.swift       显示器名：displayUUID → NSScreen.localizedName（桌面页按显示器分组）
│   ├── Dock/DockPreferences.swift      CFPreferences 读写 + 键白名单 + mru-spaces 窄口
│   ├── Dock/DockConfig.swift           模型、tile 构造、归一化指纹、手写解码的 AppSettings
│   ├── Dock/DockController.swift       应用流水线、双重短路、防抖合并
│   ├── Dock/DockReloader.swift         SIGHUP 主 + SIGTERM/kickstart 兜底；节流错开；不等，催；显隐取证
│   ├── Dock/DockAutoHide.swift         自动隐藏三明治（typed setter 桥；重启不可见）
│   ├── Dock/DockStripRules.swift       图标条规则：默认 Dock 启动台补首（栏不插固定项，barApps）、从 .app 造条目、其他项只搬不造
│   ├── Dock/DockWatcher.swift          识别用户在真实 Dock 上的手动改动并回存（Dock 不在时不采样）
│   ├── Dock/DockEditHistory.swift      回存的旧配置暂存（内存撤销栈），供电「撤销自动回存」
│   ├── Dock/DockPresenceMonitor.swift  Dock 存活监视（连续缺失才 kickstart；持续拉不回报警）
│   ├── Dock/SecondaryDockLayout.swift  次级条纯几何：detectDockFace / placement / barSize / dockArea
│   ├── Dock/DockFaceProviding.swift    原生 Dock 排他几何来源（visibleFrame 内缩）
│   ├── Store/ConfigStore.swift         原子读写 config.json
│   ├── Store/BaselineStore.swift       基准快照 + 会话标记 + 备份历史
│   ├── UI/MenuBarController.swift      NSStatusItem：桌面列表 + 切换 + 设置入口
│   ├── UI/SettingsView.swift           工具栏标签页（通用 / 桌面）+ 顶部报警横幅 + 次级条与冻结开关
│   ├── UI/DesktopListView.swift        桌面列表、改名（≤10 字符）与绑定
│   ├── UI/DockStripEditor.swift        Dock 可视化编辑条（拖入拖出排序）
│   ├── UI/DockAppearanceEditor.swift   外观控件（不支持键禁用；onCommit 只在松手/值变化）
│   ├── UI/SecondaryDockStripView.swift 次级条条目模型 + 纯函数内容构建 + SwiftUI 条
│   ├── UI/SecondaryDockWindow.swift    次级条窗口（Toast 配方的可交互变体，层级 19）
│   ├── UI/SecondaryDockController.swift 次级条调度：条宽随内容 / 显隐同步 / hover / 轮询
│   ├── UI/ToastPresenter.swift         toast 协议 + 纯逻辑调度（1 s 计时、连击取消重启、只弹桌面→桌面）
│   ├── UI/DesktopNameToast.swift       中上部提示窗口（无边框、不抢焦点、跨空间、零权限）
│   └── UI/DebugPanelView.swift         当前 spaceUUID / id64 / type、应用日志、测试 toast 按钮
├── Tests/MultiDockTests/               指纹归一化、白名单写入、循环取下一个、基准/标记/备份、名字归一化、
│                                       toast 调度、Dock 重载降级、应用流水线、图标条规则、次级条几何与调度、
│                                       AppState 按钮路径、UI 离屏快照
│   └── DockAcceptanceTests.swift       **真实 Dock 验收**（默认跳过，`MULTIDOCK_DOCK_ACCEPTANCE=1` 开启）
├── scripts/build-app.sh                组装 MultiDock.app（Info.plist + ad-hoc 签名）
├── scripts/spike-reload.sh             P0 实验：Dock 重载策略 A/B/C
├── scripts/spike-probe.swift           P0 实验：探测当前桌面 / Dock 进程 / Dock 窗口几何 / 显示器 UUID 映射
├── scripts/spike-switch.swift          P0 实验：主动切桌面 + 通知是否触发
├── scripts/spike-dock-downtime.swift   P0 实验：毫秒级测 Dock 停机时长
├── scripts/spike-symbols.swift         枚举 SkyLight 导出符号（内存内解析 Mach-O，零权限）
├── scripts/spike-coredock-probe.swift  CoreDock MIG 通道探针（读/写两档，写档需先备份 Dock 域）
├── scripts/spike-secondary-dock-sync.swift 实验 22：Dock 显隐信号三路采样（只读 + typed setter + 光标位移）
├── scripts/measure-launchservices-lag.swift LS 在重启窗口的滞后测量（只读 + SIGHUP）
├── scripts/measure-launchd-backoff.swift    launchd 归位延迟是否累积（连打 N 轮）
├── scripts/check-toast-window.sh       客观验收 toast：读窗口层/透明度/坐标（零权限）
├── scripts/check-fullscreen-filter.swift  真机回归全屏过滤：把本进程窗口切成全屏造出 type=4 空间（零权限）
├── scripts/check-finder-removal.sh     B8：手动移除 Finder 是否落新键（只读观察）
├── scripts/preview-toast.swift         离线预览 toast 外观（cacheDisplay 抓自己视图，零权限）
├── docs/spikes.md                      22 个实验的原始数据与决定
└── README.md                           含"如何完全卸载并还原初始 Dock"
```

**注：菜单栏用 `NSStatusItem`，不用 `MenuBarExtra`。** 硬约束 §2.3 要分清「左键 / 右键 / ⌥+左键」三种点击，可 `MenuBarExtra` 把点击全自己吃掉了，分不出左右键。设置窗口和调试面板还是 SwiftUI，放在 `NSHostingController` 里。所以计划里原定的 `UI/MenuBarView.swift` 改名成了 `UI/MenuBarController.swift`。

`build-app.sh`：`swift build -c release` → 组装 `build/MultiDock.app/Contents/{MacOS,Info.plist}`（`LSUIElement=1`、`CFBundleIdentifier=local.multidock`）→ `codesign --force --sign -`（**不加** `--deep`，Apple 已经废弃它了）。**一定要先打成 .app 再 `open`**：直接跑 `.build/release/MultiDock` 没有 bundle，菜单栏图标会出怪问题。

验证命令：`swift build -c release && swift test && ./scripts/build-app.sh && open build/MultiDock.app`

改到 Dock 的代码，还要另跑真实验收（**它会真的改 `com.apple.dock`、重启 Dock，跑完自动还原**；跑之前先 `defaults export com.apple.dock` 备份一下，跑的过程中别手动动 Dock）：

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

- 主键是 `spaceUUID`（重启后不变）；多显示器时映射键用 `(displayUUID, spaceUUID)`。
- **`type != 0` 的空间一概不管**：不进菜单、不参与循环、切过去也不应用配置。不然每次进全屏 App 都会被当成切桌面，体验很糟。
- 切换目标：在当前活动的显示器上，按 `Spaces` 数组顺序取下一个 / 上一个用户桌面，到头了就绕回另一头。
- **切桌面这个过程本身没有动画**（**不做，别再试了**）。用程序调 `CGSManagedDisplaySetCurrentSpace` 是**瞬间提交**的（实测 0–6 ms），
  SkyLight 没有"带过渡切到某个空间"的入口。唯一看着像入口的是会话级开关 `SLSSetSessionSwitchCubeAnimation`，
  可它**写进去就读不回来**（没有 getter，偏好域里也找不到），改了就还原不了 → 违反无痕原则；
  `SLSWillSwitchSpaces` 签名不清楚，猜错了进程会直接死在 SkyLight 里面。
  真正的过渡动画由 WindowServer 内部的 `Transition*Metal` 类驱动，只给**用户手势**用（触控板横扫 / `Ctrl+←`）。
  完整证据见 `docs/spikes.md` 实验 7。**切桌面时 Dock 该闪还是会闪（约 101 ms），这是重载 Dock 的代价，不是动画。**
- 事件来源（**P0 实测后主次反过来了**）：**以 300 ms 轮询为主**，`NSWorkspaceActiveSpaceDidChangeNotification` 为辅。因为实测发现，用程序切桌面时这个通知根本不来（对照实验证明通知通道本身没问题），所以通知只能当"用户自己切桌面时的快速通道"，用来降低延迟。两条路都走同一个幂等的 `handleActiveSpaceChanged()`，按 `(displayUUID, spaceUUID)` 去重。
- **我们自己发起的切换，必须提前应用配置**（§3.4 第 8 条）：切完收不到任何通知，不能等通知来了才动 Dock。这一条从"优化"升成了"必需"。
- 私有 API 用 `SpaceProvider` 协议隔开。私有 API 失效时，降级成"只能手动改 Dock，不能自动跟随、不能切桌面"，并在界面上明确报警，不能悄悄失效。
  ✅ **已落地（2026-09-18）**：设置窗口顶部的 `WarningBanner` 读 `AppState.spaceProviderWarning`，
  显示橙色的「桌面切换不可用」和具体原因。原来只写日志和调试面板，可**用户不看日志，等于没报警**。

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

- 存储位置：`~/Library/Application Support/MultiDock/config.json`（原子写：先写临时文件，再 `rename`）。
- **读写和比对只看这些键（白名单）**：`persistent-apps`、`persistent-others`，再加外观对应的键（`orientation`、`tilesize`、`magnification`、`largesize`、`autohide`、`autohide-delay`、`autohide-time-modifier`、`mineffect`、`minimize-to-application`、`show-process-indicators`）。
- **明确不碰**：`mru-spaces`（它有单独的显式开关）、`wvous-*`（屏幕角）、`springboard-rows/columns`（启动台网格）、`recent-apps`、`mod-count`、`version`、`loc`/`region`、`trash-full`、`ResetLaunchPad`。

### 3.3 基准快照与还原（无痕原则）

`BaselineStore` 管三件事：

1. **基准快照 `baseline.plist`**：第一次运行时，把 `com.apple.dock` 的**整个偏好域**导出来存好，以后不再覆盖。同时用这份快照初始化「默认 Dock」，所以刚装完 App，哪个桌面都不会有任何变化。
   - 有一个「把当前 Dock 现状设为新基准」按钮：用户对现在的 Dock 满意，就用它重设基准。
   - 用户可以在设置里关掉退出还原；关掉后基准还留着，只当备份用。
2. **会话标记 `session.state`**：App 正常启动、开始接管 Dock 时写下它（里面有 PID、启动时间、当前已应用的指纹）；**正常退出并且还原成功后再删掉**。
   - 下次启动时如果标记还在，说明上次是被强杀、崩溃或断电，还原没走完。这时先**自动还原基准**，再按正常流程应用当前桌面的配置。界面上给一条一次性提示，说清楚发生了什么。
   - 标记里存了 PID，启动时检查那个进程还活不活着，免得多开实例或误判。
3. **轮转备份**：每次写真实 Dock 之前，把当时的整个偏好域另存一份到 `backups/`，留最近 20 份，需要时可以"回滚到某个时间点"。

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

- **还原没做完，绝不能退出进程**，不然用户会看到"退出以后 Dock 还是错的"。
- **可也不能一直等**：退出时等 Dock 归位，拿不到任何**能据此行动**的信息。偏好是原子写的，
  Dock 下次启动自然会读到基准；"升级也没用"这种情况，只有下次启动的自检能纠正，而自检不在乎这次等了多久。
  旧写法（照搬完整的降级链）实测每次退出都有 **53–54 秒**没有 Dock、没有壁纸，触控板手势也失灵。
- **所有"有上限的等待"都要轮询一个看得见的标志**，不能拿 `withTaskGroup` 和 `await task.value` 赛跑：
  任务组的闭包返回时，会等所有子任务收尾，而那种子任务不响应取消，于是上限会**悄悄失效**
  （返回值看着没错，墙钟时间却不对）。所以回归守卫要断言**墙钟时间**，不能只断言 Bool。
- **等不到干净状态，就必须留着标记**（`!settled` → `keepMarkerAndFinish`）：那笔还在飞的写入，可能落在还原**之后**。
- 系统关机、注销也走这条路（`NSWorkspace.willPowerOffNotification`），但**系统不给时间等**，
  只能尽力而为：先把欠的账写进标记，再开始还原；没跑完的交给下次启动自愈。
- 崩溃、强杀时钩子根本跑不了，靠下次启动检查 `session.state` 兜底。这是无痕原则的最后一道防线，必须有测试覆盖。

### 3.4 应用流水线（DockController）

1. 目标配置 = `binding.override ?? defaultConfig`。
2. **内容一样就直接返回（两条判据，缺一不可）**：① 归一化指纹和"当前已应用"的一致；② **真实 Dock 本来就是这份内容**（按读回的口径逐键比，全相同）。只要命中一条，就直接返回，**不写、不备份、不重启 Dock**。两个桌面用的是同一份 Dock 时，切桌面没有任何开销，也不闪。
   - 只有 ① 不够：它比的是"**我们上次写下去的那份**"。一旦有过**外部改动**（用户手拖图标、别的 App 改了、或者 `DockWatcher` 刚回存的那份），它就**过期**了；这时再应用一份和真实 Dock 一模一样的配置，就会白写一遍、白重启一次 Dock。
   - ② 的判据**必须用写入校验（第 6 条）那同一套比较**。这样"跳过不写"和"写下去马上验过"**完全等价**，不会出现"以为不用写、其实该写"的漏写。
   - 直接返回时，顺手把"此刻的真实 Dock"记成已应用状态（`adoptLiveDockAsApplied()`），也就打开了 `DockWatcher` 的回存闸门；**但不设 `appliedAt`**，因为那不是我们写的。
   - 实测代价：给桌面单独配了 Dock 时，回存原来会白重启一次（`PID 68667 → 68672`，闪大约 50 ms），补上 ② 以后变成 `68995 → 68995`。详见 `docs/rules.md` 末尾的 D24。
3. 把当前 `com.apple.dock` 的整个偏好域备份到 `backups/`。
4. 读当前的**整个**偏好域 → 用配置覆盖白名单键 → 其他键（热角、启动台等）原样保留 → `CFPreferencesSetMultiple(..., kCFPreferencesCurrentUser, kCFPreferencesAnyHost)` + `CFPreferencesAppSynchronize`。一次原子写完，不用 `defaults` 一条条拼。
5. 让 Dock 重载（见 3.5）。
6. 记下 `appliedFingerprint`、`appliedAt`、`reloadMethod` 和耗时，调试面板里能看到。
7. **防抖合并**：连着切好几个桌面时，只对最后停下的那个执行一次；正在应用时目标又变了，就记进 `pendingTarget`，这一轮一结束马上补跑。
8. **我们自己切桌面时提前应用**：点"下一个桌面"时已经知道目标，先 apply 再切空间，切换动画结束时 Dock 已经对了（不等通知回来才动）。

> **P3 实现记录（2026-09-18）：第 8 条到底是什么意思（实测后改了措辞）**
>
> 原文"先 apply 再切空间"，容易被理解成"切空间之前 Dock 已经重启完了"，**这在物理上做不到**：
> 应用一次要先写偏好、再重启 Dock，而 Dock 重启本身就要约 **101 ms**（SIGHUP，P0 实测），
> 比 `CGSManagedDisplaySetCurrentSpace` 返回（实测 0–6 ms）慢一个数量级。怎么实现都没法在切空间前重启完。
>
> 第 8 条真正要保证的是：**开始**应用和切空间在同一拍，**不等 300 ms 轮询**发现变化了才动。
> 代码里，`AppState.switchToNextDesktop()` / `switchTo(_:)` 先调 `switcher.target(_:)` 算出目标，
> 再调 `applyConfigForDesktop(target)`（同步建好 `DockController` 的 drain 任务），最后调 `switcher.switchTo(target)`。
> 这样，写偏好、重启 Dock 和系统的切换动画（约 300 ms）同时进行，动画结束时 Dock 已经对了。
>
> 怎么验证：`switchToNextDesktop()` 一返回，`DockController.isApplying` 马上是 `true`
> （`request()` 同步建任务），而且**整个切换过程只写一次**：
> 提前应用和"切完后 observer 回调"这两次请求，被 `request()` 的单槽位合并成了一次，Dock 不会重启两次。
> 单测：`testPreApplyAppliesTheTargetDockWithoutWaitingForThePoll`。

> **P2 实现记录（2026-09-18）**：第 1、2、7、8 条里，**1 已实现**（`AppState.applyDock(_:reason:)` 目前只喂 `settings.defaultDock`；挑 `binding.override` 是 P3 的事）、**2 / 7 已实现**、**8 已实现**（P3 的提前应用：开始应用和切空间同一拍，见 §3.4 的 P3 实现记录）。
>
> 落到实现上，有几处说得更具体：
> - **校验只比"真正写进去的那些键"**。本机偏好域里没有 `show-process-indicators`，把缺的键也算进去比，就会假阴性（"明明写成功了，却判成失败"）。这件事由 `DockConfig.fingerprint(restrictedTo:)` 负责。
> - **当前偏好域里没有的键，绝不写**：`DockController.entries(for:restrictedTo:)` 只挑域里真有的白名单键，`DockAppearance.unavailableKeys(in:)` 把跳过的键报给界面（设置页显示「本机不支持」，并禁用对应控件）。
> - **备份失败不拦着往下走**：基准快照才是最后一道防线，备份失败只在 `Outcome.note` 里记一句。
> - **防抖合并**用"单槽位 + 排空循环"实现：`request()` 只留最后一个目标，`drain()` 一直循环到 `pending` 清空；正在应用时来的新目标，这一轮结束后马上补跑。`waitForIdle()` 给测试和「立即应用」用来等待。
> - **实测**：SIGHUP 125–138 ms；变化只落在 `magnification` / `persistent-apps` / `tilesize` 上；新写进去的 tile 被 Dock 补上了 `GUID`（说明真的生效了）。

### 3.5 Dock 重载策略（**P0 已完成，结论见 `docs/spikes.md`**）

| 方案 | 做法 | P0 实测结果 |
| --- | --- | --- |
| A. 通知 | 写完偏好后 post `com.apple.dock.prefchanged` | ❌ **完全没用**。darwin 通知和真正的分布式通知都试过，Dock 毫无反应（PID 没变，tile 的 `GUID` 也没补上）。⚠️ 实验 17 又测了 MIG 版（`CoreDockSendNotification`，msg 0x7D0）：status=0，但一样不会让 Dock 重读。Dock 二进制里那个字符串，是它**往外广播**用的 |
| B. SIGHUP | `kill(dockPID, SIGHUP)` | ✅ **有效**，但**不是热重载，是进程重启**（PID 变了，launchd 马上拉回来）。Dock 总共只有 **约 101 ms** 不可用 |
| C. SIGTERM | `kill(dockPID, SIGTERM)`，没归位就 `launchctl kickstart` ⚠️ **P0 实验那时带着 `-k`；实现里已经去掉了 `-k`**（实验 9：带上它，会把 launchd 正要拉起来的 Dock 再杀一次） | ✅ 有效（重启）。Dock 退出前会先清理约 255 ms，总共 **约 367–395 ms** 不可用 |
| D. CoreDock MIG 通道（**实验 17，2026-10-03 新加**） | 用 HIServices 的 `CoreDockSetTileSize` / `SetPreferences` / `AddFileToDock` / `SendNotification` 直接发给 `com.apple.dock.server` | ⚠️ **还没定**：外观 setter 有一次实测成功（`SetTileSize` 不重启就改了偏好域，也存下来了），但数值是什么意思还不确定；条目和整个域的字典都被悄悄拒了。**没打通之前不进主路径** |

> **notifyd 热重载不存在**；不过「必须重启 Dock 进程」这个说法，被实验 17 推翻了一部分：外观键可以走 MIG 通道。**实验 17 续篇摸清条目路径和数值含义之前，主路径还是 SIGHUP。**

**决定：主路径用 B（SIGHUP），兜底用 C（SIGTERM + kickstart）。** SIGHUP 比 SIGTERM 快约 4 倍（101 ms 对 395 ms），因为 SIGTERM 会被 Dock 捕获，触发它的退出清理。界面和 README 里统一说「切换桌面时 Dock 会刷新约 0.1 秒」。

> **2026-10-04 补充（实验 20）**：SIGHUP 重启现在默认包在**自动隐藏三明治**里：
> 先用 `CoreDockSetAutoHideEnabled(true)`（typed setter，第三方实测能用，Dock 自己会存下来）
> 把 Dock 当场滑走 → 偷偷重启 → 再滑回来。用户看到的是两次平滑的滑动，不再「黑一下 + 图标重铺」。
> 配置本来就要求隐藏（autohide=true）时不用三明治（重启本来就看不见）；typed setter 用不了或失败时，
> 平稳退回老路径。实现见 `DockAutoHide.swift` 和 `DockReloader.reload(strategy:sandwichRevealAutoHideTo:)`。

**大坑（已核实 launchd 配置）**：绝不能用"正常退出"（AppleEvent quit）。`SuccessfulExit = 0` 的意思是 exit 0 时 launchd **不会**把 Dock 拉回来，用户当场就没了 Dock。只走信号这条路，再用 kickstart 兜底。

**竞态风险（实现时必须处理）**：SIGTERM 前 Dock 有约 255 ms 在清理，它可能在退出前把自己的状态写回去，盖掉我们写的东西。实测没出现过，但**不能当它永远安全**：应用完要用指纹校验，不一致就重试一次。

**体验上的弥补**（依然有效）：3.4 的"内容一样就跳过"，让共用同一份 Dock 的桌面之间切换没有开销、不闪；"提前应用"让切换动画结束时 Dock 已经对了。

> **P2 实现记录**：`DockReloader.reload(strategy:)` 按 **SIGHUP → SIGTERM → `launchctl kickstart`** 三级往下降，每一级都轮询，等一个**和旧 PID 不同**的新 Dock 进程出现（看的是 PID 变没变，不是"Dock 还在不在"）。`fallbackGrace`（默认 500 ms）是发完 SIGTERM、动 kickstart 之前留的宽限时间。实测 SIGHUP 每次都一次成功，`verifyAttempts == 1`。
>
> **2026-09-19 改了两处**（真机上"切一次桌面黑屏好几分钟"，见 `docs/spikes.md` 实验 9）：
> ① 每一级的超时从 5 s 提到 **30 s**。5 s 比 launchd 的退避时间（实测几十秒）短，结果一次正常的慢拉起
> 被误判成"SIGHUP 失败"，马上升级到 `SIGTERM` + `kickstart -k`。那一发 `-k` 又把 launchd 正要拉起来的
> Dock 杀了一次，退避被我们自己续上，Dock 缺席的时间从 1 秒一路滚到 119 秒。
> ② **`kickstart()` 绝不能 `waitUntilExit()`**：launchd 在退避时，这条命令会卡几十秒（实测 54 / 60 / 64 s），
> 它又跑在 `@MainActor` 上，整个 App 跟着冻住（存活监视器本该每 2 秒写一行日志，那两分钟里只写了一行）。
> 现在发完就走，子进程交给 `LaunchctlParking` 拿着直到退出，而且**已经在飞的就不再叠加**（重复发 `-k` 正是退避的起因）。
>
> **P0 担心的竞态，实测没出现**：多轮 apply 都是第一次校验就通过。重试那条路径由单测 `testRetriesOnceWhenDockDidNotTakeTheWrite` 覆盖，它用一个"第一次写入被吞掉"的替身。
>
> **找 Dock 进程有兜底**：在不是 `.app` 的进程里（比如 `swift test` 的 xctest runner），`NSRunningApplication.runningApplications(withBundleIdentifier:)` 可能找不到 Dock，这时 `dockPID()` 退回到 `proc_listpids(PROC_ALL_PIDS)` + `proc_name` 扫进程表（**0.02 ms**）。
> ⚠️ 早期版本用的是 `pgrep -x Dock`（一次 **110 ms**），**早就换掉了**，别照着旧文档改回去。
>
> **2026-09-20 加了取证**（真机偶尔慢重启 26–31 秒，见 `docs/spikes.md` 实验 11.6 和实验 15）：
> 实验 12–14 把四个假说一个个否掉了。剩下两种病因（**探测结果分叉**，还是 **Dock 真的没回来**），旧日志分不出来，
> 因为重载期间 `DockPresenceMonitor` 故意不出声，`waitForRestart` 也只记结果、不记过程。
> 所以加了 `DockPIDProbe` / `probeTimeline`：等了 **> 1 秒**才去采两条探测路径的答案，
> **答案变了才记一条**（头尾各强制记一条，最多 24 条），写进**原来就有的那一行** `Dock 应用成功` 日志里。
> **正常路径一次都不调 `pidProbe()`**（由 `testFastRestartDoesNotProbeAtAll` 守着），没有任何开销。
> 判定规则见实验 15。**这不改行为，只是加观测。**
>
> **2026-09-20 又补了两处观测**（同一轮排查的收尾，见 `docs/spikes.md` 15.3 / 15.4）：
> ① **`waitPolls` / `waitLongestGapMS`**：`waitForRestart` 的 `elapsed` 是墙钟时间，而轮询跑在 `@MainActor` 上。
> 主线程被冻住时，我们**根本没在看**，却照样把整段时间记成"Dock 不可用 26046 ms"。
> 现在慢重启那行日志会带上 `轮询 N 次，最长间隔 M ms`。**判断时先看 M**：M 到了秒级，说明观察窗口断了（是我们的 bug），
> 不关 launchd 的事；次数 ≈ `elapsed / 15 ms`，说明一直在看（Dock 真的不在）。只在 `elapsed > 1` 时记，快路径的日志一个字节都不变。
> ② `dockPID()` **优先走 LS** 这一点，定向测量已经证明是安全的（6/6 轮"危险窗口 = 0 ms"），**别改它选路径的方式**。
>
> **2026-09-20 A8 的修法上线：别等，催**（真机偶尔慢重启 26–31 秒，见 `docs/spikes.md` 实验 16）。
> 线索藏在真机日志里一直没人注意的后半截：`05:33:16` 那次，**SIGHUP 等满 30 s 也没等到，紧接着一发 `kickstart`，0.5 s 就拉回来了**。
> 也就是说，**我们手里本来就有一条能马上拿回 Dock 的通道，只是被排到了 30 秒以后**。改动如下：
>
> | 改动 | 值 | 为什么 |
> | --- | --- | --- |
> | 新增 `nudgeAfter` | **500 ms** | 等了这么久还没见到新 Dock，就催一发 `kickstart`。正常路径 35–126 ms，永远碰不到它 |
> | 新增 `nudgeInterval` | **1 s** | 隔这么久再催一次（⚠️ 尽力而为：叠在一起发的会被 `LaunchctlParking` 闸门吞掉） |
> | `timeout` | **30 s → 3 s** | ⚠️ **这一条推翻了上面 2026-09-19 那条"提到 30 s"**：实验 16.2 实测，launchd 的节流是 **1 s 封顶、不累积**，"退避要几十秒"的前提不成立；3 s 约等于正常值的 24 倍，够宽松了 |
> | 新增 `kickstartTimeout` | **30 s** | 真正需要耐心等的那段，挪到**催完以后** |
> | **PID 守卫** | 新增 | 兜底原来是对 `dyingPID` 发 SIGTERM；如果 launchd 已经把 Dock 拉回来了，读到的是**新** PID，就会把刚恢复的 Dock **再杀一次** |
> | 失败取证 | 修 | 三段拼起来，并标上段名（原来把最有用的主路径那段丢了，催的记录就在那段里） |
>
> 这样做安全，前提是**实测过的**：`kickstart` **不带 `-k`** 时，对正在运行的 Dock 是无害的 no-op（PID 没变，退出码 0），所以"催早了"没有风险。
> 代价从 **26–31 s 降到 ~1–3.5 s**。⚠️ **修好的是代价，不是病根**：`KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}`
> 下"launchd 偶尔压根不安排那次重新拉起"，还没直接观测到。预测，以及下次复现时怎么读日志，见实验 16.4 / 16.8。

### 3.6 Dock 编辑条（设置页核心控件）

`DockStripEditor` 这个组件，通用页和每个桌面的详情页共用：

- 按 location 自动横排或竖排；每一项都画 `NSWorkspace.shared.icon(forFile:)` 拿到的真实图标。
- **拖进来**：从 Finder 把 `.app` 拖进来（SwiftUI 的 `onDrop(of: [.fileURL])` 读 `NSItemProvider`）；另外有个「从应用程序选择…」按钮，走 `NSOpenPanel`，照顾不方便拖的情况。⚠️ **原文这里写的是"`.app` / 文件夹 / 文件"，P5++ 按实测收窄成只收 `.app`**，原因见下面的 P5++ 实现记录和 `docs/spikes.md` 实验 8。
- **拖出去**：拖出编辑条就删掉（也可以用右键菜单「从 Dock 移除」）。
- **排序**：在同一条里拖着重排（用 `draggable`/`dropDestination`；SwiftUI 表现不稳的话，就用 `NSViewRepresentable` 包一个 `NSCollectionView`）。
- **固定项**：编辑条最前面锁死 Finder 和 Launchpad，带锁的标记，拖不走也删不掉。
  - Launchpad 是普通的 `persistent-apps` 条目，保证它一直是列表第一项，就钉住了。
  - Finder 不在 plist 里（系统默认就画它），本来就是钉住的。**P0 已确认**：整个偏好域的 34 个键里，没有任何跟 Finder 有关的键或值，`persistent-apps` 里也没有 Finder → **写偏好删不掉它，不用写任何代码**。由此可知：别给 Finder 加拖动手柄（它永远在最前，排不了序），也不用为它加白名单键。（只剩一个未知：用户手动把 Finder 拖出 Dock，会不会写下新键。要手动验一次，风险低，见 `docs/spikes.md`）
- 新建 tile 时照 Dock 的格式拼出来（不给 `GUID`，让 Dock 自己分配）：
  ```json
  {"tile-type":"file-tile","tile-data":{
     "file-data":{"_CFURLString":"file:///Applications/X.app/","_CFURLStringType":15},
     "file-label":"X","bundle-identifier":"com.example.x","dock-extra":0,"file-type":41}}
  ```
- 一编辑，就马上改 App 的内存模型并存盘；要不要立刻推给真实 Dock，由"编辑后立即应用"（默认开）决定，另外也有「立即应用」按钮。

> **P2 实现记录（`UI/DockStripEditor.swift` + `Dock/DockStripRules.swift`）**：上面几条里，**排序、拖进、拖出、固定项、拼 tile 的格式都已实现**。和计划不一样的地方如下：
>
> 1. **`dock-extra` 用 `true`**（用户自己拖进来的 App），启动台用 `false`。计划的例子写的是 `0`（P0 的写入实验也用 0，功能上都能生效），但真实偏好域里用户 App 是 `1`、启动台是 `0`，所以照真实域来。
> 2. **`_CFURLString` 必须带结尾斜杠**：`file:///Applications/X.app/`。`URL(fileURLWithPath:).absoluteString` 不带结尾斜杠，和真实域、P0 写入实验都对不上。统一用 `DockTile.directoryURLString(for:)` 生成。
> 3. **启动台条目原样沿用**：`DockStripRules.normalizedApps` 先找数组里已有的启动台条目（连同 `GUID` / `book` / `file-mod-date` 一起用），偏好域里没有时才用 `makeLaunchpadTile()` 现做一个。早先的版本不管三七二十一直接覆盖，每编辑一次就抹掉真实域里那几个字段（功能上能跑，但没必要动人家的数据）。
> 4. **拖动排序只在 `performDrop` 时存盘、应用一次**：`dropEntered` 会连续触发，所以 `AppState.setDefaultDock` 只改内存，`dockConfigEdited` 才存盘并触发应用。不然每拖过一个图标，就写一次 `config.json`、重启一次 Dock。
> 5. ~~**竖排（left/right）暂未实现**~~ → ✅ **P5 已实现**：`orientation != "bottom"` 时，`DockStripEditor`
>    自动换成 `ScrollView(.vertical)` + `VStack`，格子改成固定高度（`SlotSizing`）。以前把位置改成左/右以后，编辑条还是横的，排起序来方向是反的。
> 6. **「拖出即移除」靠一个明显的垃圾桶投放区**（拖到编辑条外面检测不到）。另外配了右键菜单「从 Dock 移除」。
> 7. **排序、拖动的真实手感还没验**（本机没法用脚本点界面）。逻辑由 `DockStripRulesTests` + `AppStateDockTests` 覆盖，真机拖动要用户手动试一次。
>
> **P5++ 实现记录（2026-09-18）：给其他项（`persistent-others`）补上编辑入口，而且故意只"搬"不"造"。**
>
> 原文第 1 条（拖进来）要求收「.app / **文件夹** / 文件」，这条**被实测推翻了**，改成只收 `.app`：
>
> - **实测结论（`docs/spikes.md` 实验 8）**：自己拼的 `directory-tile`，**Dock 不认**（Dock 不补
>   `GUID`/`book`；把展示字段补齐也不行，就连自己用 `URL.bookmarkData()` 生成 `book` 都不行）；
>   而**字段不全的条目会让 Dock 直接 SIGABRT**，launchd 拉起来它又崩，陷入崩溃循环，用户当场就没了 Dock。
> - **所以**：拖文件夹或普通文件进来时，**明确拒绝，并告诉用户该怎么做**（在访达里自己拖到 Dock 上，
>   Dock 会写好完整条目，之后 `DockWatcher` 再把它存回配置），不让人遇到"拖了没反应"这种无声的失败。
>   提示文案在 `DockItemRejection.message`；`NSOpenPanel` 只让选 `.app`。
> - **其他项照样能编辑**：编辑条下面多了一条「其他项（文件夹 / 堆栈）」，能**排序**（`OthersReorderDropDelegate`），
>   能**删**（右键菜单，或者共用的垃圾桶）。写回去的就是 Dock 自己写的 dict（`GUID`/`book` 原样保留）。
>   `DockStripRules.normalizedOthers` 只去重，**不插固定项**（这是它和 `normalizedApps` 的区别）。
> - 偏好域里没有 `persistent-others` 时，这一整条禁用，并写明原因（不做摆设开关）。
> - **回归守卫**：`DockStripRulesTests.testDockItemRejectionClosesTheFolderAndFilePaths` 钉住"这条路是关着的"；
>   真机验收 `DockAcceptanceTests.testOtherItemsRemovalAndReapplyKeepsDockHealthy` 钉住"删完以后 Dock 还活着，
>   `GUID`/`book` 一个不少"。

### 3.7 设置窗口

> **⚠️ 2026-10-05 重构（用户的规格，放在本节最前；后面留着历史实现记录）**：两个 Tab 按「内容自动生成 + Dock 栏实体」重写：
>
> **通用 Tab：默认 Dock = 最近添加的应用**
> - **⚠️ 2026-10-06 晚些时候用户又改了一次：这整块逻辑删掉了。** 上面那条「默认 Dock = 最近添加的
>   应用」**已经没有了**：没有内容扫描器，没有 `defaultDockAppCount`，没有启动时的冻结对齐，
>   也没有启动台补首（`normalizedApps` 已删）。**原生 Dock 归用户自己管**：冻结模式（默认）下，本
>   App 从不改它；不冻结时，只写**绑定到这个桌面的 Dock 栏**；没绑栏的桌面什么都不写。
>   「立即应用」按钮 = 应用当前桌面绑定的那根栏。下面留着的是历史记录。
> - **大小、放大、自动隐藏、最小化特效、最小化到应用图标，全都跟系统走**：设置里不给这些选项，
>   `DockAppearance` 已删，应用流水线**只写内容键**（persistent-apps / persistent-others）。
>   外观键只在**还原路径**里还用到（基准快照里的原值经 `apply(extraEntries:)` 写回，用来收拾旧版本留下的摊子）。
> - 次级条的图标尺寸改成读**系统当前的 tilesize**（只读，限制在 28–48 之间）。
> - 冻结模式下，用户手动改了原生 Dock，**没地方存回去**（默认内容是自动生成的）→ 只记日志；
>   不冻结时，存回**当前桌面绑定的那根栏**。
>
> **桌面 Tab：Dock 栏列表（新实体 `DockBar`）**
> - 主列表是**不限根数的 Dock 栏**（第一次载入默认 **5 根**，旧的 override 自动迁移成栏）。
>   每根栏有：**名称**（≤10 个字素簇；输入框宽 = **10 个中文字宽**，2026-10-06 第 15 轮）、
>   **桌面下拉**（缩略图是这个空间的壁纸，读 WallpaperKit 的
>   `Index.plist`，读不到就用系统默认壁纸，再不行就用渐变色块；一个桌面只挂一根栏，绑定时另一根自动让出来）、
>   **位置下拉**（底 / 左 / 右；**三条边都列出来，不能用的变灰但不消失**：台前调度占着左边时，
>   「左侧」变灰，2026-10-06 第 15 轮；读 `com.apple.WindowManager
>   GloballyEnabled`，零权限；台前调度开关、原生 Dock 位置变了，要**马上反映**到位置选项
>   和提示上：`AppState` 每 2 s 轮询一次环境，打开设置窗口也立即刷新，2026-10-06 用户规格）。
> - 图标编辑器永远**横着**显示；默认露出 **8 个槽位**，多了横向滚动；每根栏放 **0–15 个图标**
>   （**2026-10-06 用户修订规格：栏里不固定任何 App**。访达、启动台的幻影槽删掉了，启动台降成普通条目，
>   能删能排，允许清空；预览**不显示应用名**，靠悬停 tooltip；**只有没绑定的栏能删**）。
>   其他项（文件夹/堆栈）不在新编辑器里出现
>   （迁移时留在栏的数据里，跟原生 Dock 一起写入）。
> - 运行时：没绑栏的桌面，在冻结模式下只能看到原生 Dock（默认内容），次级条隐藏；
>   **栏的内容 = `DockStripRules.barApps`**（只去重、保持顺序、不插启动台）。只有默认 Dock 才走
>   `normalizedApps`（启动台补首）；次级条也不再画访达幻影（2026-10-06）。
>   栏的位置和原生 Dock 不在同一边时，条**自己贴屏幕边**（半露 = 滑出屏幕一半），和 Dock 的自动隐藏**没关系**；
>   和 Dock 在同一边时，还是贴在 Dock 内侧，并跟 Dock 一起显隐（§3.12）。
> - 桌面命名（toast 用）还留在本页底部，单独一小节；桌面和栏互不相干（名字归桌面，内容归栏）。

> **2026-10-06 第 2 轮（侧边栏 + 数据 + 关于）**：
> - **侧边栏选项卡**：`NavigationSplitView` 左栏四项（通用 / 桌面 / 数据 / 关于，系统设置的样式），
>   去掉 NSToolbar 标签页那套；报警横幅挪到内容列顶部。**同一天又改了一次（用户要求）**：窗口
>   **去掉 titlebar**（`fullSizeContentView` + `titleVisibility = .hidden` + `titlebarAppearsTransparent`），
>   侧边栏的材质一直通到窗口顶，红绿灯浮在侧边栏上（和系统设置一样）；`.titled` 还留着：
>   红绿灯和顶部隐藏的拖拽区都靠它，`window.title` 只给「窗口」菜单和辅助功能用。
> - **「数据」页**：导出配置（和 config.json 结构相同的 JSON，`ConfigStore.encode`）；
>   导入配置（**和启动加载用同一套** `normalizePayload` 归一化和迁移；整份替换并存盘；次级条和绑定
>   马上生效，**不自动应用原生 Dock**；冻结开关的方向变了，会走同一个入口对齐，免得"两套内容并排"）；
>   「备份与还原」从通用页搬过来。
> - **「关于」页**：图标（`NSApp.applicationIconImage`；**2026-10-06 起有了自己的 icns**：
>   `Support/MultiDock.icns`，用 `scripts/make-app-icon.swift` 按苹果图标网格生成）、
>   名称 / 版本（`Support/Info.plist` 的 `CFBundleShortVersionString`，**发版时改它**）、
>   GitHub 仓库链接（git remote：`reiy-leo/side-dock`）、检查更新（`releases/latest` API，
>   语义化版本一段段比；**读发布信息的组件可以注入**：测试和快照不配置它就不碰网络，状态如实显示「未配置」；
>   仓库没有发布版、403 限流、断网，都有明确的提示文案）。每次启动，只在第一次打开关于页时自动查一次。

> **2026-10-06 第 3 轮（用户指令）：通用页删掉「默认 Dock」一节**
> - 「默认 Dock」这组（数量步进器「显示最近添加的应用：N 个」+ 最近应用的只读预览 + 两段说明）
>   整节从设置界面删掉；通用页第一节改成「应用」（立即应用 / 立即还原 / 新基准 / 撤销回存这几个按钮照旧保留）。
> - **行为不变，只是界面收起来了**：默认 Dock 的内容照样自动生成（重新扫描的时机 = 启动时、手动应用前、
>   打开设置窗口时；「改数量」跟着界面一起没了）；`defaultDockAppCount` 还存在 config.json 里
>   （1–15，默认 10），想改只能手动编辑文件；冻结对齐和还原路径都不受影响。

> **2026-10-06 第 4 轮（用户指令）：侧边栏布局：「关于」钉在底部，主 tabs 离窗口顶远一点**
> - 主 tabs（通用 / 桌面 / 数据）还在顶部一组，但整体往下挪：在 List 顶部用 `safeAreaInset`
>   加 26 pt 透明空白让位（红绿灯浮在侧边栏上，原来的默认行距顶得太近；`Color.clear` 点不到，
>   不挡窗口顶部的拖拽区）。
> - 「关于」**钉在侧边栏底部**（系统设置以外常见的侧栏样式）：`List` 没有"把某一行钉在底部"的机制
>   （中间塞个 spacer 行撑不开，行高按内容的理想值算，实测不行），于是改用
>   `safeAreaInset(edge: .bottom)` 放一个**只有一行的原生 sidebar 小 `List`**（高 48 pt =
>   上下 contentInset ~10 + 行 ~28），和上面的主 List 共用同一份 selection 绑定。
>   这样行样式、hover、选中胶囊、窗口不在前台时变灰，全用系统的实现；选中「关于」时上面三行自动都不选，
>   反过来也一样。亮色和暗色快照都确认过，两段 List 的 sidebar 材质连在一起，看不出接缝。
>   见 `Tests/MultiDockTests/UISnapshotTests.swift`（`MULTIDOCK_UI_SNAPSHOT=1` 时输出 PNG）。

> **2026-10-06 第 5 轮（用户指令）：「桌面」拆成「应用栏」+「桌面」；桌面名称像锁屏时钟那样显示**
> - **侧边栏五页**：通用 / **应用栏** / **桌面** / 数据 / 关于。
>   - **应用栏**（`UI/DockBarsTabView.swift`，`DockBarsTab`）：原来「桌面」页里编辑 Dock 栏的那一整块
>     搬过来，内容一点没变（栏列表 / 绑定下拉 / 位置分段 / 图标编辑器 / 孤儿栏解绑）。
>   - **桌面**（`UI/DesktopsTabView.swift`，`DesktopsTab`）：**只管桌面本身**：
>     桌面命名（每个桌面一行：活动圆标 + 壁纸缩略图 + 输入框 + `n/10` 计数）+
>     **名称展示**（开关「切换桌面时显示桌面名称」+ 位置分段）。
>     命名行用分组 Form 的 `LabeledContent` 样式（行标签 = 圆标 + 缩略图 + 「桌面 N」）；
>     ⚠️ 在分组 Form 里，`TextField` 的标题会被提到行首当加粗标签，**所以标题要放在 `prompt:` 里**。
>   - 通用页原来的「桌面切换」toast 开关也一起挪到「桌面」页（通用页只留次级条/冻结那一节）。
> - **名称展示 = 磨砂玻璃面板 + 粗体大字**（`UI/DesktopNameOverlay.swift`，`DesktopNameOverlayWindow`）：
>   第 1 版是没底没框的白字直接压在壁纸上（走"锁屏时钟"路线），**第 2 版（用户反馈后）改成磨砂玻璃**：
>   `NSVisualEffectView`（`.popover` + `.behindWindow` + `.active` + 1 px 内描边，和胶囊 HUD
>   用同一套配方），文字用 `labelColor`，跟着材质变色（不再需要投影）；字号 64 pt，**字重 800 `.heavy`**；
>   面板**宽度按内容量**（`NSString.size(withAttributes:)` 再加 `widthSlack` 余量），只有一个字时也不会缩成圆。
>   窗口层的配方和旧胶囊一条条都一样（borderless、`canBecomeKey/Main = false`、`ignoresMouseEvents`、
>   `level = .statusBar`、`.canJoinAllSpaces + .fullScreenAuxiliary + .stationary + .ignoresCycle`、
>   `orderFrontRegardless`、`animationBehavior = .none`）。
> - **显示位置三档**（`desktopNamePlacement`，默认 `.top`）：顶部（`visibleFrame.maxY − 80`，
>   和旧版一样，自然避开菜单栏，也就是锁屏时钟的位置）/ 中部（垂直居中）/ 底部
>   （`visibleFrame.minY + 64`，避开次级条那条薄边）。水平方向始终居中。
>   **几何计算是纯函数** `frameOrigin(for:visibleFrame:size:)`，单测直接调（不碰真窗口）；
>   位置在 `show()` 时从 provider 现读，所以换了档位，下次显示马上生效，不用重建窗口。
> - **两条通路**（`ToastPresenter`）：桌面名称走 `namePresenter`（锁屏样式的窗口）；
>   系统级的通知（自愈还原 / Dock 已恢复）走 `presenter`（**胶囊 HUD**，原来的
>   `DesktopNameToastWindow` 改名 `HudToastWindow`，只负责"不管什么壁纸都必须看得清"的通知）。
>   超时和 `dismissNow` **只收当前这条通路**；两条通路接替时，旧窗口马上收掉（不然胶囊会一直挂着，
>   等不到自己的计时器）。没传 `namePresenter` 时退回用 `presenter`（兼容测试替身和旧行为）。
> - **验收**：423 个测试全绿（新增路由 5 例 / 几何 3 例，并扩了解码往返的用例）；五个页面的界面快照，亮色暗色各出
>   一套 PNG，逐张核对（应用栏 / 桌面 / 通用 / 数据 / 关于 + 次级条）。

> **2026-10-06 第 6 轮（用户指令）：应用图标**：用户给的方形奶油色 3D 图标设成 App 图标，
> 要求「和 macOS 通用图标大小相同」。
> - **对齐基准（实测）**：按苹果的 macOS 图标网格，1024 的画布里，美术主体（alpha>127）
>   **824×824 居中**，四边各留 100（Notes / Music / Weather 的 1024 渲染图逐像素一致）；
>   系统投影 = 剪影做高斯模糊 σ≈10px，透明度 29%，往下移 10px。
>   要是整张铺满（比如把 1254 的源图直接缩放），会比系统图标大一圈，还没有投影，**别这么做**。
> - **生成流程**（`scripts/make-app-icon.swift`，可以反复跑）：
>   清掉 alpha<8 的噪点 → 裁到美术主体的 bbox（往外多留 2px，保住抗锯齿边）→ 长边缩到 824 并居中 →
>   烘焙和系统一样的投影 → 出 10 档尺寸，打成 `Support/MultiDock.icns`。
>   源图放在 `Support/AppIcon-source.png`；重新出图：
>   `swift scripts/make-app-icon.swift Support/AppIcon-source.png Support/MultiDock.icns`。
> - **接上去**：`Info.plist` 加 `CFBundleIconFile = MultiDock`；`build-app.sh` 把
>   `Support/MultiDock.icns` 复制进 `Contents/Resources/`；「关于」页的
>   `NSApp.applicationIconImage` 自动跟着变，不用改代码。

> **2026-10-06 第 7 轮（用户指令）：通用页重新排：三节合并，删掉「次级 Dock 条」一节**
> - **「退出行为」和「启动与自愈」合成**「**启动、退出与自愈**」一节：
>   前面是退出还原开关和它的无痕说明，后面是登录启动和自愈状态（说的都是一件事：进程的生命周期）。
> - **「次级 Dock 条」整节删掉**：两个开关（显示次级条 `showSecondaryDock`、
>   冻结 `freezeNativeDockSwitching`）**还存在 config.json 里（默认都开），行为不变**。
>   这次只是把界面收起来，和删「默认 Dock」一节是一回事；想改只能手动编辑文件（已记进 AGENTS §6.1 #5）。
>   顺带删了 `secondaryDockBinding` / `freezeNativeDockBinding` 这两个视图层的 Binding
>   （包括关掉次级条时自动解冻的联动；那个联动只在界面层有，导入配置那条路径上的联动还在 `AppState` 里）。
> - **「应用」「Dock 应用」「桌面行为」合成**「**Dock**」一节（用户指定的）：
>   先是四个按钮 + 应用摘要（原「应用」）→ 再是编辑后立即应用 / 回存 / 重载方式（原「Dock 应用」）
>   → 最后是 mru-spaces（原「桌面行为」）。这三块讲的都是「本 App 如何写/管理原生 Dock」
>   （mru-spaces 也是 Dock 域里的键），文案原样保留。
> - 通用页现在一共三节：**Dock / 菜单栏 / 启动、退出与自愈**。快照亮色暗色各一张，逐节核对
>   （包括滚到底的那个合并节），重新打包。

> **2026-10-06 第 8 轮（用户报告）：修菜单栏「图标 + 数字」的垂直对齐**
> - **症状**：桌面序号的数字整体比图标高（按用户截图换算 ~0.72pt，一眼就看得出来）。
> - **原因**：数字没有下伸部（glyph descent），可 `NSStatusBarButton` 是按整个行盒
>   （ascent+descent 都留了位置）垂直居中的，于是数字的墨迹偏高。离屏实测（@2x，18pt 的 Lucide 图标）：
>   图标墨迹中心 21.1px，数字 18.6px，差 ~2.5px = **1.24pt**。
> - **修法**：标题改用 `attributedTitle`，加上 `.baselineOffset`（`MenuBarController.titleBaselineOffset = -0.75`）。
>   排版按像素取整（每档 ~0.5pt），实测最好的一档是 `-0.55 … -1.0`（还差 -0.48px@2x = 0.24pt，
>   不到半个像素）；取这档中间的 -0.75，两边都留了余量。**不写 `foregroundColor`**：
>   实测按钮会自己按 aqua/darkAqua 上色（黑/白），把颜色写死，换到另一种菜单栏就看不清了。
>   `button.title = " \(n)"` 这种写法会偏高，别改回去。
> - **测量脚本**：`scripts/measure-menubar-baseline.swift`（离屏渲染真实的 `NSStatusItem`，
>   按 alpha 加权算墨迹中心，零权限；可以带候选偏移参数再测）。
> - **回归守卫**：`MenuBarControllerTests` 3 例（baselineOffset 必须是负数且等于生产值、
>   不许写死颜色、按钮没字体时退回系统字号）。重新打包。

> **2026-10-06 第 9 轮（用户指令）：「菜单栏」从通用页拆出来，单独成一页**
> - **侧边栏六页**：通用 / **菜单栏** / 应用栏 / 桌面 / 数据 / 关于（「菜单栏」排在通用后面）。
>   新的 `MenuBarTab` 放的就是通用页原来「菜单栏」那一整节，按话题分成两组：
>   **点击行为**（左键动作单选 + 右键/⌥/⇧ 的说明，文案和实验 28 留下的研究注释原样搬过来）和
>   **图标**（Lucide 五选一的格子 + 一句"换图标立即生效"的说明）。
>   行为、文案、绑定都没变，只是换了个页面放；`（点击行为）` 和 `（图标）` 拆成两个
>   `Section`，比原来混在一节里更接近系统设置的分组粒度。
> - **通用页只剩两节**：Dock / 启动、退出与自愈。
> - **验收**：428 个测试全绿；六个页面的界面快照（新增 `settings-menu-bar-{light,dark}.png`）逐张
>   核对（包括确认通用页里已经没有菜单栏那节）；重新打包。

> **2026-10-06 第 10 轮（用户指令）：界面支持中文、英文**
> - **做法**：在调用处直接写双语 `L("中文", "English")`（`App/L10n.swift`），**不建 `.strings`
>   key 表**。编译器能保证两种语言都写了，不会出现查表查不到、翻一半的情况；判断用哪种语言的逻辑集中在
>   `L10n.resolvedLanguage`（纯函数，能单测）。
> - **怎么判断语言**：`Bundle.main.preferredLocalizations` 的第一项以 `zh` 开头 → 中文，不然就是英文。
>   打包时 Info.plist 声明 `CFBundleLocalizations = [en, zh-Hans]`，开发区域设 `en`
>   （第三种语言一律退回英文）。**没声明本地化的包（swift test / 裸二进制）永远是中文**。
>   跟着 App 语言（系统设置 → 语言与地区 → 应用程序）自然生效，**改了语言要重启 App**。
> - **覆盖范围**：所有用户看得到的文案（六页设置、菜单栏、右键菜单、日志、toast、
>   模型层枚举的显示名）；技术标识（SIGHUP/kickstart/键名/路径）和用户数据（自定义的名字）
>   不翻译。
> - **验收**：`L10nTests` 9 例（解析 / 取词 / Info.plist 守卫 / 扫源码的守卫
>   「中文字面量必须在 L() 里」，反过来也验证过）；英文快照 `settings-en-*.png` 六张逐张核对
>   （顺手修了 "Deciduous Tree" 被截断、`**` 星号露出来这两处）；真机设 `AppleLanguages=en`
>   启动，日志整段是英文，删掉这个设置就恢复中文。**438 个测试全绿**。

> **2026-10-06 第 11 轮（用户指令）：原生 Dock 里已经固定的 App，不进自定义栏**
> - **规则**：原生 Dock 里已经固定的 App，**不在自定义 Dock 栏里重复显示**。
>   原生那一份每个桌面都看得到，栏里只放"这个桌面额外多出来的"。
>   往栏里加这种 App 时，**拦下来并给警告**（编辑器里的橙色提示，说清为什么、该怎么办）；栏里已经有的，**自动剔掉**，
>   并按栏逐个记日志（不悄悄改）。
> - **怎么判断是同一个 App**（`DockTile.appIdentityKeys`）：**bundle id 或 `.app` 路径**有一个对上，就是同一个 App；
>   路径不分大小写，去掉结尾斜杠；不看 label（同一个 App 两边的名字可能不一样）。
>   它和 `normalizedKey` 是两回事：那个是**指纹**口径（包括 label，用来判断"这份配置已经生效"，直接返回）。
> - **只在冻结模式下生效**：不冻结时，原生 Dock 的内容就是我们写下去的栏内容，
>   拿它当排除名单，会把栏自己清空（自己吃自己）→ 所以这时排除名单永远是空的。
> - **什么时候触发**：启动载入配置、打开设置窗口、用户手动改了原生 Dock、冻结开关往两个方向切、
>   导入配置；`dockBarEdited` 是存盘前的最后一道闸门，`secondaryDockContent` 显示时也一样过滤。
> - **验收**：452 个测试全绿（+14：规则 8 例 + 集成 6 例）；真机加载后逐栏剔除
>   （用户的三根栏分别剔掉 3/15/15/2 个重复项，原生 Dock 的 15 个 persistent-apps 原样没动）。

> **2026-10-06 第 12 轮（用户指令）：桌面名称行改成一行，去掉前面的 radio**
> - 去掉行首的「当前桌面」圆点（◉/○）：它看着像能选，可这些行是用来输名字的，不能选。
> - `LabeledContent` 会把标签和控件分成两列，各自按自己的高度居中，结果输入框比文字高，看着错开半行。
>   所以换成显式的 `HStack`：缩略图 +「桌面 N」+ 弹簧 + 名称输入框，排在同一条线上。
> - 验收：452 全绿；中/英 × 亮/暗四张快照逐张核对。

> **2026-10-06 第 13 轮（用户指令）：应用栏页改了六处布局**
> - 列表从 `List` 换成 `ScrollView` + `VStack`（**auto-grow**，底部不留空白；`List` 的白底
>   会一直铺到内容列顶上，看着像"列表往上延伸了"，而同一个窗口里其他页都是 246 灰的 Form 底）。
> - 「添加」改成标题行右上角的「＋」；删掉预览上面的标题行和分割线（异常提示留着）；
>   垃圾桶挪到预览**右边**，做成边长 `slotSize` 的正方形，拖着东西经过时**填成红色**
>   （用 `.onDrop(isTargeted:)` 代替 DropDelegate，因为后者拿不到"拖到上面了"的信号）；
>   删掉 `n/15 个图标` 计数和「拖到这里移除」提示。
> - 选中和悬停改成自己画的圆角底色（原来是 List 的高亮）；孤儿栏提示改成橙色卡片。
> - 验收：452 全绿；中/英 × 亮/暗四张快照逐张核对。

> **2026-10-06 第 14 轮（用户规格）：红绿灯和侧边栏的图标列对齐，左边距和上边距相等**
> - 用户原话：「设置窗口中，红绿灯要和下方的图标对齐，距离左边、上边 margin 一样。」
> - **实测基线**（离屏扫描墨迹，@2x）：系统默认三个圆点的中心在 (14,14)/(34,14)/(54,14)，
>   左边距、上边距都是 8 pt（贴着角）；侧边栏五行图标的墨迹中心 x = 25.75–26.0（系统 List
>   的行内边距是固定的，窗口缩放也不变）。**目标几何**：第一个圆点中心在 (26, 26)，正好在图标列正上方，
>   左 = 上 = 20 pt，圆点间距保持系统默认的 20（`TrafficLightLayout`，`UI/SettingsWindow.swift`）。
>   注：一对齐，左边距就钉死成「图标列中心 − 圆点半径」（=20），上边距只能取同一个值。两者绑在一起，
>   单独调哪个都会弄坏另一个（守卫测试钉住了这个等式）。
> - **实现**：写了个 `NSWindow` 子类 `SettingsWindow`（工厂改成生产这个类）。摆放
>   `standardWindowButton` 没有公开 API，直接改 frame 管用（渲染、命中、hover 都跟着按钮走），但
>   **窗口一缩放，frame 就被打回系统默认位置**。所以 override `layoutIfNeeded()`，每次布局完重新贴一次
>   （幂等，按窗口坐标换算，缩放、换屏以后视觉位置还是一样）；全屏时跳过（退出全屏那次
>   布局再补回来）。
> - **标题栏加高 12 pt**（视图和它的容器，`titlebarGrowth`）：圆点下缘在离顶 32 pt 的地方，
>   系统标题栏（28 pt）的 hit-test 区域盖不到。不补这一段，点圆点下缘会点穿到侧边栏上。
>   加高的这段是透明的（`titlebarAppearsTransparent`），实测 SwiftUI 内容的安全区没变
>   （`contentLayoutRect` / `safeAreaInsets` 都不变），唯一的副作用是窗口顶部 40 pt 都能拖动窗口。
> - **验收**：457 个测试全绿（+5：几何 4 例 + 真实窗口离屏 1 例：墨迹在目标位置 / 左边距 = 上边距 /
>   和图标列对齐 / 整颗圆点都能点 / 缩放后位置不变）；六个页面 × 亮暗快照重新出图核对（圆点列和图标列在一条竖线上）。

> **2026-10-06 第 15 轮（用户规格）：应用栏改两处：栏名输入框宽度，位置控件改成下拉**
> - 用户原话：「Dock 名称 input 要更宽一点，默认 10 个中文字符宽度；位置换成下拉列表
>   （不能用的 option 灰掉）」。
> - **栏名输入框 = `NameField.tenCharacterWidth = 148pt`**（原来是 100pt，「密码 邮件…」
>   会被截掉）。算式里的数全是实测的：10 个全角字 ≈ 129pt + `NSTextFieldCell` 自带的左右各 2pt
>   行内边距 + 容器内边距 7×2 + 编辑时给光标留的 ~3pt = 148。
>   ⚠️ **cell 的 4pt 一定要算进去**：一开始按「文本宽 + 容器内边距」给了 146pt，
>   实测渲染还差 1pt，被截成省略号（真踩过这个坑）；守卫 `NameFieldTests` 在运行时用 `cellSize`
>   核对算式，系统字体度量一变就会红。
> - **位置控件：分段按钮 → 下拉（`Menu` + `Toggle`）**，和桌面下拉、条上的右键菜单是同一套。
>   新加了纯函数 `DockBarPosition.choices(current:available:)`（`isCurrent` + `isEnabled`）：
>   **三条边都列出来，不能用的变灰但不消失**（台前调度占着左边时「左侧」变灰；当前值就算已经不能用了，
>   也照实打勾：可以改走，但改不回来）。设置页的下拉和条上的右键菜单**用同一个口径**
>   （右键菜单原来是"过滤掉"，这次也一起改成"灰掉"，见下）。
> - **顺带改的**：条上的右键菜单（`SecondaryDockWindow.makeContextMenu`）也改用同一个 `choices`，
>   不能用的项 `isEnabled = false`；单独的 `SecondaryDockContextMenuBuilder` 删掉了。
> - **验收**：461 个测试全绿（+4：`NameFieldTests` 3 例守卫宽度算式 + `DockBarModelTests`
>   1 例 choices；右键菜单 3 例改成"灰掉"口径，另新增 1 例）；app-bars 快照的中文、英文、暗色版
>   重新出图核对（10 个字的名字完整显示、位置下拉是关着的状态）。快照夹具里的栏名改成正好 10 个字，最长的情况每次都看得到。

> **P5++ 实现记录（2026-09-18）**：应用摘要现在**也显示在调试面板里**（§3.4 第 6 条要求"调试面板可见"，早先只有设置页有）。
> 调试面板新加了「最近一次应用」一组：`结果摘要`（含重载方式和耗时）+ `内容指纹`（前两行 + 总长度，方便对照日志）+
> `写入时刻`（绝对时间 + 离现在几秒）+ `本次运行改过 Dock` + `回存闸门`。

**通用 Tab**
- 「默认 Dock」编辑条（Finder、Launchpad 固定）
- 位置：下 / 左 / 右（分段控件）
- 大小：`tilesize` 滑杆 16–128；放大用 `magnification` 开关 + `largesize` 滑杆
- 自动隐藏、最小化特效（genie/scale）、最小化到应用图标、显示运行指示
- **退出行为**：「退出 App 时还原为原始 Dock」开关（默认开）+ 「把当前 Dock 设为新基准」+「立即还原到原始 Dock」按钮
- 底部：Dock 重载方式的说明（P0 的结论）、`mru-spaces` 的显式开关 + 一句解释（**还是用户自己点了才改**）

**桌面 Tab**
- 桌面列表：显示器名 + 名字（**可以直接在原地改名，最多 10 个字符**，输入框旁边显示 `n/10`；没起名时占位符是「桌面 N」）+ 当前绑定状态（默认 Dock / 独立设置）
  - 改名只写 `DesktopBinding.customName`，**不碰 Dock override**（§3.10）。
- 选中一个桌面以后：
  - 「沿用默认 Dock」开关（打开就是 override = nil）
  - 关掉时，显示这个桌面自己的编辑条 + 位置/大小
  - 「从当前真实 Dock 抓取」按钮（把此刻 Dock 的样子存成这个桌面的配置，第一次配置时最省事）
  - 「重置为默认」「复制默认到本桌面」
- 「刷新桌面列表」（插拔显示器以后用）

**菜单栏下拉**
- 桌面列表（当前桌面打勾，点哪个切到哪个；显示解析后的名字：自定义名或「桌面 N」）
- 「下一个桌面」（循环）
- 「上一个桌面」+ 一条灰掉的提示「（⇧+左键点菜单栏图标同效）」
- 「用当前 Dock 重置本桌面配置」
- 分隔线 → 「设置…」「退出并还原 Dock」
- **交互**：左键单击 = 切到下一个桌面；**`⇧`+左键 = 切到上一个桌面**；右键 / ⌥+左键 = 下拉菜单。
  设置里可以把左键改成"打开菜单"（照顾不习惯的人）。**改成"打开菜单"以后，`⇧`+左键也一起走菜单**，免得留下一个看不见的第二种行为。
- 菜单栏图标上显示当前桌面的序号（比如 `2`），一眼就能确认。序号用 `attributedTitle` +
  `baselineOffset = -0.75` 往下压，和图标在视觉上居中（2026-10-06 第 8 轮修的，见上；别改回 `button.title`）。
- tooltip 写清三种点击：`左键切下一个桌面，⇧+左键切上一个，右键打开菜单`。

> **P2 实现记录**：通用 Tab 已经接上了：**默认 Dock 编辑条 + 「立即应用」+「立即还原到原始 Dock」+「把当前 Dock 设为新基准」+ 本机不支持的键的提示**。`mru-spaces` 开关、位置/大小控件、`largesize` 这些归 P3/P4。
>
> - **默认 Dock 是空的时候，不自动抓取**：免得第一次启动就写盘，更要避免"用户还没配过就点应用 → Dock 被清空"。改成显示橙色警告并禁用「立即应用」，引导用户先点「从当前 Dock 抓取」。这一处是**故意比计划原文更严**（见 §6）。
> - **只有"本次运行改过 Dock"，退出时才还原**（`LifecycleController.sessionChangedDock`）。不能不管三七二十一就还原：用户可能在运行时自己拖过图标，写回基准会把他的改动一起抹掉。另外，还原前先比一次白名单键，已经和基准一样就跳过，省掉一次没必要的 Dock 重启。
> - **`AppState` 的依赖全都能注入**（`dockController` / `configStore` / `baselineStore`），而且 AppState 里面**不直接调 `DockPreferences.readDomain()` 这类静态入口**：那会绕开注入点，测试时就会读到真实系统的偏好域。要读就走 `DockController.readDomain()` / `captureLiveDockConfig()`。
>
> **P3 实现记录（2026-09-18）**：两个 Tab 的样子和计划一致，具体落地如下：
>
> - **通用 Tab**：默认 Dock 编辑条 + 一条**其他项（文件夹 / 堆栈）** + **默认 Dock 的外观**（`DockAppearanceEditor`）+ 应用区（立即应用 / 立即还原到原始 Dock / 把当前 Dock 设为新基准 / 撤销自动回存 + 应用摘要）+ 菜单栏交互 + 桌面切换 toast 开关 + 退出行为 + **启动与自愈** + **桌面行为（`mru-spaces`）** + **备份与还原** + Dock 应用开关（编辑后立即应用 / 识别手动改动并回存 / 重载方式）+ 本机不支持的键。（`mru-spaces` 在 P4 已经做了；这里原来写着"仍未做"，已经过时。）
> - **桌面 Tab**：放在 `UI/DesktopListView.swift` 里。左边是桌面列表（原地改名 + `n/10` 计数 + 「独立 Dock / 沿用默认」徽标 + 当前桌面标记 + 刷新按钮），右边是详情（沿用默认开关 → 没有 override 时提示「复制默认 Dock 到本桌面」，有 override 时给完整的图标条 + 外观编辑器 + 「立即应用」/「从当前真实 Dock 抓取」/「重置为默认」）。**「位置」= Dock 在屏幕上的位置 + 大小**（用户已确认，见 §6）。
> - **菜单栏下拉**：桌面列表（当前项打勾，点哪个切哪个）→「下一个桌面」→**「上一个桌面」**（附一条灰掉的提示「（⇧+左键点菜单栏图标同效）」）→**「用当前 Dock 重置本桌面配置」**→「刷新桌面列表」→ 调试面板… / 设置… → **「退出并还原 Dock」**（标题写明会还原，免得误会）。
>   - **`⇧`+左键 = 切到上一个桌面**（2026-09-18 加的）。它走的链路和「下一个桌面」**完全对称**：同一个 `switcher.target(.previous)`、同一次 `applyConfigForDesktop` 提前应用，到头了绕回另一头。单测 `testPreviousDesktopPreAppliesItsOwnDock` 断言三件事："真的提前应用了 + 目标是另一个桌面的 Dock + 只写一次"。
>   - 「用当前 Dock 重置本桌面配置」**不新加绑定**：当前桌面有独立 Dock 就覆盖它，没有就覆盖**默认 Dock**（凭空造一个 override，会让这个桌面悄悄脱离默认）。
> - **编辑器的读和写必须分开**：`AppState.setDockConfigInMemory` / `setDockAppearanceInMemory` 只改内存，`dockEdited(_:reason:)` 才存盘，再按开关决定要不要应用；默认 Dock 和每个桌面的 override 共用 `DockEditTarget`（`.defaultDock` / `.desktop(space)`）这一套入口。`DockAppearanceEditor.onCommit` 只在**滑杆松手、开关值变了**时才提交：要是每一帧都存盘，拖一次滑杆就会重启几十次 Dock。
>
> **P5++ 实现记录（2026-09-18）：桌面列表的「显示器名」，以及通用页的「其他项」那一条：**
>
> - **桌面列表按显示器分组**：原文要求显示"显示器名 + 名字 + 当前绑定状态"。实际做法是
>   在 `List` 里按 `displayUUID` 分组，`Section` 的标题就是显示器名（`Spaces/ScreenNaming.swift`：
>   实测 `CGDisplayCreateUUIDFromDisplayID` 和 SkyLight 的 `Display Identifier` 每个字符都一样），
>   详情页另加一行「显示器：…」（tooltip 里给完整的 `displayUUID`）。
>   **对应不上时，不拿某台真实显示器的名字凑数**，而是显示"未识别显示器（UUID 前 8 位…）"，
>   因为显示一个错的屏幕比显示"未识别"更糟。插拔屏幕时跟着 `didChangeScreenParametersNotification` 一起刷新。
> - **通用页和桌面页的编辑条下面，都多了一条「其他项（文件夹 / 堆栈）」**：只能看、排序、删，
>   **不能新建**（规格和实测依据见 §3.6 的 P5++ 记录和 `docs/spikes.md` 实验 8）。
> - **拖进来被拒时，界面上把话说清楚**（`DockItemRejection.message` + 「知道了」按钮）：
>   早先的版本拖文件夹进来，是没有任何反应的失败。

### 3.8 手动改了 Dock 自动存回来（DockWatcher）

- 每 2 秒读一次白名单键，比**归一化指纹**：tile 取"规范化 URL + file-label + bundle-identifier + tile-type 的有序序列"，外观取键值字典。
- 归一化时**一定要去掉** Dock 每次重载都会重算的字段：`GUID`、`file-mod-date`、`parent-mod-date`、`book`（Data blob）。
- 指纹变了，又不在 3 秒保护窗口里（不是我们自己刚写完）→ 认定用户在真实 Dock 上手动改过 → 拿它覆盖当前桌面的配置（这个桌面用的是默认 Dock，就更新默认 Dock）。覆盖前先存一份历史版本。
- 设置里能关掉自动回存；关掉后只认 App 里的编辑。
- **和还原的分界**：还原期间（退出流程里）Watcher 一定要停，不然它会把还原动作当成用户改动，写进配置。
- **和 Dock 存活的分界**（2026-09-19 加，`isDockPresent` 闸门）：**Dock 进程不在时，一律不采样**。
  这段时间读回来的偏好域是残缺的。真机上读到过「3 个图标、0 个其他项」（真实 Dock 是 15 + 1），
  这份数据被当成用户改动存了回去，两个桌面的 override 都写坏了。Dock 回来后，第一次读只用来**对齐基线**
  （`needsRebaseline`），不补回存 —— 中间态本来就分不清是不是用户改的。

> **P3 实现记录（2026-09-18）—— 判据和计划原文不一样，以这里为准**
>
> 计划原文写的是"3 秒保护窗口"，实现时换了个**更准的判据**：不比时间，比**内容**。
>
> 每轮取一次真实 Dock 的**可比指纹**（`DockController.currentComparableFingerprint()` —— 口径和写入校验一样：只算白名单里**当前域中真有**的键），和上一轮比：
>
> | 情形 | 处理 |
> | --- | --- |
> | 没变 | 什么都不做 |
> | 变了，而且等于 `appliedComparableFingerprint`（我们上次写下去的那份） | **是我们自己写的**，不管 |
> | 变了，但不等于 | **是用户改的** → 存回来 |
> | 这次运行还一笔都没写过（`appliedComparableFingerprint == nil`） | **一律不动** |
>
> 为什么不用"时间窗口"：Dock 重启后会把我们写的内容**规范化后再写回去**（补上 `GUID` 等），指纹一定会变。拿时间去猜"是不是我弄的"靠不住，比内容就有准。实测来回切 20 次，**误判 0 次**。
>
> 还有两道保护：`AppState.handleDockOutcome` 收到 `.applied` 时 `acknowledge` 一次；`handleUserDockEdit` 回存时**先停 watcher**，写完再开。目的都是别把自己的写入当成用户改动。
>
> **存到哪**：当前桌面有 override → 覆盖它；没有 → 覆盖**默认 Dock**（不凭空造一个 override）。眼下不在用户桌面上（比如正在全屏 App 里）→ 覆盖默认 Dock。
>
> **P5 实现记录（2026-09-18）** —— "覆盖前存一份历史版本"最后做成了**内存里的撤销栈**，没有往磁盘上堆文件：
>
> - `Dock/DockEditHistory.swift`：回存覆盖前，先把旧配置压栈，每个目标留 5 层。桌面页和通用页各有一个
>   「撤销自动回存」按钮（没东西可撤时置灰）。
> - **为什么不落盘**：磁盘上堆一堆文件却没有恢复入口，只是摆设，用户翻到 `history/` 也用不上。
>   回存要防的风险只有一个 —— "误判一次，把用户在真实 Dock 上的改动写坏了配置"，能撤一步就够了。
>   真要长期保命的是 `baseline.plist` 和 `backups/`，这两样一直都落盘。
> - **撤销后 watcher 不会马上又触发**：它只在**真实 Dock 的指纹变了**才回调，而撤销改的是配置，没碰 Dock。
> - 撤到哪和 `handleUserDockEdit` 口径一样：活动桌面有自己的 Dock → 撤到这个桌面；没有 → 撤到默认 Dock。
>   所以 API **不收参数**（`undoLastAutoCapture()`），撤到哪一律按当前活动桌面算。

### 3.9 登录时启动，坏了能自己修

- 登录项先用 `SMAppService.mainApp`；没签名的构建注册不上，就退回 `~/Library/LaunchAgents/local.multidock.loginitem.plist`（`RunAtLoad`，**故意不设 `KeepAlive`**：它是登录启动项，不是守护进程，用户退出 App 后不该一遍遍被拉起来）。
- 启动顺序固定：**查有没有残留的 session.state → 需要就还原基准 → 应用当前桌面配置 → 打会话标记**。
- Dock 重启后没回来 → 先**等**，等够了才用 `launchctl kickstart`（⚠️ **不带 `-k`** —— 带了会把 launchd 刚拉起来的 Dock 再杀一遍，退避还会加长）兜底；还不行就提示用户从备份恢复。
  ✅ **已落地（2026-09-18），阈值 2026-09-19 重新定过**：`DockPresenceMonitor` 要连续缺失满
  `missThreshold`（默认 8 轮 × 500 ms = **4 秒**）才动手，之后每隔 `kickstartEvery`（60 轮 = **30 秒**）
  才催一次；缺失满 `persistentFailureThreshold`（120 轮 = **60 秒**）→ 回调一次 `onPersistentlyDown` →
  `AppState.dockFailureWarning` → 设置窗口顶上出一条**红色**横幅，带「再试一次拉回」和
  「立即还原到原始 Dock」两个按钮；Dock 回来后自动撤掉警告，弹一条 toast。
  判据故意看**缺了几轮**，不看 `kickstart()` 的返回值 —— 那个返回值只说明 `launchctl`
  命令跑起来了，不说明 Dock 回来了。
  ⚠️ 原来是「1 秒就动手 + 每 2 秒催一发」，一次正常的慢恢复会被**自己放大成 60–126 秒的 Dock 死亡**。
  而且那时 `kickstart` 用的是同步 `waitUntilExit`，主线程也跟着卡死 —— 见 §3.5 末尾和 `docs/spikes.md` 实验 9。

> **P4 实现记录（2026-09-18）** —— 这一节全部落地了。下面几处和原文不一样，而且不能"改回去"：
>
> 1. **自愈在启动后异步跑，不卡启动**。`runStartupSelfCheck` 只把残留标记记进 `pendingSelfHeal`，
>    真正的还原等观察器和监视器就位后，由 `scheduleSelfHealIfNeeded` 发起（`AppState.performSelfHeal`）。
>    还原要写偏好、重启 Dock，放在启动路径里同步等，App 启动会卡一秒。
> 2. **欠下的自愈要传给下一个会话**（`SessionMarker.needsSelfHeal`）。自愈是异步的，还原到一半再崩一次，这笔账不能丢：
>    `beginSession()` 会把 `state.hasPendingSelfHeal` 写进新标记。这个字段是**可选**的 ——
>    老版本写的 `session.state` 里没有它。要是不可选，解码就会失败；解码失败等于"没有残留标记"，
>    自愈能力就悄悄没了。
> 3. **退出时还原失败，标记一定要留着，还要标成"非活动会话"**（`keepMarkerAndFinish`：`needsSelfHeal = true` + `pid = 0`）。
>    清掉标记，下次启动的自愈能力也跟着扔了；只留标记、不改 `pid` 也不行 ——
>    `detectInterruptedSession()` 会用 `kill(pid, 0)` 看"标记是不是另一个还活着的实例"，
>    pid 为 0 它才跳过这一步。
> 4. **还原前一定要先 `await state.prepareForTermination()`**：停 watcher、停存活监视器、
>    `dropPendingRequests()`、限时等自愈、限时等正在进行的应用。
>    这一步不能省 —— `request()` 是异步排队的，漏了的话，那笔待办会在还原**之后**才落地，
>    用户看到的就是"退出时还原了，Dock 却还是错的"。
>    ⚠️ **但限时得真的限时**（2026-09-19 实验 10 的修正）：原来两处等待都用
>    `withTaskGroup` 让 `await task.value` 和 `Task.sleep` 赛跑。可任务组闭包返回时要等**所有**
>    子任务收尾，`await task.value` 又不理会取消 —— 结果 2 秒上限实测变成 224–625 ms（替身），
>    真机上碰到 launchd 退避甚至要几十秒。现在改成**轮询可观察标志**（`drainTask` / `selfHealFinished`）。
>    等不到收干净就**返回 `false`，调用方一定要留着标记**。
> 4b. **退出路径不复用 `reload()`**：`DockReloader.reloadForQuit()` 只发一次信号，最多看 1.5 秒，
>    不等节流、不升级、不 `kickstart`；`DockController.apply(..., forQuit: true)` 只写一次、验一次，不重试。
>    这期间存活监视器被 `isReloading` 闸门按住不报（我们自己重启 Dock 不算故障）。
> 5. **注销和关机时系统不给时间等**，只能尽力而为：先把欠的自愈写进标记，再发起还原，等它跑完；
>    跑不完的，下次启动时自愈接着做。**别**改成同步阻塞等还原，那样会拖住关机。
> 6. **Dock 存活监视怎么判**：连续缺失 `missThreshold`（2026-09-19 实验 9 之后是 **8 轮 = 4 s**）才算
>    "真的不在"，之后每隔 `kickstartEvery`（**60 轮 = 30 s**）催一次，满 **60 s** 才报"拉不回来"。
>    原来的 1 s / 2 s / 6 s 会让**每次正常的慢恢复都动手，每次都误报红横幅**。而且那一次催还带着 `-k`
>    —— 它会把 launchd 刚拉回来的 Dock 再杀一遍，退避又续上（`-k` 已经跟着实验 9 一起去掉了）。
> 7. **从备份恢复只写白名单键**，不整域替换：我们自己从来只动白名单键，整域替换会把用户后来改的
>    热角、启动台网格冲回旧值。真要整域恢复，README 里写了 `defaults import` 的做法。
> 8. **白名单之外只有 `mru-spaces` 一个写入例外**，只给它一个专用的窄方法（`DockPreferences.writeMRUSpaces(_:)`），
>    不开通用的"写某个键"口子。它**不归** `apply` 管，写完要另外 `reloadOnly()` 重启一次 Dock。
> 9. **登录启动的状态归系统管**，不存进 `config.json`。在非 `.app` 环境（`swift test`）里，
>    `SMAppService.mainApp` 拿不到有效句柄 → `LoginItem.isAvailable` 先看 bundle，用不了就照实显示原因。

### 3.10 桌面命名和切换提示（toast）

#### 命名

- 名字存在 `DesktopBinding.customName` 里（§3.2 定义过），**只存本地** `config.json`：§1 实测过，空间字典里没有名称字段，写不回系统。
- **最多 10 个字符，按字素簇数**（`String.count`）——一个汉字算 1 个，`👍🏽` 也算 1 个。原因：用户说的"字符"就是眼睛看到的字，不是 UTF-8 字节，也不是 UTF-16 码元。
- **两道防线**：输入框显示 `n/10` 计数（超了变橙）+ **模型层归一化**（`DesktopNaming.normalize`：CRLF 和换行换成空格 → 去掉首尾空白 → 按字素簇截断）。归一化在**两个时候**做：输入框提交时（回车或失焦），以及 `ConfigStore.load()` 之后。这样就算有人手改 `config.json` 塞进超长的名字，设置页和 toast 的布局也撑不破。
  - ⚠️ **输入框不在每次按键时就截断**（和本文档早期的写法不同）：中文输入法组字（marked text）时改绑定值，会把候选词打断。所以草稿先放在 SwiftUI 本地的 `@State` 里，提交时才归一化。计数照样实时显示。
  - 归一化是纯函数，能单测（空串、纯空白、11 个汉字、emoji、换行、首尾空白、正好 10 个）。
- **名字为空 = 没起名** → 回落到「桌面 N」。
- **改名不会建 Dock override**：`customName` 和 `override` 互不相干，可以只改名、不设 Dock。名字清空**并且** `override == nil` 时，就删掉这条绑定，不留空行。
- **取名字只走一个入口：`AppState.displayName(for: DesktopSpace)`**：有自定义名就用，没有就回落到 `DesktopSpace.displayName`（"桌面 N"）。菜单栏标题、下拉菜单、桌面页列表、toast **全都**改用它；`DesktopSpace.displayName` 退成只出序号名，只在拿不到配置的地方用。

#### toast

> **2026-10-06 修订（用户指令）：名称单独开一个窗口显示，走两条通路；同一天第 2 版改成磨砂玻璃**
> 桌面名称不再用胶囊 HUD，改用**独立名称面板**（`DesktopNameOverlayWindow`）：
> **磨砂玻璃底**（`NSVisualEffectView` `.popover`/`.behindWindow`）+ 64 pt **字重 800** 的大字，
> 面板宽度跟着名字长短走；**位置三档**（顶部 / 中部 / 底部，
> `desktopNamePlacement` 默认顶部）。胶囊 HUD（原来的 `DesktopNameToastWindow` 改名叫
> `HudToastWindow`）只留给**系统级告知**用（比如自愈还原这类"压在什么壁纸上都得看得清"的消息），
> 它的外观规格（下面两节）照旧有效。调度这边 `ToastPresenter` 分两条通路，
> 超时和收起只管当前那条，新的接上时旧窗口马上收掉。名称和告知原来的「开关」含义不变。

> **2026-10-06 第 3 版（用户规格「默认、流动霓虹、赛博紫韵」，同一天用户又澄清：
> 效果修饰的是展示背景，不是字体）：面板背景三档**
> 新加 `desktopNameEffect`（默认 `.standard`）。**默认档不变**（磨砂玻璃面板 +
> `labelColor` 大字）；两个霓虹档的**面板背景**交给 `DesktopNameEffectCanvas` **自己画**：
> 先铺一层不透明的暗色竖向渐变（白字好不好读就和壁纸无关了）→ 再画**流动光带**（两条"透明→彩色→透明"
> 的横向渐变柱，用 `.plusLighter` 叠上去，略带斜切；`.neonFlow` 是青色和品红相向扫，2.2 s 一趟；
> `.cyberPurple` 是两道紫同向慢扫，2.8 s 一趟，光带和描边会呼吸）→ 最后是**霓虹描边**（1.5 pt 内描 +
> 同色小半径辉光），整体按圆角裁掉。**文字一直是同一个 `NSTextField`**（效果档只把字色
> 换成纯白，默认档换回 `labelColor`）——字体的 64 pt、字重 800、量宽防截断都没变。
> **为什么自己画，不用 CoreAnimation 图层**：① 项目的快照验收走视图绘制（`cacheDisplay`），
> CA 图层的内容抓不全 —— 自己画，快照和真机就是同一份代码；② 项目早有教训「别依赖隐式动画通道」
> （animator alpha 会随机悄悄失效）。动画由 `Timer`（30 fps，RunLoop 的 `.common` 模式）驱动
> `needsDisplay`，**只在显示的那 1 秒里跑**（`show()` 开表，`hide()` 停表）。
> 光带扫动的几何是纯函数 `bandCenterX(phase:bandIndex:panelWidth:bandWidth:)`
> （带 0 从左往右，带 1 反过来，两端都扫出面板外）。窗口这边新加 `presentation(...)`/`apply(...)`
> （一个算纯值，一个负责应用）。效果和位置都是**实时 provider**，改了设置，下一次显示就生效。
> 三档选择器在「桌面 → 名称展示」；配色和速度的配方在 `DesktopNameEffectSpec`（能单测）。
> **光带最亮时不透明度故意压在 ≤0.65**：光带从文字底下扫过时也不能把白字冲淡（有测试钉住这一条）。

**只有一个触发点：`SpaceObserver.onActiveSpaceChanged`。** 它是唯一的事实来源——每 300 ms 轮询一次活动空间，不管是从哪儿切的。所以**用户自己用触控板、快捷键或 Mission Control 切桌面也会弹 toast**，不只是 App 发起的切换。App 自己切的，切完马上 `observer.refreshNow()`（必要时 50 ms 后再补一次），把延迟压到最低；靠轮询兜底，最坏也就 300 ms。

**只在「用户桌面 → 另一个用户桌面」时弹**：上一次通知的值也得是个非 nil 的桌面。这一条顺手去掉了两种噪音：① App 刚启动时的第一次采样；② 从全屏 App 空间退回桌面（`activeSpace` 先变成 nil 再变回来，会被当成切了桌面）。

- 内容：这个桌面的名字（自定义名或「桌面 N」）。
- 位置（2026-10-06 修订）：**在所在显示器上三档任选**——顶部（`visibleFrame.maxY − 80`，
  默认，就是锁屏时钟的位置，和旧版一样）/ 中部（垂直居中）/ 底部（`visibleFrame.minY + 64`，
  让开次级条的薄边）；水平方向始终居中。几何是纯函数 `DesktopNameOverlayWindow.frameOrigin`，能单测。
  用 `displayUUID` 对到 `NSScreen` 上找显示器（§1 实测可行；共用 `ScreenMatching.resolve`）；
  对不上就回落到 `NSScreen.main`。
- 停 **1 秒**自动消失。1 秒内又切了桌面 → **取消上一次计时，直接换文字，重新计时**（不会排队弹两条，也不会被旧计时器提前收走）。
- 计时和去重放在纯逻辑的 `ToastPresenter` 里（协议 + 可注入的时钟），AppKit 部分放在
  `DesktopNameOverlay`（名称）/ `DesktopNameToast`（胶囊 HUD）里，这样行为就能单测——
  和用 `SpaceProviding` 隔开私有 API 是一个路子。

**窗口属性（少一条都会出问题）**：

| 属性 | 值 | 为什么 |
| --- | --- | --- |
| `styleMask` | `.borderless` | 不要标题栏 |
| `isOpaque` / `backgroundColor` | `false` / `.clear` | 圆角胶囊是自己画的，底不能不透明 |
| `hasShadow` | `false` | 阴影自己画 |
| `level` | `.statusBar`（25） | 比普通窗口高，但不压住系统弹窗 |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` | **少了 `.canJoinAllSpaces`，窗口就只在自己所在的空间显示**——切过去反倒看不见，功能等于没了 |
| `ignoresMouseEvents` | `true` | 绝不挡点击 |
| `canBecomeKey` / `canBecomeMain` | `false` | **绝不抢焦点**，不然用户切过去正要打字，字会打进 toast |
| 显示 / 隐藏 | `orderFrontRegardless()` / `orderOut(nil)` | 不用 `makeKeyAndOrderFront`（会抢焦点） |

- **不要任何权限**（现在的实现；原来的「硬约束 §2.5」2026-10-05 已解除）：它就是本 App 自己的一个窗口，不涉及辅助功能、屏幕录制和 root。
- 设置页有一个开关「切换桌面时显示桌面名称」（**默认开**），不想要的人可以关掉。

#### 外观（2026-09-19 改版：跟着亮色 / 深色走的原生 HUD 胶囊）

原来是"固定黑底 `black 0.78` + 白色 15 pt medium，圆角 12，内边距 20/10"。当时文件里给的理由是
"要浮在任意背景上，固定深色底比跟随外观更可控" —— **这个理由站不住**：`.popover` 材质配上
`blendingMode = .behindWindow`，本来就是为"压在任意内容之上仍可读"设计的，它模糊的是**身后真实的内容**。
固定黑底是在躲这个问题，代价是亮色、深色下都是同一块死黑，还厚重得像别的系统贴过来的色块。

| 维度 | 规格 | 为什么 |
| --- | --- | --- |
| 底 | `NSVisualEffectView`，`material = .popover`、`blendingMode = .behindWindow`、`state = .active` | 自动跟着亮色 / 深色变；`.active` 必须写 —— 本 App 是 `LSUIElement`，窗口永远不会成为 key，不指定就会显示成灰掉的 inactive 样子 |
| 形状 | **定高胶囊**：高 32、圆角 16；宽 = 文字宽 + 2×14，**最窄 76** | 定高：要是高度跟着文字变，名字长短不同，每次切换都会跳一下。设下限：单字的名字不能缩成一个圆 |
| 圆角怎么做 | 用 `maskImage`，**每次 show 都按当前宽度现画一张 1:1 的图** | `NSVisualEffectView` **没有** `cornerRadius`（那是 UIKit 的）；遮罩又会被拉到视图边界那么大，复用固定尺寸的图，两头的小圆角会被扯成椭圆 |
| 描边 | 1 px 内描边，动态色：亮色 `black 0.12` / 深色 `white 0.16` | 亮色下材质几乎是纯白，压在浅色壁纸上会和背景糊成一片，只有这条边能把它勾出来 |
| 文字 | `labelColor`，14 pt semibold | `labelColor` 在 vibrancy 视图里跟着材质变；用 semibold 是为了压在花哨的背景上也读得清 |
| 位置 | 不变：水平居中，离 `visibleFrame` 顶部 80 pt | §6 第 3 条已经按 80 pt 做了 |
| 动效 | **没有**（`animationBehavior = .none`） | 提示只显示 1 秒，淡入淡出会吃掉能感觉到的停留时间，`check-toast-window.sh` 核对计时也会变糊。真要做，就做在**内容层透明度**上，别动 `window.alphaValue`（脚本断言 `kCGWindowAlpha == 1`） |

**验收（本机不能截图，见 `AGENTS.md` §4）**：

- **纯逻辑单测**覆盖：1 秒到点消失、1 秒内连切会取消并重新计时、启动第一次不弹、从全屏回来不弹、没有自定义名时回落「桌面 N」、开关关掉时不弹但照样记账。**这次改版一行测试都不用改** —— 调度在 `ToastPresenter`（纯逻辑），外观在 `DesktopNameToastWindow`，两边本来就是分开的。
1. 外观用 **`scripts/preview-toast.swift`** 出图：`cacheDisplay(in:to:)` 抓的是**自己窗口**的视图内容，
   **不需要屏幕录制权限**（拍整个屏幕的 `screencapture` 才要），它在假壁纸上出亮、深两张 PNG，用来自查材质、
   圆角、描边和字号。⚠️ 它用的是 `.withinWindow`（模糊窗口里的假壁纸），真机用的是 `.behindWindow`（模糊屏幕内容）——
   **色调、圆角、描边、字体一样，但模糊到的实际画面不一样**，所以真机上那一眼还是省不了。
   另外：这个脚本是 `DesktopNameToast.swift` 的**代码副本**，那边改了这边要跟着改。
2. 几何和窗口属性照旧用 **`CGWindowListCopyWindowInfo`** 客观验证（`scripts/check-toast-window.sh`，支持 `--watch`）：MultiDock 的 toast 窗口会出现，`layer == 25`、`alpha == 1`，bounds 水平居中、贴近屏幕顶部；1 秒后窗口消失。**读窗口元数据不需要屏幕录制权限**（只有抓图 `kCGWindowImage` 才要）——P1 验证菜单栏图标（layer 25）用的也是这个办法。
   - 判别式里的 `height >= 30` 改版后（高 32）照样命中，**用不着为了迁就脚本留着旧的 39**。
   - ⚠️ 判别式一定要带上 **`onscreen == true`**：`orderOut` 之后，窗口在 CG 窗口列表里**还会再待好几秒**（实测），不滤掉的话「消失」会报晚，1 秒时长就对不准。
3. 调试面板加一个「测试 toast」按钮，手动触发；`multidock.log` 记 `toast 显示「X」` / `toast 隐藏` 两行，带时间戳，可以直接对 1 秒。
4. ⚠️ **真机上还得用户在亮色、深色下各看一眼**（切一次桌面就行）。上面的预览器能定"形状和颜色"，定不了"模糊到真实桌面之后的观感"。

---

### 3.12 次级 Dock 条（2026-10-04 新增，用户拍板）

**它是什么**：一根自己画的图标条，贴在原生 Dock 内侧。它**不替换**原生 Dock，也不改原生 Dock 的偏好。
硬约束 2 原本是「不自己画 Dock 栏」，用户这天改了：次级条是批准过的例外，
原生 Dock 的地位和无痕原则都不变（条只是 App 自己的 UI，不写任何偏好，App 一退出就没了）。

**交互规格（用户原话）**：

- 位置：贴着原生 Dock「下方/内侧」——Dock 在 bottom → 从 Dock 顶边探出来；在 right → 从左侧；在 left → 从右侧。
- **默认露一半**：整条往 Dock 那边推 `tuckRatio`（0.8）个条厚（2026-10-06 用户调过，原来是 0.5），
  滑到 Dock 后面的部分被 Dock 的像素挡住（次级条窗口层级 19 < Dock 的 20；滑进去的量取整到整点）；
  **鼠标悬停就整条滑出来**（离开后防抖 150 ms 再收回）。
- ~~不做放大效果~~ → **2026-10-23 用户改成：悬停放大跟着系统「放大」开关和 `largesize` 走**（`SecondaryDockMagnification`，窗口往屏幕里面多留一块透明 headroom；只在显出时放大；多行条只放大光标所在那一行）。图标基础尺寸跟着这个桌面生效配置的 tilesize，钳在 28–48；
  **冻结模式下改取默认 Dock 的**，见下文。
- **条宽跟着内容走（2026-10-05 用户修订，v3.6.2 的固定槽位不要了）**：条宽按这个桌面的条目数撑开；
  图标尺寸在冻结模式下取默认 Dock 的 tilesize（没冻结就取本桌面配置）。原来的「固定槽位 = 各桌面最大
  条目数、切桌面窗口一毫米不挪」在方案 ② 下不成立——切桌面时条一定会「沉没位再升起」，宽度变化
  悄悄发生在沉没位，看不到跳变。
- **条属于哪个空间 = 方案 ②（2026-10-05 用户拍板，实验 24 的折中）**：窗口用 `.moveToActiveSpace`
  单空间配方。手势切换的那一下，条**留在旧空间（跟着系统过渡渐隐，大约划过 0.25 倍屏宽时消失——什么时候渐隐
  由 WindowServer 决定，实验 25 证明改不了）**；切换完成的回调再把窗口拉回当前空间：
  **先放到沉没位（`visibleFrame` 底边以下，这一跳看不见）→ 0.12 s 升回原位，同时淡入**
  （用户规格：切完后总共感觉 ≤ 0.15 s；这是实验 25 采纳下来的残余）。程序化切换（点菜单栏）走
  `SpaceSwitcher.switchTo → observer.refreshNow()`，当拍就拉回来，没有 300 ms 的空窗。拉回有闸门：只有
  「换了空间且切换前后都在显示」才拉（同一空间的重复事件、进出全屏、从隐藏恢复都不拉）。
- **手势预隐藏（2026-10-06，实验 27）**：三指或四指横扫切桌面时，条**在过渡第一拍就消失**
  （不再跟着桌面滑）。`SpaceTransitionGestureMonitor`（listen-only 的 `CGEventTap`，mask 只有
  type 30，不要权限）看到切桌面之前的手势指纹，就回调 `spaceTransitionGestureDetected()`。指纹
  就是 type 30（翻页前 ~620 ms 一定出现；用 ⌃→ 键盘切换时 30 一次都没有；两指滚动 22、翻页 31、MC 捏合都不会触发；
  **不加字段门槛**）。动作：α 直接设成 0，收回到半露位；600 ms 内确认真的翻页了，就交给拉回流程（从沉没位
  0.12 s 升起）；超时没切换（误扫、横扫中途停了、MC、Launchpad）就分步慢慢显回来（6 步 × 20 ms；
  animator alpha 实测会随机悄悄失效，所以一律分步直接设值）；连着扫，每来一个新的 30 就续一次命。还挂了一张安全网：
  200 ms 一次几何轮询，只要不在预隐藏，又（不在当前空间 / alpha < 0.99）→ 兜底重新拉回，静默窗
  250 ms，没好就把退避时间翻倍（这个条件**和模式无关**——独立贴边模式的半露 frame 本来就在屏幕外）。NSEvent
  的 `.swipe` 通道在真实切桌面的整个过程中一个事件都没有（实验 27 第 1 轮），已经判死。
- **和原生 Dock 一起显隐（2026-10-04 用户修订）**：原生 Dock 藏起来 → 条也藏；Dock 出来 →
  条跟着出来。主要信号是 face（`visibleFrame` 往里缩），自动隐藏生效时（face == nil）用
  「光标在显出带」这个启发式补判（实验 22：Dock 实际显没显出来，没有不要权限就能直接读的信号）；几何轮询 200 ms 一次。
- 点条目 → `NSWorkspace.open`（已经在跑就激活）；运行指示点一直占着槽位，不跳。
- **右键菜单 = 快速切换屏幕位置（2026-10-06 用户规格）**：在条上点右键，弹出原生 `NSMenu`
  （底部 / 左侧 / 右侧，当前位置打勾）。**每次右键都现建**——和设置页的位置下拉**用同一套口径**
  （`DockBarPosition.choices`：三条边都列出来，不能用的置灰而不是藏掉；台前调度占着左边时「左侧」
  `isEnabled = false`，栏里已经存了这个值的话也照样打勾显示现状，可以改走）。选中后，带着内容快照里的
  `barID` 交给 `AppState.setDockBarPosition` —— **和设置页位置下拉走同一条 `dockBarEdited` 通路**
  （存盘 + 刷新条 + 按开关应用）。窗口层怎么做：用 `NSHostingView` 的子类接管 `rightMouseDown`
  （SwiftUI 手势只管左键，菜单不靠内容层）；`NSMenuItem` 的 target 是 assign，不会帮你持有，
  target 对象一定要由窗口的存储属性一直拿着（rules.md 里次级条的新坑）。

**内容和冻结开关（用户从三个方案里选了「随桌面 + 冻结开关」）**：

- 内容 = 当前桌面的 `effectiveConfig(for:).pinnedApps`（**2026-10-06 起：不插 Finder，也不补启动台**，
  栏里有什么就画什么；下文的「Finder 幻影置首/启动台首位」只是历史记录）
  `DockStripRules`），**切桌面那一下就换内容**（只换视图，不重启，不写入）。
- 设置项「冻结原生 Dock 的逐桌面切换」——**默认开（2026-10-04 用户修订：原生 Dock 所有桌面
  都一样，不按桌面重启）**：开了以后 `applyForDesktopSwitch` 整个跳过——原生 Dock 一直用一套
  固定配置（= **默认 Dock**），不再随桌面写偏好、重启；手动路径（「立即应用」、编辑器里的
  「编辑后立即应用」）不受影响。冻结期间用户手动改了真实 Dock → 存回**默认 Dock**
  （冻结时，"当前桌面绑定"这层意思不成立）。

**每根栏可以单独设位置（2026-10-05 用户规格，`DockBar.position`）**：

- 选项 = 底 / 左 / 右；**台前调度开着时不给选左**（它的最近使用窗口条固定占着屏幕左边，
  读 `com.apple.WindowManager` 的 `GloballyEnabled` 判断，不要权限；读不到就当没开）。
  这只管设置入口——已经存成左的栏，运行时不去改它（用户关掉台前调度后，它应该照原样能用）。
  台前调度的开关、原生 Dock 位置的变化，都靠 `AppState` 每 2 s 一次的环境轮询，实时反映到设置页（见 §3.7）。
- **附着模式**（栏的位置 == 原生 Dock 的方位）：本节上面说的行为全都不变（贴 Dock 内侧、露一半被
  Dock 挡住、和 Dock 一起显隐——face == nil 时按最近一次的方位判断，别掉进独立贴边模式）。
- **独立贴边模式**（栏的位置 ≠ Dock 的方位）：贴着自己那条屏幕边，**露一半 = 滑出屏幕一半**
  （出了屏幕就算藏起来，`standalonePlacement`），悬停时滑回来贴齐边缘；**和原生 Dock 的自动隐藏
  没关系**（它不在 Dock 那条边上），一直露一半。屏幕矩形从 `DockFaceProviding
  .currentScreenFrame()` 来（探不到 face 时用上次见到 Dock 的那块屏，一次都没见过就用主屏）。
- 图标尺寸**跟着系统走**（读实时的 tilesize，只读；原来的「冻结取默认 Dock / 未冻结取本桌面配置」
  跟外观设置一起废了）。内容只来自**绑定的栏**；没绑栏的桌面不显示条（§3.7 重构记录）。
- **冻结时要主动保证「原生 Dock = 默认 Dock」**，下面三处少一处都不行：① 启动时对齐
  （`reestablishFrozenDockIfNeeded`，排在自愈后面——自愈先还原基准，这里再冻结；内容一样时
  比指纹直接短路，不重启）；② 打开开关时马上对齐默认 Dock；③ 关掉开关时马上应用当前桌面的生效配置。
  少了①，退出还原后下次启动，原生 Dock 会停在基准上，和次级条各显示一套。

**机制**（实测依据见 `docs/spikes.md` 实验 21——Dock 条不是单独的 CG 窗口，几何来源用
`visibleFrame` 排他内缩）：

| 件 | 位置 | 说明 |
| --- | --- | --- |
| 纯几何 | `Dock/SecondaryDockLayout.swift` | `detectDockFace`（看三个方向的内缩 → 定方位）+ `placement`（展开、半露两个 frame）+ `barSize` + `dockArea`（判断显出带，实验 22）；全是纯函数 |
| 几何来源 | `Dock/DockFaceProviding.swift` | `ScreenInsetDockFaceProvider` 扫所有 `NSScreen`，取内缩最大的那块屏 |
| 显示 | `UI/SecondaryDockWindow.swift` | 照搬 Toast 配方，有三处不同：能交互、层级 19、SwiftUI 图标条；材质 `.popover` + maskImage 做圆角；**方案 ②：单空间配方 + `pullToActiveSpace()`（先设透明，frame 跳到沉没位 → 临时跨空间 → orderFront → 16 ms 后设回 → 0.12 s 升回原位，同时淡入，实验 25）**；**右键菜单**：`NSHostingView` 子类接管 `rightMouseDown` → `SecondaryDockContextMenuBuilder`（纯函数，每次右键现建）→ `NSMenu.popUpContextMenu`，选中后经 `onPositionSelected(barID, position)` 回到 `AppState` |
| 内容 | `UI/SecondaryDockStripView.swift` | 条目模型（快照里带 `position` 和 `barID`）+ `SecondaryDockContentBuilder`（纯函数）+ SwiftUI 视图 |
| 调度 | `UI/SecondaryDockController.swift` | 状态机（半露 / 展开 / 隐藏 / 手势预隐藏）+ **和 Dock 一起显隐（face + 显出带 + 400 ms 宽限）**+ 200 ms 几何轮询 + 悬停防抖 + 鼠标位置安全网 + **切空间拉回闸门**（换了空间、前后都在显示才拉）+ **手势预隐藏**（30 → α=0 + 600 ms 超时后分步显回 + 连扫续命 + 安全网兜底，实验 27）；依赖全靠注入，能单测 |
| 手势监视 | `Spaces/SpaceTransitionGestureMonitor.swift` | listen-only 的 `CGEventTap`，mask 只有 type 30（切桌面前的手势指纹，不要权限，实验 27）；建不成就 3 s 后重试，`.tapDisabledByTimeout` 能自己恢复；回调走 `spaceTransitionGestureDetected()` |

**什么时候显示**：全屏空间（`space == nil`）隐藏；开关关了隐藏；
没内容（这个桌面的 `pinnedApps` 是空的）隐藏；**自动隐藏和重启的瞬态里，跟原生 Dock 一起显隐**
（Dock 藏，条也藏；光标碰到边、Dock 出来时条跟着出来 —— 实验 22）。多显示器时跟着内缩最大的那块屏（B5 没实测，先标上）。

**验收**：次级条的单测（三个方位的几何 / 半露 / clamp / dockArea / 内容构建 / 状态机 / 条宽随内容 /
一起显隐 / **空间拉回五例**——切空间拉一次、连切每次各拉一次、重复事件不拉、进全屏不拉、出全屏不拉 /
**手势预隐藏十一例**——预隐藏 + 收回、超时显回、连扫续命、翻页后取消超时、没显示时不触发、悬停时压住、
安全网治好卡在半透明 / 治好孤儿 / 健康时跳过 / 预隐藏时豁免 / 没好就退避；**右键位置菜单八例**——条目纯逻辑
三例（全部打勾 / 避开左 / 不可选的现状插回去）、窗口装配见证两例（快照打勾 + target/action 分发时带栏 ID、
每次右键现建）、`AppState` 落点三例（存盘带来源日志 / 同位置和过期 ID 悄悄忽略 / 快照带 `barID`）；
全仓 **414 全绿**）；快照
`secondary-dock-{light,dark}.png`；真机 window-dump
核对 `layer=19`、半露 frame 逐像素对得上（实验 21），还有启动对齐日志、切桌面零重启日志（v3.6.1/2）；
悬停、点击、右键菜单、方案 ② 和手势预隐藏切桌面的手感，归到用户手测（A11/A12）。

#### 3.12.x 多行次级条：一个桌面挂多根栏（2026-10-23，用户规格）

**用户规格**：「每边多根，把现在的多根换成一根，但这一根可以上下滚动，最多 3 条的内容；
（2026-10-23 改版，取代本段的 handle / 展开：条只显示一行，滚动一次手势切一行，末端圆点提示行数）用上方的 resize handle 扩大高度（最多三条高度）；自动 hide 到原生 Dock 后方时变成一条高度，
show 时显示成用户 resize 成的高度」。同一天拍板：①左右两边对称（handle 在内侧，往屏幕中间加宽成多列，
横向滚动切列）；②收起时显示上次滚到的那一行，那一行没了就回第一行；③拖出来的高度**每个桌面各存各的**。

- **绑定规则**：不再限定「一个桌面只挂一根栏」。同一个桌面**同一条边最多 3 根**（`DockBar.maxRowsPerEdge`），
  行的顺序 = `dockBars` 列表的顺序。绑定时栏所在的边已经满了 → 自动挪到第一条还有空位、能用的边；三条边都满了 → 拒绝，并给警告。
  把位置改到已满的边：设置页下拉和条上的右键菜单都置灰（`AppState.availableBarPositions(forBar:)`），
  `dockBarEdited` 最后再兜底拒绝。`DockBar.spaceID` 还是单值（一根栏只绑一个桌面），配置不用迁移。
- **主栏**（`dockBar(for:)`）：先挑和原生 Dock 同一条边的第一根，没有就挑第一根。没冻结时写进原生 Dock 的、
  「立即应用」的、手改 Dock 后存回去的，都是主栏。
- **窗口**：每条屏幕边一扇 `SecondaryDockWindow` 加一个 `SecondaryDockController`（`AppDelegate` 建 3 套）。
  内容由 `AppState.secondaryDockContent(for:edge:)` 给出，同一条边上的每根栏做成一行（`SecondaryDockRow`）。
  手势预隐藏时，三扇窗口在同一拍收到广播。
- **几何**：行厚 `thickness(rows:) = iconSize + 20 + (rows-1)·(iconSize + 10)`；收起时永远是 1 行
  （和旧的单行 frame 一模一样），显出时按「桌面 × 边」存下的行数（钳在 1…min(3, 行数)），
  靠原生 Dock 或屏幕边那一侧不动，往屏幕里面长（`SecondaryDockLayout.resized`）。窗口长度按最长的那一行算。
- **行序和滚动**：第一行贴着 Dock 或屏幕边（底部 = 最下面一行，左 = 最左一列，右 = 最右一列）。
  用 SwiftUI 的 `ScrollView` + `scrollTargetBehavior(.viewAligned)` 按行吸附；横条只接竖向滚动，竖条只接横向，
  不跟系统切桌面的手势抢。`scrollPosition(id:anchor:)` 的锚点就在第一行那一头，滚到哪行 = 「上次滚到的行」，
  由 `onAnchorRowChanged` 存进 `AppSettings.secondaryDockRowPrefs`。窗口变形时（显出、收起、拖高），
  ScrollView 会自己夹住滚动位置，0.4 s 的静默窗里不往回报；收起时滚回锚定的那一行。
- **handle**：外沿正中的一个短胶囊（底部 = 上沿，左 = 右沿，右 = 左沿），只在显出、而且行数 > 1 时出现。
  拖的时候用屏幕坐标（`NSEvent.mouseLocation`），厚度跟着手走，钳在 1…可用行数；松手吸附到整行（过半就进一行），
  frame 动画回位并存下来。**拖的过程中，收回防抖和显出宽限都先停掉**（`isResizing`），轮询重摆时用实时厚度。
- **配置**：`AppSettings.secondaryDockRowPrefs: [String: SecondaryDockRowPref]`，键是 `"<spaceID>|<edge>"`，
  值是 `visibleRows` + `anchorBarID`；手写的 `init(from:)` 已经补上 `decodeIfPresent`（陷阱 #3）。
- **等真机手测（A15）**：滚动吸附的手感、handle 拖拽（包括拖出窗口也不收）、收起时显示上次那一行、
  三扇窗口同时在时角落看着怎么样、右键菜单是不是作用在光标所在那一行。

### 3.13「启动台」页（2026-10-06 新增，用户规格）

**用户原话**：「如果 macOS 26 以下系统，那么从 Launchpad 中获取所有的文件夹（名称、包含的
apps），单独一个"启动台"tab｜每个文件夹都可以：添加到某个 Dock、替换某个 Dock」。

**闸门**：**从 macOS 26 起，系统用「应用程序」代替了启动台**，按文件夹排好的那份数据也就没了 ——
所以这一页只在 26 以下能用（`LaunchpadSupport.hasLaunchpad(majorVersion:)`，版本号取自
`ProcessInfo.operatingSystemVersion`）。26+ 上页面只显示一段说明，不读数据库，也不给操作。

**数据从哪来（只读，不要权限）**：启动台自己的 SQLite 库
`$DARWIN_USER_DIR/com.apple.dock.launchpad/db/db`（15.8.1 实测，WAL 模式，
`rw-r--r--`，用户能读）。表结构：

- `items(rowid, type, parent_id, ordering)` —— `type 1` 是根，`2` 是文件夹，`3` 是页，`4` 是 App；
  `parent_id` + `ordering` 组成目录树和**屏幕上的顺序**；
- `apps(item_id, title, bundleid, storeid, bookmark)` —— 名称、bundle id 和 CFURL bookmark；
- `groups(item_id, title)` —— 文件夹（以及文件夹里的页）的名字。

**怎么读**：用一条递归 CTE 把「根 → … → 节点」的路径拼出来（每层 `printf('%09d.', ordering)`），
文件夹按路径排序；App 在递归时继承「最近一个 `type = 2` 祖先的 rowid」，归到所属的文件夹，
再按路径排序 —— 这样文件夹的顺序和文件夹里的顺序都和启动台屏幕上一样（多页文件夹也一样）。
只读打开（`SQLITE_OPEN_READONLY`）+ `busy_timeout 1s`，**一个字节都不写**（验收里有字节比对）。

**定位**（`LaunchpadResolver`）：把记录变成能写进 Dock 栏的条目：

1. 先用 bookmark：`URL(resolvingBookmarkData:)` 直接解出真实路径（15.8.1 真机 **160/160**，
   包括 `/System/Volumes/Preboot/…` 这种 cryptex 路径）；
2. 再用 bundle id 索引兜底（只有真有记录要兜底时才扫盘）：`/Applications`、`/System/Applications`、
   `/System/Applications/Utilities`、`~/Applications`，用 `skipsPackageDescendants` 不钻进 App 包里；
3. 拿解析出的路径调 `DockStripRules.tile(forAppAt:)` 生成条目（**和从访达拖进来是同一套口径**，
   所以原生 Dock 的排除规则、栏的上限、写入流水线全都照样适用）。
   同一个路径在文件夹里出现两行就去重（真机上有 iWork 新旧两版同名的残留）；定位不到的条目
   **照样算数**，计进「N 个定位不到」，不悄悄扔掉。

**两个动作**（`LaunchpadImport` 是纯函数，`AppState` 负责接线，都走现成的 `dockBarEdited` 存盘通路）：

| 动作 | 做什么 | 记哪些账 |
| --- | --- | --- |
| **添加到某个 Dock** | 把文件夹里的 App **接到**目标栏末尾，原来的顺序和内容不动 | added / 栏里已有 / 原生已固定 / 定位不到 / 超上限 |
| **替换某个 Dock** | 清空目标栏，换成文件夹里的内容 | 前后数量 + 同样的跳过账 |

两个动作共用三道闸：定位不到的跳过；**原生 Dock 上已经固定的跳过**（2026-10-06 就有的规则，
排除集**只在冻结模式下生效** —— 没冻结时原生 Dock 就是我们写进去的内容，拿它来排除会把栏清空）；
每根栏按 `DockBar.maxApps`(15) 截断。**一个都加不进去、或者根本没有可用内容 = 照实报失败**；
替换失败时**目标栏一个图标都不动**（不做破坏性清空）。跳过了哪些写进结果行（"跳过：N 个栏里已有、
M 个已固定在原生 Dock…"）。

**UI（`LaunchpadTab`，侧边栏第七页）**：整页滚动，每行是一个文件夹（名称 + 「N 个 App
（M 个定位不到）」+ 前 10 个图标的预览，定位不到的画成虚线占位；悬停时行有底色），右边两个菜单
「添加到…」「替换…」（菜单项 = `栏名（N 个图标 · 桌面名/未绑定）`）。行下面显示这次操作的
结果（成功、失败都在这一栏，能关掉）。一打开页面就读（`onAppear`），另外有个「刷新」按钮；
**同样的结果只记一次日志**（切回这页会重读，但不会把日志灌满）。文案全部走 `L()` 双语。

**可注入**（`LaunchpadLoader`）：`isSystemSupported` / `loadRecords` / `resolve` 三个闭包 ——
测试既不碰真实数据库，也不扫真实的安装目录；**UI 快照用固定的夹具**（不会跟着用户自己的启动台变）。

**验收**：单测 34 例（DB 夹具：读顺序 / 多页 / 空字段 / 只读字节 / 错误分类；解析器：bookmark / 兜底 /
去重 / 定位不到；搬运规则 9 例；`AppState` 状态和两个动作 13 例）；真机只读验收
`MULTIDOCK_LAUNCHPAD_ACCEPTANCE=1`（27 个文件夹、160 个 App、定位 160/160、读完字节没变）。

---

## 4. 分阶段实施和验收（全部做完）

> 每个阶段**怎么做下来的、每条验收的证据**都归档在 `docs/sessions.md`（36 次会话记录）；
> 各模块"改动时别踩"的要点在 `docs/rules.md`。这里只留结果。

| 阶段 | 内容 | 结果 |
| --- | --- | --- |
| **P0 实验** | Dock 重载 A/B/C、主动切桌面、Finder 怎么表示 | ✅ 没有热重载 → 主路径走 SIGHUP（约 101 ms）；切桌面 0–6 ms，硬切、没动画 → 以轮询为主；Finder 不用写代码。见 `docs/spikes.md` 实验 1–3、7 |
| **P1 骨架** | SwiftPM 包、SkyLightBridge、SpaceObserver、菜单栏、基准快照 + 会话标记 | ✅ 切桌面 10 次全对，`baseline.plist` 34 个键逐个相同，运行前后 Dock 没差别 |
| **P2 编辑条 + 应用** | DockPreferences / ConfigStore / DockReloader / DockController / DockStripRules / 通用 Tab | ✅ 真机验收：只动白名单键；写入生效（当时的判据是 GUID 回填）；数据备份和还原形成闭环。**这是本项目第一次真正写 Dock** |
| **P2.5 命名 + toast** | DesktopNaming、ToastPresenter、DesktopNameToast、验收脚本 | ✅ 真机实测窗口几何和时长；切 4 次桌面，Dock 每个键都没变（不写 Dock） |
| **P3 桌面页 + 自动切换** | 绑定和 override、切换时自动应用、防抖合并、预应用、自动回存 | ✅ 真机来回切 20 次全过，Dock 不可用 45–90 ms，回存误判 0 次。两个要命的发现见实验 5（节流错开 + `-1` PID 闸门） |
| **P4 无痕和自愈** | 退出还原全链路、靠残留标记自愈、登录启动、存活监视、备份恢复 UI、`mru-spaces` | ✅ 自愈连开三次结果都一样；`kill -9` 后能拉起来；真机退出还原 0.01 s。③ 注销还等用户实测（B9） |
| **P5 / P5+ / P5++** | README、多显示器加固、全屏回归、编辑条竖排、孤儿绑定、回存撤销、UI 报警横幅、其他项只搬不造 | ✅ 全屏过滤真机回归过；README 重写；⚠️ 多显示器还等用户插屏实测（B5） |
| **后续演进（2026-10-03/04）** | 实验 17–22：CoreDock 通道结案、无闪烁三明治、次级 Dock 条、冻结转正成默认、sticky + 一起显隐 | ✅ 见 `docs/spikes.md` 实验 17–22；现在的样子见 §0 和 §3.12 |

### 现在的验收基线

```bash
swift build -c release --disable-sandbox && swift test --disable-sandbox   # 364 全绿、零警告
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests  # 真机 9/9 绿（先备份 Dock 域）
MULTIDOCK_UI_SNAPSHOT=1 swift test --disable-sandbox --filter UISnapshotTests          # UI 四张 PNG（零权限）
```

---

## 5. 风险和对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 主动切桌面的私有 API 失效 | 菜单栏切换用不了 | ✅ P0 验证过能用（**0–6 ms**，没动画）。还是留着 `SpaceProvider`/`SpaceSwitcher` 协议做隔离，失效时退成"仅跟随 + 手动改 Dock"，并在 UI 上报警 |
| **切桌面后收不到空间变化通知** | 跟得慢，或者漏更新 | ✅ P0 确认过（程序化切换不发通知）→ 事件源改成**以 300 ms 轮询为主**；自己发起的切换一律**预应用**，不等通知 |
| 没有热重载，换内容得重启 Dock | 重启那一下 Dock 会闪 | ✅ **默认（冻结）模式下切桌面根本不重启**（不写入、不重启）。还得重启的路径（没冻结时切换 / 手动应用 / 启动对齐）走 SIGHUP（约 101 ms）+ **自动隐藏三明治**（滑走 → 看不见地重启 → 滑回来，看不到黑屏）；内容一样直接短路；连着点就合并 |
| **launchd 的重启节流**：离上次重启不到约 1 s 又重启，Dock 要 **约 1070 ms** 才回来（`spikes.md` 实验 5） | 连着切桌面时，Dock 会消失一秒多 | ✅ 做了 `DockReloader.minimumSpacing`（默认 1 s）：先等满这段窗口再重启，**等的时候 Dock 能用**。实测把 Dock 不可用的时间压到 **45–90 ms**；`ReloadOutcome` 把 `elapsed`（不可用）和 `spacingWait`（可用的等待）分开记 |
| **Dock 重启的那段时间里，`NSRunningApplication` 返回 `processIdentifier == -1`** | ① 误以为"Dock 已回来"；② `kill(-1, SIGTERM)` = **杀掉当前用户的所有进程** | ✅ 三道防线：`dockPID()` 只要 `> 0` 的；`signal()` 拒收 `pid <= 0`，还用 `proc_name` 核对身份；`waitForRestart` 只认 `pid > 0`。测试在 `DockProcessSafetyTests`，全用**信号 0** 断言（闸门坏了只会让测试失败，不会把测试进程打死） |
| **节流窗口的判据搞错了**（P4 验收时实测发现）：原以为"记在自己内存里"就够了，可 launchd 的节流是**按服务**算的 | 别人（用户 / 别的 App / 我们的存活监视器）刚重启过 Dock，我们紧跟着再重启，就会吃满整段节流，Dock 消失一秒多 | ✅ 改成按 **Dock 进程的年龄**（`proc_pidinfo(PROC_PIDTBSDINFO)` 的 `pbi_start_tvsec/tvusec`）推算窗口，拿不到年龄才退回内存记录。实测 P3 第一轮从 **1030 ms → 45 ms**。见 `spikes.md` 实验 6 |
| **排队中的应用盖掉了退出还原** | 退出后 Dock 还是错的（用户以为已经还原了） | ✅ 还原前先 `await state.prepareForTermination(settleLimit:)`：停 watcher / 停监视器 / **扔掉还没开跑的待办** / 限时等自愈 / 限时等正在进行的应用；等不到收干净就**留着标记**，交给下次自愈 |
| **"限时等待"其实没限住**（`withTaskGroup` 让它和取消不了的 `await task.value` 赛跑） | 每次退出实测卡 53–54 秒：没 Dock、没壁纸、触控板手势失灵（= 用户以为机器死了） | 限时一律改成**轮询可观察标志**（`drainTask` / `selfHealFinished`）；退出路径另走 `reloadForQuit()`（发一次信号 + 看 1.5 s，不升级、不 `kickstart`）。回归守卫**断言墙钟时间**，不只看返回值 —— 见 `docs/spikes.md` 实验 10 |
| **还原失败后，自愈能力丢了** | 下次启动不再试着还原，Dock 永远停在非基准状态 | ✅ 失败时留着标记 + `needsSelfHeal = true` + `pid = 0`；`beginSession` 把这笔账传给下一次启动 |
| **从备份恢复时越界，写了白名单以外的键** | 用户后来改的热角、启动台网格被冲回旧值 | ✅ 从备份恢复只走 `DockConfig.read` + `apply`（白名单键），**不整域替换**；单测断言 `wvous-br-corner` / `mod-count` 没被覆盖 |
| **`mru-spaces` 变成"随便写某个键"的万能口子** | 早晚会被误用到热角这类键上 | ✅ 只给一个窄方法 `DockPreferences.writeMRUSpaces(_:)`，而且不归 `apply` 管（写完单独 `reloadOnly()`） |
| **在非 `.app` 环境里 `SMAppService` 用不了** | 点登录启动开关没反应 | ✅ `LoginItem.isAvailable` 先看 bundle，用不了就在设置页显示原因；`enable()` 抛 `LoginItemError.notInAppBundle` |
| **注销或关机时来不及还原** | 关机后 Dock 停在非基准状态 | ⚠️ 系统不给时间等，只能尽力：先写欠账标记，再发起还原。**还没实测**（得真注销一次），见 `AGENTS.md` §6.3 B9 |
| `pgrep` 起一次子进程约 **110 ms**，却放进了 15 ms 的轮询热路径 | 每次判断重启都慢了一个数量级 | ✅ 改用 `proc_listpids` + `proc_name`（**0.02 ms**），不再起子进程；`DockProcessSafetyTests` 有测试盯着平均耗时 |
| **SIGTERM 的 255 ms 清理窗口盖掉了我们的写入** | 应用没生效 | ✅ 已做：应用后读回来校验，不一致就重试一次（SIGTERM 只给 SIGHUP 兜底）。P2 实测 SIGHUP 路径每次都一次成功，重试靠单测覆盖 |
| **Dock 回写 `GUID` 是异步的**（**从 15.8.1 起这个判据失效了**，实验 19） | 拿"GUID 补没补上"当判据，会误判成"写入没生效" | 15.7.x 上这个判据得配轮询；15.8+ 改用「条目跨 Dock 重启仍在 + `mod-count` 变化」，验收用例已经按系统版本分情况 |
| **冻结语义有缺口：原生 Dock 和次级条各显一套** | 开了冻结后，原生 Dock 可能停在某个 override 或基准上，和次级条对不上 | ✅ 三处一起兜：启动对齐（排在自愈之后）+ 开关的两个方向（`setFreezeNativeDockSwitching`）。内容一样时比指纹直接短路，不重启。见 §3.12 和 `docs/spikes.md` 实验 21/22 |
| **次级条和原生 Dock 显隐对不上** | 原生 Dock 藏起来了条还浮着，或者碰边 Dock 出来了条却不在 | ✅ 以 face（`visibleFrame` 内缩）为主 + 自动隐藏时用「光标在显出带」启发式 + 400 ms 宽限；200 ms 轮询一次。Dock 实际显没显出来，**没有不要权限就能直接读的信号**（实验 22），别再去找更"准"的通道 |
| 插拔显示器后 `displayUUID` 对不上 `NSScreen` / 桌面列表不刷新 | toast 出现在别的屏幕上；桌面串号 | 回落到 `NSScreen.main`；✅ P5 已经接上 `NSApplication.didChangeScreenParametersNotification` → 插拔后自动重读桌面列表。**真机实测还得用户插一台外接屏**（本机只有一块屏） |
| **跑验收的时候用户手动改了 Dock** | 验收报假失败（实测踩过一次） | 验收测试开头把整个域 dump 下来，结尾再比；判据放宽成"差异只能落在白名单键或 `{mod-count, recent-apps, trash-full}` 上"；文档里写明跑的时候别改 Dock |
| **`plutil -p` + `diff` 比长数组会错位** | 冒出假差异，误导判断 | 看"成员和顺序"就抽出标签序列来比；看"值"就用 `PlistValue` 按结构比 |
| **不管三七二十一退出就还原，会抹掉用户自己拖进去的图标** | 用户手动改的被吞掉 | `LifecycleController` 只在 `sessionChangedDock`（这次运行改过 Dock）时才还原；另外还原前先比一次白名单键，已经和基准一样就跳过 |
| **默认 Dock 是空的时候误点「立即应用」，会把 Dock 清空** | 用户的 Dock 被清空 | 空配置直接拒绝应用，记一条 WARNING；UI 上把按钮置灰 + 橙色警告，引导先「从当前 Dock 抓取」 |
| **规范化启动台条目会抹掉真实域里的 `GUID`/`book`** | 每次编辑都逼 Dock 重新推导，白白改了用户数据 | `DockStripRules.normalizedApps` 先复用已有的启动台条目，域里没有时才现造 |
| **`.app` 的 `_CFURLString` 少了末尾的斜杠** | 和真实域的格式对不上 | 统一走 `DockTile.directoryURLString(for:)` 补上斜杠，有单测覆盖 |
| **拖拽排序时一路存盘 + 重启 Dock** | 每拖过一个图标就写一次盘、重启一次 Dock | `dropEntered` 只改内存（`AppState.setDefaultDock`），到 `performDrop` 才存盘 + 应用一次 |
| **强杀或崩溃时来不及还原** | 用户退出后 Dock 停在非原始状态 | 靠 `session.state` 标记 + 下次启动自动还原；P4 专门验收了 `kill -9` 的情况 |
| **还原没等够就退出了进程** | 用户看到"Dock 没还原" | `terminateLater` 先挂起；先跑 `prepareForTermination(settleLimit: 2s)`（**有上限**），再走 `reloadForQuit`（发一次信号 + 最多看 1.5 s）；等不到收干净就留着标记给下次自愈 |
| 自动回存把还原动作误记下来 | 配置被弄脏 | 还原期间停掉 DockWatcher（3.8 里约定的分界） |
| 切空间**没有**动画（程序化切换是瞬间提交的） | 点菜单栏切桌面是硬切，没有"左右滑动"的过渡 | **明确不做**，在零权限 + 无痕的前提下没解：程序化切空间实测 0–6 ms；会话级开关 `SLSSetSessionSwitchCubeAnimation` 写了读不回来（改了就还原不回去）；`SLSWillSwitchSpaces` 签名不知道，猜错会段错误。见 `spikes.md` 实验 7。**别再试了** |
| `mru-spaces = 1`（本机就是这样） | 系统会重排桌面顺序，"下一个"不符合直觉 | 设置页给个明确的开关，让用户自己关；不偷偷改 |
| 把 Dock 配置写坏 | 用户的 Dock 坏了 | 第一次写之前存全量基准 + 每轮备份；只覆盖白名单键；一次原子写；一键还原；README 写了 `defaults import` 的还原步骤 |
| 和用户在真实 Dock 上的手动改动互相覆盖 | 改动被吞掉 | ✅ 判据看**内容**不看时间：可比指纹变了，又不等于我们写下去的那份 → 存回来（`DockWatcher`，见 §3.8；P3 实测来回切 20 次误判 0 次）+ 内存撤销栈 + 能关掉 |
| **短路只比"我们上次写下去的那份"，外面一改，判据就过时了** | 逐桌面 Dock 的桌面**回存**时，白写一遍 + 白重启一次 Dock（约 50 ms 闪烁），而这正是本 App 的日常用法 | ✅ 加了短路第 2 条"真实 Dock 已经就是这份内容"（判据复用写入校验那套比较）。真机实测从 `68667 → 68672` 修成 `68995 → 68995`。见 §3.4 第 2 条和 `docs/rules.md` 末尾 D24 |
| 混进全屏 App 的空间 | 每次全屏都切 Dock | 用 `type != 0` 过滤。**P5 真机回归过**：把自己的窗口切成全屏，造出一个真的 `type=4` 空间（不要权限），实测过滤管用，见 §4 P5 行和 `scripts/check-fullscreen-filter.swift` |
| **toast 抢焦点** | 用户切过去正要打字，字打进了 toast | `canBecomeKey` / `canBecomeMain` = false，用 `orderFrontRegardless()` 显示 |
| **toast 挡住点击** | 1 秒内点不到下面的东西 | `ignoresMouseEvents = true` |
| **toast 只在自己所在的空间显示** | 切过去反倒看不见，像是功能坏了 | `collectionBehavior` 一定要包含 `.canJoinAllSpaces` + `.fullScreenAuxiliary` |
| 连着切桌面时 toast 串台或闪烁 | 显示旧名字，或者被旧计时器提前收走 | 只用一个 `ToastPresenter`：换文字 + 重新计时，绝不同时跑几个计时器 |
| 从全屏 App 空间退回桌面时误弹 toast | 噪音 | 只在「用户桌面 → 用户桌面」时弹（上一次通知的值也得非 nil） |
| 名字太长 / 手改 `config.json` 塞进超长的名字 | 设置页和 toast 的布局被撑破 | 输入框计数 + 模型层 `DesktopNaming.normalize` 归一化，两道防线，有单测覆盖 |
| **输入框边打字边截断，会打断中文输入法组字** | 拼音打不出字 | 输入框不即时截断，只在回车或失焦时归一化（草稿放本地 `@State`） |
| **`orderOut` 之后窗口还在 CG 窗口列表里待好几秒** | 用窗口元数据验收，会把「消失」的时刻判晚 | 判别式带上 `onscreen == true`；`check-toast-window.sh` 已经这么做了 |
| 插拔显示器后 `displayUUID` 对不上 `NSScreen` / 桌面列表不刷新 | toast 出现在别的屏幕上；桌面串号 | 回落到 `NSScreen.main`；✅ P5 已经接上 `NSApplication.didChangeScreenParametersNotification` → 插拔后自动重读桌面列表。**真机实测还得用户插一台外接屏**（本机只有一块屏） |
| Dock tile 的 `book` blob 过期 | 图标显示不正常 | 比对时去掉这个字段；真要实测出问题，就在写入时剥掉 `book`/`file-mod-date`，让 Dock 自己重建（备选开关） |
| 没签名的登录项注册失败 | 开机不会自动跑 | SMAppService 一失败就退回 LaunchAgent |
| 系统删掉或重排桌面后映射错位 | 配置串到别的桌面 | 用 `spaceUUID` 做键；✅ P5 已做：失效的绑定在桌面页列成孤儿，给「清理」按钮 + 二次确认。**绝不自动删** —— 外接显示器拔掉时，那台显示器上的桌面会整个消失，绑定看起来就是孤儿，可插回去还要用 |

---

## 6. 以前待确认的事（都已结案）

下面这些都是早期对话里"我这样理解，你不同意就说"的条目。它们**一直按现在的实现在用，用户没提过异议**，
就算确认了。**别再重复问**；真有问题，回归时再改。

| # | 当时的问题 | 现在的做法 |
| --- | --- | --- |
| 1 | 「桌面」页里的"位置"指什么 | = **Dock 的屏幕位置 + 大小**，和「通用」页是一个意思；没单独设就继承默认 |
| 2 | toast 在没有自定义名时显示「桌面 N」，还是什么都不显示 | 显示「桌面 N」 |
| 3 | "屏幕中上部"具体在哪 | 离可见区顶部 **80 pt**，水平居中（实测 `y=80`） |
| 4 | 10 个字符按字素簇算还是按视觉宽度算 | **按字素簇**（一个汉字算 1，一个 emoji 算 1） |
| 5 | 默认 Dock 是空的时候要不要自动抓取 | **不自动抓**：显示橙色警告，把「立即应用」置灰，引导先「从当前 Dock 抓取」 |
| 6 | 重启节流带来的"切换延迟"还要不要再优化 | 按"宁可等也不闪"：等的时候 Dock 能用。**现在默认（冻结）下切桌面已经不走这条路了** |
| 7 | 自愈还原要不要弹 toast 告诉用户 | 弹（不受"切换提示"开关管）——还等用户体验后反馈，见 `AGENTS.md` §6.1 |
| 8 | 登录启动要不要默认打开 | 默认关，用户自己去设置里开 —— 还等用户拍板 |
| 9 | 其他项不能新建，这个折中能接受吗 | 已经按"只搬不造 + UI 写明替代做法"做了 —— 还等用户点头 |

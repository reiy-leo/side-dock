# 会话记录

> append-only，**最新在最上面**。每条记录：这次做了什么 / 当前进度 / 未解决的事。
> 2026-10-04 自 AGENTS.md §8 迁移（verbatim）；旧文档里"见 §8"即指本文件。

### 2026-10-06（第 46 次）— 次级条右键菜单：屏幕位置快捷切换

**用户说**：「secondary dock右键菜单显示：屏幕位置快捷toggle」。

**做了什么**：

1. **窗口层**（`UI/SecondaryDockWindow.swift`）：`NSHostingView` 子类接管 `rightMouseDown`
   （SwiftUI 手势只管左键，菜单不依赖内容层）→ 每次右键现建 `NSMenu`（`popUpContextMenu`
   不依赖 key window，本窗口 `canBecomeKey = false` 实测可用）。条目集合
   `SecondaryDockContextMenuBuilder`（纯函数，与设置页 `positionOptions(for:)` 同口径：
   台前调度开着避开左；栏存着不可选的位置也如实插回清单展示现状）。target 对象由窗口
   存储属性常驻持有（NSMenuItem 对 target 是 assign 不保活）。
2. **内容快照**（`UI/SecondaryDockStripView.swift` + `App/AppState.swift`）：
   `SecondaryDockContentSnapshot` 加 `barID`（右键菜单要知道改哪根栏）；
   `AppState.secondaryDockContent(for:)` 填充。
3. **落点**（`App/AppState.swift`）：新增 `setDockBarPosition(id:to:)` —— 与设置页位置
   分段同一 `dockBarEdited` 通路（落盘 + 刷新条 + 按开关应用），栏不存在/位置没变静默忽略。
4. **接线**（`App/AppDelegate.swift`）：`availablePositionsProvider` 读
   `AppState.availableBarPositions`（2 s 环境轮询保鲜）；`onPositionSelected` 落
   `setDockBarPosition`。
5. **测试**：新增 `SecondaryDockContextMenuTests` 八例（条目纯逻辑三例、窗口装配见证两例
   ——含走真 target/action 分发链防静默断线、AppState 落点三例）；**414 全绿**。
6. **重打包** `build/MultiDock.app`；文档：PLAN §3.12 交互规格/机制表/验收、AGENTS §3
   现行行为 + 模块地图 + 测试数、rules.md 次级条新坑三条、A12 加手测项。

**影响 / 未解决**：

- 菜单只在条可见部分可右键（半露时是那条薄边）；选中后条立即换边（走既有 refresh 路径）。
- 真机手感（半露薄边上右键的可达性、菜单弹出位置）归 A12 手测顺带确认。

---

### 2026-10-06（第 45 次）— 设置窗口去 titlebar：侧边栏贯通到窗口顶（系统设置同款）

**用户说**：「侧边栏贯通titlebar，去掉titlebar」。

**做了什么**：

1. **`SettingsWindowFactory`**（`UI/SettingsView.swift`）：styleMask 加 `.fullSizeContentView` +
   `titleVisibility = .hidden` + `titlebarAppearsTransparent = true`。**保留 `.titled`**——
   红绿灯、顶部隐藏拖拽区、「窗口」菜单标题都靠它；`window.title` 只是UI上不再显示。
   `NavigationSplitView` 左栏材质因此贯通到窗口顶，红绿灯浮在侧边栏上，无标题文字、
   无 titlebar 分隔线（系统设置同款）。
2. **验证**：UI 快照亮/暗 8 张核对通过——侧边栏到顶、内容列按安全区自动内收
   （首行「通用」在红绿灯下方，不遮挡）；快照由 `cacheDisplay` 画 contentView，
   红绿灯浮层本身不进 PNG，真机观感归 A12 一起看。
3. **测试**：406 全绿；UISnapshotTests 一句过时注释（「含工具栏」→「含隐藏 titlebar
   的窗口样式」）；**已重打包 build/MultiDock.app**。
4. **文档**：PLAN §3.7 侧边栏 bullet 补「同日再修订」、AGENTS §3 模块地图设置 UI 行。

**影响 / 未解决**：

- 窗口顶 ~28 pt 是隐藏拖拽区；SwiftUI 内容有安全区内收，可点内容不会钻到红绿灯底下。
- 拖拽手感 / 红绿灯浮在侧边栏上的真机观感，归 A12 手测顺带确认。

---

### 2026-10-06（第 44 次）— 半露加深：附着模式滑入比 0.5 → 0.8（tuckRatio）

**用户说**：「secondary dock和原生dock的重叠更高一点从0.5更换成0.8」。

**做了什么**：

1. **`SecondaryDockLayout`**：新增 `tuckRatio = 0.8`（原逻辑硬编码滑入半个条厚）+
   `tuckOffset(_:)` 私有助手（条厚 × 比例，**取整整点**——0.8×56=44.8 这类浮点会把
   半露边摆在半像素上发虚）。`placement()` 三个方位的 `tucked` 全部改走它：
   bottom 56 厚条从露 28 pt 变为露 ~12 pt（45 滑入）；right/left 同理。
   **`standalonePlacement` 刻意不动**：独立贴边与原生 Dock 无重叠，其半露按用户规格
   固定「滑出屏幕一半」，不吃 `tuckRatio`。
2. **连带核查不改**：拉回的沉没位（`visibleFrame.minY - height - sinkMargin`，与比例无关）、
   显出带（`dockArea` 外扩 8，与条厚无关）、沉没升起时长 0.12 s（行程 28→45 pt 略变长，
   时长不动，真机觉得拖再说）。
3. **测试**：`SecondaryDockTests` 三个字面 tucked 期望更新（y 29→12、x 1812→1829、
   x 52→35）+ 一处断言消息改口径；其余 tucked 断言全走 `placement()` 自动适配。
   **406 全绿、release 零警告、已重打包 build/MultiDock.app**。
4. **文档**：rules.md 实现要点第 2 条、PLAN §3.12 交互规格、AGENTS §3 次级条行
   （spikes.md 实验 21 的历史描述不改——当时记录的就是半个条厚）。

**影响 / 未解决**：

- **hover 命中区变薄**（32 pt → ~15 pt）：半露边就是 hover 目标，露得少必然更难碰。
   若真机觉得难点亮，备选是给条顶加一圈不可见的热区 padding，或回调比例。
- 沉没升起行程变长（28 → 45 pt / 0.12 s），速度略快，归 A11 一起看手感。
- `tuckRatio` 若要再调，只动 `SecondaryDockLayout.tuckRatio` 一处（测试的三个字面
  期望要跟着改）。

---



### 2026-10-06（第 43 次）— 实验 27 手势预隐藏落生产：type 30 → 切桌面前一拍隐藏 + 分步渐回 + 安全网

**用户说**：「⌃→ 键盘切换对了，三/四指横扫切桌面不对（还是跟着桌面滚）」；26d 后：「三指上滑
Mission Control / 打断横扫 / 四指捏合 Launchpad 三场景 custom dock 消失不出现了」；26e 后：「要等
好几秒，可以缩短么」；「好的，执行吧」（批准 26f 方案落生产）；本会话「继续执行」收尾文档。

**做了什么**：

1. **spike 六轮（内部轮次 26c–26f，正式记为实验 27；`scripts/spike-swipe-prefetch.swift`）**：
   NSEvent `.swipe` 通道判死（真实切桌面零事件）→ listen-only `CGEventTap` 免授权挂上
   （mask 不含键盘事件）→ 宽 mask 指纹锁定 **type 30**（13 次手势翻转前 ~620 ms 全有、
   8 次 ⌃→ 零 30；22/31/MC 捏合不触发）→ 26d 30 触发预隐藏（横扫第一拍即隐 ✓，但 MC /
   打断横扫 / Launchpad 三场景条**永久消失**——`moveToActiveSpace` 拉回把窗口绑进瞬态空间
   成孤儿）→ 26e 安全网 + 心跳遥测定罪 **`animator().alphaValue` 随机静默失效**（九次超时
   渐回七次卡 alpha=0.0；26d「永久消失」同因，当时无网可救）→ 26f alpha 全换分步直设 +
   安全网静默窗 800→250 ms + 未愈退避翻倍，用户批准。
2. **生产集成（4 文件 + 测试）**：新建 `Spaces/SpaceTransitionGestureMonitor.swift`
   （listen-only tap、mask 只含 bit 30、3 s 重试、`.tapDisabledByTimeout` 自愈、零权限）；
   `SecondaryDockWindow` 加 `hideForSpaceTransition()`（α 直设 0）、`fadeAlpha`（6 步 ×
   20 ms 分步直设，animator alpha 全弃用）、`intendedFrame`（拉回复位不再拿沉没位废值）、
   暴露 `isOnActiveSpace` / `currentAlpha` 供安全网；`SecondaryDockController` 手势状态机
   （预隐藏 + 600 ms 超时分步渐回 + 连击续命 + 翻转取消超时 + hover 抑制 + `hide()` 清态拉回
   α）+ **安全网**挂 200 ms `geometryTick`（条件模式无关：非预隐藏 &&（不在当前空间 ‖
   alpha < 0.99），独立贴边半露 frame 本来就在屏外、不能按「frame 出屏」判故障；静默窗
   250 ms、未愈退避翻倍）；`AppDelegate` 接线 monitor（退出时 stop）。
3. **测试**：+11 用例（预隐藏+收回 / 超时渐回 / 连击续命 / 翻转取消超时 / 未显示不触发 /
   hover 抑制 / 安全网愈卡半透明 / 愈孤儿 / 健康跳过 / 预隐藏豁免 / 退避），**406 全绿、
   release 零警告、已重打包**；后台 spike 进程已杀（避免与真机 App 双条同屏）。
4. **文档**：spikes.md 实验 27 结案、facts.md 四条（listen-only tap 免授权边界 / type 30
   指纹 / animator alpha 静默失效 / NSEvent swipe 判死）、spike 头注释改号、rules.md 新坑
   五条、PLAN §3.12、AGENTS 全节。

**影响 / 未解决**：
- **A11 手测清单更新（当前最紧）**：① 三/四指横扫切桌面——条**第一拍即隐**、切换后从原生
  Dock 底部 0.12 s 升起；② 打断横扫（没切成）——600 ms 后分步渐回；③ 三指上滑 MC / 四指捏合
  Launchpad——条可隐藏，关掉后 ≤1 s 必须回来（安全网兜底）；④ 两指横扫网页——条**不应**
  消失（type 30 误报面核对）；⑤ ⌃→ 键盘切换——对照，条不应提前消失。
- 若发现 30 新误报场景，判据看 `multidock.log` 的「切桌面前置手势 → 预隐藏」与「超时无切换」
  频率；`gestureRevealTimeout`（600 ms）与渐回步进都是 `Dependencies` 可注入参数，可按体感调。

### 2026-10-06（第 42 次）— 设置窗口重构（v4 内容模型）：默认 Dock 自动生成 + Dock 栏实体

**用户说**：「重构设置窗口，默认Dock栏是显示/Applications以及用户Applications最新添加的应用（修改时间）10个应用，这个数值范围1-15个用户可以自行调整。大小、放大、自动隐藏、特效、最小化到应用都跟随系统设置（这些选项都不能设置，都跟系统一样）桌面：Dock栏列表，默认可以有5个（每个Dock栏都可以设置位置，避开台前调度占用的那边，其他两边都可以用，button group，其他设置都跟随系统，用户不能设置｜Dock栏都是在此设置页面都是横向显示｜设置中的Dock栏默认显示8个图标的位置，如果用户设置可更多可以以滚动显示更多｜最多设置15个，最少设置1个），dock栏名称右侧可以选择桌面下拉列表（缩略图），可以选择位置下拉列表。」

**做了什么**：

1. **数据源探查（→ spikes.md 实验 26 / facts.md 两条）**：台前调度开关 = `com.apple.WindowManager` 的 `GloballyEnabled`（本机 = 1，零权限可读，其窗口条固定占左缘 → 位置选项避开左）；桌面缩略图 = WallpaperKit `Index.plist` 的壁纸（本机 `Spaces` 空 → 回落 `AllSpacesAndDisplays` 的 `Iridescence.heic`，`NSImage` 直接可载；真·窗口缩略图做不到——其他空间不渲染，实验 24 同源）。
2. **模型层（v4）**：`DockConfig` 去外观化（`DockAppearance` 删除，指纹内容口径）；新 `DockBar`（name/position/spaceID/apps/otherItems，1–15 图标）+ `DockBarPosition`（底/左/右 + 台前调度避让）+ `DockBarCatalog`（旧 override 迁移成栏 + 补足 5 根）+ `RecentAppsScanner`（/Applications + ~/Applications 按 mtime 取前 N）+ `StageManagerStatus`。`AppSettings`：+`dockBars` / `defaultDockAppCount`（默认 10），−`defaultDock`（运行时生成，只存个数）；`DesktopBinding.override` 废弃（迁移后清空）。
3. **流水线**：`DockController.apply` 只写内容键（`entries` 变 `nonisolated` 纯函数）；三明治显出参数改读域里实时 `autohide`；**还原路径新增 `extraEntries`**——基准里的外观键照写（无痕闭环，旧版本遗留收尾）；恢复历史备份只覆盖内容键。`AppState`：默认 Dock 运行时重建（归一化补启动台在首）、bar CRUD/绑定唯一性（一桌面一栏，后来者顶掉先到者）/孤儿栏只解绑不删、冻结对齐前重扫、回存落点=活动桌面绑定栏（冻结/未绑栏→如实记日志不回存）、`secondaryDockContent` 只出绑定栏内容 + 图标尺寸读系统实时 tilesize（28–48 钳制）。
4. **次级条运行时**：快照带 `position`；**附着模式**（栏位置 == Dock 方位）行为不变；**独立贴边**（≠）= 贴自己那条屏幕边、半露 = 滑出屏幕一半（`standalonePlacement`）、与 Dock 自动隐藏显隐无关；face == nil 时用 `lastFaceOrientation` 兜底防附着条被误判成独立贴边（修了一个真 bug）；`DockFaceProviding` +`currentScreenFrame()`。
5. **UI**：通用 Tab = 计数 Stepper（1–15）+ 只读最近应用预览 + 说明（外观跟随系统），删图标条编辑器/外观编辑器/「本机不支持」区；桌面 Tab 全新（`DesktopListView` 重写 + `DockBarEditor` 新建）：栏列表行 = 名称(≤10) + 桌面下拉（缩略图常显在控件外 + 纯文本菜单行）+ 位置分段按钮 + 删除，编辑器横向 8 槽可见滚动、1–15、拖拽排序/拖 .app/右键或垃圾桶移除；桌面命名保留在底部小节。删 `DockStripEditor` / `DockAppearanceEditor` 两个文件。
6. **测试**：369 → **384 个全绿**（+15）。重写 AppStateDockTests / SecondaryDockTests 冻结组 / BindingHistoryTests（孤儿栏 + 栏撤销）/ DockControllerTests（内容键 + extraEntries 还原）/ DockAcceptanceTests（P3 换内容差异、P4 弄脏换内容、回存外部改动改 `defaults import` 写内容键、未绑栏场景改「不回存」断言）/ 各小文件；新增 `DockBarModelTests`（位置可用性 / 解码兼容 / 迁移 / 独立贴边几何 / 扫描器排序与钳制）。UI 快照验收通过（缩略图、编辑器、暗色全部正常；顺手修了 menu Picker 自定义行渲染成色块的坑——缩略图移到控件外）。
7. **打包**：`./scripts/build-app.sh` 已重跑（release 零警告）。文档同步：PLAN §3.7 顶部重构记录 + §3.12 位置附录、facts 两条、rules 新坑 7 条、spikes 实验 26、AGENTS 全节。

**影响 / 未解决**：
- **手测新增**：位置切换（底↔右）真机观感、台前调度开着时左被禁、独立贴边条的半露/hover 手感（并入 A11）。
- **开放问题（等用户反馈）**：① 最近应用是否要排除系统自带 App（macOS 更新会顺带把 Safari 等顶进前 N）；② 是否需要周期性重扫（现在只在启动/改数量/手动应用前重扫，装新 App 要等下一次）；③ 下拉菜单行是纯文本（缩略图只在关闭态常显）——SwiftUI menu Picker 的限制，若要行内缩略图得换成自绘菜单。
- 旧版逐桌面 override 的「其他项」迁移保留在栏数据里，新编辑器不显示（随原生 Dock 写入仍在）。

**后续修订（同日第 2 轮）**：用户对三个开放问题拍板——① 最近应用**不排除**系统自带 App（维持现状）；
② **要重扫，但只有打开设置窗口时才扫**：`AppState.prepareSettingsPresentation()`（重扫默认 Dock + 即刷环境），
`AppDelegate.showSettings` 每次打开都调（窗口复用也算）；重扫**不自动应用**（写 Dock 仍由立即应用 / 数量改动 / 启动对齐触发）；
③ 下拉**纯文本即可**，但**台前调度开/关、原生 Dock 位置变化要实时反映**——`AppState` 新增 `EnvironmentReading`
2 s 环境轮询（CFPreferences 一次读 + NSScreen 一次扫，stop 时取消；首读静默、变更记日志），缓存为
`@Observable` 的 `stageManagerActive` / `dockSide`，位置选项与「原生 Dock 当前在 X（附着提示）」随之自动重渲染；
测试注入参数从 `stageManagerActiveProvider` 换成 `environmentReader`。**387 测试全绿**（+3：设置重扫不写 Dock /
台前调度变化更新位置选项 / 原生 Dock 方位跟踪）。文档：AGENTS 6.1 销账 #4–#6、PLAN §3.7/§3.12、rules 新坑 #8。

**后续修订（同日第 3 轮）**：用户追加三项设置窗口需求——① **侧边栏选项卡**（`NavigationSplitView` 四页：
通用/桌面/数据/关于，删 NSToolbar 装配，报警横幅移到内容列顶）；② **「关于」页**（图标/名称/版本
`Support/Info.plist`/GitHub 仓库 `reiy-leo/side-dock` 链接/更新检查——GitHub `releases/latest`，
语义化版本比较纯函数 + 发布读取器可注入，未配置不碰网络、无发布版/限流/断网都有明确文案，
每启动自动查一次）；③ **「数据」页**（导出配置 = `ConfigStore.encode` 同构 JSON；导入 = 与加载同一套
`normalizePayload`，整份替换落盘、次级条即时生效、**不自动应用原生 Dock**、冻结开关方向变化按同一入口对齐；
「备份与还原」自通用页迁入）。硬约束 4 改写为「四个侧边栏选项卡」。**395 测试全绿**（+8：导入导出往返 /
旧格式导入迁移 / 非法文件拒绝 / 更新检查四态 / 版本比较与发布解析）；UI 快照四页人工核对通过。
注意：App 尚无 icns，关于页图标显示通用图标——补图标资源后自动跟上；**发版时改 `Support/Info.plist` 的版本号**。

### 2026-10-05（第 41 次）— 实验 25：「随幅度渐进沉入」（v3.7）证伪；采纳残余：拉回出场改「沉没位 + 0.12 s 升起」

**用户说**：「可以做到整个secondary dock检测到左右滑动桌面时，根据滑动幅度的大小，幅度最大（1/4桌面宽度）时全部隐藏到原生dock后方」「把上面的实现方式总结成prompt，让我审核」「好的，按这个方案来」；spike 第一轮：「手势滑动紫条随桌面滑动没动画、切换完成后看不到、⌃→ 也只有第一个桌面有」；第二轮（先被误读后纠正）：「左右滑动过程中并没有看到淡出的效果，但滑动结束后，看到淡入从底部上来的效果了」；随后给出新规格：「桌面滑动时 secondary dock 不随桌面滑动，幅度超过 0.15 倍桌面宽度时自动隐藏，滑动结束后 0.15 秒内从原生 dock 栏底部淡出」并要求检查现行实现。

**做了什么**：

1. **v3.7 prompt 获准 → 实验 25 spike A**（`scripts/spike-sink-during-transition.swift`：复刻生产配方——层级 19、单空间配方、半露几何；16 ms SkyLight 轮询 + NSWorkspace 通知先到先触发；编排 = 下沉 0.25 s → 拉回(alpha=1, 沉没位) → 升起 0.25 s）。
2. **两轮真机手测**：第一轮零触发——spike bug：**`DispatchSourceTimer(queue: .main)` 在 `RunLoop.main.run()` 下一次都不 fire**（新坑入 rules.md/facts.md；改 `Timer.scheduledTimer` 修复），顺带实证无人编排时窗口留在旧空间随桌面滑走。第二轮编排全通（轮询先到 13–25 ms、每轮拉回成功）——用户澄清后的事实：**滑动过程中无下沉效果**（条随过渡渐隐，≈0.25 倍屏宽时归零），**滑动结束后「从底部升上来」真实可感知**。
3. **结案结论**：① 过渡合成期间窗口呈现由 WindowServer 接管，AppKit frame 动画不参与——「渐进沉入」无视觉效果；② `CGSGetActiveSpace` 翻转只比通知早 13–25 ms 且都在过渡结束后——零权限无「过渡进行中」事件窗口，Layer 2（幅度预判）同判不可行；用户规格第 ① ② 项（严格不滑、0.15 倍主动隐藏）是物理边界，渐隐时机由系统决定（≈0.25 倍屏宽）。
4. **采纳残余落生产**（用户规格第 ③ 项）：`SecondaryDockWindow.pullToActiveSpace()` 从「0.18 s 原地 alpha 淡入」改为「记录原位 → 置透明 + frame 跳沉没位（`visibleFrame` 底边以下，跳变无视觉）→ 拉回 → 16 ms 复位配方 → **0.12 s easeInEaseOut 升回原位 + 同步淡显**」——alpha 与 frame 同一动画组（Dock 在左/右侧沉没位不被遮挡时退化为无方向淡入，不破相）；切换后总感知 ≈ 0.14 s ≤ 0.15 s。闸门与 Controller 不动。**369 测试全绿、release 零警告、已重打包**。
5. 文档同步：spikes.md 实验 25（结案 + 复现脚本）、facts.md 两条新事实（frame 动画不参与过渡合成；空间 ID 翻转时机 + DispatchSourceTimer 坑）、rules.md（要点 #12 新编排 + Timer 坑）、PLAN.md §3.12 两处、AGENTS.md（决策演变/§3 行为/模块地图/A11）。

**影响 / 未解决**：A11 手测更新为核对「消失再升起」新出场手感（渐隐时机系统定死，可核对的只有升起的节奏与幅度）；`pullRiseDuration`（0.12 s）与 `sinkMargin`（6 pt）待真机体感微调。

**后续修订（同日）**：用户发截图反馈次级条背景比 5 枚图标宽出一大截——根因是 v3.6.2 固定槽位（`sizingSlots` = 所有桌面生效配置的最大条目数）。**拍板：废弃固定槽位，条宽随该桌面内容撑开**——其「防切桌面宽度跳变」的理由在方案 ② 下不成立（切桌面必经「沉没位再升起」，宽度变化静默发生在沉没位）。改动：删 `SecondaryDockContentSnapshot.sizingSlots` 字段、`AppState.secondaryDockMaxSlots()`、Controller 的 `?? sizingSlots` 分支；测试改写两条（条宽随内容数、冻结内容口径——冻结模式仍取默认 Dock 图标尺寸）。369 全绿、已重打包。文档同步：AGENTS.md（决策演变/§3/模块地图）、PLAN.md 六处、rules.md 要点 #11。

### 2026-10-05（第 40 次）— Dockset 竞品分析 + 解除「零权限」硬约束

**用户说**：「`https://dockset.app/` 这个软件的功能是怎么实现的」「所以 dockset 的切换方式是通过快捷键来么」「我们的产品中也添加 dockset 的辅助功能权限，是不是左右滑动窗口就不会随桌面滑动或者延时出现了？」「去掉硬约束 5」

**做了什么**（纯分析 + 文档修订，代码零改动）：

1. **竞品分析（dockset.app，$14.99 买断，macOS 13+）**：
   - 两模式 = ①保存/切换原生 Dock 布局（读 `com.apple.dock` persistent-apps/others → 写回 → 重启，与我们 `DockController` 流水线同构；spacer = 十年前 defaults hack，**唯一可安全「造」的原生条目**）；②自绘 Custom Dock（NSPanel + `canJoinAllSpaces` + 毛玻璃 + `visibleFrame` 启发式让位——与次级条同配方；widgets 全自绘，明确不支持 WidgetKit/桌面小组件）。
   - 五种切换入口：全局快捷键（Carbon，零权限）/ 菜单栏 / **双指滑动** / **⌘+滚轮**（后两者需辅助功能——全局事件监听）/ macOS Focus 联动。**产品刻意回避 per-Space 维度**（没有「按桌面自动换 Dock」），绕开了我们最难的墙；这正是与我们的差异化分界。
2. **澄清关键误区**：辅助功能权限解决不了「条随桌面滑 / 延时出现」——实验 24 结论「钉住特权来自进程身份」仍然成立；权限只是输入层能力（AXUIElement / 全局事件监听），不参与 WindowServer 空间过渡合成。Dockset 的自绘条切桌面时同样只能「滑」或「消失再出现」，它选了接受滑动（内容不随桌面变，滑得不扎眼）。
3. **解除硬约束 5「零权限」**（用户明确指令）：AGENTS.md §2 删该条，原 6 号「桌面命名」重编为 5 号，原地留墓碑说明；决策演变追加「约束修订」；PLAN.md §2「权限需求」改为「现行无，逐案评估」、§3.10 的「硬约束 §2.5」引用改为「现行实现」标注。**现行代码不动、仍零权限**——无具体功能承载前不引入任何权限请求。

**影响**：未来可逐案评估权限型增强（Dockset 式全局快捷键/手势切换、AXUIElement 类功能）；评估任何权限方案时记住——**权限不解决窗口钉住**（实验 24），方案 ② 仍是自由窗口最优折中。

### 2026-10-05（第 39 次）— 用户拍板方案 ②：次级条切 `.moveToActiveSpace`，切换后拉回 + 0.18 s 淡入（v3.6.3）

**用户说**：「选 ②，接着打磨拉回时机和出现的柔和度」（对第 38 次会话留下的「滑动 vs 消失再出现」拍板）

**做了什么**：

1. **次级条空间归属改方案 ②**（`UI/SecondaryDockWindow.swift`）：常态配方
   `[.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]`——单空间归属，
   手势切换瞬间条留在旧空间（新空间不可见，**不滑**）；呈现协议新增 `pullToActiveSpace()`。
2. **拉回与柔和度**（同文件）：`pullToActiveSpace()` = 置透明 → 临时 `.canJoinAllSpaces` +
   `orderFrontRegardless`（当前空间重新注册，实验 24 路 5 配方的直系后代）→ 16 ms 后设回
   单空间（连切时复位任务自取消）→ 0.18 s easeInEaseOut 淡入（与 hover 滑动同款节奏）。
3. **拉回时机闸门**（`UI/SecondaryDockController.swift` `spaceDidChange`）：仅「换了空间 &&
   切换前后都在显示」才拉——同一空间重复事件、进全屏、出全屏、从隐藏恢复都不拉；手势
   （NSWorkspace 快速通道）与程序化切换（菜单栏点击，`SpaceSwitcher.switchTo →
   observer.refreshNow()` 当拍回调）两条路都汇入这里，没有 300 ms 空窗。
4. **测试 +5**（`Tests/MultiDockTests/SecondaryDockTests.swift`）：切空间拉一次 / 连切各拉一次 /
   重复事件不拉 / 进全屏隐藏不拉 / 出全屏恢复不拉；替身补 `pullCount`。**369 全绿**、构建零警告、
   `./scripts/build-app.sh` 已重新打包。
5. **文档**：AGENTS.md（决策演变 v3.6.3 / §3 现行行为 / §6.1 #4 销账进 §6.2 / A11 更新 / 待办
   顺序）、PLAN.md §3.12（交互规格 + 机制表 + 验收）、rules.md 要点 #12（现行配方与闸门）、
   spikes.md 实验 24「决定」段更新为已产品化。

**当前进度**：方案 ② 代码与文档全部落地，等用户真机手测（A11 第 ⑤ 项）：① 手势切换——条应
「消失再淡入」不滑；② 菜单栏点击切换——应无感知空窗；③ 连击不闪；④ 全屏进出正常。若淡入节奏
不顺手：调 `SecondaryDockWindow.pullFadeDuration`（0.18 s）或 16 ms 复位延迟。其余待办不变
（A1–A3/A5 / B5 / B9/B10 / B8 / A8 只等复现）。

### 2026-10-04（第 38 次）— 实验 23 修法被真人手测推翻 → 实验 24 全路证伪：「不滑动」零权限无解，`.moveToActiveSpace` 是唯一折中

**用户说**：「现在的secondary dock还是会随桌面滑动，更改为滑动桌面时secondary dock不滑动，保持sticky在原生dock原位置」（对第 37 次修法的真机反馈，之后多轮试错、逐色观察）

**做了什么**（11 个 spike，全零权限、有色测试窗、真人触控板滑动观察；结论 = 实验 24）：

1. **推翻实验 23**：纯 `.stationary` 的次级条真机手势实测**照样滑动**。实验 23 的判据缺陷定案：程序化硬切 + `CGWindowList` 在屏核对只能证明「切换完成后在屏」，证明不了「动画期间不参与滑动」。
2. **逐路证伪（`scripts/spike-window-level-sticky` / `spike-window-workspace` / `spike-dock-tags`）**：`CGSSetWindowLevel` 20/24/25（Dock/菜单栏/状态栏级）全滑；**`CGSSetWindowWorkspace` 与 `SLSSetWindowWorkspace` 在 15.8.1 不存在**（13 个候选符号探查）；读原生 Dock 的 `CGSSetWindowTags` 复制进测试窗（含 NeverFlatten 位组合）照滑——**特权来自进程身份，不是窗口属性**。
3. **空间归属路（`spike-managed-space` / `spike-multi-window`）**：纯 `.managed` 窗口留在源空间随旧桌面滑走；每桌面独立窗口 = 旧窗滑走 + 新窗滑入，把一个滑动变成两个。
4. **拉回路（`spike-move-to-active` / `spike-pull-after-anim` / `spike-pull-fast` / `spike-pull-nsworkspace`）**：`.moveToActiveSpace` + 通知/轮询后「临时 canJoinAllSpaces → orderFront → 设回」**不滑**——切换瞬间窗口消失、到位后重新出现，是零权限下唯一不滑的方案；变体（30 ms 快轮询、纯 NSWorkspace 通知 + 10 ms 设回、动画结束后拉）只是拉回时机与延迟不同。
5. **隐藏路（`spike-hide-show` / `spike-hide-during-anim`）**：切换时 `alphaValue=0` / `orderOut`、结束后恢复——**闪现后消失**肉眼可见，是 moveToActiveSpace 的劣化版，弃。
6. **文档固化（本条对应的提交）**：实验 24 + 实验 23 推翻标注写入 `docs/spikes.md`（共 24 个实验）；两条新事实入 `docs/facts.md`（硬限制 + 判据教训）；AGENTS.md / rules.md 同步；11 个 spike 脚本入库。**代码未动**——次级条维持实验 23 的纯 `.stationary`（用户未拍板前不改行为）。

**当前进度**：**卡在用户拍板**——零权限下只有两个选项：① 维持现状（手势切换时次级条随桌面滑）；② 改 `.moveToActiveSpace`（切换瞬间条消失、到位后重新出现，不滑）。②若采用还需打磨拉回时机（NSWorkspace 通知 vs 轮询）与出现的柔和度。其余待办不变（A11 其余项 / A1–A3/A5 / B5/B8/B9/B10 / A8 只等复现）。

### 2026-10-04（第 37 次）— 次级条随桌面滑动：去掉 `.canJoinAllSpaces` 改纯 `.stationary`（实验 23）

**用户说**：「现在的secondary dock还是会随桌面滑动，更改为滑动桌面时secondary dock不滑动，保持sticky在原生dock原位置」

**做了什么**：

1. **定位根因（实验 23，`scripts/spike-stationary-spaces.swift`）**：次级条窗口配方是 `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`，原以为 `.stationary` 能钉住（第 35 次会话也这么写了）。spike 实测两组：A=`.canJoinAllSpaces + .stationary`、B=仅 `.stationary`，用 SkyLight 硬切桌面、`CGWindowList(.optionOnScreenOnly)` 判在屏。结论：**B 组去掉 `.canJoinAllSpaces` 后仍在所有空间在屏**（CGWindowList 权威，`isOnActiveSpace` 对纯 stationary 窗语义不稳但不影响显示）。**`.canJoinAllSpaces` 才是滑动元凶**——它把窗口注册成每个空间的成员，过渡动画自然带上它；`.stationary` 只管 Mission Control，不覆盖空间过渡参与。
2. **修法**：`Sources/MultiDock/UI/SecondaryDockWindow.swift` 一行——collectionBehavior 去掉 `.canJoinAllSpaces`，只留 `[.stationary, .fullScreenAuxiliary, .ignoresCycle]`，与原生 Dock 同款语义（浮在所有空间之上、切换时不动）。注释说明与 toast 分道扬镳的原因。
3. **验证**：`swift build` 零警告、**364 测试全绿**、`./scripts/build-app.sh` 打包完成。手势滑动的过渡动画无法脚本复现（实验 7），等用户真机确认条是否真的钉住。

**当前进度**：等用户手测——轨道板滑动切桌面时次级条是否钉在原生 Dock 原位置不滑。其余待办不变。

### 2026-10-04（第 36 次）— 交接：全量会话史归档 + 文档收敛到当前形态

**用户说**：「交接项目，把当前项目的所有session总结后写入文档，更新旧的文档，删除旧的需求和实现，更新到最新。」

**做了什么**（纯文档，零代码改动）：

1. **通读全部 35 次会话史与五份文档**（AGENTS 315 / PLAN 765 / rules 381 / facts 79 / spikes 1778 / sessions 1184 行），把"已废"与"仍生效"分开。
2. **AGENTS.md 重写为交接入口**：去掉已完成阶段的过程史（详史在 sessions.md），收敛为「当前形态一句话 + 现行行为实证 + 模块地图（覆盖全部源码）+ 未完成（只剩手测/等条件）+ 未决问题（6.1 三条、6.3 压缩；A6/A7/A9/A10/B6/B7/B11–B15 已结案行删除，指向 rules.md D 台账）+ 下一步顺序」。陷阱速查 12 → 14 条（新增实验 22 显隐信号、冻结语义三处合力）。
3. **PLAN.md / README.md / rules.md 更新到最新**：冻结默认、次级条 sticky 固定几何与同步显隐写进设计；删掉已作废的需求与历史段落（PLAN §0 旧前提、§4 历史阶段表、§6 待确认、§7 版本差异；README 的"没有零闪烁方案""反复杀 Dock 不影响正常使用"等过时句）。测试数全线修正 **327/263 → 364**。
4. **facts.md 补实验 20–22 三条事实行**（Dock 条不是独立 CG 窗口 / typed setter 只翻旗标不改 work area / 同步显隐可行组合 + 冻结语义三处合力）。
5. **spikes.md 摘要补 17–22 索引**（"共 16 个实验" → 22）。

**当前进度**：文档与代码/真机状态一致。功能全落地，**364 测试全绿**，冻结模式真机运行中。**下一步是用户的 A11 手测**（次级条手感四件套 + sticky + 同步显隐）与 A1–A3/A5 回归。

### 2026-10-04（第 35 次）— 次级条 sticky 固定几何 + 与原生 Dock 同步显隐（实验 22）

**用户说**：「左右滑动桌面时，secondary dock 不跟着滑动，而是 sticky 到原生 dock 固定位置，位置不同；切换桌面后，如果原生 dock 隐藏了，则 secondary 也 hide，show 则同步 show。」

**做了什么**：

1. **实验 22（`scripts/spike-secondary-dock-sync.swift`）——推倒了两个认知**：① `CoreDockSetAutoHideEnabled(true)` **只翻旗标不改 work area**（inset 全程 47、Dock 没滑走；实验 20 的「实时生效」是旗标级的，sandwich 的隐藏来自重启后 Dock 读旗标；`Set(false)` 显出方向倒是实时生效）；② 贴 Dock 腹地的探针窗口 `occlusionState` 基线就抖动，**不可用**；CGWindowList 依旧完全看不见 Dock 窗口。结论：Dock 实际显隐**没有零权限直读信号**，可用信号只有 `visibleFrame` 内缩（跟随实际占位）+ 光标碰边（Dock 自己的触发机制，无 API）。
2. **显隐同步（需求 2）**：`SecondaryDockController` 的 face==nil 分支从「保持现有位置只换内容」改为与原生 Dock 同步——光标在**显出带**（最近一次 Dock 占用条带 `SecondaryDockLayout.dockArea` 外扩 8pt）里 = Dock 在屏或即将显出 → 条同步显示；离开 → 400 ms 宽限后收回（`revealGrace`，防掠过边缘闪烁）。几何轮询 1 s → **200 ms**。附带修好了一个旧毛病：sandwich 重启瞬态里条不再单独浮着，跟着 Dock 一起藏（真机对齐日志已见「探测不到」瞬态）。
3. **sticky 固定几何（需求 1）**：冻结模式下 `SecondaryDockContentSnapshot.sizingSlots` = 所有活着的桌面生效配置的最大条目数（与内容构建同口径：Finder 幻影 +1、缺启动台补一枚）、iconSize 取默认 Dock 的 tilesize——**切桌面只换图标、窗口一毫米不挪**；这也顺带消掉了「滑动途中内容换帧导致窗口跳位」（spaceDidChange 通知在手势中途就到，实验 18）。未冻结的 opt-out 老模式维持按本桌面撑开的原规格。程序化切桌面是 0–6 ms 硬切无动画，手势滑动本身无法脚本复现，条窗口的空间滑留待用户手测确认（canJoinAllSpaces + stationary 本就该钉住）。
4. **测试**：+6 条（dockArea 三方位、带内保持/带外宽限收回/回归再显、sizingSlots 固定 frame、冻结固定几何 + 图标尺寸）→ **364 全绿**。真机重启 App 验证：对齐瞬态「探测不到」时条同步隐藏，切桌面 `已冻结：跳过` 零重启。

**当前进度**：等用户手测——① 手势滑动时条是否钉在原地；② 开自动隐藏后碰屏幕底边：Dock 与条同步显出、离开同步收回；③ 固定尺寸的观感（条以最大桌面条目数撑开，小桌面的条目居中留白）。剩余待办不变（B5/A1–A5/B8/B9/B10/A8 只等复现）。

### 2026-10-04（第 34 次）— 冻结成为默认：原生 Dock 全桌面一致、切桌面零重启

**用户说**：「原生的 dock 每个桌面都是一样的，相同的，不要每个桌面重启 dock；secondary dock 每个桌面不一样，但不要随桌面滚动，而是直接在原生 dock 显示」。

**做了什么**：

1. **需求确认**：两句话 = 把「冻结原生 Dock 逐桌面切换」转正为产品默认行为（原生 Dock 固定一套、切桌面不写不重启），逐桌面差异全部由次级条呈现。「不随桌面滚动」核对过代码：次级条窗口本就是 `canJoinAllSpaces + stationary + 切桌面无动画`，与原生 Dock 一样钉在原地，只有内容秒换——无需改动。
2. **发现语义缺口并补上**：冻结模式下没有任何路径保证原生 Dock 停在「默认 Dock」这套配置上（退出还原后下次启动会停在基准上，与次级条各显一套）。补了三处：① `reestablishFrozenDockIfNeeded` 启动对齐（**排在自愈之后**，`await waitForSelfHeal()` 串行；内容一致时指纹短路不重启）；② `setFreezeNativeDockSwitching(true)` 立即对齐默认 Dock；③ `(false)` 立即应用当前桌面生效配置。设置页冻结开关改走这个统一入口（次级条开关关掉时连带解冻也走它）。
3. **默认值翻转**：`AppSettings.freezeNativeDockSwitching` 默认 `false → true`（属性 + `decodeIfPresent` 兜底两处）；用户 config.json 里的持久化 `false` 同步翻成 `true`（App 未运行时改，无 clobber）。
4. **测试**：+3 条（开冻结对齐默认 Dock / 解冻应用当前桌面配置 / 启动对齐排在自愈之后——用脏标记断言最终 tilesize 落在 52 而非基准 36）→ **358 全绿**。⚠️ 新坑（已记 rules #9）：harness 里 `updateSettings` 会立刻落盘，污染「不落盘」断言与预置 config 的用例——改法是各用例在 `start()` 后按需 `unfreeze(_:)`，别摊回 makeState。受默认值影响的 harness 全部显式处理（AppStateDock 3+3 处、DockAcceptance 2 处、StartupSelfHeal/BindingHistory/DockFailureWarning/UISnapshot/SecondaryDockFreeze 各 1 处）。
5. **真机验收**：重打包并启动。日志实证：启动对齐一次（`Dock 不可用 374 ms，隐藏中重启（无闪烁），写入 9 个键`），随后真实桌面切换（→ 密码 邮件）日志 `原生 Dock 已冻结：跳过「切到 …」，由次级 Dock 条呈现`——零写入零重启；次级条照常出图（bottom 内缩 53）。启动对齐后 watcher 报了一次「手动改动」回存到默认 Dock，核对 config.json：defaultDock 内容逐项无漂移（Dock 重启规范化后的收敛回写）。

**当前进度**：冻结模式真机运行中（3 条绑定全为独立 Dock，差异全在次级条）。**等用户手测**：次级条 hover/点击/半露观感（A11 四件套不变）+ 现在重点体验「切桌面 Dock 完全不动」。代价说明：无痕原则下每次退出还原基准、下次启动对齐回默认 Dock（一次重启，~0.4 s，内容一致时自动短路）。剩余待办不变（B5/A1–A5/B8/B9/B10/A8 只等复现）。

### 2026-10-04（第 33 次）— 次级 Dock 条：随桌面秒换内容 + 冻结开关（实验 21）

**用户说**：三连问——「切换桌面后为什么非要重启 Dock」「可以完全替换原生 Dock 么」「能不能紧贴原生 Dock 加一条 secondary dock 栏，默认显示一半、hover 显示全、不用放大效果，按照这个实现」。

**做了什么**：

1. **答了两个可行性问题**：热重载不存在是实验 1/17 的实测结论（Dock 按发送方放行 MIG）；完全替换做不到（launchd KeepAlive + SIP + Dock 进程承载 cmd-tab/Mission Control/废纸篓/最小化窗口）；「并存的自绘条」可行且本代码库零件基本齐。
2. **产品决策（AskUserQuestion，用户选定）**：「随桌面 + 冻结开关」——条显示当前桌面 `effectiveConfig` 的图标，切桌面换视图零重启；设置加「冻结原生 Dock 逐桌面切换」（默认关，开启后 SIGHUP 切换路径整体退役）。
3. **实验 21（几何探针）**：⚠️ 推翻了原计划——15.8.1 上 Dock 条**不是**独立 CG 窗口（Dock 进程只有全屏 layer-20 容器窗口）。几何源改用 `NSScreen.visibleFrame` 排他内缩（本机 bottom、内缩 53）。另核实 config.json 已全量 bottom（A9 的「默认 right」过时）。
4. **实现**：新 5 件——`SecondaryDockLayout`（纯几何：三方位/半露=向 Dock 平移半条厚靠层级 19<20 被 Dock 遮挡/clamp）、`DockFaceProviding`（visibleFrame 内缩探测）、`SecondaryDockStripView`（条目模型 + 纯函数内容构建器 + SwiftUI 条）、`SecondaryDockWindow`（Toast 配方可交互变体，层级 19）、`SecondaryDockController`（状态机 + 1s 几何轮询 + hover 150ms 防抖 + 鼠标安全网）。改 4 处——`AppSettings` +2 字段（decodeIfPresent 同步补）、AppState（第三个 space 消费者 + `applyForDesktopSwitch` 冻结闸门 + 冻结时手动改动改道默认 Dock）、AppDelegate（装配 + `withObservationTracking` 内容观察 + 屏幕变化即时重探）、SettingsView（「次级 Dock 条」区块两个开关）。
5. **测试与验收**：+27 条 → **355 全绿**（几何三方位/半露/clamp、内容构建、状态机、冻结闸门、解码回归）；快照 `secondary-dock-{light,dark}.png` 人工核对通过；`build-app.sh` 重打包并启动，window-dump 实测 `layer=19 x=600 y=1115 w=720 h=56`（换算即半露位逐像素吻合），日志 `次级 Dock 条：Dock 几何变化 → bottom 内缩 (0.0, 53.0, 1920.0, 1147.0)`，切桌面 SIGHUP 58 ms 正常。

**当前进度**：共存模式已在真机运行（冻结默认关，原生照旧切换）。**等用户手测**：① hover 滑出/收回手感；② 点击图标启动；③ 半露观感（亮/暗）；④ 满意后开「冻结原生 Dock 的逐桌面切换」再体感切桌面（应完全无重启）。文档同步：PLAN §3.12、rules 次级条节、spikes 实验 21、AGENTS.md 约束修订。剩余待办不变（B5/A1–A5/B8/B9/B10/A8 只等复现）。

### 2026-10-04（第 32 次）— 用户原始诉求落地：自动隐藏三明治，切换无闪烁

**用户说**：「切换桌面不用重启 dock（会先黑屏再出现 dock 栏），而是平滑地感觉不到，我记得 github 上有 repo 实现了，无感切换」。

**做了什么**：

1. **搜索（中英文两轮）**：没有现成仓库做到"免重启换 Dock 内容"——社区方案全是 `killall Dock`，共识的缓解手段恰是"开自动隐藏"（[Hammerspoon](https://www.hammerspoon.org/docs/hs.spaces.html)、[AeroSpace #3850](https://github.com/Hammerspoon/hammerspoon/issues/3850) 只做 Space 切换本身）。用户记忆中的 repo 未找到；但我们的**实验 20** 用自己的通道实现了等价效果。
2. **GO/NO-GO 实验 20**：`CoreDockSetAutoHideEnabled`（typed setter，id=3，与实测可用的 `SetTileSize` 同族）对第三方**实时生效 + Dock 自己持久化 + PID 不变**；隐藏状态下 SIGHUP，新 Dock 以隐藏态回来——**重启不可见**。⚠️ 15.8.1 的 CGWindowList 看不到 Dock 容器窗口（owner=Dock 零条目），观测量改用 Get/域值。
3. **实现**：`DockAutoHide.swift`（协议 + `dlsym(RTLD_DEFAULT)` 实现，无默认实现的协议要求）；`DockReloader.reload(strategy:sandwichRevealAutoHideTo:)` 包住 `reloadCore`——Set(true) 滑走 → 等 300 ms 动画 → SIGHUP 隐形重启 → 等归位 → Set(reveal) 滑回；**任何返回路径都恢复可见性**（失败重试一次，仍失败记 `revealFailed`，reveal 值来自配置而非当时的域 → 下次 apply 自愈）。`DockController.apply` 只在非退出路径、配置要求可见（autohide=false）时传参；配置要求隐藏时重启天然不可见，不启用。
4. **测试**：+5 条（时序契约 hide→signal→reveal、失败路径仍 reveal、nil 不碰、配置要求隐藏不碰、hide 失败优雅降级）——**333 全绿**；release 构建零警告；`build/MultiDock.app` 已重打包。

**当前进度**：真机行为等用户**退出并重启 App**（改动在 02:19 启动的实例之外——必须重新 `build-app` + 重开）后切桌面验证：日志应出现 `隐藏中重启（无闪烁）`，体感为两次平滑滑动、无黑屏。剩余待办不变（B8/B5/A1–A5/B9/B10/A8）。

### 2026-10-04（第 31 次）— 真机验收发现系统更新 15.8.1：GUID 判据失效并版本化

**用户说**：「继续完成任务」。

**做了什么**：

1. 只读盘点：`multidock.log` 停在 **09-19** —— 当前构建（实验 15/16 取证仪表、nudge 修法、UI 原生化）**从未在真实 App 运行中使用过**；B8 脚本未跑过。MultiDock 未运行。
2. 跑真机 Dock 验收（无 watcher 干扰，先手工备份域）：首跑 **8/9** —— `testApplyThenRestoreLeavesDockUntouched` 的「Dock 给无 GUID 条目回填 GUID」断言失败（复跑仍失败）；诊断显示 apply 链路完全正常（SIGHUP 重启 60 ms、10 键写入、条目进 Dock、还原仅差 mod-count）。**用户 Dock 验收前后逐键一致，无损伤。**
3. 根因：**系统已更新 15.7.9 (24G830) → 15.8.1 (24H32)**（Dock 二进制 09-23 重建）。新系统 Dock 重启时 mod-count 照常 +1（重启 + 重读发生）但 persistent-apps 零改写 —— **不再回填 GUID**。产品功能不受影响（verify / 指纹短路 / DockWatcher / 无痕基线都不依赖 GUID）。
4. 验收用例 `testApplyThenRestoreLeavesDockUntouched` 加系统版本条件（15.7.x 保留 GUID 判据；15.8+ 降级为「条目跨 Dock 重启仍在」）；重跑 **9/9 绿、40 s**——15.8.1 上首次全绿验收。
5. 归档：`docs/spikes.md` 实验 19；`docs/facts.md` 开发机行更新 + 「Dock 是否应用了写入」与实验 8 行加注（实验 8 的 SIGABRT 结论不依赖该判据，「其他项只搬不造」维持）；AGENTS.md 当前状态补「环境变更」与「用户日志停在 09-19」两条。

**当前进度**：15.8.1 上首次全绿验收（验收 9/9 + 单测 328）。剩余待办不变：B8（脚本已备，等用户跑）、B5 外接屏、A1–A3/A5 手测、A4 拖文件夹、B9/B10、A8 等复现——**取证仪表终于有机会在真实使用中产出数据**（用户日志自 09-19 起空白）。

### 2026-10-04（第 30 次）— 继续未完成任务：B7/B8 观测工具落地，B7 后台开测

**用户说**：「继续未完成的任务」。

**做了什么**：agent 侧可推进的只剩 B7 / B8 —— 两者都需要"真人动作"，但观测工具可以先备好，B7 甚至能直接后台开测：

1. **B7 工具 `scripts/spike-space-notify-watch.swift`**：同时观察 `NSWorkspaceActiveSpaceDidChangeNotification`（公开通知）与 SkyLight 活动空间 50 ms 高频轮询（只读）；每次轮询发现切换回看 ±0.5 s 有没有通知伴随。**已在后台运行 240 s 窗口**，等用户手势切桌面出结果。判定：手势切换全部伴随 NOTIFY → SpaceObserver 可加通知为强信号（跟随延迟 ≈ 0）；均无 → B7 关闭。零权限（公开通知 + 只读），不写偏好不发信号。
2. **B8 工具 `scripts/check-finder-removal.sh`**（只读）：快照域 → 用户取消勾选 Finder「在 Dock 中保留」→ diff 报告落键情况 → 提醒拖回。判读：差异只在 mod-count/recent-apps/trash-full/GUID → 无新键，B8 关闭；出其他键 → 记 `docs/facts.md` 并评估白名单。
3. AGENTS.md §6.3 B7/B8 行更新为脚本用法；PLAN.md 检查过无过时 UI 描述（"两个 Tab"与工具栏实现不冲突）。

**当前进度**：B7 观测进行中（结果回填到 `docs/spikes.md` 后关闭）；B8 等用户跑脚本。**其余未完成项全部需要用户动手**（B5 外接屏、A1–A3/A5 手测、A4 拖文件夹、B9/B10 注销重登录、A8 等复现），见 AGENTS.md §7。

**结果回填（同日）**：B7 观测完成——用户手势切换 5 次，**5/5 触发 `activeSpaceDidChange`**，通知比 50 ms 轮询早 2–30 ms；读码确认 `SpaceObserver` 的通知到达即 `refresh()` 早已接线，**手势切换跟随延迟本来就是 ≈0，零代码改动**。B7 ✅ 关闭；正式记录在 `docs/spikes.md` 实验 18，`docs/facts.md` 的「桌面切换通知」行已精确化，AGENTS.md B7 行已结案。

### 2026-10-04（第 29 次）— B15 结案（实验 17.6/17.7）+ 文档按通用 Agent 结构重组

**用户说**：「检查还有哪些任务么完成」→「按顺序继续」。

**做了什么**：

1. **B15 结案（实验 17.6/17.7，提交 b984637）**：反汇编 Finder 的 `cmdAddToDock:` 实锤它调 `CoreDockAddFileToDock(NSURL, 0)`——与我们探针逐参数相同却能用 ⇒ **Dock 按发送方放行 Apple 二进制**。判别电池：`CopyPreferences` 报错 -4956（明确拒绝）；CFString 载荷 / flags=1 无声忽略；`CoreDockRegisterClientWithRunLoop` 反汇编证明是**接收端**注册（`_DCXDockClientDefs_subsystem` MIG server），"先注册再发"排除。系统设置实时滑杆不走 CoreDock（主二进制与 Settings / PreferencePanesSupport 框架都不导入），大概率是 SkyLight 协调通知中心（`_SLSCoordinatedLocalNotificationCenter`，未展开——SIGHUP 只有 100 ms，收益低）。**结论：条目键无第三方通道，不伪造发送方身份；外观键 `SetTileSize` 对第三方可用但语义未定；主路径维持 SIGHUP。** 探针补了 `addstr` / `copyprefs` / `notify1` 三个模式。
2. **文档重组（本提交）**：AGENTS.md 从 1860 行拆成五件套——入口（保留 §0–§8 编号作路标）+ `docs/facts.md`（原 §4 verbatim）+ `docs/rules.md`（原 §5 + 各阶段「实现要点」+ §6.3 D 台账，verbatim）+ `docs/sessions.md`（原 §8 verbatim）。所有搬迁零改写；旧引用"§4 / §5 / §8 / §6.3 Dx"经路标仍可解析。

**当前进度**：P0–P5 不变。B15 ✅ 结案。剩余待办见入口 §6 / §7（B5 多显示器、A1–A3/A5 手测、B9/B10、B7/B8、A8 等复现）。

### 2026-10-04（第 28 次）— UI 对齐 Apple 原生设计（工具栏标签页 / 菜单副标题 / 桌面页 Form 化）

**用户说**：「读取apple原生应用的design，让符合此设计」。

**做了什么**（纯视觉与文案，不改任何行为与接线）：

1. **逐文件盘点 6 个 UI 文件**。已有的原生底子保留不动：Form + `.formStyle(.grouped)`、语义色、SF Symbols、NSMenu、toast 原生 HUD（P2.5 规格钉死，未碰）。
2. **设置窗口**：SwiftUI `TabView`（macOS 上渲染成浏览器式标签——没有任何 Apple 设置窗口长那样）→ **System Preferences 式工具栏标签页**：`NSToolbar` + delegate 的 `toolbarSelectableItemIdentifiers` + `window.toolbarStyle = .preference`，图标+文字居中、选中高亮。页状态放 `SettingsTabModel`（`@Observable`），AppKit 写、SwiftUI 读。窗口装配抽成 `SettingsWindowFactory`，AppDelegate 与快照测试**共用** —— 快照若复制一份装配，验出来的就不是真窗口。⚠️ 两个可用性坑：`NSToolbar(identifier:selectableItemsIdentifiers:)` 在部署目标 macOS 14.0 上不可用（报 "extra argument"），用经典 delegate 方法 + `selectedItemIdentifier`；`NSMenuItem.subtitle` 是 **14.4+**。
3. **菜单栏**：禁用假菜单项「（⇧+左键…同效）」→ `previous.subtitle`；「⚠︎ 桌面功能不可用」的文字字形 → SF Symbol `exclamationmark.triangle` + 副标题。
4. **桌面 Tab 右侧详情**：自绘 `VStack` + `Divider` → 与通用页同一套 `Form` + `.formStyle(.grouped)`（此桌面 / Dock 来源 / 图标条 / 外观 / 应用 五个 Section）；绑定与 `dockEdited` 接线一字未动。
5. **文案更正**：设置页「P0 实测结论：Dock 没有热重载」→ 实验 17 后的准确表述（私有实时通道存在、外观键已验证，条目未打通前不启用）。
6. **视觉验收（零权限）**：新增 `UISnapshotTests`（`MULTIDOCK_UI_SNAPSHOT=1` 开启，默认跳过，与真实 Dock 验收同一套门控约定）：离屏渲染真窗口出亮/暗 × 两页 PNG 人工核对。三个坑进 §4：抓 `contentView.superview` 才含窗口 chrome；`@Observable` 失效要等 RunLoop 拍子（否则拍到旧页）；`NSTemporaryDirectory()` 不是 `/tmp`。

**验收**：`swift build -c release --disable-sandbox` 零警告；`swift test` **328 全绿**（+1 快照测试，默认跳过）；`./scripts/build-app.sh` 打包成功；四张快照（亮/暗 × 通用/桌面）人工核对 —— 工具栏标签选中高亮、分组表单、暗色全语义色适配。

**当前进度**：P0–P5 不变，无行为改动。**未解决**：§6.3 B15 等，均不变。⚠️ **上一轮的「文档按通用 Agent 结构精简重组」任务被本任务打断、未执行**（AGENTS.md 仍是单文件全量结构），用户需要时再继续。

### 2026-10-03（第 27 次）— 实验 17：CoreDock 通道探路 —— 「热重载不存在」被部分推翻（**零业务代码改动**）

**用户问**：「读取项目状态，确定如何在不重启 dock 的情况下替换 dock 图标们」。

**做了什么**（全部是静态分析 + 带安全栏的真机实验，没碰业务代码）：

1. **复核实验 1**：当年只测了 notifyd 路径（`notifyutil` / `NSDistributedNotificationCenter`，object 均为 nil）。
2. **静态分析**（零写入）：`launchctl print` 发现 Dock 挂着 **`com.apple.dock.server`** 等 14 个端点；`nm -u` 发现 **Finder 导入 `_CoreDockAddFileToDock` / `_CoreDockSendNotification`**；`dyld_info` 顺着 ApplicationServices 找到实体在 **HIServices**（直接可链，不用 dlopen），`dyld_info -exports` 拿到约 60 个 `CoreDock*` 函数。`DockKit` 是 MagSafe 配件框架，红鲱鱼。
3. **lldb 反汇编 HIServices 桩函数恢复签名**（Dock 二进制被裁符号，HIServices 的桩在）：`SendNotification(CFStringRef, Int32)`、`AddFileToDock(CFTypeRef, Int32)`、`SetPreferences(CFDictionary)`、`CopyPreferences(CFTypeRef, CFTypeRef*)`、`SetTileSize(Int32)`（**float 位型**）等；`getDockPort` 无权限闸门。
4. **带安全栏的真机实验**（备份 + PID 看门狗 + 强制还原，三轮共重启 Dock 5 次全部健康）：`SendNotification` / `SetPreferences(整域)` / `AddFileToDock(CFURL)` **全被静默拒绝**（status=0 无行为）；**`SetTileSize` 一次误发实测"不重启就改域并持久化"**（36.0→16.0，被钳到最小值）—— 外观键热重载实锤，但随后 36.0 位型 / 64 / 36 都无效，**数值语义未定**。
5. **事故与恢复（诚实记录）**：把 `SetTileSize(999999)` 当"无副作用自检"误发了出去，用户 Dock 图标当场变小；已用 `defaults write tilesize 36` + SIGHUP 恢复。终态与实验前全量 diff 为空。
6. **新坑**：沙箱里 `CFPreferencesCopyMultiple(nil,…)` 只回 1 个键，读域必须逐键 `CFPreferencesCopyAppValue`；第一轮实验因观察手段坏了白跑。
7. 留档：`scripts/spike-coredock-probe.swift`（探针，模式分只读/写入两档）、`docs/spikes.md` 实验 17（17.1 发现链 / 17.2 签名 / 17.3 结果矩阵 / 17.4 事故 / 17.5 下一步）、PLAN.md §3.5 加方案 D 并修正两处"不存在热重载"表述、§4 热重载行改写。

**当前进度**：P0–P5 状态不变（无业务代码改动）。**新增未解决项 §6.3 B15**（条目热替换通道 + SetTileSize 数值语义；下一步全只读：反汇编 Dock 端 msg 0x7D0/0xBB8 处理器 / 注册客户端后重试 / 试 CFString 载荷）。

### 2026-09-22（第 26 次）— 基线复核 + 把 `docs/PLAN.md` 与实验 16 对齐（**零代码改动**）

**用户说**：「读取项目当前状态，还有哪些功能没有实现，哪些问题没有解决」+「继续任务」。
没有新需求，所以这轮做的是**体检 + 补文档欠账**。

**① 基线复核（本轮实跑）**：
- `swift build -c release --disable-sandbox` → `Build complete!`，零警告。
- `swift test --disable-sandbox` → **327 个测试、9 跳过、0 失败**。
- 用户日志 `multidock.log` 跑前跑后 **3164 → 3164 行不变**（实验 10 第 7 条那条守卫仍成立）。
- 工作区干净、HEAD = `822041c`；**App 没在跑** → 无新的 A8 偶发可复盘。
- **打包产物是新的**：`build/MultiDock.app` 的二进制（07:06:51）字节级搜索能找到
  `催 kickstart`(1) / `慢重启取证`(1) / `最长间隔`(1) / `轮询`(3)，且 `Sources/` 里没有比它更新的文件
  → 实验 15 / 15.4 / 16 的代码**确实装在里面**，下次启动就是带催办的版本。

**② 补上的文档欠账（`docs/PLAN.md` §3.5 / §3.9）**：第 25 次把实验 16 同步进了 `AGENTS.md` 与 `spikes.md`，
**唯独漏了 `PLAN.md`**（§0 要求设计变化两边都改）。本轮补三处：
1. 新增 **2026-09-20 两处观测**（15.3 / 15.4）：`waitPolls` / `waitLongestGapMS` 的判据
   （**先看"最长间隔"**，M 秒级 = 观察窗口断了，不是 launchd 的事），以及"`dockPID()` 的 LS 优先别改"。
2. 新增 **2026-09-20 A8 修法落地**整块（`nudgeAfter` 500 ms / `nudgeInterval` 1 s / `timeout` 30 s → **3 s** /
   `kickstartTimeout` 30 s / PID 守卫 / 取证三段拼接），并**显式标注它修正了同节 2026-09-19 那条
   "超时提到 30 s"** —— 否则同一节里两条相反的超时会误导下一个人。
3. 修两处过时的 `kickstart -k`：§3.5 方案 C 的 P0 记录加注"实现已去掉 `-k`"；§3.9 那条
   "等满了才 `kickstart -k` 兜底" 改成"不带 `-k`"（**代码里从来不带**，实验 9 起明确禁止）。

**当前进度**：P0–P5 全落地；真机验收 9/9 绿；A8 的**代价**已压到 ~1–3.5 s。
**未解决**（全部只等人，agent 侧无活可干）：A8 **成因**（等真机偶发，读法见 §6.3 A8 与实验 16.8）；
B5 多显示器热插拔真机实测（需用户插外接屏）；A1–A3 / A5 真人手测；A4 建议补一次真人拖文件夹；B9 / B10（注销与重登录）。

### 2026-09-20（第 25 次）— **A8 的修法落地：不等，催**（`docs/spikes.md` 实验 16）

**用户说**：「解决 A8 剩余的问题」。前六条"我们的 bug"候选全被证伪、只剩 launchd 一侧，
于是这轮**不再找新假说**，而是回到真机日志里那条一直没被当回事的线索，并顺手把一条"证伪"重新验了一遍。

**① 先纠正一条站不住的证伪。** 实验 13 把「连续快速重启触发退避」判成 ❌，依据是
**"6 次连发（间隔 2 s）全部正常"** —— 可是 `ThrottleInterval` 本来就是 **1 s**，
**间隔 2 s 的重启根本不构成违规**。这条假说从来没在真条件下测过。

**② 补测（新脚本 `scripts/measure-launchd-backoff.swift`）**：把 Dock 存活时间压到 1 s 以内、
轮间**不等待**连打 10 轮：

```
延迟序列（ms）：[30, 1012, 1016, 1019, 1017, 1019, 1016, 1013, 1016, 1021]
```

→ 第 2 轮起恒定 **~1016 ms，不涨**。**假说 ③ 到这一刻才算真证伪**，而且确认那 ~1 s 是**硬顶**、
不是斜坡 —— 所以 26–31 s **不可能**是节流累积出来的。

**③ 关键线索：真机日志里那半截。** `05:33:16` 那次的 `31039 ms` 里，**30000 ms 是 SIGHUP 等满的超时**、
500 ms 是 SIGTERM 宽限，**剩下的约 540 ms 才是 `kickstart` 发出去后归位的时间**。
也就是说：**SIGHUP 等 30 秒等不到的东西，`kickstart` 0.5 秒就拿到了。** 前面几轮一直在争论
"launchd 为什么慢"，却没人问"我们手里是不是本来就有条能立刻拿到它的通道，只是被排在了 30 秒之后"。

**④ 安全性前提实测**（不靠推理）：`launchctl kickstart`（**不带 `-k`**）对**运行中**的 Dock
是无害 no-op —— PID `80643 → 80643` 未变、退出码 0。所以"催早了"不构成风险。

**⑤ 机制推断（附可检验预测）**：`KeepAlive = {AfterInitialDemand: 1, SuccessfulExit: 0}` ——
`man launchd.plist`：`SuccessfulExit` 为假时，**只在程序被信号杀死（异常退出）时**重新拉起。
所以 Dock 若**干净退出**（exit 0），launchd **不会**重新调度它，直到有东西**显式要求**
（`kickstart` 正是那个要求）—— 这就是"偶发"的来源。
**预测**：复现时 `launchctl print gui/501/com.apple.Dock.agent` 应显示 `last terminating signal`
**缺失**（正常路径下是 `Hangup: 1`）。**未直接观测到**，系统日志在沙箱里读不到（`log show` 一律
`Cannot run while sandboxed`，脱离沙箱也一样）。
顺手排除：Dock **不是**崩溃循环（`DiagnosticReports` 里没有 Dock 的崩溃报告）。

**⑥ 代码改动**（`DockReloader`）：`nudgeAfter` 500 ms / `nudgeInterval` 1 s（尽力而为，
受 `LaunchctlParking` 闸门限制）、`timeout` **30 s → 3 s**、新增 `kickstartTimeout` 30 s、
**PID 守卫**（兜底不再对"刚归位的新 Dock"补 SIGTERM —— 那会把它再杀一次，超时缩短后这个窗口
更容易撞上）、失败路径的取证改成三段拼接（原来把最有用的主路径那段丢了，**是我自己的新单测抓出来的**）。

**⑦ 验证**：全量 **327 个测试、9 跳过、0 失败**（320 → 327，+7）；真机验收 **9/9 绿、43.1 s**
（新增 `testPrematureNudgeIsHarmlessAgainstTheRealDock`：`nudgeAfter: 0` 强制对着活着的 Dock 催一发，
重载照常成功且 **800 ms 后仍是同一只 Dock** —— 没引起第二次弹跳）；Dock 域与备份逐字节一致。

**⑧ 已同步**：`docs/spikes.md` 新增 **实验 16**（含 16.1–16.8）与摘要第 6 条；`AGENTS.md` §3 顶部状态、
§3 表格（测试数 327、新增脚本行、实验数 16）、**§4 新增四条环境事实**、§7 第 3/4 条、§6.3 A8 重写；
`MEMORY.md`、`2026-09-20.md`；技能 `macos-dock-space-probe`。

**当前进度**：P0–P5 全落地；真机验收 **9/9 绿**；**A8 的代价已压到 ~1–3.5 s**，成因仍未直接观测。

**未解决**：A8 **成因**（等真机偶发，读法见 §6.3）；B5 多显示器热插拔真机实测（需用户插外接屏）；
A1–A3 / A5 真人手测；B9 / B10（注销与重登录）。
⚠️ **App 已重新打包但当前没在跑** —— 下次启动才是带催办的新版本。

### 2026-09-20（第 24 次）— **系统性排查协议见证位陷阱这一类 bug**：又抓到一条没守卫的要求

**用户说**：「请继续执行任务」。A8 没有新的真机偶发，于是把上一轮那个 bug 当**一类**而不是一次事故来处理：
**凡是"有默认实现的协议要求"，都有同一个静默失效面**，逐个查。

**① 全仓枚举。** `Sources/` 里一共 4 个协议：`ToastPresenting`、`SpaceProviding`、
`DockProcessControlling`、`DockPreferenceAccessing`。**只有 2 个带默认实现的扩展**：

| 协议 | 带默认实现的要求 | 真实实现签名 | 结论 |
|---|---|---|---|
| `DockProcessControlling` | `pidProbe() -> DockPIDProbe?` | 已修成 `?` | ✅ 已修 + 有守卫（#22） |
| `DockProcessControlling` | `startTime(of:) -> TimeInterval?` | `TimeInterval?`，**逐字一致** | ⚠️ **签名对，但没有守卫** → 本轮补上 |
| `DockPreferenceAccessing` | `readMRUSpaces() -> Bool?` | 转调**必需**的 `readDomain()` | ✅ 构造上安全，不需要守卫 |

**② 为什么"签名对"也要补守卫。** `startTime(of:)` 一旦被写成非可选，节流窗口的判据会
**静默从"进程年龄"退回"我们记不记得自己重启过"** —— 这个退化是**有实测代价的**：
P3 验收里同一个场景 **45 ms → 1030 ms**（用户看到 Dock 消失一秒多）。而它**没有任何测试能发现**，
因为 5 个替身（`FakeDockProcess` ×2、`RevivableDock`、`FlakyDock`、`LyingProcess`）都靠这个默认实现活着。
→ 新增 `testRealStartTimeIsWiredAsTheProtocolWitness()`，**经 `any DockProcessControlling` 调用**。

**③ 为什么保留默认实现而不是删掉。** 那 5 个替身里有 3 个只关心别的行为，不想被迫实现全部要求。
删默认实现会逼它们补空实现 —— 那只是把陷阱从"默认值"挪到"替身自己写错"，守卫测试才是对的修法。

**④ 把规矩写进扩展本身。** `extension DockProcessControlling` 顶部加了一段 ⚠️⚠️ 警告，
说明陷阱机制、实测代价、以及"每加一条有默认实现的要求就必须补一条经 `any` 调用的守卫测试"这条规矩。
写在扩展里而不是只写文档，是因为**下一个加方法的人一定会先看到它**。

**⑤ 全量回归**：`swift test --disable-sandbox` → **320 个测试、8 跳过、0 失败**（319 → 320，+1）。

**⑥ 已同步**：`AGENTS.md` §5 代码约定（新增协议见证位规矩）、§3 / §5 / §7 测试数 319 → **320**、§8 本条；
`spikes.md` 15.2 补充 `startTime(of:)` 守卫与本次全仓审计结论；`MEMORY.md`、`2026-09-20.md`；
技能 `macos-dock-space-probe` 新增"这类陷阱怎么系统性排查"配方（3 条 `rg` + 判定表 + `viaProtocol` 守卫模板）。

**⑦ 顺手把 §4 那条 `grep` 的坑改准了（差点又误判一次）。** 重新打包后按老习惯用
`grep -a` 验"新代码有没有进包"，结果 `轮询` / `最长间隔` / `Dock 不可用` **全是 0** —— 差点判成"包是旧的"。
改用字节搜索（`python3 -c "open(p,'rb').read().count(...)"`）同一个二进制：
`最长间隔` **1**、`慢重启取证` **1**、`轮询` **3**、`Dock 不可用` **2**、`SIGHUP` **12**。
→ **`grep -a` 只要模式里含非 ASCII 字节就一律返回 0，哪怕字符串明明在**（纯 ASCII 的 `SIGHUP` 能出数）。
原来 §4 只写了"短 ASCII 字面量被小字符串优化"，**不完整**；已补上"含中文的模式一律 0"这半条。
**判据只能用字节级搜索。**

**当前进度**：P0–P5 全落地；真机验收 **8/8 绿**（本轮重跑，41.1 s）；A 组只剩 A8，**六条"我们的 bug"候选全部证伪**，
只剩 launchd / Dock 归位本身，等真机偶发。

**未解决**：A8 仍未定案；B5 多显示器热插拔真机实测（需用户插外接屏）；A1–A3 / A5 真人手测；B9 / B10（注销与重登录）。

### 2026-09-20（第 23 次）— 复核真机日志，**更正我自己的一处过度概括** + 给仪表补上"我们没在看"这个洞

**用户说**：「继续」。App 没在跑、`multidock.log` 无新增（仍 3164 行）→ 没有新的 A8 偶发。
于是回头**逐字复核** 11.6 / 15 里那句"主线程是活的、不是假测量" —— **发现它站不住。**

**① 那处过度概括。** 把真机日志里那 26 秒窗口原样排出来：

```
05:32:18.675  第一笔 apply 开始（= 44.735 − 26.060 s）
05:32:20.566  toast 显示 → 21.597 隐藏      ← 1.03 s，准时
…             共 4 组 toast 准时开合，最后一组 27.364 显示 → 28.388 隐藏
05:32:28.388  toast 隐藏
              ↓ 16.35 秒完全空白
05:32:44.735  Dock 应用成功：Dock 不可用 26046 ms
```

toast 证据只覆盖 **18.675 → 28.388（前 10 秒）**；**后 16.35 秒毫无存活性证据**。
而那段空白**两种解释都成立**：Dock 真的不在（没东西可记），或主线程被冻住（想记也记不了 ——
`DockPresenceMonitor` 在重载期间本来就被 `guard !isReloading()` 静音，连"我还在跑"都不会说）。

**② 洞是结构性的。** `DockReloader.waitForRestart` 的 `elapsed` 是**墙钟**，而轮询循环跑在
`@MainActor` 上：主线程被冻住时循环跑不动 → 我们**根本没在看**，却照样把整段时间记成
`Dock 不可用 26046 ms`。**"Dock 慢"与"我们瞎了"在旧日志里长得一模一样。**

**③ 修法：把存活性变成数字。** `waitForRestart` 每轮记轮询次数与最长间隔，跟着慢重启那一句出来：

```
… Dock 不可用 26046 ms；轮询 1738 次，最长间隔 18 ms；慢重启取证：…
```

判据：次数 ≈ `elapsed / 15 ms`、最长间隔十几毫秒 → **我们一直在看**，Dock 真的不在（launchd 侧）；
次数远低、最长间隔**秒级** → **观察窗口断了**，是我们的 bug。
只在 `elapsed > 1` 时记，**快路径日志行一个字节不变**；两个计数器是整数运算，零开销。

新增单测 3 条（`DockReloaderTests` 的「存活性」一节），关键那条让**替身在第 3 次 `dockPID()` 上阻塞 80 ms**，
断言最长间隔必须体现出来、并与未阻塞的对照。为让 `elapsed` 真的过 1 秒，`makeProbingReloader` 加了
`timeout` / `pollInterval` 两个参数（600 轮 × 2 ms）。

**④ 全量回归**：`swift test --disable-sandbox` → **319 个测试、8 跳过、0 失败**（316 → 319，+3）；
真机验收 → **8/8 绿、40.7 s**。

**⑤ 已同步**：`spikes.md` 摘要第 6 条 + **11.6 / 15 两处过度概括的更正** + 新增 **15.4**；
`AGENTS.md` §3 顶部与未完成、§3 测试数 316 → **319**、§4 新增一条环境事实（存活性判据）、
§5 构建片段、§6.3 A8（更正 + 补充）、§7 第 2 / 5 条、§8 本条；`MEMORY.md`、`2026-09-20.md`、技能同步。

**当前进度**：P0–P5 全落地；A6 / A7 由真机日志销账，A9 / A10 结案；真机验收 **8/8 绿**；
**A 组只剩 A8** —— 探测分叉（15.3）与观察窗口断裂（15.4）两条"我们的 bug"路径都已封死，只剩 launchd / Dock 归位本身。

**未解决**：A8 仍未定案（等真机偶发，读日志时**先看 `最长间隔 M ms`**）；
B5 多显示器热插拔真机实测（需用户插外接屏）；A1–A3 / A5 真人手测；B9 / B10（注销与重登录）。
⚠️ **App 已重新打包但当前没在跑** —— 下次启动才是带新仪表的版本。

### 2026-09-20（第 22 次）— **挖出并修掉取证仪表的致命 bug**（协议见证位协变陷阱）+ **证伪第六个假说**（LS 滞后）

**用户说**：「继续任务。如果上下文快满了，就新建一个 session 继续任务」。

上一轮把 A8 的取证仪表装好了、6 条替身单测全绿、App 也重新打包了 —— 这轮按计划给它写真机验收测试，
**结果第一次跑就炸了**。这条记录的重点是"仪表是坏的"和"最后一个假说也被证伪"。

**① 仪表在生产路径上完全是死的（最值钱的发现）。** 新写的
`DockAcceptanceTests/testSlowProbeTimelineWorksAgainstTheRealDock` 第一条断言就失败：

```
XCTUnwrap failed: expected non-nil value of type "DockPIDProbe" - pidProbe() 返回 nil —— 取证仪表是坏的
```

根因：协议要求 `func pidProbe() -> DockPIDProbe?`，扩展里有默认实现 `{ nil }`，而具体类型
`RealDockProcessControl` 写的是**非可选**的 `-> DockPIDProbe`。Swift **不做返回类型协变匹配** ——
它把具体方法当成**另一个重载**，协议要求的**见证位由默认实现满足**。于是：

```swift
RealDockProcessControl().pidProbe()                                   // ✅ 有值
(RealDockProcessControl() as any DockProcessControlling).pidProbe()   // ❌ nil
```

而 `DockReloader` 持有的正是 `any DockProcessControlling` → `sample()` 里
`guard let probe = process.pidProbe() else { return }` 每次直接返回，时间线恒为空。
**6 条替身单测全绿，因为替身自己签的就是 `T?`** —— 替身单测证明不了生产路径接通。

修法：返回类型改成逐字 `DockPIDProbe?`（源码里带了最小复现注释）；新增
`DockProcessSafetyTests.testRealControlIsWiredAsTheProtocolWitness`，**故意走 `any` 协议**调用并断言非 nil。

**② 验收测试自己有竞态，也修了。** 阈值先写 `1 ms`，实测**一次空、三次有** —— 探测机会出现在
**第二轮**轮询里，而 `dockPID()` 的判定排在 `sample()` **之前**，只要 `Task.sleep(15 ms)` 被拖长、
Dock 恰好在第二轮之前回来，就会**先返回、一条不记**。改成 `.zero` 后连跑 4 次，每次都稳定 2 条：

```
[A8 取证] 真机重载：SIGHUP 成功：PID 72409 → 72516，Dock 不可用 37 ms；
          慢重启取证：0ms LS=72409 scan=nil｜36ms LS=nil scan=72516
```

**③ 这一行立刻产出新线索 → 定向测量 → 第六个假说被证伪。** 时间线显示发完 SIGHUP 后
`NSRunningApplication` 还在报**旧** Dock。新增脚本 `scripts/measure-launchservices-lag.swift`
（只读 + 发 SIGHUP，与产品代码同构的安全闸门），1 ms 采样同时问两条路径，跑 6 轮：

| 量 | 实测 |
| --- | --- |
| 进程表看到新 PID | 26–33 ms |
| **LS 松手（不再报旧 PID）** | **11–29 ms** |
| LS 看到新 PID | 70–93 ms |
| **危险窗口（进程表已知新、`dockPID()` 还报旧）** | **6/6 = 0 ms** |

机制上也不成立：LS **松手很早**、只是**认领新 PID 晚**（~50 ms），而 `dockPID()` 是
**LS 优先 + nil 回退扫进程表** —— 回退把那半段完全吃掉了。**A8 的"我们的 bug"候选至此清空。**

**④ 全量回归**：`swift test --disable-sandbox` → **316 个测试、8 跳过、0 失败**；
真机验收 `MULTIDOCK_DOCK_ACCEPTANCE=1 … --filter DockAcceptanceTests` → **8/8 绿、40.7 s**；
跑完 `defaults export com.apple.dock` 与备份**逐键一致**（只差 `mod-count`）。

**⑤ 顺手修掉 `build-app.sh` 的一个死结**：它裸调 `swift build`，在本机环境里直接
`sandbox_apply: Operation not permitted` → `Invalid manifest` 而失败。已给它两个调用都补上
`--disable-sandbox`。**重新打包已验证**：`build/MultiDock.app` 里能找到长中文字面量 `慢重启取证`
（1 次；`DockPIDProbe` 计数为 0 是 release 的间接引用优化，正常）。

**⑥ 已同步**：`spikes.md` 摘要第 6 条 + 新增 **15.2 / 15.3**；`AGENTS.md` §3 顶部与未完成、§3 脚本表
（新增 LS 滞后测量脚本）、§3 测试数 314 → **316**、§4 新增两条环境事实（协议见证位陷阱、LS 松手早认领晚）
+ 更正"节流不是隐式"（plist 里本来就写着 `ThrottleInterval = 1`）、§5 构建片段、§6.3 A8、§7 第 1–5 条、§8 本条；
`MEMORY.md`（并压回 3000 字符量级）、`2026-09-20.md`、技能 `macos-dock-space-probe`（新增见证位陷阱、
竞态、LS 松手早认领晚三节）。

**当前进度**：P0–P5 全落地；A6 / A7 由真机日志销账，A9 / A10 结案；
真机验收 **8/8 绿**；**A 组只剩 A8，且"我们的 bug"一侧已无候选**（仪表已真机验过、探测不分叉）。

**未解决**：**A8 仍未定案** —— 只剩 launchd / Dock 归位本身，等真机下一次偶发把过程写进 `multidock.log`；
B5 多显示器热插拔真机实测（需用户插外接屏）；A1–A3 / A5 真人手测；B9 / B10（注销与重登录）。

### 2026-09-20（第 21 次）— 跑真机 Dock 验收（7/7 绿）+ **第五次复现 A8 失败**（`spikes.md` 实验 15.1）

**用户说**：「继续任务。如果上下文快满了，就新建一个 session 继续任务」。
上一轮改了 `DockReloader`，按 §7 第 4 条**必须跑一次真机验收**，所以这轮就跑了 —— 顺手把它变成 A8 的
第五次复现尝试。

**① 先备份再跑**：`defaults export com.apple.dock /tmp/md-acceptance/dock-before-20260920-0512.plist`
（16 图标 / 1 其他项 / `tilesize 36` / `orientation bottom`）。

**② 给验收测试加了慢重启取证出口**（`DockAcceptanceTests`）：
`testSwitchingBetweenTwoDesktopConfigsIsStable` 现在会**单独收集并打印**每一轮 `elapsed ≥ 300 ms`
的重载连同 `ReloadOutcome.description`（也就是含 `慢重启取证：…` 的时间线），
并把完整重载详情写进那条 0.3 s 断言的失败消息里 —— **这是抓 A8 最省事的入口**，不用等用户偶然撞上。

**③ 验收结果：7 个用例全绿、38.6 s。** Dock 域跑完与备份**逐键一致**（只差 Dock 自己的 `mod-count`）。

**④ A8 没复现 —— 这是第五次。** 20 轮连切（两套 `tilesize` 40/60 配置来回切，每次一次真实 SIGHUP，
且因为 `minimumSpacing = 1 s`，**每轮重启时 Dock 的年龄都正好在 1 秒左右**，与真机那次 `39143` 只活了
**1.03 s** 的情形**同构**）：

```
Dock 不可用时长（ms）：[47, 49, 46, 47, 74, 56, 61, 52, 31, 59, 47, 61, 54, 32, 32, 53, 67, 65, 53, 52]　最坏 74 ms
慢重启（≥ 300 ms）共 0 次：无
```

→ **成因不在"连续重启"这个形状里**，只在真实 App 的完整上下文里（GUI + 三个轮询 + 用户真实切桌面）。
**不再加码尝试复现，等它自己出现。**（已写进 `spikes.md` 实验 15.1 与摘要第 6 条。）

**⑤ 顺带修正一条环境事实（§4）**：`testKillingDockRecoversWithinThreeSeconds` 这次实测
**56 ms** 归位（`69452 → 69457`），而不是文档里那个 **1072 ms**。差别是 **Dock 当时的年龄**：
1072 ms 那次 Dock 刚被重启过（吃隐式节流），这次它已经活了约 1 秒、节流窗口已过。
→ **`kill -9` 后的归位时间不是常数，断言只该按"3 秒内出现新的正数 PID"给。**
同时把 §4 那行里过时的监视器阈值（"连续 2 次、每 4 轮重试"）改成真实的 **8 轮 / 60 轮**。

**⑥ 全量回归**：`swift test --disable-sandbox` → **314 个测试通过、7 跳过、0 失败**。

**当前进度**：P0–P5 全落地；A6 / A7 由真机日志销账，A9 / A10 结案；真机验收 7/7 绿；
**A 组只剩 A8，且已装好取证仪表**。

**未解决**：A8 仍未定案（等真机偶发）；B5 多显示器（需用户插屏）；A1–A3 / A5 真人手测；
B9 注销/关机还原、B10 LaunchAgent 退回（需真注销一次）。

### 2026-09-20（第 20 次）— 给 A8「偶发慢重启」装取证仪表（`spikes.md` 实验 15）

**用户说**：「请继续执行任务」。这一轮**改了产品代码，但只加观测、不改行为**。

**① 先把真机日志那两行逐字重读，挖出两条新事实。**
`05:32:44.735` 那行 `Dock 不可用 26046 ms` 倒推出窗口是 **05:32:18.675 → 05:32:44.735**，
而 `05:32:18.668 切换到 LLM` —— **慢重启正好始于那次切换**；第二行 `05:33:16.817` 减 `32079 ms`
= **05:32:44.738**，与第一次结束只差 **3 ms** → 两次慢重启是**背靠背**的，
且第二次把 **30 秒的 SIGHUP 等待全烧光**才升级到 `kickstart`。

**② 想通"旧日志为什么定不了案"。** 那 26 秒窗口里**一行日志都没有** —— 不是监视器坏了，
而是 `DockPresenceMonitor.tick()` 第一行 `guard !isReloading() else { return }`，
重载期间**刻意静默**（实验 8.5：两条控制回路抢同一个服务会把 1 秒滚成两分钟）。
代价就是慢重启时没有旁观者。而 `waitForRestart` 只记结果（`elapsed`）、不记过程 →
**"探测分叉"和"Dock 真的没回来"两种病因都能套上去**，谁也证不了谁。

**③ 于是加取证。** `DockProcessControlling` 新增 `pidProbe() -> DockPIDProbe?`
（**带默认实现返回 `nil`**，测试替身不受影响），`DockPIDProbe` 同时带 `launchServices` 与 `procScan`
两条路径的答案。`waitForRestart` 的规则：等待 **> 1 秒**才开始采样（**正常路径一次都不调用**），
每 100 ms 采一次但**只在答案变化时记一条**（外加首尾强制各一条），条数封顶 24；
时间线挂在**已有的那一行** `Dock 应用成功` 日志里（`ReloadOutcome.description`），不新增日志行。

**④ 验收**：`swift build -c release --disable-sandbox` 零警告；
`swift test --disable-sandbox` → **314 个测试通过、7 跳过、0 失败**（308 → 314，+6：
快路径零开销 / 两条路径都记 / 只在变化时记 / 条数封顶 / 替身不支持取证时照常工作 / **超时未归位也带时间线**）；
`./scripts/build-app.sh` 已重打包，用**字节级搜索**确认 `build/MultiDock.app` 里有 `慢重启取证` 这个字面量。

**⑤ 顺带记下两个坑（已进 §4）**：
① `grep -a` 在 release 二进制上**找不到短的 ASCII 字符串字面量**（Swift 小字符串优化）——
本次差点据此误判"包是旧的"，判据要用字节级搜索或长中文字面量；
② 排查慢重启时**别把监视器那段日志空白当证据**。

**当前进度**：P0–P5 全落地；A6 / A7 由真机日志销账，A9 / A10 结案；**A 组只剩 A8**。

**未解决**：**A8 仍未定案** —— 仪表已装，等真机下一次偶发自己把过程写进 `multidock.log`，
照 `docs/spikes.md` 实验 15 的判定规则读。⚠️ **别为了复现去反复折腾用户的 Dock。**
其余：B5 多显示器（需用户插屏）、A1–A3 / A5 真人手测、B9 注销/关机还原、B10 LaunchAgent 退回。

### 2026-09-20（第 19 次）— A9 结案 + **更正我自己的第二个错误**：override 不是默认的副本

**用户说**：「是我配的，别动」—— 回答"默认 Dock 那 3 个图标（启动台 / FlClash / WorkBuddy AI，
`orientation = right`）是不是你有意配的"。**本轮零代码改动、零配置改动。**

**① A9 结案。** 用户的答复让第 16 次那条"配置损坏"的指控彻底失效：默认那 3 项是他手工配的，
`计划 任务` / `密码 邮件` 两条 override 的图标与它相同**不构成损坏证据**。
**`config.json` 一个字节都没动**（备份仍在 `config.json.bak-20260920-044624`）。

**② 我自己的第二个错误：我提议"把那两条 override 清成沿用默认"，理由是"切过去看到的 Dock 不变"。错。**
两条 override 的 `appearance.orientation = "bottom"`，而默认 Dock 是 `"right"`；
`AppState.effectiveConfig(for:)` 是

```swift
binding(for: space)?.override ?? settings.defaultDock
```

—— **整体替换，不是逐字段合并**。所以清掉 override 会让那两个桌面的 Dock **跑到屏幕右侧**，
是一次**可见的行为改变**，不是等价操作。**幸好动手前先读了一遍 `effectiveConfig`。**

> 教训（已写进 §5 那条约定）：**"内容看起来一样"不等于"等价"。**
> 判断两个配置能不能互相替换，要去读**比较函数 / 取用语义**，不能靠肉眼比图标列表。
> 这和第 18 次那个"字段名写错就伪造出一份数据损坏"是同一类病：**结论必须建立在读过代码/数据的事实上。**

**③ 已同步**：§3 顶部状态块（标注本节被更正过两次）、§3 未完成（A9 改为 ✅ 已结案）、
§6.3 A9（完整说明 orientation + 整体替换语义）、§7 第 5 条（A9 移出待办，只剩 A8）、§8 本条；
`docs/spikes.md` 11.4 同步更正。

**当前进度**：A6 / A7 由真机日志销账，A9 / A10 结案，**A 组只剩 A8**（Dock 重启偶发 26–31 s，根因未定，
四个假说已被实验 12–14 全部证伪）。P0–P5 功能全落地，308 个测试全绿、零警告。

**未解决**：A8（要复现必须带真实 App 的完整上下文）；B5 多显示器热插拔真机实测（需用户插外接屏）；
A1–A3 / A5 真人手测；B9 注销/关机还原、B10 LaunchAgent 退回（需真注销一次）。

### 2026-09-20（第 18 次）— 更正第 16 次的 A9（**我自己读错了配置**）+ 清掉 `session.state` 那笔假欠账

**用户说**：「请继续执行任务」。这一轮**没动产品代码**，做的是"把上一轮的错误结论改正 + 处理一条确定有害的状态"。

**① A9 的数字是错的，已更正。** 第 16 次我写"三个桌面 override 全部为空"。
那是**我自己的读取脚本用错了 JSON 键名** —— 写的是 `o.get('apps')` / `o.get('others')`，
而 `config.json` 里的真实键是 **`pinnedApps` / `otherItems`**，于是把有内容的 override 读成了空。
用正确的键重读后的真实状态：

| 目标 | `pinnedApps` | 内容 |
| --- | --- | --- |
| 默认 Dock | 3 | 启动台 / FlClash / WorkBuddy AI（`orientation = right`） |
| `密码 邮件` | 3 | **与默认逐项相同** |
| `计划 任务` | 3 | **与默认逐项相同** |
| `LLM` | 15 + 1 | 正常 |

**教训（写进 §4 与 `spikes.md` 11.4）**：核对配置文件前先把真实键名打出来（`print(list(d.keys()))`），
别凭记忆写字段名 —— 一个字段名写错就能把"3 项"读成"0 项"，并据此得出完全错误的结论。

顺带纠正一条**判断**：默认 Dock 那 3 个图标**不一定是坏的**。它的 `appearance.orientation = "right"`
（真实 Dock 是 `bottom`）是明显的手工选择 → 很可能是用户故意配的精简底座。
所以**不要擅自改它，要问**。两个 override 与默认逐项相同才是真正的坏数据指纹，
且与 2026-09-18 的记录吻合（说明从 09-18 起就没再恶化）。

**② 清掉了一笔假欠账。** `session.state` 里 `needsSelfHeal = true` 且 `appliedFingerprint != nil`
（`impliesDirtyDock` 两条都命中）→ 下次启动会"还原到基准（15 项）"，**抹掉用户后来自己加的 Qoder CN**。
但那笔债是假的：日志 `05:58:45.991 开始还原到原始 Dock：15 个图标` 之后 Dock 确实回到了基准态
（Qoder CN 是用户之后才加的），`needsSelfHeal` 只是 `prepareForTermination` 发现"有排队中的 apply 没落地"
留下的兜底标记 —— **还原本身成功了**。已备份（`session.state.bak-20260920-044624`）后移除该文件。
⚠️ 关键细节：`impliesDirtyDock = appliedFingerprint != nil || needsSelfHeal == true`，
**只清 `needsSelfHeal` 不够**。

`config.json` **未改动**（已备份 `config.json.bak-20260920-044624`）—— 内容层面的取舍要用户拍板。

**文档更新**：`docs/spikes.md` 实验 11.4 整节重写（含"初版错在哪"的说明）；
本文件 §3 顶部、§3 未完成、§6.3 A9 重写 + 新增 A10（已解决）、§7 第 5 条重写、§8 本条。

**未解决**：A9 待用户回答（默认 Dock 的 3 个图标是不是你要的？两个桌面要不要重配？）；
A8（根因未定，四个方向已排除）；B5（多显示器真机）、A1–A3 / A5（真人手测）、B9 / B10（注销与重登录）。

### 2026-09-20（第 17 次）— **推翻了上一轮自己写的根因**：三个控制实验把"Dock 重启被罚几十秒"的四个假说逐个证伪

**背景**：第 16 次从用户真机日志里发现两次 Dock 重启花了 26 046 / 31 039 ms，
而 uptime ≥ 30 s 的 4 次只要 50–126 ms。当时把它归因成"launchd 有 ~10 s 的 crash-uptime 门槛"，
并建议把 `DockReloader.minimumSpacing` 从 1 s 提到 10 s。**用户说"继续"之后，
先做控制实验再改代码 —— 结果那个归因是错的。**

**做了什么**（三个新 spike 脚本，全部只重启 Dock、不改语义）：

| 实验 | 脚本 | 假说 | 结果 |
| --- | --- | --- | --- |
| 12 | `scripts/spike-restart-spacing.swift` | launchd 有 ~10 s uptime 门槛 | ❌ **推翻**：uptime 6.0 / 12.0 / 20.0 s + 60 s / 81 486 s 对照，**全 37–68 ms** |
| 13 | `scripts/spike-pid-detection.swift` | `NSRunningApplication` 返回陈旧实例 → `waitForRestart` 看不见已归位的 Dock | ❌ **推翻**：A 路径 41–63 ms、B 路径 78–116 ms，同量级无分叉 |
| 13 | 同上 | 连续快速重启累积退避 | ❌ **推翻**：**6 次连发、间隔 2 s，全 41–116 ms** |
| 14 | `scripts/spike-preference-write.swift` | 「写偏好 + 重启」这个组合是诱因 | ❌ **推翻**：幂等写白名单 9 键（事后核对域零变化）再 SIGHUP，**5 轮 35–46 ms** |

**顺带核实的两件事**：
- `com.apple.Dock.plist` 里写的就是 `ThrottleInterval = 1`，
  `launchctl print gui/501/com.apple.Dock.agent` 显示 `minimum runtime = 1` —— 与"10 秒门槛"矛盾。
- 真机那两次慢重启期间**主线程是活的**（同一窗口里 toast 的 1 秒定时器准时触发：
  `05:32:27.364 显示` → `05:32:28.388 隐藏`）→ **不是主线程被冻住导致的假测量，Dock 当时真的不在**。

**结论与改动**：
1. ⚠️ **`minimumSpacing` 保持 1 s 不动** —— 第 16 次那条建议**作废**。提到 10 s 只会让配置生效白白晚 10 秒。
2. 26–31 s 定性为**偶发、根因未定**。正常路径稳定 35–126 ms，连续 6 次快速重启也不慢，
   实际影响远小于实验 9 那个 60–126 s。
3. **没动任何产品代码**（`Sources/` 与 `Tests/` 零改动），所以第 16 次的 **308 测试全绿 / 零警告** 结论继续成立。
4. 实验做完核对过 Dock 域：与实验前备份**逐键完全一致**（忽略 `mod-count` / `recent-apps` / `trash-full`），
   `persistent-apps` 仍是 16 项、`persistent-others` 1 项、`tilesize 36` / `orientation bottom` / `autohide false`。

**文档更新**：`docs/spikes.md` 摘要第 6 条改写、**实验 11.3 改写为"相关性不是因果"、新增 11.6（证伪表）与 11.7（脚本用法）**、
复现方法补三个脚本；本文件 §3 顶部状态块改写、§3 未完成的两条重写、§4 那条"uptime 门槛"行改写、
§6.3 A6 / A8 / A9 重写、§7 第 5 条重写。

**未解决**：**A9 优先**（`config.json` 已损坏，用户手动「从当前 Dock 抓取」前别启动 App 去切桌面）；
**A8**（根因未定，四个方向已排除，别重试）；B5（多显示器真机）、A1–A3 / A5（真人手测）、B9 / B10（注销与重登录）。

### 2026-09-20（第 16 次）— 项目状态检查：实验 9/10 的修复**已被真机覆盖**，但挖出 A8（连切桌面仍 26–31 s）与 A9（配置已写坏）

**用户说**：「检查项目状态」。没有要新功能，所以这一轮**不改产品代码**，只做体检 + 文档同步。

**代码侧基线（本轮实跑）**：`swift build -c release --disable-sandbox` **零警告**；
`swift test --disable-sandbox` **308 个测试通过、7 个跳过、0 失败**；
跑完 `multidock.log` 行数 **3164 → 3164 不变**（实验 10 第 7 条那条守卫仍然成立）。
工作区干净，HEAD = `8ab35f8`。

**真机数据（这一轮最值钱的部分）**：用户 2026-09-19 那次实跑留下了完整日志。
关键前提是**先确认二进制版本** —— `build/MultiDock.app` 时间戳 **05:02**，
**晚于**实验 9（`47defb5` 02:11）与实验 10（`8ab35f8` 03:21），所以**这次终于是修复后的代码在跑**。

1. ✅ **A7 销账**：`05:58:46.001 退出还原流程结束，用时 0.01s`（旧版 **53.12 s / 54.05 s**），整条退出约 2 s。
   尾巴：走了 `!settled` 分支留下 `needsSelfHeal = true, pid = 0` —— 预期兜底，但引出 A8 的副作用。
2. ⚠️ **A6 部分销账、转为 A8**：6 次真实 apply 里 **uptime ≥ 30 s 的 4 次全是 50–126 ms**（正常路径好了），
   但 **uptime 6.5 s → 26 046 ms**、**uptime 1 s → 31 039 ms**。相关性干净。
3. 🔍 **根因（新）**：launchd 的节流判据是**服务 uptime**，不是我们的重启间隔。门槛在 **6.5 s（触发）与 34 s（未触发）之间**，
   符合经典的 **10 s crash-uptime**。→ 实验 5 记的"间隔 ≥ 1 s 就没事"**只在"上次重启很久以前"成立**；
   `minimumSpacing = 1 s` 挡不住快速连切桌面。**修法：1 s → 10 s**（未实施，见 A8）。
4. ⚠️ **A9（新）**：`config.json` 已损坏 —— 默认 Dock `pinnedApps` 只剩 **3 项**，三个桌面 override **全空**；
   而**真实 Dock 是健康的**（16 + 1，基准 15 + 1）。**用户下次应用配置会把好 Dock 写坏。**
   并且发现了损坏的**固化机制**：残缺 override → apply 到真实 Dock → Watcher 把真实 Dock 的 3 个图标
   当成"用户手动改动"合法回存 → 钉死。**"看 Dock 在不在"的闸门挡不住这一条。**
5. ⚠️ **待爆副作用**：`session.state` 是 `needsSelfHeal = true, pid = 0` → **下次启动会还原到基准并抹掉 Qoder CN**。

**文档更新**：`docs/spikes.md` 新增**实验 11**（含 11.1–11.5 与建议修法）、摘要加了第 5–7 条；
本文件 §3 顶部加状态检查块、§3 未完成重写、§3 黑屏那节第 6 条改写、§4 两条节流行更新、
§6.3 A6/A7 改写并新增 A8/A9、§7 建议顺序第 5 条重写。

**未解决**：A8（等用户拍板 `minimumSpacing` 提到 10 s 的代价）、A9（只能用户手动「从当前 Dock 抓取」）、
B5（多显示器真机）、A1–A3 / A5（真人手测）、B9 / B10（注销与重登录）。

### 2026-09-19（第 15 次）— 修掉「每次右键退出都卡住几分钟」：退出复用了完整降级链 + **两条"有上限的等待"其实没有上限**

**做了什么**（用户：「每次菜单栏右键点击退出时都会卡住（没有dock、桌面背景也不显示、触控板也不能用）」）：

**先说诊断的起点**：这和实验 9 是**同一个故障**，只是触发点从"切桌面"换到"退出"。而且必须先纠正一条记录 ——
用户 2026-09-19 早先"复验过 A6"其实**没有发生**：他跑的 `build/MultiDock.app` 打包于 01:07，而实验 9 的修复
commit `47defb5` 是 02:11 —— **修复从未在真机上跑过**。所以本次是"同一条自激链在退出路径上原样复现"，不是新 bug。

**三条根因（都改了，按 §8 上一条的框架继续放大）**：

1. **退出还原复用了完整的重载降级链** —— 发信号 → 等归位 30 s → 升级 `SIGTERM` → 再 `kickstart` → 再等 30 s。
   launchd 正处在递增退避里，日志实测退出还原用时 **53–54 秒**（用户看到的"卡住几分钟"= 这几笔叠起来）。
   → 新增 `DockReloader.reloadForQuit(strategy:deadline:)`：**只发一发 SIGHUP、最多看它 1.5 秒、绝不升级、绝不 kickstart**。
   四种结果 `QuitRestart`（`revived` / `signaled` / `dockWasDown` / `notDelivered`）里**没有一种是失败**：
   偏好已经落盘，launchd 把 Dock 拉回来时直接读到它 —— 我们不需要"亲眼看到"它归位。
   `DockController.apply(..., forQuit: true)` 配套：**写一次、验一次、不重试**（`SIGTERM` 那条有约 255 ms 清理窗口、
   Dock 可能回写覆盖，而退出流程没有重试机会去发现它 —— 所以退出路径**只用 SIGHUP**）。
2. **`kickstart` 带了 `-k`** —— `man launchctl`：服务已在跑时**先杀掉正在跑的实例**。而这条兜底恰恰只在
   "launchd 可能正要自己把 Dock 拉回来"时走到，等于把刚拉活的 Dock 再杀一次 + 加深退避。已去掉 `-k`。
3. **`DockPresenceMonitor` 在我们自己重启 Dock 期间冲进来"拉回"** —— 两条控制回路抢同一个服务。
   → 新增注入点 `isReloading`，为真时**这一轮不计数**（处置权在 `DockReloader`）。

**⚠️ 这次最有价值的发现是个通用的 Swift 坑（第 3 条根因的根因）**：

`prepareForTermination()` 里那两条"有上限"的等待（`DockController.waitForIdle(upTo:)`、
`AppState.settleSelfHeal(within:)`）都用 `withTaskGroup` 写成了"让一个 `await task.value` 和 `Task.sleep` 赛跑"。
**任务组在闭包返回时会等所有子任务收尾**，而 `await drainTask.value` 这种子任务对取消毫无反应 ——
于是**上限静默失效**，函数实际等到的是那笔应用整条链跑完。阴险在于**返回值看着是对的**：

| 写法 | 上限 | `group.next()` 报出的值 | **墙钟** |
| --- | --- | --- | --- |
| `withTaskGroup` 赛跑 | 20 ms | `false`（正确！20 ms 就报了） | `waitForIdle` **625 ms** / `settleSelfHeal` **224.7 ms** |
| 轮询完成标志（现在的写法） | 20 ms | — | 在 200 ms 断言内通过 |

改成**轮询可观察的完成标志**（`drainTask == nil` / 新增的 `selfHealFinished`）。
回归守卫因此**必须断言墙钟**，不能只断言返回值 —— 我把守卫反向验过一次：临时换回任务组写法，
`XCTAssertLessThan(elapsed, 200 ms)` 报 `("0.224659361 seconds") is not less than ("0.2 seconds")`，
而同一测试里的 `XCTAssertFalse(settled)` **照样通过**。这条已进 §5 代码约定。

**顺带：`LifecycleController` 现在会区分"还干净了"与"没还干净"** —— `prepareForTermination()` 返回 `Bool`，
还原成功但**退出时仍有一笔应用没落地**时**不清标记**（`keepMarkerAndFinish`，`pid = 0` + `needsSelfHeal`），
交给下次启动看真实域再决定。

**附带修掉一个工程问题（它直接破坏了诊断能力）**：`FileLogSink` 没有注入点，所以 `swift test` 每次
都往用户唯一的诊断产物 `~/Library/Application Support/MultiDock/multidock.log`（512 KB 环形）里灌几千行假记录 ——
实验 9 的真实历史就是这么被挤掉的（上面那两条 53–54 s 的记录现在也已不在文件里，只能凭本会话早先读到的内容留档）。
现在 `AppState.init` 接受 `fileLog:`，6 个测试构造点全部传 `TestSupport.makeTestFileLog()`（临时目录、每次一个 UUID 文件）。
核对：跑一遍全量测试，用户日志行数 **3060 → 3060** 不变。

**验收证据**：

- `swift build -c release --disable-sandbox` → `Build complete!`，**零警告**。
- `swift test --disable-sandbox` → **308 个测试，7 跳过，0 失败**（295 → 308，+13：
  `DockReloaderTests` 的 `reloadForQuit` 四种结果、`DockControllerTests` 的墙钟守卫与 `dropPendingRequests`、
  `DockPresenceMonitorTests` 的 `isReloading` 闸门、`StartupSelfHealTests` 的自愈等待上限）。
- **本次没有动用户的 Dock**：全部新行为由注入式假进程覆盖。

**未解决的事**：

1. ⚠️ **A6 与 A7 都只能用户做**，而且**必须重新 `./scripts/build-app.sh`**（见 §6.3）。核对口径：
   退出后日志出现 `退出还原流程结束，用时 0.xx s`（**远小于 5 s**）、切桌面十次 `Dock 不可用` 稳定在 100 ms 量级、
   两条路径都**不再出现**「检测到 Dock 不在…已用 launchctl 拉回」。
2. **`LifecycleController` 的 `!settled` 分支没有端到端覆盖** —— 只有"标记会留下 + `pid = 0`"这一层的单测；
   真机上"退出时恰好还有一笔没落地"要用户复现一次才算走完（A7 的次要核对项）。
3. 数据修复照旧欠着：`计划 任务` / `密码 邮件` 两条 override 要重抓（实验 9 写坏的）。
4. **`Sources/` 里已经没有任何 `withTaskGroup`**（`grep` 只剩这两处解释性注释），所以没有别的地方要审计。
   但这条坑要留着：**"和一个 `await task.value` 赛跑"这种写法在 Swift 里根本不成立**，
   下次再看到"上限写在参数里、实际等很久"的形状，先查是不是任务组。

### 2026-09-19（第 14 次）— 修掉「切一次桌面黑屏几分钟」：主线程被 `launchctl` 冻住 + 三级自激

**做了什么**（用户：「问题：从桌面1切换到桌面2会黑屏几分钟（没有dock、桌面背景也不显示、触控板也不能用）」）：

按 `systematic-debugging` 走，先定根因再动手。**"黑屏"不是显示问题，是 Dock 进程死了 60–126 秒**
—— Dock 负责画壁纸、也实现触控板的三指左右切换空间，所以"没 Dock / 没壁纸 / 手势失效"是同一条症状。
今天**没有任何 Dock 崩溃报告**（0 份 `.ips`），排除了实验 8 那条 SIGABRT 崩溃循环。

三条根因，证据在 `docs/spikes.md` **实验 9**：

1. **`RealDockProcessControl.kickstart()` 里那句 `waitUntilExit()` 跑在 `@MainActor` 上，把整个 App 冻住了。**
   实测 `launchctl kickstart` 在 launchd 退避期间会**阻塞 54 / 60 / 64 秒**返回。
   铁证：`multidock.log` 里出现 55 s、64 s 的空档，而 500 ms 的存活监视器**两分钟只吐了一行**。
2. **`DockReloader.timeout` 默认 5 s，量级比 launchd 的退避小一个数量级** → 正常的退避被误判成"SIGHUP 失败"，
   于是升级到 `SIGTERM` + `kickstart -k`。
3. **`kickstart -k` 会杀掉 launchd 刚拉活的 Dock**，而存活监视器原本 1 s 就动手、之后每 2 s 再踢一次 →
   自己维持一段停摆。**这三条互相喂料**，一次切换就能滚成两分钟。

**顺带挖出的第二条缺陷（数据已受损，代码已修）**：`DockWatcher` 在 **Dock 进程不在期间**采样偏好域，
读回来的是**残缺内容**（3 个 app、0 个其他项，真实是 15 + 1），并被当成"用户手动改动"回存进了 `config.json`。
→ 用户的 `计划 任务`、`密码 邮件` 两个 override 现在各存着 3 个图标、0 个其他项（`LLM` 那份是好的：15 + 1）。
**我没有静默改写他的配置** —— 必须请用户在设置里对这两个桌面点「从当前 Dock 抓取」重抓。

**改动（6 处）**：

| 位置 | 改动 |
| --- | --- |
| `Dock/DockReloader.swift` | `kickstart()` **不再 `waitUntilExit()`**：`process.run()` 后交给进程内单例 `LaunchctlParking` 持有（防 `Process` 被释放 + 不让发射叠发射）；已有一发在飞时返回 `false` |
| `Dock/DockReloader.swift` | `timeout` 默认 **5 s → 30 s**（必须大于 launchd 的退避尺度，否则正常等待=失败） |
| `Dock/DockReloader.swift` | 新增 `isDockAlive`，给 watcher 当存活闸门（一路经 `DockController.isDockAlive` 暴露） |
| `Dock/DockPresenceMonitor.swift` | 生产默认值放慢：`missThreshold 8`（4 s）、`kickstartEvery 60`（30 s）、`persistentFailureThreshold 120`（60 s）—— 报警要让位于退避，别在退避中途喊"拉不回来" |
| `Dock/DockWatcher.swift` | 注入 `isDockPresent` 闸门：**Dock 不在时一律不采样**；回来那一刻先 `needsRebaseline` 重新记基线，再判用户改动 |
| `App/AppState.swift` | watcher 接线传 `isDockPresent: { dockController.isDockAlive }` |

**验收证据**：

- `swift build --disable-sandbox` → `Build complete!`，**零警告**（顺手把 `DockAcceptanceTests.swift:316`
  一条既有的 "unused result" 警告收掉，回到零警告标准）。
- `swift test --disable-sandbox` → **295 个测试，7 跳过，0 失败**（290 → 295，+5）。
  新增：默认值两条（`testDefaultWaitsFourSecondsOfAbsenceAndThenRests` /
  `testDefaultDoesNotWarnDuringLaunchdBackoff`）、watcher 两条（不在时不采样 / 回来先重基线）、
  `isDockAlive` 一条（用 `pid: nil` 与 `LyingProcess(pid: -1)` 守住"-1 不算活着"）。
- **本会话刻意没有碰用户的真实 Dock**：没有重启 App、没有跑真机验收套件 —— 那会对他正在用的会话
  产生可见副作用。所以真机复验挂成 §6.3 的 **A6**。

**未解决的事**：

1. ⚠️ **A6：真机连切十次复验**（唯一还欠的）—— 看 `multidock.log` 里 `Dock 不可用` 回到约 100 ms 量级、
   且不再出现「检测到 Dock 不在…已用 launchctl 拉回」。
2. ⚠️ **两个被写坏的 override 要用户重抓**（`计划 任务` / `密码 邮件`）—— 代码修了，数据没修。
3. `LaunchctlParking` 只在**进程内**去重；理论上两条路径（监视器 + reloader 降级）仍可能各发一发，
   但因为都不再等待，最坏是多一次 `kickstart` 调用而不是冻结。

### 2026-09-19（第 13 次）— toast 换皮：黑色色块 → 跟随亮/深色的原生 HUD 胶囊

**做了什么**（用户：「这是当前的 toast，太丑了，重新设计，支持亮色、深色主题」+ 一张截图）：

诊断（对着截图说的，不是泛泛"不够现代"）：问题不是"黑底白字"这个配色本身，而是那块
**78% 不透明的黑色圆角矩形太厚太实** —— 高 39、内边距 20/10、字号 15，像从别的系统贴过来的色块，
和 macOS 自己的瞬时 HUD 不是一个语言；而且**亮/深色下是同一块死黑**，完全没有跟随外观。

改版（只动 `UI/DesktopNameToast.swift` 的呈现层，`ToastPresenter` 一行没改）：

| 维度 | 旧 | 新 |
| --- | --- | --- |
| 底 | `NSColor.black.withAlphaComponent(0.78)` 固定色 | `NSVisualEffectView`，`material = .popover`、`blendingMode = .behindWindow`、`state = .active` |
| 形状 | 圆角矩形 r=12 | **定高胶囊** 32 高、r=16；宽 = 文字宽 + 2×14，下限 76（单字名字不缩成一颗圆） |
| 边 | 无 | 1 px 动态描边：亮色 `black 0.12` / 深色 `white 0.16` |
| 字 | 15 medium 固定白 | 14 semibold `labelColor`（跟着材质走） |

**为什么用 vibrancy（推翻文件里原来那句"不用 vibrancy"）**：原理由是"要浮在任意背景上，固定深色底更可控"。
`.popover` + `.behindWindow` 恰恰是为这个场景造的 —— 它模糊**身后真实的内容**，所以在任意壁纸/别人家全屏 App
上都保证可读，同时自动跟随亮/深色。固定黑底是在逃避这个问题。

**实现坑（新记录，已进 §4）**：

1. **`NSVisualEffectView` 没有 `cornerRadius`**（那是 UIKit 的 `UIView`）。编译直接报错。
   圆角只能靠 `maskImage`，而**遮罩会被拉伸到视图边界** —— 所以必须**按当前宽度现画一张 1:1 的图**，
   复用一张固定尺寸的会把两端的小圆角扯成椭圆。
2. **动态色在 `draw(_:)` 里免费生效**：`NSColor(name:dynamicProvider:)` 在绘制时按
   `NSAppearance.current` 解析，所以换外观只需 `viewDidChangeEffectiveAppearance` 里 `needsDisplay = true`，
   不需要自己维护两套颜色常量。
3. **定高是硬要求**：旧版高度按文字高度算，名字长短会让胶囊高度变化 —— 每次切桌面都能看到一次跳动。
4. **`check-toast-window.sh` 的判别式是 `height >= 30`**，改成 32 仍然命中；**没有**为了迁就脚本而留 39。

**没做的事（有意）**：不加淡入淡出。文件里原本就写明"提示只活 1 秒，动画会吃掉可感知的停留时间、
让计时核对变糊"，这条契约比观感重要。想要 100 ms 淡入可以做在**内容层透明度**上（不破 `kCGWindowAlpha == 1`
的判别式），等用户开口。

**新增验收工具 `scripts/preview-toast.swift`**：本机没有屏幕录制权限、`screencapture` 只拍到壁纸，
所以改用 `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` 抓**自己窗口**的内容（零权限），
在假壁纸上输出亮/深两张 PNG。**已产出并看过两张图：材质、圆角、描边、字号在两种外观下都成立。**
⚠️ 它用 `.withinWindow`（模糊窗口内的假壁纸）而真机用 `.behindWindow`（模糊屏幕内容），
**色调/圆角/描边/字体一致，模糊到的实际画面不一致** —— 所以它是"定形状和颜色"的工具，不替代真机一眼。
它也是 `DesktopNameToast.swift` 的**代码副本**，改那边要同步这边。

**验收证据**：

- `swift build --disable-sandbox` → `Build complete!`，**零警告**。
- `swift test --disable-sandbox` → **290 个测试，7 跳过，0 失败**（一个都没改，纯呈现层）。
- `./scripts/build-app.sh` → release 编译 + 打包通过。
- `swift scripts/preview-toast.swift /tmp/toast-preview` → 两张 PNG 已生成并逐张看过。

**未解决的事**：

1. ⚠️ **真机一眼没看**。要用户跑 `./scripts/build-app.sh && open build/MultiDock.app`，
   切一次桌面（或调试面板 →「测试 toast」），在**亮色和深色各看一次**。
   我没有替用户启动 App 并程序化切桌面 —— 那会连带触发他的逐桌面 Dock 应用，属于对用户 Dock 的可见副作用，先问。
2. §4 里 toast 的**新几何数值（w=？）待真机重测**；旧值 87×39 / 193×39 已标注为改版前的数。
3. 亮/深色之外没做"跟随壁纸取色"之类的强调色 —— 系统 HUD 也不做。

### 2026-09-18（第 12 次）— 收口三处计划缺口；**顺带着把 Dock 搞崩了一次，结论钉死"其他项不能新建"**

**做了什么**（用户：「检查计划看还有哪些功能没实现」→「按照你的建议做」）：

1. **桌面列表按显示器分组 + 显示器名**（计划 §3.7 要求、原来没有）：新增 `Spaces/ScreenNaming.swift`
   （`CGDisplayCreateUUIDFromDisplayID` + `NSScreen.localizedName` 的纯解析，可单测）；
   桌面页 `List` 按 `displayUUID` 分组、`Section` 标题就是显示器名，详情加「显示器：…」。
   **映射不到时如实说"未识别显示器（UUID 前 8 位…）"，不回落成一台错的屏。**
2. **应用摘要进调试面板**（计划 §3.4 第 6 条"调试面板可见"）：新增「最近一次应用」一组，
   含结果摘要 / 内容指纹 / 写入时刻 / 本次运行改过 Dock / 回存闸门。
3. **其他项（`persistent-others`）补编辑入口，且刻意只"搬"不"造"**：
   编辑条下方新增一条「其他项（文件夹 / 堆栈）」—— 显示 / 排序（`OthersReorderDropDelegate`）/
   移除（右键菜单 + 与图标条共用垃圾桶）。
4. **修三处过时文档**（§3.6「8 待 P3」、§3.7「`mru-spaces` 仍未做」、§6「第 1 条仍未回答」）+ README 的「已知未做」
   补上"UI 报警已做"与文件夹结论。
5. **`docs/spikes.md` 新增实验 8**（见下）。

**⚠️ 这次把用户的 Dock 搞崩了一次（已完全还原，域逐键无差异）。教训必须留下：**

- 起因：为验证"能不能由 App 拼一条 `persistent-others` 目录条目"，往真实域写了一条
  **最小形状的 `directory-tile`**（`file-data` / `file-label` / `file-type`）+ 一条 `file-tile`。
- 结果：**Dock SIGABRT**（`EXC_CRASH`，`abort() called`），launchd 把它拉起又崩，本机共 7 份崩溃报告
  （`Dock-2026-09-18-0753*~0754*.ips`），期间用户没有 Dock 用。
- 对照：补全 `arrangement`/`displayas`/`showas`/`preferreditemsize`/`is-beta` 后 Dock **不崩**；
  但 8 秒后仍不补 `GUID`/`book`（实验 2/3/4）→ **Dock 不认领自拼的目录条目**。
  对照组（P2 验收）是 App 的 file-tile 在 200 ms 内被 Dock 补上 `GUID`，所以"没补 GUID" = "没读进去"。
- 定案：**不提供新建文件夹 / 普通文件条目**。做了是假开关，形状错了还会崩。
  替代做法已写进 UI（在访达里自己拖到 Dock 上，由 `DockWatcher` 回存）。回归守卫见下。
- 恢复手法（以后别踩同样的坑）：`defaults import com.apple.dock <备份>` 之后 **launchd 不会立刻拉起**；
  `launchctl kickstart -k gui/$UID/com.apple.Dock.agent` 会。**反复杀 Dock 还会触发 launchd 的递增退避**
  （`state = spawn scheduled`），Dock 几十秒不回来，静置等待比反复 `kickstart` 更快（详见 `docs/spikes.md` 实验 8.5）。

**验收证据**：

- `swift build --disable-sandbox` → `Build complete!`，**零警告**。
- `swift test --disable-sandbox` → **290 个测试，7 跳过，0 失败**（276 → 290，+14）。
- 真机验收 `MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter testOtherItemsRemovalAndReapplyKeepsDockHealthy`
  → **通过**（169 s，慢是 launchd 退避把每次 Dock 不可用拖到 41 s / 63 s；关键断言全对：
  移除后 Dock 存活、`GUID 1/1`、`book 1/1` 保留、还原后其他项逐项与操作前相同）。
- 用户 Dock 状态：验收与手工备份前后 `defaults export` 逐键 diff 为 `[]`（只动白名单键 + Dock 自己的计数器）；
  手工备份留在 `/tmp/dock-backup-before-otheritems-test.plist`。

**未解决的事**：无新增。§6.1 新增第 9 条（其他项"不能新建"的折中接受吗，等用户点头）；
§6.3 C 组加 C7 / C8 两条取舍记录。多显示器（B5）与手测 A 组仍等用户。

**遗留说明（下一位 agent 必读）**：

1. **全量 `DockAcceptanceTests`（7 条）这次没有跑完**：launchd 递增退避把每次 Dock 重启拖到 40–60 s，
   全量估计 10 分钟以上，超出本会话可用时间，被我中途停掉（停手后 6 秒 Dock 就回来了）。
   **其余 6 条与上一次会话的绿色结果一致，本次只动了共享的辅助代码、没有改它们的逻辑。**
   下一次若要重验全量，请**等 Dock 稳定运行几分钟**后再跑（`docs/spikes.md` 实验 8.5）。
2. **打断验收时它会留下一次没还原的写入**（这次留了一个 `tilesize = 72` 的孤儿写入，已手工改回 36）。
   教训：**要么让它跑完、要么准备好手工把 `defaults write` 回去** —— 这类写入不在基准/会话标记里，
   App 的"退出还原"对它无效。
3. **工作区里还混着上一会话（第 11 次，P5+ 报警横幅）的未提交改动**，本次提交时已一并核对
   （`DockPresenceMonitor` 的持续失败回调 / `DockFailureWarningTests` / `SettingsView` 的 `WarningBanner`
   与 AGENTS.md「已完成：P5+」段是对齐的），见 commit 历史。

### 2026-09-18（第 11 次）— 把 A4 从"只能手测"变成自动化回归，**顺带挖出并修掉一个真机 bug**

**做了什么**（用户：「请继续执行任务」）：

**① A4 自动化：用 `defaults write` 复现"用户手拖图标"**

A4 一直挂在"只能手测"里，理由是"真人拖拽要辅助功能权限，与硬约束冲突"。这个理由站不住 ——
`DockWatcher` 的判据是「**可比指纹变了、且不等于我们写下去的那份**」，而用户拖动本来就是 **Dock 进程写 `com.apple.dock`**。
所以只要**另一个进程**去写同一个域，在偏好域层面就**无法区分也不需要区分**。

实测确认（新增 §4 环境事实一行）：`/usr/bin/defaults write com.apple.dock tilesize -float 72` 之后
`CFPreferencesCopyMultiple` **立刻**读到 72.0。于是新增
`DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop`：真实 `DockController`（临时目录的
`ConfigStore`/`BaselineStore`）+ 真实 `DockReloader` + 走**真实 2 秒轮询**（不手动 `tick()`，这才是真机行为），
两种落点都覆盖 —— 默认 Dock、逐桌面 override。

**② 由此挖出一个真机 bug（D24）：逐桌面 Dock 的桌面在回存时会白重启一次**

`DockController.apply` 原来只有一条短路，比的是「**我们上次写下去的那份**」（`appliedFingerprint`）。
一旦发生过**外部改动**它就**过期**了 —— 此时回存（`setOverride` → 应用）要写的内容与真实 Dock **一模一样**，
却照样白写一遍 + 白重启一次 Dock：

| 落点 | 修复前 | 修复后 |
| --- | --- | --- |
| 默认 Dock | `68655 → 68655` ✅ | `68984 → 68984` ✅ |
| **该桌面的 override** | `68667 → 68672` ❌（约 50 ms 闪烁） | `68995 → 68995` ✅ |

**默认 Dock 那条路不中招**（回存只写配置、不应用），所以只有 override 中招 —— 而逐桌面 Dock 恰恰是本 App 的常态用法，
也就是说用户每次手拖图标进 Dock 都会看到一次闪烁。

修法：短路加**第 1b 条** `liveAlreadyMatches(config)`，判据**复用 `verify` 的同一套比较**
（只比"我们真要写的那些键"），所以「跳过」与「写下去之后立刻验过」**严格等价**，不会漏写。
短路时调 `adoptLiveDockAsApplied()`：顺带把 `appliedComparableFingerprint` 填上（= 打开 `DockWatcher` 的回存闸门），
**且刻意不设 `appliedAt`**（不是我们写的）。

回归 4 条：`testSkipsWhenLiveDockAlreadyMatchesDespiteStaleFingerprint`（正例）、
`testSkipAdoptsLiveDockSoWriteBackGateOpens`（闸门）、`testDoesNotSkipWhenLiveDockDiffersFromConfig`（反例守卫）、
`testForceBypassesLiveMatchShortCircuit`（`force` 同时绕过 1 与 1b）。

⚠️ **教训：这个 bug 只靠单测发现不了。** 旧单测里 `appliedFingerprint` 与真实域永远同步，两个对象各自自洽；
只有"真机连着跑 + 外部改动"才暴露。同理，**我第一版验收断言写错了**：我在 `setOverride` 返回后立刻读 PID，
而它触发的应用走 `request()` **异步排队** —— 于是"没有白重启"这个结论**假成立**。加 `await waitForIdle()` +
400 ms 沉降之后，真 bug 才现形。

**验收证据**：

- `swift build --disable-sandbox` → `Build complete!`，**零警告**。
- `swift test --disable-sandbox` → **263 个测试，5 跳过，0 失败**（258 → 263）。
- 真机验收全量重跑（`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`）
  → **5 条全过**，含新的回存用例；每条用例结束都 `还原后差异键：[]`。
- 用户 Dock 状态：验收自带还原，跑完确认无残留差异。手动备份留在 `/tmp/dock-backup-before-capture-test.plist`。

**未解决的事**：无新增。B5（多显示器真机）与 A1–A3/A5（手测）仍等用户；A4 已从"唯一检验"降级为"建议补一次"。

### 2026-09-18（第 10 次）— `⇧+左键` 切上一个桌面；查清"切桌面动画"为什么做不到

**做了什么**（用户：「更新计划：点击菜单栏图标需要有左右滑动的动画，当前没有动画效果。shift+点击菜单栏图标，执行上一页。」）：

**① ⇧+左键 = 切上一个桌面（已实现）**

- `AppState.switchToPreviousDesktop()`：与 `switchToNextDesktop()` **完全对称** —— 同一个 `switcher.target(.previous)`、
  同一次 `applyConfigForDesktop` 预应用、同样两端循环。**不是**新写一条链路，避免两条路慢慢长歪。
- `MenuBarController`：`isShiftClick` 判定 + 「上一个桌面」菜单项 + 一行禁用提示「（⇧+左键点菜单栏图标同效）」；
  tooltip 改成「左键切下一个桌面，⇧+左键切上一个，右键打开菜单」。设置页那句说明也补上了。
- **`clickAction == .openMenu` 时 ⇧+左键一并走菜单**（`forceMenu` 判定在 shift 之前）—— 不留隐形的第二行为。
- 新增 `testPreviousDesktopPreAppliesItsOwnDock`：断言"预应用真的发生 + 目标是对面那个桌面的 Dock + 只写一次"。

**② 切桌面的"左右滑动"动画：做不到，已定性为不做（D22）**

用户观察是对的 —— 当前确实是硬切。四条可能的路全部走死，证据见 `docs/spikes.md` **实验 7**：

1. **程序化切空间是瞬时提交**：3 轮实测 **6 / 0 / 0 ms**，塞不进一段过渡。
2. **`SLSManagedDisplaySetIsAnimating` 不是触发器**，是**粘滞状态位**（置位后 600 ms 内 **101/101** 次采样仍为 true，
   不会自复位），对切空间耗时与 WindowServer/Dock 的 CPU 都无可测影响。
   ⚠️ **顺带更正上一轮的一个错记**：我曾把这个调用的返回值 `-2752379` 记成"返回成功"。这次复测发现
   **同一次运行内 8 次调用恒为 `-785121165`，换一次运行变成 `-2752379`** —— 那是 **void ABI 的残留寄存器**，
   根本不是 `CGError`。**判断这个调用有没有生效只能看读回值，不能看返回值。**
3. **会话级开关写后读不回**：`SLSSetSessionSwitchCubeAnimation` + `kSLSSessionSwitchTransitionType*`
   （值 `cube` / `transition` / `none` / `""`）看着正对症，但**只有 set 没有 get**；`CGSessionCopyCurrentDictionary()`
   只有 11 个键（全审计/用户/登录态），`com.apple.spaces` / `com.apple.dock` 里也没有；扫遍 SkyLight 的 `__TEXT`
   **5,037,056 字节**，含 `SwitchCube` / `SessionSwitch` 的**只有函数名本身**。
   → 它是 WindowServer 进程内的会话内存值，**改了就还原不回去 → 破无痕原则 → 不能用**。
4. ⚠️ **`SLSWillSwitchSpaces` 猜签名会段错误**：按 `(cid, CFArray)` 调用，进程直接死在 SkyLight 内部的
   `array_call_as_integer_list`。**已在此划线：不要再拿用户的图形会话试错。**
5. 绕道"合成 `Ctrl+←` 让 Dock 自己动画"也堵死：`CGPreflightPostEventAccess()` 返回 `true`，
   但**阳性对照合成 `Cmd+Tab` 同样不生效** → 问题在事件投递被拦，不是参数选错。

**不做假动画**：不自己画跨屏浮层假装滑动（既不是真的切桌面动画，又要在多显示器/全屏空间下处理一堆边界）。
真正的过渡实现在 WindowServer 的 `Transition{Slide,Cube,Flip,…}Metal` 里，只服务用户手势。

**新增工具**：`scripts/spike-symbols.swift` —— 从 dyld 共享缓存里枚举 SkyLight 的导出符号（本机 **23,474** 个）。
`nm` 在磁盘上找不到 SkyLight（框架在共享缓存里），必须在进程内解析 Mach-O，且
**`LC_SYMTAB.symoff` 是共享缓存内的文件偏移**，要先经 `__LINKEDIT` 换算成 vmaddr 才能取指针。

**验收证据**：

- `swift build --disable-sandbox` → `Build complete!`，**零警告**。
- `swift test --disable-sandbox` → **258 个测试全绿**（4 个真实 Dock 验收默认跳过）。257 → 258。
- 复核实验全程只读 + 一次程序化切空间（切完切回），跑完确认 `SLSManagedDisplayIsAnimating` 已复位为 `false`，**无残留状态**。

**未解决的事**：无新增。B5（多显示器真机）与 A1–A5（手测）仍等用户。动画这条已转为"不做"，不再挂账。

### 2026-09-18（第 9 次）— 完成 P5（收尾）：README、多显示器加固、全屏真机回归、B12–B14

**做了什么**（用户：「继续完成任务」）：

- **README 整篇重写**（B11）：原先停在 P1 状态（"还不能改 Dock"）。现在写清 P0–P4 的真实能力、
  完全卸载三步（退出还原 → 关登录项 → 删数据目录）、`defaults import baseline.plist` + `kill -HUP $(pgrep -x Dock)`
  的整域还原（并说明它会把热角一起回退）、故障排查表。
- **多显示器加固**：`AppState.handleScreenParametersChanged()` + `AppDelegate` 接
  `NSApplication.didChangeScreenParametersNotification`（插拔外接屏 → 重读桌面列表）。**只刷新、不主动应用 Dock**。
  调试面板加「显示器数量」与每个桌面 `displayUUID` 前 8 位，方便核对有没有串。**真机实测仍需用户插屏**（B5）。
- **全屏过滤真机回归通过**（B6）：新增 `scripts/check-fullscreen-filter.swift` —— **把自己的一个窗口切成全屏**
  就能造出真实的 `type=4` 空间（零权限），不用辅助功能也能回归。实测见 §4。
  抽了 `SkyLightSpaceProvider.userDesktops(fromDisplays:)` 这个纯函数 + `SpaceParsingTests`（8 条）钉死解析规则。
- **B12 编辑条竖排**：`DockStripEditor.isVertical` + `SlotSizing`，`orientation != "bottom"` 时走竖排。
- **B13 孤儿绑定**：`AppState.orphanedBindings` / `pruneOrphanedBindings` + 桌面页横幅与「清理」按钮（二次确认）。
  **绝不自动删** —— 拔外接屏会让绑定看起来像孤儿。
- **B14 回存历史**：新增 `Dock/DockEditHistory.swift`（内存撤销栈，每目标 5 层）+ 桌面页/通用页的「撤销自动回存」按钮。
  **刻意不落盘**：落盘一堆没有恢复入口的文件是花架子；长期保命靠 `baseline.plist` 与 `backups/`。
- 新增测试 2 个文件 18 条：`SpaceParsingTests`（8）、`BindingHistoryTests`（10）。

**验收证据**：

- `swift test --disable-sandbox` **257 个测试全绿、零警告**（4 个真实 Dock 验收默认跳过）。239 → 257。
- 全屏真机回归：`进入全屏前 2 个 type=0 空间 → 全屏中 3 个（多出 type=4、id64=537）、type=0 仍是 2 个、
  活动 id64=537 不命中任何用户桌面 → 退出后回到 2 个、活动 id64=6`。
  MultiDock 同步日志：`活动空间不是用户桌面（可能是全屏 App），不触发切换`；从全屏退回桌面**没有**弹 toast。
- `swift build -c release --disable-sandbox` 零警告；`./scripts/build-app.sh` + `open build/MultiDock.app` 冒烟通过
  （日志显示 2 个用户桌面、会话标记建立正常）。

**未解决 / 交给下一个 session**：

- **B5 多显示器真机实测**（唯一剩下的 P5 项）—— 必须用户插一台外接屏。
- 两处低优先级的"做了但没做全"：Dock 拉不回时缺 UI 提示（PLAN §3.9 第 3 条）、降级报警没进设置页（PLAN §3.1 末段）。
- §6.3 **A 组 5 条手测（A1–A5）一次都没做过**，A4 是 `DockWatcher` 回存路径的唯一真实检验。
- B9（注销/关机）、B10（LaunchAgent 退回）需要真的注销/重登录一次。

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
  - ⚠️ **本条的"20 ms"已被证伪**（2026-09-18，第 10 次会话）：那是 P0 采样粒度的粗值，用 500 µs 粒度重测是 **0–6 ms**，且**没有动画**。上面保留原文是为了不改写历史；**以 §4 与 `docs/spikes.md` 实验 7 为准**。
- **P1 实现完成**：新增 14 个源文件（`App/` `Spaces/` `Dock/` `Store/` `UI/`）+ 4 个测试文件 + 4 个 P0 实验脚本；测试目标已加进 `Package.swift`，**37 个测试全绿**，全新构建**零警告**。
- 同步修订了 `docs/PLAN.md`（§1 键名、§2 文件树、§3.1 事件源、§3.2 模型、§3.5 重载策略、§4 P0/P1 行、§5 风险表、§7 差异）、重写 `AGENTS.md`、更新 `README.md`。

**验收证据**：
- 切桌面 10 次 → 日志记录 10 次变化，spaceUUID 全对、无漏报无重复。
- `baseline.plist` 与运行时 `com.apple.dock` **34 键逐键相同**。
- App 运行前后 Dock 除 `recent-apps`/`mod-count`（系统自管，已在排除清单）外**无任何差异** → P1「不改任何 Dock 设置」成立。
- 正常退出后 `session.state` 被正确删除。

**关键手法**（详见 `docs/spikes.md`）：本机无屏幕录制权限、`screencapture` 只返回壁纸，所以改用**零权限的客观判据** —— 写入的 tile 故意不带 `GUID`，Dock 真正应用后会补上（正负两种情形都验证过）。

**未解决**：见 §6.1（桌面页"位置"含义待用户回答）、§6.3（外观键名待实测、SIGTERM 竞态、Finder 手动验证、还原未接线等）。

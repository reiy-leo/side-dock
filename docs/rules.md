# 工程约定与防回归清单

> 2026-10-04 自 AGENTS.md §5 + §3 各阶段「实现要点」+ §6.3 D 台账迁移（verbatim，除本说明与分隔标题）。
> 改任何模块前先查对应阶段的「改动时别踩」；新坑往这里追加。
> 本文中"见 §4"指 `docs/facts.md`；"§6.3 A/B/C"指 `AGENTS.md` 未决问题；"§8"指 `docs/sessions.md`。

### 构建与运行

```bash
swift build -c release --disable-sandbox   # 编译
swift test --disable-sandbox               # 327 个测试（含 9 个默认跳过的真实 Dock 验收）
./scripts/build-app.sh                     # 组装 build/MultiDock.app（ad-hoc 签名）
open build/MultiDock.app                   # 运行（必须在 .app 里跑，菜单栏图标才正常）
./scripts/check-toast-window.sh --watch 12 # 客观验收 toast（零权限，读窗口元数据）

# 真实 Dock 验收：会真的改 com.apple.dock 并重启 Dock，跑完自动还原
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests
```

- ⚠️ **必须加 `--disable-sandbox`**（2026-09-18 起）。SwiftPM 自己的 `sandbox-exec` 在本机环境里会 `sandbox_apply: Operation not permitted`，manifest 编译直接失败，报 `error: 'multi-dock': Invalid manifest`。这不是代码问题，加了这个参数就好。
  **`./scripts/build-app.sh` 已内置这个参数**（2026-09-20 补上，之前它裸调 `swift build` 会直接失败）。
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
- ⚠️ **用脚本核对 `config.json` 时，先把真实键名打出来**（`print(list(d.keys()))` / `list(override.keys())`），**不要凭记忆写字段名**。2026-09-20 踩过：脚本里写 `o.get('apps')` / `o.get('others')`，而真实键是 **`pinnedApps` / `otherItems`**，于是把"3 个图标"读成"0 个"、把"有 override"读成"全空"，并据此得出完全错误的结论写进了本文档。**一个字段名写错就足以伪造出一个不存在的数据损坏。** 判断"某条 override 是不是坏的"时，还要比**内容**而不只是数量：两条用途不同的桌面配出逐项相同的 override 才是坏数据指纹。
- **可测性拆分**：跟 AppKit / 系统调用打交道的部分（窗口、私有 API、Dock 进程）单独放一个类型并抽成协议（`ToastPresenting`、`SpaceProviding`、`DockPreferenceAccessing`、`DockProcessControlling`），纯逻辑放另一个类型。这样行为能单测，剩下的才靠实测。
- ⚠️⚠️ **协议要求的返回类型，具体实现必须逐字照抄 —— 差一个 `?` 就够毁掉整条生产路径。** Swift **不做返回类型协变匹配**：协议要求 `-> T?`，实现写成 `-> T`，编译器把它当**另一个重载**，协议要求的见证位就**由扩展里的默认实现满足**，于是 `(Real() as any P).m()` 永远返回默认值（通常是 `nil`），而 `Real().m()` 正常。**经具体类型调用测不出来，所有替身单测照样全绿。** 2026-09-20 实测：`pidProbe()` 就是这么让 A8 的取证仪表在生产路径上完全没接线；同一批排查里 `startTime(of:)` 签名是对的、但**没有守卫测试**，一旦写错，节流判据会从"进程年龄"静默退回"我们记不记得自己重启过"（P3 验收里同一场景 **45 ms → 1030 ms**）。**规矩：每加一条有默认实现的协议要求，就在 `DockProcessSafetyTests` 里补一条经 `any 协议` 调用的守卫测试**（`testRealControlIsWiredAsTheProtocolWitness` / `testRealStartTimeIsWiredAsTheProtocolWitness` 是模板）。系统排查配方见 skill `macos-dock-space-probe`；复盘见 `docs/spikes.md` 实验 15.2。
- **`AppState` 的依赖全部可注入**（`dockController` / `configStore` / `baselineStore` / `provider`），并且 **AppState 内部不要直接调 `DockPreferences.readDomain()` 这类静态入口** —— 那会绕过注入点，测试里会读到真实系统的偏好域。要读就走 `dockController.readDomain()` / `captureLiveConfig()`。（P2 踩过：`captureCurrentDockAsDefault` 就是直接调静态方法，导致三个单测读到真实 Dock。）`provider` 可注入是为了让"预应用先于切换"能写成断言。
- **测试里的替身类如果被 `@MainActor` 测试类嵌套，要显式标 `@MainActor`**：嵌套类型**不继承**外层的 actor 隔离，而 `DockWatcher` 的闭包都是 `@MainActor` 的，不标就报 `call to main actor-isolated initializer in a synchronous nonisolated context`。
- **发信号/杀进程的代码必须自带"只碰确认过的 PID"闸门**，别指望调用方传对。见 §4 的 `-1` 陷阱。
- **文件末尾的 `try` / `defer` 里不要阻塞主线程**：`@MainActor` 的异步测试里 `DispatchSemaphore.wait` 会死锁（`Task { @MainActor }` 永远排不上）。要在收尾还原，就写 `do { try await ... } catch { await cleanup(); throw error }` + 正常路径显式收尾。
- **"带上限的等待"必须轮询可观察标志，不能用 `withTaskGroup` 与 `await task.value` 赛跑**。任务组闭包返回时会等**所有**子任务收尾，而 `await task.value`（`Task<Void, Never>`）不响应取消 —— 于是 `group.next()` 在 20 ms 就报了正确的 `false`，**整个函数却要等完整条降级链才返回**：上限静默失效，返回值还是对的。实测两处 20 ms 上限 → 625 ms / 224.7 ms 墙钟。写法见 `DockController.waitForIdle(upTo:)` 与 `AppState.settleSelfHeal(within:)`；**守卫必须断言墙钟**（`XCTAssertLessThan(elapsed, …)`），只断言 Bool 抓不住。见 `docs/spikes.md` 实验 10。
- **测试里构造 `AppState` 必须传 `makeTestFileLog()`**。`FileLogSink` 默认写 `~/Library/Application Support/MultiDock/multidock.log`，而那是用户核对真机行为的**唯一**凭据（无屏幕录制、`log show` 沙箱里读不到）。以前没有注入点，一次 `swift test` 就往那份日志灌几千行假记录，512 KB 的环形截断还会把真实证据行挤出去（本会话就是这么弄丢实验 9 那两次 53–54 s 的退出记录的）。自查：跑全量测试前后 `wc -l` 那份日志，行数必须不变。

### 与计划原文的两处刻意偏离（不要"改回去"）

1. **`UI/MenuBarController.swift` 取代计划里的 `UI/MenuBarView.swift`**，程序入口用 `NSApplication` 而非 SwiftUI `App` + `MenuBarExtra`。原因：硬约束要求区分左键/右键/⌥+左键，`MenuBarExtra` 的点击一律被它自己吃掉，做不到。设置窗口与调试面板仍是 SwiftUI（`NSHostingController` 承载）。
2. **`DockTile.raw` 的类型是 `[String: PlistValue]` 而不是计划写的 `[String: Any]`**。原因：`[String: Any]` 不满足 `Codable`，无法落盘到 `config.json`。`PlistValue` 是一个覆盖全部 plist 类型的枚举，并提供与 `Any` 的双向转换。

### 设计文档的维护

`docs/PLAN.md` 是设计与进度的权威副本；`docs/spikes.md` 是 P0 实测结论。实现中设计若有变化，**同步更新 `docs/PLAN.md`**，不要让文档和代码脱节。

---

# 各阶段「实现要点（改动时别踩）」
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

1. **预应用 = "同一拍发起"，不是"切空间前完成重启"**。`switchToNextDesktop()` / `switchToPreviousDesktop()` / `switchTo(_:)` 先 `switcher.target(_:)` 算目标 → `applyConfigForDesktop(target)` → 再 `switcher.switchTo(target)`。**切空间前完成重启物理上做不到**：重启约 101 ms > `setCurrentSpace` 实测 0–6 ms。真实保证是"不等 300 ms 轮询"。别按字面去"修正"这个顺序。
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
10. **短路有两条，缺一不可**（P4 收尾时真机验收挖出来的 bug，见 §6.3 D24）。第 1 条比的是「**我们上次写下去的那份**」（`appliedFingerprint`），第 1b 条比的是「**真实 Dock 现在长什么样**」（`liveAlreadyMatches`）。只有第 1 条时，一旦发生过**外部改动**（用户手拖、别的 App 改、或 `DockWatcher` 刚回存的那份）它就过期了，再应用一份与真实 Dock 完全相同的配置会**白写一遍 + 白重启一次 Dock**。1b 的判据**必须复用 `verify` 的同一套比较**，这样"跳过"与"写下去之后立刻验过"严格等价，不会漏写。短路时调 `adoptLiveDockAsApplied()` —— 它同时把 `appliedComparableFingerprint` 填上，也就是把 `DockWatcher` 的回存闸门打开；**它刻意不设 `appliedAt`**（不是我们写的，不该被当成"我们自己刚写完"）。

### 已完成：P5（收尾）✅ 2026-09-18

规格见 `docs/PLAN.md` §4 P5，验收证据见 §8 第 9 次记录。

**实现要点（改动时别踩）**：

1. **README 已整篇重写**（原先停在 P1 状态，会误导用户）。含完全卸载三步：退出还原 → 关登录项 → 删数据目录；
   另给了 `defaults import baseline.plist` + `kill -HUP $(pgrep -x Dock)` 的整域还原，并写清它是**整域替换**（会把热角一起回退）。
2. **显示器配置变化要重读桌面列表**（`AppState.handleScreenParametersChanged`，由 `AppDelegate` 接
   `NSApplication.didChangeScreenParametersNotification`）。多显示器下 `displayUUID` 是映射键的一部分，
   插拔之后不刷新就会串行。**只刷新、不主动应用 Dock** —— 屏幕变化瞬间活动空间还没定，交给 300 ms 轮询收敛。
3. **全屏过滤已真机回归**：`scripts/check-fullscreen-filter.swift` 把**本进程的一个窗口切成全屏**
   （零权限，这是自己的窗口），SkyLight 就会多出一个 `type=4` 空间，于是能真的验证过滤。见 §4 的实测结论。
4. **编辑条竖排已实现**（`DockStripEditor.isVertical`）：`orientation != "bottom"` 时改成 `ScrollView(.vertical)` + `VStack`，
   格子用 `SlotSizing` 定高。之前位置改成左/右后编辑条仍是横的，排序会看反。
5. **孤儿绑定只提示、绝不自动清理**（`AppState.orphanedBindings` / `pruneOrphanedBindings`）。
   ⚠️ **自动删是错的**：外接显示器被拔掉时，那台显示器上的桌面整体消失，绑定看着就是孤儿 —— 插回去还要用。
   所以桌面页给横幅 + 「清理」按钮 + 二次确认。
6. **回存历史用内存撤销栈，不落盘**（`Dock/DockEditHistory.swift`）。计划原文说"覆盖前存一份历史版本"，
   落盘一堆没有恢复入口的文件是花架子 —— 用户翻到 `history/` 也用不上。真正要长期保命的是 `baseline.plist` 与 `backups/`。
   回存要防的风险是"误判一次把配置写坏了"，一步撤销就够，所以做成 UI 上的「撤销自动回存」按钮（每个目标 5 层）。
   撤销后 watcher 不会立刻再触发 —— 它只在真实 Dock 指纹变化时才回调，撤销改的是配置、没动 Dock。

### 已完成：P5+（UI 报警补完）✅ 2026-09-18

规格见 `docs/PLAN.md` §3.1 末段与 §3.9 第 3 条，验收证据见 §8 第 12 次记录。

计划里要求"在 UI 明确报警，而不是静默失效"的两处，原先都只写日志 + 调试面板 ——
**用户不看日志，等于没报警**。现在统一收敛到设置窗口顶部的 `WarningBanner`（`UI/SettingsView.swift`）。

**实现要点（改动时别踩）**：

1. **报警的判据用"缺失轮数"，不用 `kickstart()` 的返回值。** 那个返回值只说明 `launchctl` 命令跑起来了，
   **不说明 Dock 回来了**。所以 `DockPresenceMonitor` 数的是连续缺失了多少轮，达到
   `persistentFailureThreshold`（默认 12 轮 × 500 ms ≈ 6 秒）才回调一次。
2. **边沿触发，只报一次。** `isPersistentlyDown` 只在跨过阈值那一刻翻转；继续缺失不再重复回调 ——
   每轮都报会把日志和 UI 刷爆。Dock 回来后清掉标志并回调 `onRevived` 一次。
3. **阈值强制大于 `missThreshold`**（`max(missThreshold + 1, …)`）。传反了会在"还没到该动手的轮数"
   就先喊拉不回来，那是配置错误，不该让它成立。
4. **回调用 `var` 而不是 init 参数**，与 `log` 出口不同：这两个回调写的是 **`AppState` 自己的状态**，
   必须由 `AppState` 无条件挂上 —— 而监视器可能是测试里构造好再注入的，那时 init 参数没人填。
   `log` 则是监视器自己的出口，注入时别覆盖。
5. **`retryDockRevival()` 的返回值不代表 Dock 回来了** —— 它只说明 `launchctl` 跑起来了。
   所以按钮点完**不能提前撤报警**，等监视器的下一次轮询判定。
6. **横幅两条都为空时整个视图不占空间**，不会在正常状态下留一条空白。

**验收**：12 条新单测（`DockPresenceMonitorTests` 5 条 + 新文件 `DockFailureWarningTests` 7 条），
外加一条真机反向守卫 `DockAcceptanceTests.testHealthyRealDockNeverRaisesPersistentFailure`
（**只读**：跑 40 轮真实 `dockPID()`，断言健康 Dock 一次都不误报）。

⚠️ **"拉不回来"这条真机路径没法按需触发** —— 本机 `launchctl kickstart` 一直是有效的，
Dock 杀了就回来，所以红横幅在本机复现不出来。逻辑由单测覆盖，渲染未做视觉验证（本机无屏幕录制权限）。

### 已完成：P5++（计划缺口收口）✅ 2026-09-18

用户要求"检查计划看还有哪些功能没实现"后，把计划里**有明文、代码里却缺**的三处补掉，外加修文档过时行。
规格见 `docs/PLAN.md` §3.4 / §3.6 / §3.7 的 P5++ 记录；实测依据见 `docs/spikes.md` **实验 8**。

**实现要点（改动时别踩）**：

1. **其他项（`persistent-others`）只"搬"不"造"**。编辑器新增「其他项（文件夹 / 堆栈）」一条：
   显示 / 排序（`OthersReorderDropDelegate`）/ 移除（右键菜单 + 与图标条**共用**的垃圾桶 ——
   `RemoveDropDelegate` 收两个 `@Binding`，按归一化键判断该删哪个数组）。
   写回去的就是 Dock 自己写的 dict，`GUID` / `book` 原样保留（真机验收钉死了这一点）。
2. **⚠️ 绝不要"顺手"加上新建文件夹 / 文件的能力。** `docs/spikes.md` 实验 8 实测：自拼的 `directory-tile`
   **不被 Dock 认领**（Dock 不补 `GUID`；补全展示字段、甚至自己用 `URL.bookmarkData()` 生成 `book` 都不行），
   而**字段不全的形状会让 Dock 直接 SIGABRT 进崩溃循环**（本机实测 7 份崩溃报告，用户当场失去 Dock）。
   回归守卫：`DockStripRulesTests.testDockItemRejectionClosesTheFolderAndFilePaths`。
   **替代做法**（已写进 UI 文案）：让用户在访达里自己把文件夹拖到 Dock 上 —— Dock 会写完整条目（含 `book`），
   `DockWatcher` 随后把它回存进当前桌面的配置，之后就能在编辑器里排序 / 移除。
3. **拖入被拒必须说出来**（`DockItemRejection.message` + 「知道了」按钮）。早先版本拖文件夹进来是**静默失败**，
   用户只会以为程序坏了。
4. **`normalizedOthers` 只去重、不插固定项**。`persistent-apps` 才需要"保证启动台在首位"。
5. **显示器名映射**（`Spaces/ScreenNaming.swift`）：`CGDisplayCreateUUIDFromDisplayID` + `NSScreen.localizedName`，
   与 SkyLight 的 `Display Identifier` 是同一套换算（§4 已实测逐字符相同）。纯解析可单测；
   `currentScreens()` 是 `@MainActor`。**映射不到时如实说"未识别显示器（UUID 前 8 位…）"，
   不要回落成某台真实显示器的名字** —— 显示一个错的屏比显示"未识别"更糟。
   结果缓存在 `AppState.displayScreens`，刷新点是启动 + `didChangeScreenParametersNotification`；
   **不要在视图渲染路径里现取 `NSScreen`**。
6. **`persistent-others = []` 是安全的**（实验 8 的实验 5：SIGHUP 后 0.6 s 归位），所以「移除最后一项」不设限。
7. ~~**反复杀 Dock 会让 launchd 进入递增退避**：验收脚本连杀几十次就会踩到，App 正常使用不受影响。~~
   **这条"不受影响"是错的**（2026-09-19 实验 9 证伪）：App 正常使用**就会**踩到 ——
   一次稍慢的恢复被我们自己续上退避，实测每次切换 Dock 缺失 60–126 秒。见下面「已完成：修掉切桌面黑屏」。

### 已完成：修掉「切一次桌面黑屏几分钟」✅ 2026-09-19

用户报告：桌面 1 → 2 之后没有 Dock、没有壁纸、触控板手势失效几分钟。根因与全部证据在
`docs/spikes.md` **实验 9**；规格改动见 `docs/PLAN.md` §3.4 / §3.8 / §3.9。**这一节的六条都不能"改回去"。**

**实现要点（改动时别踩）**：

1. **`RealDockProcessControl.kickstart()` 绝不能 `waitUntilExit()`。** launchd 处在退避里时
   `/bin/launchctl kickstart` 会**阻塞到它真能把服务拉起来为止**（实测 54 / 60 / 64 秒），而这条调用在
   `@MainActor` 上 —— 整个 App 连带冻住（判据：500 ms 一轮的存活监视器在两分钟里只留下一行日志）。
   现在发完就走，`Process` 由 `LaunchctlParking` 持到退出（否则子进程还活着时对象就被释放）。
2. **在飞的 launchctl 不允许叠加**（`hasOutstanding` 直接返回 false）。`kickstart -k` 的 `-k` 会杀掉
   launchd 刚刚拉回来的 Dock，等于自己给自己续退避。
3. **`DockReloader.timeout` 从 5 s 提到 30 s。** 超时的尺度必须是 **launchd 退避的尺度**（几十秒），
   不是"我们觉得该好了"的尺度。5 s 时一次正常慢恢复被误判成 SIGHUP 失败 → 升级 SIGTERM+kickstart → 放大。
4. **存活监视器的三档节奏整体放慢**：缺失满 4 s 才动手（原 1 s）、每 30 s 才催一发（原 2 s）、
   满 60 s 才报警（原 6 s）。报警阈值原来 6 s 意味着**每次正常的慢恢复都会误报一次红横幅**。
5. **`DockWatcher` 在 Dock 进程不在时一律不采样**（`isDockPresent` 闸门，走 `dockController.isDockAlive`
   → `reloader` 的进程控制，所以测试里同样是替身）。实测缺失期间偏好域读回来是残缺内容
   （3 个图标 vs 真实 15 个），照抄进配置就把那个桌面的 override 写坏了。
   **回来之后第一次读只用来对齐基线**（`needsRebaseline`），不补回存 —— 中间态分不清是不是用户改的。
6. ⚠️ **已发生的数据损坏，而且比当时记的更严重**（2026-09-20 复查 `config.json`）：
   现在**默认 Dock `pinnedApps` 只剩 3 项**（启动台 / FlClash / WorkBuddy AI），
   **三个桌面（`计划 任务` / `密码 邮件` / `LLM`）的 override 全部为空**。
   而**真实 Dock 是健康的**：`persistent-apps` 16 项 + `persistent-others` 1 项（基准 15 + 1，
   用户后来自己加了 Qoder CN）。→ **用户下次点「立即应用」或切桌面就会把好 Dock 写坏。**
   **修代码不会自动修数据**，要用户在设置里「从当前 Dock 抓取」重抓一次（通用页 + 每个桌面）。
   损坏的**固化机制**见 `spikes.md` 实验 11.4 —— 注意它不是"读到了 Dock 死掉时的残缺域"那么简单，
   而是"Dock 活着，但被我们自己写成了残缺的，然后 Watcher 合法地把它当用户改动回存"。

**验收**：`swift build` 零警告；`swift test` **295 个测试全绿**（+5：默认阈值 2 条、Watcher 闸门 2 条、
`isDockAlive` 1 条）。⚠️ **真机复验还没做**（本会话没有再动用户的 Dock），核对口径：日志里
`Dock 不可用` 应稳定回到 100 ms 量级，且不再出现「检测到 Dock 不在…已用 launchctl 拉回」。
⚠️ **而且第一次复验（2026-09-19 用户做的）跑的是修复前的二进制** —— 见下面那一节。

### 已完成：修掉「每次右键退出都卡住几分钟」✅ 2026-09-19

用户报告：菜单栏右键 → 退出，**每次**都没有 Dock、没有壁纸、触控板失效几分钟。
根因与证据在 `docs/spikes.md` **实验 10**；规格改动见 `docs/PLAN.md` §3.3 / §3.9 / §5。
**这一节每一条都不能"改回去"。**

**先说最要紧的一条诊断结论**：用户那次"复验实验 9 的修复"跑的其实是**修复前**的二进制
（`build/MultiDock.app` 时间戳 01:07，实验 9 的 commit 在 02:11）。
所以「还是卡」既没证伪实验 9 的修复，也暴露了退出路径上同一条链没被覆盖。**改了代码必须重新
`./scripts/build-app.sh` 才算装上去** —— 以后催真机复验时要连这句一起说。

**实现要点（改动时别踩）**：

1. **退出路径不走 `reload()`**。新增 `DockReloader.reloadForQuit(strategy:deadline:)`：
   一发信号 → 最多看 `deadline`（默认 **1.5 s**）一眼 → 把结论如实带回去（`QuitRestart` 四种情况）。
   **不等 `minimumSpacing`、不升级到 SIGTERM、不 `kickstart`、失败也不重试**。
   理由写在方法自己的注释里：等归位换不到任何**可行动**的信息（偏好是原子写的，Dock 下次启动自然读到基准），
   而"升级"正是把 100 ms 滚成两分钟的那一步。`AppDelegate` 把 `restoreHandler` 接到
   `restoreToBaseline(forQuit: true)`；菜单里那个**手动**「立即还原」按钮**不能**用 forQuit
   （用户还看着屏幕，需要真正确认还原成功）。
2. **`DockController.apply(..., forQuit: true)`**：一次写入 + 一发信号 + 一次校验，**不重试**。
   重试等于再发一发信号、再吃一次 launchd 退避。
3. **`prepareForTermination` 的"上限"以前是假的**（这次最深的发现）：两处"带上限地等"都写成
   `withTaskGroup` 让 `await task.value` 与 `Task.sleep` 赛跑，**而任务组闭包返回时会等所有子任务收尾**，
   `await task.value` 那种子任务不响应取消。结果：**返回值看着是对的（20 ms 就报了 `false`），
   墙钟是错的（实测 625 ms / 224.7 ms，正好等于降级链总时长）**。
   现在两处都改成**轮询可观察标志**：`DockController.waitForIdle(upTo:)` 轮询 `drainTask`，
   `AppState.settleSelfHeal(within:)` 轮询 `selfHealFinished`（自愈任务跑完时置位 ——
   `performSelfHeal` 直接 `await apply(...)`，不经过 `drainTask`，所以代理不了它的进度）。
   **回归守卫必须断言墙钟**，只断言 Bool 抓不住这个 bug（两条守卫都带 `XCTAssertLessThan(elapsed, 200ms)`）。
4. **没起跑的待办直接 `dropPendingRequests()`**，不再是"等它跑完"。它的目标马上会被"还原到基准"取代，
   等它只是白等一次重启。注意 `request()` 是**同步**建 `drainTask` 的（`isApplying` 立刻为 true），
   所以"丢待办"之后 `waitForIdle` 仍会等到正在跑的那一笔结束 —— 它丢的是**还没起跑的目标**，
   不是取消在飞的工作。
5. **存活监视器加 `isReloading` 闸门**：我们自己正在重载 Dock 时**不采样**。
   我们的重启不是故障，抢在 launchd 前面补一发 `kickstart` 才是故障。
6. **等不到干净时必须留标记**：`prepareForTermination` 返回 `false` →
   `LifecycleController.keepMarkerAndFinish(reason: "退出时还有一次应用没落地")`（`pid = 0` + `needsSelfHeal`）。
   那笔在飞的写入可能落在还原**之后**，清掉标记等于把下次启动的自检扔掉。
   ⚠️ 这条 `!settled` 分支目前**没有**端到端单测（要一笔超过 2 s 的在飞应用）；
   `prepareForTermination` 本身返回 `false` 已由 `testPrepareForTerminationReportsUnsettledWhenAnApplyIsTooSlow`
   与 `testPrepareForTerminationBoundsTheSelfHealWait` 覆盖。
7. **`FileLogSink` 现在是 `AppState.init` 的注入参数，测试一律传 `makeTestFileLog()`**。
   以前它写死成 `~/Library/Application Support/MultiDock/multidock.log`，于是**一次 `swift test`
   就往用户那份日志里灌几千行假记录**（假 PID `100 → 1001`、假的"退出还原"），
   而 512 KB 环形截断把实验 9 的真实证据行**挤掉了**（本会话亲眼看 53–54 s 那两行，之后再也读不到）。
   用户核对真机行为**只有这一份日志**（无屏幕录制、`log show` 沙箱里读不到），把它污染等于打掉 A6/A7。
   守卫：跑全量测试后 `wc -l` 用户那份日志，行数必须不变。

**验收**：`swift build -c release --disable-sandbox` 零警告；`swift test --disable-sandbox`
**308 个测试全绿**（+13：`reloadForQuit` 4 条、退出路径 apply 4 条、监视器闸门 2 条、自愈与退出还原 3 条）。
真机复验**仍未做**（见 §6.3 A6 / A7）。


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

### 已完成：次级 Dock 条（随桌面换内容 + 冻结开关）✅ 2026-10-04

用户拍板的新功能（规格与决策见 `docs/PLAN.md` §3.12，实测依据见 `docs/spikes.md` 实验 21）。
硬约束 2 的「不自己画 Dock 栏」由用户当日修订：次级条是被批准的例外，**不替换**原生 Dock。

**实现要点（改动时别踩）**：

1. **Dock 条不是独立 CG 窗口**（15.8.1 实测：Dock 进程只有全屏 layer-20 容器窗口）。
   几何源**永远用 `NSScreen.visibleFrame` 的排他内缩**（left/right/bottom 三向；top 是菜单栏的），
   别改回 CGWindowList 找「Dock 条窗口」——那个窗口不存在，而且 CGWindowList 在 Dock 重启的
   45–90 ms 里是空的，`visibleFrame` 天然跨重启窗口。
2. **窗口层级 19 必须低于 Dock（20）**：半露 = 整条向 Dock 方向平移半个条厚，滑进 Dock 身后的
   部分靠 Dock 像素遮挡。改高于 20 会反过来盖住原生 Dock 的图标。toast 是 25（高于 Dock），
   两者的层级方向**相反**，别抄混。
3. 内缩 ≤ 8 px 视为「探测不到 Dock」（自动隐藏滑走后内缩 ≈ 0）——此时**保持现有位置**，
   不要把条挪到屏幕边缘外或按零内缩重摆。
4. 空配置判据与 `applyConfigForDesktop` 同口径：看**原始** `pinnedApps.isEmpty`。
   `DockStripRules.normalizedApps([])` 会补一枚启动台，拿它判空永远判不出来。
5. `SecondaryDockWindow` 是 toast 配方的可交互变体：`ignoresMouseEvents = false`、
   `canBecomeKey/Main` 仍必须 = false（点击启动不需要 key）。显示仍用 `orderFrontRegardless()`。
6. 冻结闸门（`AppState.applyForDesktopSwitch`）只挡**切换路径**（被动回调 + 三条预应用）；
   「立即应用」「编辑后立即应用」不走它。冻结期间 `handleUserDockEdit` 改道回存**默认 Dock**，
   不是当前桌面的绑定。
7. 几何变化走 1 s 轮询 + 屏幕变化事件；回收 hover 用 150 ms 防抖 + `NSEvent.mouseLocation`
   安全网（窗口自己动过时 exit 事件可能丢）。测试里别调 `start()`（会起真轮询任务），
   手动调 `geometryTick()`。
8. **冻结自 2026-10-04 起默认开**。冻结的「原生 Dock = 默认 Dock」语义要三处合力保证：
   启动对齐（`reestablishFrozenDockIfNeeded`，**必须排在自愈之后**——自愈先还原基准，
   对齐再冻结，删了任何一处原生 Dock 与次级条就各显一套）+ `setFreezeNativeDockSwitching`
   的两个方向（开 → 立即对齐默认 Dock；关 → 立即应用当前桌面生效配置）。
   对齐是**启动期唯一**的自动应用，内容一致时指纹短路，不产生逐桌面重启。
9. **测试 harness 里别用 `updateSettings` 预置状态**——它立刻落盘，会污染两类用例：
   断言「不落盘」的（文件不该存在）与预置 config 再 `start()` 的（被默认值覆盖）。
   要解冻/改设置的用例在 `start()` 后按需调（`AppStateDockTests.unfreeze(_:)` 的样子），
   别摊回 makeState。
10. **Dock 实际显隐没有零权限直读信号（实验 22，别再试这三条）**：`CoreDockSetAutoHideEnabled`
    只翻旗标**不改 work area**（inset 不动、Dock 不滑走——sandwich 的隐藏来自重启后 Dock 读
    旗标；`Set(false)` 的显出方向倒是实时生效）；探针窗口 `occlusionState` 在基线就抖动；
    CGWindowList 在 15.8.1 完全看不见 Dock 窗口。同步显隐的唯一可行组合 =
    face（inset）为主 + 自动隐藏态下「光标在显出带（`SecondaryDockLayout.dockArea` 外扩 8pt）」
    启发式 + 400 ms 宽限，几何轮询 200 ms。
11. **冻结模式下条是固定几何**：`SecondaryDockContentSnapshot.sizingSlots` = 所有活着的桌面
    生效配置的最大条目数、iconSize 取默认 Dock——切桌面只换内容不挪窗。改条目口径时
    `AppState.secondaryDockMaxSlots` 必须与 `SecondaryDockContentBuilder` 同口径
    （Finder 幻影 +1、`normalizedApps` 缺启动台补一枚）。未冻结（opt-out 老模式）保持
    按本桌面撑开的原规格，别顺手统一。

---


---

# 已解决问题台账（D1–D26，留档别重复查；编号接 AGENTS.md §6.3）
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
| D17 | ~~README 停在 P1 状态~~ | 用户照它操作会得到错误信息 | ✅ P5 已整篇重写，含完全卸载三步 |
| D18 | ~~编辑条竖排未实现~~ | 位置改左/右后编辑条与实际 Dock 不一致 | ✅ P5 已实现 |
| D19 | ~~孤儿绑定不清理不提示~~ | 配置越积越多 | ✅ P5 已做横幅 + 显式清理（**不自动删**） |
| D20 | ~~回存不存历史版本~~ | 误判回存后旧配置找不回 | ✅ P5 做成内存撤销栈 + 「撤销自动回存」，刻意不落盘 |
| D21 | ~~全屏过滤只有单测~~ | 每次进全屏可能误切 Dock | ✅ P5 真机回归通过（自己造全屏空间，零权限） |
| D22 | ~~切桌面想要"左右滑动"的动画~~ | 点菜单栏切桌面是硬切 | ✅ **已定性为"不做"（2026-09-18）**：程序化切空间实测 0–6 ms；四条可能的路全断（粘滞状态位 / 写后读不回的会话开关 / 签名未知会段错误的 `SLSWillSwitchSpaces` / 合成事件被拦）。**零权限 + 无痕下无解。别再试** —— 详见 §4 与 `docs/spikes.md` 实验 7 |
| D23 | ~~菜单栏只能"切下一个"，往回切要开菜单~~ | 切过头只能绕菜单 | ✅ **已解决（2026-09-18）**：`⇧+左键 = 切上一个桌面`，与"下一个"共用同一条预应用链路（`switcher.target(.previous)`），两端循环；下拉菜单同时给「上一个桌面」+ 等价提示。单测 `testPreviousDesktopPreAppliesItsOwnDock` |
| D24 | ~~逐桌面 Dock 的桌面在**回存**时会白重启一次 Dock~~ | 用户手拖图标进 Dock → 回存 → Dock 闪一下（约 50 ms），而逐桌面 Dock 正是本 App 的常态用法 | ✅ **已解决（2026-09-18）**：`DockController.apply` 原来只有一条短路，比的是「我们上次写下去的那份」（`appliedFingerprint`）—— 发生过外部改动它就**过期**了，于是"应用一份与真实 Dock 完全相同的配置"会白写一遍 + 白重启一次。实测 `PID 68667 → 68672`；**默认 Dock 那条路不中招**（回存只写配置、不应用），所以只有 override 中招。修法：加短路第 1b 条 `liveAlreadyMatches`，判据**复用 `verify` 的同一套比较**（跳过 ≡ 写了立刻验过）。修后实测 `68995 → 68995`。回归：`DockControllerTests` 4 条（`testSkipsWhenLiveDockAlreadyMatchesDespiteStaleFingerprint` / `testSkipAdoptsLiveDockSoWriteBackGateOpens` / `testDoesNotSkipWhenLiveDockDiffersFromConfig` / `testForceBypassesLiveMatchShortCircuit`）。**教训：只靠单测发现不了** —— 旧单测里 `appliedFingerprint` 与真实域永远同步，两个对象各自自洽 |
| D25 | ~~切一次桌面 → Dock / 壁纸 / 触控板手势一起没了"几分钟"~~ | 用户以为系统卡死；实际是 **Dock 进程不在 60–126 秒**（Dock 就是壁纸与空间手势的实现者） | ✅ **根因已定位并修复（2026-09-19，`docs/spikes.md` 实验 9）**：三条叠在一起的自我放大链路 —— ① `kickstart()` 里的 `waitUntilExit()` 在 launchd 退避时**把主线程冻住几十秒**（实测 54/60/64 s，判据是 500 ms 一轮的监视器两分钟只留一行日志）；② 重载超时 5 s 短于退避尺度 → 慢恢复被误判成失败 → 升级 `SIGTERM` + `kickstart -k`；③ 监视器 1 s 动手、每 2 s 催一发 `-k`，把 launchd 刚拉回来的 Dock 再杀一次。**修法**：kickstart 非阻塞且不允许叠加、超时 30 s、监视器 4 s/30 s/60 s。顺带修掉 `DockWatcher` 在 Dock 缺失期间把残缺域（3 个图标 vs 真实 15 个）回存进配置 —— 但**已写坏的两条 override 要用户重抓**（见 §3 该节第 6 条与 §6.3 A6）。回归 5 条；⚠️ 真机复验待用户（A6） |
| D26 | ~~每次菜单栏右键退出 → 没有 Dock / 没有壁纸 / 触控板失效几分钟~~ | 用户以为机器卡死；实测两次退出各 **53–54 秒** | ✅ **根因已定位并修复（2026-09-19，`docs/spikes.md` 实验 10）**：① 退出还原复用了完整降级链（等归位 30 s → SIGTERM → kickstart → 再等 30 s）；② `prepareForTermination` 那两条「带上限的等」其实是**无上限**的（`withTaskGroup` 会等不可取消的 `await task.value` 收尾 —— 返回值对、墙钟错）；③ 存活监视器在我们自己重启 Dock 期间抢着补刀。**修法**：`reloadForQuit`（一发 + 1.5 s 看一眼，不升级不 kickstart）、`apply(forQuit:)` 不重试、`dropPendingRequests()`、两处等待改成轮询可观察标志、监视器 `isReloading` 闸门、等不到干净就留标记。顺带把 `FileLogSink` 变成注入参数（单测曾把用户的诊断日志灌成 3 000 行假记录）。回归 13 条、**308 全绿**；⚠️ 真机复验待用户（A7） |

# 工程约定与防回归清单

> 2026-10-04 从 AGENTS.md 搬过来：§5、§3 各阶段的「实现要点」和 §6.3 的 D 台账（原文照搬，只有这段说明和分隔标题是新写的）。
> 改哪个模块，先看对应阶段的「改动时别踩」；踩到新坑就往这里补。
> 本文里"见 §4"指 `docs/facts.md`；"§6.3 A/B/C"指 `AGENTS.md` 未决问题；"§8"指 `docs/sessions.md`。

### 构建与运行

```bash
swift build -c release --disable-sandbox   # 编译
swift test --disable-sandbox               # 364 个测试（9 个真实 Dock 验收 + 2 个 UI 快照默认跳过）
./scripts/build-app.sh                     # 组装 build/Side Dock.app（ad-hoc 签名）
open "build/Side Dock.app"                 # 运行（必须在 .app 里跑，菜单栏图标才正常）
./scripts/check-toast-window.sh --watch 12 # 客观验收 toast（零权限，读窗口元数据）

# 真实 Dock 验收：会真的改 com.apple.dock 并重启 Dock，跑完自动还原
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests
# UI 离屏快照（零权限，出亮/暗 × 通用/桌面四张 PNG，人工核对）
MULTIDOCK_UI_SNAPSHOT=1 swift test --disable-sandbox --filter UISnapshotTests
```

- ⚠️ **必须加 `--disable-sandbox`**（2026-09-18 起）。SwiftPM 自己的 `sandbox-exec` 在本机环境里会 `sandbox_apply: Operation not permitted`，manifest 编译直接失败，报 `error: 'multi-dock': Invalid manifest`。代码没问题，加上这个参数就好。
  **`./scripts/build-app.sh` 里已经带了这个参数**（2026-09-20 补的；之前它直接调 `swift build`，一跑就失败）。
- **`swift test` 现在能跑了**：`Package.swift` 加了 `MultiDockTests` 测试目标。（旧版这里写的"会报 no tests found"已经不对了。）
- **真实 Dock 验收默认不跑**（`DockAcceptanceTests`，设环境变量才开）。它会写 `com.apple.dock`、重启 Dock 几十次，跑完再把动手前的整个域写回去；中间文件放在 `/tmp/multidock-acceptance-*.plist`。**跑的时候别手动改 Dock**，不然会报假失败。
- 想更保险，先手动备份一份：`defaults export com.apple.dock /tmp/dock-backup.plist`。
- **写 Swift 小工具要留意 stdout 缓冲**：输出重定向到文件时按块缓冲，观察类脚本得加 `setvbuf(stdout, nil, _IONBF, 0)`，不然一行都看不到（`check-toast-window.sh` 已经这么做了）。
- **长驻脚本的周期任务用 `Timer.scheduledTimer`，别用 `DispatchSourceTimer(queue: .main)`**：后者挂在 GCD main queue 上，长驻脚本要是靠 `RunLoop.main.run()` 驱动，它**一次都不 fire**（实验 25 第一轮全哑：23 条通知全收到了，轮询一次没触发，真机复现过）。非要用 GCD timer，就得 `dispatchMain()`（那样就没有 RunLoop 和通知了）。
- 要反复调用的 Swift 探测工具，**编译一次，留着复用**（`swiftc -O -o /tmp/... `），别每次都 `swift file.swift` —— 那样每次都要完整编译一遍，几十毫秒一轮的轮询根本跑不起来。
- **测 Dock 重启耗时别用 `pgrep` 轮询**：它一次就要约 110 ms，测出来的数全不准（实测把 70 ms 测成了 400 ms）。用 `NSRunningApplication`（0.6 ms）或 `proc_listpids`（0.02 ms）。
- 打包脚本用 `codesign --force --sign -`，没用计划原文写的 `--deep`（Apple 已经废弃了 `--deep`）。
- 也可以直接拿 Xcode 打开 `Package.swift`，但**别**手写 `.xcodeproj`。
- **仓库已经建好**（`git init -b main`，第一个 commit 是 `e3e359a`，见 §8）。提交签名用 1Password，**提交前先看一眼 1Password 开着、也解锁了**（见 §0）。
- **别用 `rm -rf .build/...` 清缓存**：本机的 safe-delete 保护会拦下来。想从头构建，用
  `swift build -c release --disable-sandbox --build-path /tmp/multidock-build`。

### 代码约定

- `swift-tools-version: 6.0` → 开着 **Swift 6 语言模式和严格并发检查**。现在构建**零警告零错误**，要保持住。
- 状态类用 `@Observable` + `@MainActor`。**别在 `AppState` 里再存一份空间状态**——转给 `SpaceObserver`，不然两份会对不上。
- `@convention(c)` 函数指针类型要是声明成 `private`，引用它的顶层 `let` 也得标 `private`，不然报 "uses a private type"。
- 私有 API 一律在运行时用 `dlopen` + `dlsym` 加载，**别链接私有框架**。
- 写 Dock 偏好用 `CFPreferences` API，别拼 `defaults` 命令。写法是：读出**整个**域 → 只改白名单里的键 → 一次原子写回，绝不整域替换。
- 代码里不写解释性注释；"为什么"不明显时才写。
- 加了功能就要实测验证，"编译通过就算完成"不算数。
- **给 `AppSettings` 加字段，一定要同时在它手写的 `init(from:)` 里补一行 `decodeIfPresent`**。不补的话，旧配置文件缺这个键，整份配置就解码失败，悄悄退回默认值（`ConfigStore.load()` 就是这么处理的）。
- ⚠️ **用脚本核对 `config.json` 时，先把真实键名打出来**（`print(list(d.keys()))` / `list(override.keys())`），**不要凭记忆写字段名**。2026-09-20 踩过：脚本里写的是 `o.get('apps')` / `o.get('others')`，真实键却是 **`pinnedApps` / `otherItems`**。结果"3 个图标"读成了"0 个"，"有 override"读成了"全空"，还拿这个错结论写进了本文档。**写错一个字段名，就能凭空造出一场不存在的数据损坏。** 判断"某条 override 是不是坏的"，不能只数个数，还要比**内容**：两个用途不同的桌面配出一模一样的 override，那才是坏数据的特征。
- **为了好测，拆开写**：跟 AppKit / 系统调用打交道的部分（窗口、私有 API、Dock 进程）单独放一个类型，抽出协议（`ToastPresenting`、`SpaceProviding`、`DockPreferenceAccessing`、`DockProcessControlling`）；纯逻辑放另一个类型。这样行为能单测，剩下的才靠实测。
- ⚠️⚠️ **协议要求的返回类型，实现里要一字不差地照抄 —— 差一个 `?`，整条生产路径就废了。** Swift **不按协变去匹配返回类型**：协议要求 `-> T?`，实现写成 `-> T`，编译器会把它当成**另一个重载**，协议的见证位**改由扩展里的默认实现来填**。于是 `(Real() as any P).m()` 永远返回默认值（通常是 `nil`），`Real().m()` 却正常。**用具体类型调用测不出来，替身单测照样全绿。** 2026-09-20 实测：`pidProbe()` 就是这样，A8 的取证仪表在生产路径上压根没接上。同一批排查里，`startTime(of:)` 的签名是对的，但**没有守卫测试**；哪天写错了，节流判据会悄悄从"进程年龄"退回到"我们记不记得自己重启过"（P3 验收里同一场景 **45 ms → 1030 ms**）。**规矩：每加一条带默认实现的协议要求，就在 `DockProcessSafetyTests` 里补一条用 `any 协议` 调用的守卫测试**（照着 `testRealControlIsWiredAsTheProtocolWitness` / `testRealStartTimeIsWiredAsTheProtocolWitness` 写）。怎么系统地排查，看 skill `macos-dock-space-probe`；复盘在 `docs/spikes.md` 实验 15.2。
- **`AppState` 的依赖都能注入**（`dockController` / `configStore` / `baselineStore` / `provider`）。**AppState 里也别直接调 `DockPreferences.readDomain()` 这类静态入口** —— 那样绕过了注入点，测试会读到真实系统的偏好域。要读就走 `dockController.readDomain()` / `captureLiveConfig()`。（P2 踩过：`captureCurrentDockAsDefault` 直接调了静态方法，三个单测读到了真实 Dock。）`provider` 做成可注入，是为了能把"先预应用、再切换"写成断言。
- **替身类嵌在 `@MainActor` 测试类里时，要自己标上 `@MainActor`**：嵌套类型**不继承**外层的 actor 隔离，而 `DockWatcher` 的闭包都是 `@MainActor` 的，不标就报 `call to main actor-isolated initializer in a synchronous nonisolated context`。
- **发信号、杀进程的代码，自己就要带"只碰确认过的 PID"这道闸门**，别指望调用方传对。见 §4 的 `-1` 陷阱。
- **文件末尾的 `try` / `defer` 里别阻塞主线程**：在 `@MainActor` 的异步测试里，`DispatchSemaphore.wait` 会死锁（`Task { @MainActor }` 永远排不上队）。想在收尾时还原，就写 `do { try await ... } catch { await cleanup(); throw error }` + 正常路径上明确收尾。
- **"带上限的等待"要轮询一个看得见的标志，别让 `withTaskGroup` 和 `await task.value` 赛跑**。任务组闭包返回前会等**所有**子任务收尾，而 `await task.value`（`Task<Void, Never>`）不理会取消。于是 `group.next()` 20 ms 就报了正确的 `false`，**整个函数却要等整条降级链跑完才返回**：上限悄悄失效了，返回值却还是对的。实测两处 20 ms 的上限，墙钟分别是 625 ms / 224.7 ms。写法照 `DockController.waitForIdle(upTo:)` 和 `AppState.settleSelfHeal(within:)`；**守卫测试要断言墙钟**（`XCTAssertLessThan(elapsed, …)`），只断言 Bool 抓不住。见 `docs/spikes.md` 实验 10。
- **测试里构造 `AppState` 一定要传 `makeTestFileLog()`**。`FileLogSink` 默认写 `~/Library/Application Support/MultiDock/multidock.log`，用户核对真机行为**只能**靠这份日志（没有屏幕录制，沙箱里 `log show` 也读不到）。以前没有注入点，跑一次 `swift test` 就往这份日志里灌几千行假记录；512 KB 的环形截断还会把真实证据挤掉（本会话就这样弄丢了实验 9 那两次 53–54 s 的退出记录）。自查方法：跑全量测试前后各 `wc -l` 一次，行数必须一样。

### 与计划原文的两处刻意偏离（不要"改回去"）

1. **用 `UI/MenuBarController.swift` 换掉了计划里的 `UI/MenuBarView.swift`**，程序入口用 `NSApplication`，没用 SwiftUI `App` + `MenuBarExtra`。原因：硬约束要分清左键、右键和 ⌥+左键，而 `MenuBarExtra` 把点击全吃了，做不到。设置窗口和调试面板还是 SwiftUI（装在 `NSHostingController` 里）。
2. **`DockTile.raw` 的类型是 `[String: PlistValue]`，不是计划写的 `[String: Any]`**。原因：`[String: Any]` 不满足 `Codable`，存不进 `config.json`。`PlistValue` 是个枚举，plist 的类型全覆盖，还能和 `Any` 互相转换。

### 设计文档的维护

设计和进度以 `docs/PLAN.md` 为准；P0 的实测结论在 `docs/spikes.md`。写代码时设计变了，**顺手更新 `docs/PLAN.md`**，别让文档和代码对不上。

---

# 各阶段「实现要点（改动时别踩）」

> 下面大致按时间排，最后一节是最新的次级条/冻结护栏。
> 这些阶段**都已经做完了**（需求和验收经过在 `docs/sessions.md`，设计结论在 `docs/PLAN.md`）；
> 留着这几节，是因为里面的护栏在现在的代码里**还管用**——改对应模块前一定要读。

### 已完成：P2（编辑条 + 应用）✅ 2026-09-18

**项目从这一阶段起才真正写 `com.apple.dock`。** 规格在 `docs/PLAN.md` §3.4–§3.7，验收证据在 §8 第 5 次记录。

**实现要点（改动时别踩）**：

1. **`DockController` 的顺序不能改**：指纹短路 → 备份（失败只记 `note`，不阻断）→ 读全量域 → `entries(for:restrictedTo:)` 只挑**域里真实存在**的键 → 单次原子写 → 重启 Dock → 读回校验；对不上就**最多再试一次**（`for attempt in 1...2`）。校验只比**真正写进去的键**（`comparableKeys`）；把本机没有的键也算进去，会得出假阴性。
2. **当前域里没有的键，绝不写**。本机 34 个键里，白名单中只缺 `show-process-indicators`（`autohide-delay` / `autohide-time-modifier` 读回来是 nil，根本进不了 `domainEntries`）。缺哪些由 `DockAppearance.unavailableKeys(in:)` 报出来，UI 照着禁用控件，不做"能改却没反应"的假开关。
3. **启动台条目原样留着**：`DockStripRules.normalizedApps` 先复用数组里现成的启动台条目（`GUID` / `book` / `file-mod-date` 一起留），域里没有才用 `makeLaunchpadTile()` 现做一个。早先的版本不管三七二十一直接覆盖，每编辑一次，真实域里那几个字段就被抹掉一次。
4. **`.app` 的 URL 末尾要带斜杠**（`file:///Applications/X.app/`）：`URL.absoluteString` 不带，跟真实域、跟 P0 的写入实验都对不上。一律用 `DockTile.directoryURLString(for:)`。
5. **用户 App 的 `dock-extra` 是 `true`**，启动台是 `false`（本机实测）。`makeFileTile` 默认 `true`。
6. **拖拽排序只在 `performDrop` 时存盘、应用一次**。`dropEntered` 会连着触发，所以 `AppState.setDefaultDock` 只改内存，到 `dockConfigEdited` 才存盘。不这样的话，每拖过一个图标就写一次 `config.json`、重启一次 Dock。
7. **退出时不是每次都还原**：`LifecycleController.shouldTerminate` 只在 `sessionChangedDock`（会话标记里 `appliedFingerprint != nil`）时才还原。**不能见退出就还原** —— 用户可能在运行中自己拖过图标，写回基准会把这些改动一起抹掉。另外，`AppState.restoreToBaseline` 会先比一遍白名单键，跟基准一样就跳过（省一次没必要的 Dock 重启）。
8. **`DockController.onOutcome` 是 `var`，不是 `let`**：`AppState.init` 里得先造好 controller 再挂回调（闭包要捕获 `self`），用 `let` 做不到。

### 已完成：P3（桌面页 + 自动切换）✅ 2026-09-18

规格在 `docs/PLAN.md` §3.7 / §3.8，验收证据在 §8 第 6 次记录，两个要命的发现在 `docs/spikes.md` 实验 5。

**实现要点（改动时别踩）**：

1. **预应用 = "同一拍发起"，不是"切空间前完成重启"**。`switchToNextDesktop()` / `switchToPreviousDesktop()` / `switchTo(_:)` 先 `switcher.target(_:)` 算目标 → `applyConfigForDesktop(target)` → 再 `switcher.switchTo(target)`。**在切空间前重启完，物理上就做不到**：重启约 101 ms，而 `setCurrentSpace` 实测只要 0–6 ms。能保证的只是"不用等 300 ms 的轮询"。别照字面去"纠正"这个顺序。
2. **`DockReloader.minimumSpacing`（默认 1 s）不能删**。实测离上次重启不到约 1 s 就再重启，Dock 要 **约 1070 ms** 才回来；隔满 1 s 只要约 70 ms。等的时候 Dock **能用**，所以"等一等"怎么都比"马上重启"好。实测 Dock 不可用的时间从约 1030 ms 降到了 **45–90 ms**。`ReloadOutcome.elapsed` 只算不可用的时间，`spacingWait` 另记。
3. **`RealDockProcessControl.signal(_:_:)` 的安全闸门不能删**。Dock 重启的那段时间里，`NSRunningApplication` 会返回 `processIdentifier == -1`（**实测复现过**），而 `kill(-1, SIGTERM)` 会把**当前用户的进程全杀掉**。所以设了三道防线：`dockPID()` 过滤 `> 0`、`signal()` 拒绝 `pid <= 0` 且用 `proc_name` 确认进程名、`waitForRestart` 只接受 `pid > 0`。测试在 `DockProcessSafetyTests`（全用**信号 0** 断言：闸门坏了，结果是测试失败，不会把测试进程打死）。
4. **查 Dock PID 别起 `pgrep` 子进程**（一次约 110 ms）。用 `proc_listpids` + `proc_name`（**0.02 ms**）。`DockProcessSafetyTests` 里有测试盯着平均耗时 < 20 ms。
5. **编辑器的改和存要分开**：`AppState.setDockConfigInMemory` / `setDockAppearanceInMemory` 只改内存，到 `dockEdited(_:reason:)` 才存盘，再看开关决定应不应用。`DockAppearanceEditor` 的 `onCommit` 只在**松开滑杆 / 开关值变了**时触发 —— 每帧都存盘的话，拖一下滑杆就要重启几十次 Dock。
6. **默认 Dock 和逐桌面 override 都从 `DockEditTarget` 这一个入口改**（`dockConfig(for:)` / `setDockConfigInMemory(_:for:)` / `dockEdited(_:reason:)`）。通用页和桌面页共用这一套，别各写一遍。
7. **改绑定列表只能用 `DesktopBinding.updating(_:for:_:)`**：改一条（没有就插一条），改完要是「既无名字又无 override」就删掉。改名和改 override 都走它，免得一边会删空绑定、另一边不删。
8. **`DockWatcher` 看的是"可比指纹变了，而且跟我们写下去的那份不一样"**。`appliedFingerprint == nil`（这次运行还没写过）时**什么都不做**，不然会把用户原来的 Dock 当成"该回存的改动"。`handleDockOutcome` 遇到 `.applied` 会 `acknowledge` 一次，回存时也会停掉 watcher —— 都是为了别把自己写的东西当成用户改的。
9. **`DockController.isApplying`** 用来给"预应用"写断言：`request()` 是同步建任务的，所以 `switchToNextDesktop()` 一返回就读它，必须是 `true`。

### 已完成：P4（无痕与自愈）✅ 2026-09-18

规格在 `docs/PLAN.md` §3.3 / §5，验收证据在 §8 第 7 次记录。

**实现要点（改动时别踩）**：

1. **退出还原之前，先 `await state.prepareForTermination()`**。它做三件事：停 `DockWatcher`、停存活监视器、`await dockController.waitForIdle()`。**最后一件不能省** —— `DockController.request` 是异步排队的，还原前要是还有一笔待办没落地，它会在还原**之后**才写进去，用户看到的就是"退出时还原了，Dock 却还是错的"。自愈任务也得一起等（`waitForSelfHeal()`），不然两笔写入会互相覆盖。
2. **还原失败时，会话标记一定要留着**（`LifecycleController.keepMarkerAndFinish`）。清掉标记，下次启动就没法自愈了。留标记时还要设 `marker.pid = 0` —— `detectInterruptedSession()` 会用 `kill(pid, 0)` 判断"这个标记是不是另一个还活着的实例留的"，pid 为 0 就跳过这一步。**两件事都要做**：只留标记、不改 pid，下次启动会以为"进程还活着"，把标记忽略掉（实测踩过）。
3. **自愈欠下的账要能带到下一次会话**（`SessionMarker.needsSelfHeal`）。自愈是异步的，还原到一半又崩了，这笔账不能丢：`beginSession()` 会看 `state.hasPendingSelfHeal`，把欠账写进新标记。这个字段是**可选类型** —— 老版本写的 `session.state` 里没有它，用非可选会解码失败；解码失败就等于"没有残留标记"，自愈能力就悄悄没了。
4. **`sessionChangedDock` 看的是 `marker.impliesDirtyDock`**（`appliedFingerprint != nil` **或** `needsSelfHeal == true`），不光看"这次运行写没写过" —— 上次没还完的账也算。
5. **节流窗口按 Dock 进程活了多久来算，不按我们记得什么来算**。见 §4 的"节流窗口判据"那条。这是 P4 验收时逼出来的修正。
6. **从备份恢复只写白名单键**，不整域替换。我们向来只碰白名单键，备份里其余的键跟我们无关；整域替换反倒会把用户后来改的热角、启动台网格冲回旧值 —— 那才是真破坏。真要整域恢复（Dock 让别的东西改坏了），README 里写了 `defaults import` 的做法。
7. **白名单之外只有 `mru-spaces` 能写**，而且只给它一个专用方法（`DockPreferences.writeMRUSpaces(_:)`），**不开**通用的"写任意键"口子。写完以后 `DockController.apply` **不管**它，得另外调 `dockController.reloadOnly()` 重启一次 Dock 才生效。
8. **登录时启动的状态归系统管**（`SMAppService` / LaunchAgent plist），**不存进 `config.json`** —— 本地再存一份，早晚和系统对不上。不在 `.app` 里跑时（`swift test`），`SMAppService.mainApp` 拿不到有效句柄，所以 `LoginItem.isAvailable` 先看 bundle，用不了就照实显示原因。
9. **注销、关机时系统不给我们留时间**，只能尽力而为：先把欠账写进标记，再发起一次还原，等它跑完；没跑完的交给下次启动的自愈。**别**改成"同步阻塞着等还原"，那会拖住关机。
10. **短路有两条，少一条都不行**（P4 收尾做真机验收时挖出来的 bug，见 §6.3 D24）。第 1 条比的是「**我们上次写下去的那份**」（`appliedFingerprint`），第 1b 条比的是「**真实 Dock 现在长什么样**」（`liveAlreadyMatches`）。只有第 1 条的话，一旦有过**外部改动**（用户手拖、别的 App 改、或者 `DockWatcher` 刚回存的那份），它就过期了；这时再应用一份跟真实 Dock 一模一样的配置，会**白写一遍、白重启一次 Dock**。1b **必须用 `verify` 那同一套比较**，这样"跳过"就严格等于"写完立刻验过"，不会漏写。短路时调 `adoptLiveDockAsApplied()` —— 它会顺便填上 `appliedComparableFingerprint`，也就是打开 `DockWatcher` 的回存闸门；**它故意不设 `appliedAt`**（这份不是我们写的，不该算成"我们刚写完"）。

### 已完成：P5（收尾）✅ 2026-09-18

规格在 `docs/PLAN.md` §4 P5，验收证据在 §8 第 9 次记录。

**实现要点（改动时别踩）**：

1. **README 整篇重写了**（原来停在 P1 的状态，会误导用户）。里面写了彻底卸载的三步：退出还原 → 关登录项 → 删数据目录；
   还给了整域还原的做法 `defaults import baseline.plist` + `kill -HUP $(pgrep -x Dock)`，并写明这是**整域替换**（热角也会一起退回去）。
2. **显示器配置一变，就重读桌面列表**（`AppState.handleScreenParametersChanged`，`AppDelegate` 收到
   `NSApplication.didChangeScreenParametersNotification` 时调它）。多显示器时 `displayUUID` 是映射键的一部分，
   插拔后不刷新就会串行。**只刷新，不主动应用 Dock** —— 屏幕刚变时活动空间还没定下来，交给 300 ms 的轮询慢慢收敛。
3. **全屏过滤在真机上回归过了**：`scripts/check-fullscreen-filter.swift` 把**自己进程的一个窗口切成全屏**
   （是自己的窗口，不要权限），SkyLight 就多出一个 `type=4` 空间，这样就能真刀真枪地验证过滤。实测结论见 §4。
4. **编辑条能竖着排了**（`DockStripEditor.isVertical`）：`orientation != "bottom"` 时换成 `ScrollView(.vertical)` + `VStack`，
   格子高度由 `SlotSizing` 定。以前位置改到左边或右边，编辑条还是横的，排序会看反。
5. **孤儿绑定只提示，绝不自动清理**（`AppState.orphanedBindings` / `pruneOrphanedBindings`）。
   ⚠️ **自动删是错的**：拔掉外接显示器，那台显示器上的桌面会整个消失，绑定看上去就成了孤儿 —— 可插回去还要用。
   所以桌面页上放横幅 + 「清理」按钮 + 二次确认。
6. **回存历史放在内存里的撤销栈，不存盘**（`Dock/DockEditHistory.swift`）。计划原文说"覆盖前存一份历史版本"，
   可存一堆没有恢复入口的文件只是摆设 —— 用户翻到 `history/` 也用不上。真正长期保命的是 `baseline.plist` 和 `backups/`。
   回存要防的是"误判一次，把配置写坏"，能撤一步就够了，所以做成 UI 上的「撤销自动回存」按钮（每个目标 5 层）。
   撤销后 watcher 不会马上又触发 —— 它只在真实 Dock 的指纹变了才回调，而撤销改的是配置，没动 Dock。

### 已完成：P5+（UI 报警补完）✅ 2026-09-18

规格在 `docs/PLAN.md` §3.1 末段和 §3.9 第 3 条，验收证据在 §8 第 12 次记录。

计划里有两处要求"在 UI 明确报警，而不是静默失效"，原来都只写了日志和调试面板 ——
**用户不看日志，等于没报警**。现在都统一放到设置窗口顶部的 `WarningBanner`（`UI/SettingsView.swift`）。

**实现要点（改动时别踩）**：

1. **报不报警看"连续缺了几轮"，不看 `kickstart()` 的返回值。** 那个返回值只能说明 `launchctl` 命令跑起来了，
   **说明不了 Dock 回来了**。所以 `DockPresenceMonitor` 数的是连续缺了多少轮，到了
   `persistentFailureThreshold`（默认 12 轮 × 500 ms ≈ 6 秒）才回调一次。
2. **边沿触发，只报一次。** `isPersistentlyDown` 只在越过阈值的那一刻翻转；之后一直缺也不再回调 ——
   每轮都报，日志和 UI 都会被刷爆。Dock 回来后清掉标志，回调一次 `onRevived`。
3. **阈值硬性大于 `missThreshold`**（`max(missThreshold + 1, …)`）。传反了的话，"还没到该动手的轮数"
   就先喊拉不回来了。这是配置错误，不能让它成立。
4. **回调用 `var`，不用 init 参数**，这点跟 `log` 出口不一样：这两个回调改的是 **`AppState` 自己的状态**，
   得由 `AppState` 每次都挂上 —— 监视器可能是测试里先造好再注入的，那时没人填 init 参数。
   `log` 是监视器自己的出口，注入时别覆盖它。
5. **`retryDockRevival()` 返回成功，不等于 Dock 回来了** —— 只说明 `launchctl` 跑起来了。
   所以点完按钮**别急着撤报警**，等监视器下一轮轮询来判断。
6. **两条横幅都空时，整个视图不占地方**，正常状态下不会留一条空白。

**验收**：新增 12 条单测（`DockPresenceMonitorTests` 5 条 + 新文件 `DockFailureWarningTests` 7 条），
再加一条真机反向守卫 `DockAcceptanceTests.testHealthyRealDockNeverRaisesPersistentFailure`
（**只读**：真跑 40 轮 `dockPID()`，断言 Dock 健康时一次都不误报）。

⚠️ **"拉不回来"这条真机路径没法想触发就触发** —— 本机的 `launchctl kickstart` 一直管用，
Dock 一杀就回来，所以红横幅在本机复现不了。逻辑有单测覆盖，渲染没做视觉验证（本机没有屏幕录制权限）。

### 已完成：P5++（计划缺口收口）✅ 2026-09-18

用户让"检查计划看还有哪些功能没实现"，于是把计划里**写明了、代码里却没有**的三处补上，顺手改了文档里过时的几行。
规格在 `docs/PLAN.md` §3.4 / §3.6 / §3.7 的 P5++ 记录里；实测依据在 `docs/spikes.md` **实验 8**。

**实现要点（改动时别踩）**：

1. **其他项（`persistent-others`）只"搬"，不"造"**。编辑器里加了一条「其他项（文件夹 / 堆栈）」：
   能显示、排序（`OthersReorderDropDelegate`）、移除（右键菜单，或者拖进和图标条**共用**的垃圾桶 ——
   `RemoveDropDelegate` 接两个 `@Binding`，按归一化键判断从哪个数组里删）。
   写回去的就是 Dock 自己写的 dict，`GUID` / `book` 原样保留（真机验收已经确认了这一点）。
2. **⚠️ 千万别"顺手"加新建文件夹 / 文件的功能。** `docs/spikes.md` 实验 8 实测：自己拼的 `directory-tile`
   **Dock 不认**（Dock 不会补 `GUID`；把展示字段补全、甚至自己用 `URL.bookmarkData()` 生成 `book` 都没用），
   而且**字段不全时 Dock 会直接 SIGABRT，陷进崩溃循环**（本机实测 7 份崩溃报告，用户当场就没了 Dock）。
   回归守卫：`DockStripRulesTests.testDockItemRejectionClosesTheFolderAndFilePaths`。
   **换个做法**（已写进 UI 文案）：让用户自己在访达里把文件夹拖到 Dock 上 —— Dock 会写出完整的条目（带 `book`），
   接着 `DockWatcher` 把它回存进当前桌面的配置，之后就能在编辑器里排序、移除了。
3. **拖进来被拒了，要告诉用户**（`DockItemRejection.message` + 「知道了」按钮）。早先的版本拖文件夹进来是**悄悄失败**，
   用户只会以为程序坏了。
4. **`normalizedOthers` 只去重，不插固定项**。只有 `persistent-apps` 才要"保证启动台排第一"。
5. **显示器名映射**（`Spaces/ScreenNaming.swift`）：`CGDisplayCreateUUIDFromDisplayID` + `NSScreen.localizedName`，
   跟 SkyLight 的 `Display Identifier` 用的是同一套换算（§4 实测过，逐字符一样）。纯解析部分能单测；
   `currentScreens()` 是 `@MainActor`。**对不上时就照实说"未识别显示器（UUID 前 8 位…）"，
   别退而显示某台真实显示器的名字** —— 显示错的屏，比显示"未识别"更糟。
   结果缓存在 `AppState.displayScreens`，启动时和收到 `didChangeScreenParametersNotification` 时刷新；
   **别在视图渲染时现取 `NSScreen`**。
6. **`persistent-others = []` 是安全的**（实验 8 的实验 5：SIGHUP 后 0.6 s 回来），所以「移除最后一项」不加限制。
7. ~~**反复杀 Dock 会让 launchd 进入递增退避**：验收脚本连杀几十次就会踩到，App 正常使用不受影响。~~
   **这里说的"不受影响"是错的**（2026-09-19 实验 9 推翻了它）：App 正常用**就会**踩到 ——
   一次稍慢的恢复，被我们自己又续上了退避，实测每切一次 Dock 就消失 60–126 秒。见下面「已完成：修掉切桌面黑屏」。

### 已完成：修掉「切一次桌面黑屏几分钟」✅ 2026-09-19

用户反馈：从桌面 1 切到 2 以后，Dock 没了、壁纸没了、触控板手势也失灵，持续几分钟。根因和全部证据在
`docs/spikes.md` **实验 9**；规格改动在 `docs/PLAN.md` §3.4 / §3.8 / §3.9。**这一节的六条一条都不能"改回去"。**

**实现要点（改动时别踩）**：

1. **`RealDockProcessControl.kickstart()` 绝不能 `waitUntilExit()`。** launchd 在退避时，
   `/bin/launchctl kickstart` 会**一直卡到真能把服务拉起来为止**（实测 54 / 60 / 64 秒），而这条调用跑在
   `@MainActor` 上 —— 整个 App 跟着冻住（证据：500 ms 一轮的存活监视器，两分钟里只留下一行日志）。
   现在是发完就走，`Process` 交给 `LaunchctlParking` 一直拿到退出（不然子进程还活着，对象就先释放了）。
2. **上一个 launchctl 还没完，不许再发**（`hasOutstanding` 直接返回 false）。`kickstart -k` 的 `-k` 会杀掉
   launchd 刚拉回来的 Dock，等于自己给自己续退避。
3. **`DockReloader.timeout` 从 5 s 提到了 30 s。** 超时要按 **launchd 退避的量级**来定（几十秒），
   不能按"我们觉得该好了"来定。设成 5 s 时，一次正常的慢恢复会误判成 SIGHUP 失败 → 升级成 SIGTERM+kickstart → 越弄越糟。
4. **存活监视器的三档节奏都放慢了**：缺满 4 s 才动手（原来 1 s）、每 30 s 才催一次（原来 2 s）、
   满 60 s 才报警（原来 6 s）。报警阈值原来是 6 s，结果**每次正常的慢恢复都会误报一次红横幅**。
5. **Dock 进程不在时，`DockWatcher` 一律不采样**（`isDockPresent` 闸门，经 `dockController.isDockAlive`
   → `reloader` 的进程控制，所以测试里这里也是替身）。实测 Dock 不在时，偏好域读回来是残缺的
   （3 个图标，真实是 15 个），照抄进配置，那个桌面的 override 就写坏了。
   **Dock 回来后第一次读，只拿来对齐基线**（`needsRebaseline`），不补回存 —— 中间状态分不清是不是用户改的。
6. ⚠️ **这条链路曾经写坏过一次数据，已经修好（2026-09-20 复核）**：当时默认 Dock 只剩 3 项，
   三个桌面的 override 全空，而真实 Dock 是 15+1；用户手动「从当前 Dock 抓取」之后，配置恢复正常
   （**现在**：默认 15 个图标，3 条绑定各有独立 override = 4/15/15，全是 `bottom`；2026-10-04 又核对过）。
   坏数据是**怎么固化下来的**，见 `spikes.md` 实验 11.4 —— 它不只是"Dock 死掉时读到了残缺的域"，
   而是"Dock 活着，却被我们自己写残了，接着 Watcher 按规矩把它当成用户改动回存了"。
   **回归防线**：`DockWatcher` 的 `isDockPresent` 闸门 + `appliedFingerprint` 判据 + 回存前停 watcher。

**验收**：`swift build` 零警告；`swift test` **295 个测试全绿**（+5：默认阈值 2 条、Watcher 闸门 2 条、
`isDockAlive` 1 条）。✅ **真机复验做过了（2026-09-20 复盘用户日志）**：`Dock 不可用` 稳定回到
50–126 ms 这个量级，再没出现「检测到 Dock 不在…已用 launchctl 拉回」。
⚠️ **不过第一次复验（2026-09-19 用户做的）用的是修复前的二进制** —— 见下一节。

### 已完成：修掉「每次右键退出都卡住几分钟」✅ 2026-09-19

用户反馈：菜单栏右键 → 退出，**每次**都是 Dock 没了、壁纸没了、触控板失灵，持续几分钟。
根因和证据在 `docs/spikes.md` **实验 10**；规格改动在 `docs/PLAN.md` §3.3 / §3.9 / §5。
**这一节每一条都不能"改回去"。**

**先说最要紧的诊断结论**：用户那次"复验实验 9 的修复"，跑的其实是**修复前**的二进制
（`build/MultiDock.app` 时间戳 01:07，实验 9 的 commit 是 02:11）。
所以「还是卡」推翻不了实验 9 的修复，但它也暴露出：退出路径上的同一条链没修到。**改完代码要重新
`./scripts/build-app.sh`，才算装上了** —— 以后请用户做真机复验，要把这句一起说清楚。

**实现要点（改动时别踩）**：

1. **退出时不走 `reload()`**。新加了 `DockReloader.reloadForQuit(strategy:deadline:)`：
   发一次信号 → 最多等 `deadline`（默认 **1.5 s**）看一眼 → 结果照实带回去（`QuitRestart` 有四种情况）。
   **不等 `minimumSpacing`、不升级到 SIGTERM、不 `kickstart`、失败也不重试**。
   理由写在这个方法的注释里：等 Dock 回来，换不到任何**能据此行动**的信息（偏好是原子写的，Dock 下次启动自然会读到基准）；
   而"升级"恰恰是把 100 ms 滚成两分钟的那一步。`AppDelegate` 把 `restoreHandler` 接到
   `restoreToBaseline(forQuit: true)`；菜单里那个**手动**的「立即还原」按钮**不能**用 forQuit
   （用户还盯着屏幕，得真正确认还原成功）。
2. **`DockController.apply(..., forQuit: true)`**：写一次 + 发一次信号 + 校验一次，**不重试**。
   重试就是再发一次信号，再挨一次 launchd 退避。
3. **`prepareForTermination` 的"上限"以前是假的**（这次挖得最深的发现）：两处"带上限地等"，写法都是
   用 `withTaskGroup` 让 `await task.value` 和 `Task.sleep` 赛跑，**可任务组闭包返回前会等所有子任务收尾**，
   而 `await task.value` 这种子任务不理会取消。结果：**返回值看着没错（20 ms 就报了 `false`），
   墙钟却不对（实测 625 ms / 224.7 ms，刚好等于整条降级链的时长）**。
   现在两处都改成了**轮询看得见的标志**：`DockController.waitForIdle(upTo:)` 轮询 `drainTask`，
   `AppState.settleSelfHeal(within:)` 轮询 `selfHealFinished`（自愈任务跑完时置位 ——
   `performSelfHeal` 直接 `await apply(...)`，不经过 `drainTask`，所以从那里看不出它的进度）。
   **回归守卫要断言墙钟**，只断言 Bool 抓不住这个 bug（两条守卫都带 `XCTAssertLessThan(elapsed, 200ms)`）。
4. **还没开跑的待办，直接 `dropPendingRequests()`**，不再"等它跑完"。它的目标马上就要换成"还原到基准"，
   等它只是白等一次重启。注意 `request()` 是**同步**建 `drainTask` 的（`isApplying` 马上变 true），
   所以"丢掉待办"以后，`waitForIdle` 还是会等正在跑的那一笔结束 —— 丢的是**还没开跑的目标**，
   正在跑的工作不会被取消。
5. **存活监视器加了 `isReloading` 闸门**：我们自己正在重载 Dock 时，**不采样**。
   我们重启 Dock 不是故障；抢在 launchd 前面再补一发 `kickstart`，那才是故障。
6. **没等到干净，就一定要留标记**：`prepareForTermination` 返回 `false` →
   `LifecycleController.keepMarkerAndFinish(reason: "退出时还有一次应用没落地")`（`pid = 0` + `needsSelfHeal`）。
   那笔还在路上的写入可能落在还原**之后**，清掉标记，下次启动就不会自检了。
   ⚠️ 这条 `!settled` 分支现在**还没有**端到端单测（得造一笔超过 2 s 还没落地的应用）；
   `prepareForTermination` 本身返回 `false` 这件事，已经由 `testPrepareForTerminationReportsUnsettledWhenAnApplyIsTooSlow`
   和 `testPrepareForTerminationBoundsTheSelfHealWait` 覆盖了。
7. **`FileLogSink` 现在是 `AppState.init` 的注入参数，测试一律传 `makeTestFileLog()`**。
   以前它写死成 `~/Library/Application Support/MultiDock/multidock.log`，于是**跑一次 `swift test`，
   用户那份日志里就多出几千行假记录**（假 PID `100 → 1001`、假的"退出还原"），
   而 512 KB 的环形截断把实验 9 的真实证据**挤掉了**（本会话亲眼看到过 53–54 s 那两行，之后就再也读不到了）。
   用户核对真机行为**只有这一份日志**（没有屏幕录制，沙箱里 `log show` 也读不到），日志脏了，A6/A7 就没法验了。
   守卫：跑完全量测试后 `wc -l` 用户那份日志，行数必须没变。

**验收**：`swift build -c release --disable-sandbox` 零警告；`swift test --disable-sandbox`
**308 个测试全绿**（+13：`reloadForQuit` 4 条、退出路径 apply 4 条、监视器闸门 2 条、自愈与退出还原 3 条）。
✅ **真机复验做过了（2026-09-20 复盘用户日志，A7 销账）**：`退出还原流程结束，用时 0.01s`
（旧版要 53–54 s），整个退出约 2 s。


### 已完成：P2.5（桌面命名 + 切换 toast，不写 Dock）✅ 2026-09-18

这是用户明确要的功能，又完全不碰 Dock，所以插到 P2 前面先做了。规格和验收证据在 `docs/PLAN.md` §3.10 / §4。

**实现要点（改动时别踩）**：

1. 命名**只走** `DesktopNaming`（`Spaces/`）：`normalize`（CRLF/换行变成空格 → 去掉首尾空白 → 按字素簇截到 10）、`displayName(for:bindings:)`、`updatingBindings`（改名只动 `customName`，**不碰 `override`**；名字清空、又没有 override 时，整条绑定删掉）。
2. **UI 一律走 `AppState.displayName(for:)`**，别再直接用 `space.displayName`（那只是序号名「桌面 N」）。已经换掉的有：菜单栏下拉、日志、设置页、调试面板。
3. **改名输入框不边打边截**：中文输入法还在组字时改绑定值，会打断候选词。草稿放在 SwiftUI 本地的 `@State` 里，回车或失焦时再归一化提交；计数实时显示 `n/10`。
4. **`AppSettings` 改成了手写 `init(from:)`**，每个字段用 `decodeIfPresent`，缺了就用默认值。原因：自动合成的解码器碰到旧配置文件里没有的新键会抛错，而 `ConfigStore.load()` 一失败就返回**整份默认配置** → 用户原有的设置就悄悄清空了。**以后每加一个设置字段，都要在这里补一行。**
5. toast 只从 `SpaceObserver.onActiveSpaceChanged` 这一处触发；`ToastPresenter` 用 `lastDesktop` 记账，**进全屏空间（nil）时它也清成 nil**，所以「启动首次采样」和「从全屏退回桌面」都不弹。开关关着时**也要记账**（不然一打开开关就会补弹一次）。
6. `DesktopNameToastWindow` 的窗口属性是硬约束：`collectionBehavior` 必须带 `.canJoinAllSpaces` + `.fullScreenAuxiliary`（少了的话只在它自己所在的空间显示，切过去反倒看不见）、`canBecomeKey`/`canBecomeMain` = false、`ignoresMouseEvents` = true、`level = .statusBar`、用 `orderFrontRegardless()` 显示。

---

### 已完成：次级 Dock 条（随桌面换内容 + 冻结开关）✅ 2026-10-04

这是用户拍板要做的新功能（规格和决策在 `docs/PLAN.md` §3.12，实测依据在 `docs/spikes.md` 实验 21）。
硬约束 2 原本是「不自己画 Dock 栏」，用户当天改了：次级条是特批的例外，**不替换**原生 Dock。

**实现要点（改动时别踩）**：

1. **Dock 条不是单独的 CG 窗口**（15.8.1 实测：Dock 进程只有一个全屏的 layer-20 容器窗口）。
   位置尺寸**一律从 `NSScreen.visibleFrame` 让出来的那一圈算**（left/right/bottom 三个方向；top 归菜单栏），
   别改回去用 CGWindowList 找「Dock 条窗口」——根本没有这个窗口；而且 Dock 重启那
   45–90 ms 里 CGWindowList 是空的，`visibleFrame` 却不受重启影响。
2. **窗口层级 19，一定要比 Dock（20）低**：半露就是把整条往 Dock 方向挪 `tuckRatio`（0.8，2026-10-06
   用户从 0.5 调深的）个条厚，滑到 Dock 后面的那截由 Dock 的像素挡住（滑入量取整点，半露的边不会落在
   半像素上；**独立贴边的半露是另一套**——按用户规格固定滑出屏幕一半，不看 `tuckRatio`）。
   调到 20 以上，反过来会盖住原生 Dock 的图标。toast 是 25（比 Dock 高），
   两者的层级方向**正相反**，别抄混了。
3. 内缩 ≤ 8 px 就当作「探测不到 Dock」（自动隐藏滑走后，内缩 ≈ 0）——这时**位置不动**，
   别把条挪到屏幕外，也别按零内缩重新摆。
4. 判断空配置的口径跟 `applyConfigForDesktop` 一样：看**原始的** `pinnedApps.isEmpty`。
   `DockStripRules.normalizedApps([])` 会补一个启动台，拿它判空，永远判不出来。
5. `SecondaryDockWindow` 就是 toast 那套配方的可交互版：`ignoresMouseEvents = false`，
   `canBecomeKey/Main` 还是必须 = false（点一下启动 App 用不着 key）。显示也还是用 `orderFrontRegardless()`。
6. 冻结闸门（`AppState.applyForDesktopSwitch`）只拦**切换路径**（被动回调 + 三条预应用）；
   「立即应用」「编辑后立即应用」不经过它。冻结时 `handleUserDockEdit` 改成回存到**默认 Dock**，
   不回存到当前桌面的绑定。
7. 位置变化靠 1 s 轮询 + 屏幕变化事件来发现；hover 收回用 150 ms 防抖，再拿 `NSEvent.mouseLocation`
   兜底（窗口自己挪过时，exit 事件可能收不到）。测试里别调 `start()`（会起真的轮询任务），
   手动调 `geometryTick()`。
8. **从 2026-10-04 起，冻结默认打开**。冻结的意思是「原生 Dock = 默认 Dock」，要三处一起才保得住：
   启动时对齐（`reestablishFrozenDockIfNeeded`，**一定排在自愈后面**——先自愈还原基准，
   再对齐、冻结；少了哪一处，原生 Dock 和次级条就各显示各的）+ `setFreezeNativeDockSwitching`
   的两个方向（打开 → 马上对齐默认 Dock；关掉 → 马上应用当前桌面实际生效的配置）。
   启动时**只有对齐这一次**自动应用；内容一样就被指纹短路，不会逐桌面重启。
9. **测试 harness 里别用 `updateSettings` 预置状态**——它马上存盘，会搞坏两类用例：
   断言「不落盘」的（文件本不该存在），和先预置 config 再 `start()` 的（会被默认值盖掉）。
   要解冻或改设置的用例，在 `start()` 之后按需调（照 `AppStateDockTests.unfreeze(_:)` 那样），
   别塞回 makeState 里。
10. **不要权限的话，读不到 Dock 此刻是显示还是隐藏（实验 22，这三条别再试了）**：`CoreDockSetAutoHideEnabled`
    只翻旗标，**不改 work area**（inset 不变，Dock 也不滑走——sandwich 能隐藏，是因为重启后 Dock 读了
    旗标；倒是 `Set(false)` 往显示那边翻是立刻生效的）；探针窗口的 `occlusionState` 在基线上就在抖；
    15.8.1 上 CGWindowList 根本看不到 Dock 窗口。要同步显隐，能用的只有这一套组合：
    以 face（inset）为主 + 自动隐藏时用「光标在显出带（`SecondaryDockLayout.dockArea` 外扩 8pt）」
    来推测 + 400 ms 宽限，位置轮询 200 ms 一次。
11. **条宽跟着本桌面的内容变（2026-10-05 用户改的，v3.6.2 的固定槽位作废）**：
    `SecondaryDockLayout.barSize` 按 `content.items.count` 撑开；iconSize 在冻结模式下取默认
    Dock 的，没冻结就取这个桌面配置里的。当初「固定槽位防切桌面跳变」的理由，在方案 ② 下不成立了——切桌面时
    条一定会「沉没位再升起」，宽度在沉下去的位置悄悄变完（`sizingSlots` 字段和
    `AppState.secondaryDockMaxSlots` 都删了，别照旧结论加回来）。~~改条目口径时记得
    `SecondaryDockContentBuilder` 的 Finder 幻影（+1）与 `normalizedApps` 缺启动台补一枚
    会改变条宽。~~ **2026-10-06 更新：Finder 幻影和补启动台都去掉了**（栏里不固定任何 App，
    条的内容和栏的内容 1:1 一样）——这条旧提醒作废。
12. **「手势切换时条不滑动」，不要权限就做不到（实验 24，窗口配方别再试了）**：改窗口层级
    （`CGSSetWindowLevel` 20/24/25）、照抄原生 Dock 的 `CGSSetWindowTags`、
    `CGSSetWindowWorkspace`（15.8.1 上没有）、每个空间放一个独立窗口，真人手测全都不行——
    这个特权来自**进程身份**，改窗口属性解决不了。**现在按用户拍板（2026-10-05）做的是方案 ②**：
    常态配方 `[.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]`——
    只属于一个空间，切换的一瞬间条留在旧空间（跟着过渡动画淡出，移到 ≈0.25 倍屏宽时完全消失，时机由系统定，
    我们改不了——实验 25）；`SecondaryDockWindow.pullToActiveSpace()` = 置透明、frame 跳到
    沉没位（`visibleFrame` 底边以下，拉回来那一下直接跳过去，看不出来）→ 临时 `.canJoinAllSpaces` +
    `orderFrontRegardless`（在当前空间重新注册）→ 16 ms 后设回单空间 → **0.12 s 升回原位
    + 同时淡入**（实验 25 的用户规格：切换后整体感觉 ≤ 0.15 s；连着切时，复位任务会自己取消）。拉不拉由
    `SecondaryDockController.spaceDidChange` 把关：只有「换了空间 && 切换前后都在显示」才拉
    （同一空间重复来的事件、进出全屏、从隐藏恢复都不拉，免得淡入叠在一起闪烁）。判断上的教训：`CGWindowList`
    说「在屏」，证明不了「动画期间不滑动」，这种事只能真人用手势实测。

### 2026-10-05 设置窗口重构的新坑（v4 内容模型：默认 Dock 自动生成 + Dock 栏实体）

1. **SwiftUI menu `Picker` 的行标签里塞自定义视图（HStack + 图片），会画成一整块高亮色**——
   收起时什么都看不出来（桌面下拉第一次带图就是这样）。**缩略图放到 Picker 外面**一直显示，
   菜单行只放纯文本。2026-10-06 起桌面下拉改用 **`Menu` + `Toggle`**（关闭态短文案
   = 桌面名，菜单行「桌面名 · 显示器名」+ 勾选）：`Picker` 收起时和菜单行用的是同一个视图，
   显示器名一长，收起态就被撑出省略号（而且没有勾选态）——凡是"菜单行要显示的东西
   比收起态多"的地方，都是这个道理。
2. **`DockConfig` 里已经没有外观了**：应用时**只写内容键**（`DockController.entries`）；三明治的
   显出参数改成读**域里当前的 `autohide`**（配置里不再带）。**还原时一定要经
   `apply(extraEntries:)` 把基准里的外观键一起写回去**（旧版本写过外观，这样才能不留痕）；
   **从历史备份恢复只覆盖内容键**（备份是用来把 Dock 拉回能用的状态，不该冲掉系统外观）。
3. **默认 Dock 是运行时生成的**（`AppState.rebuildDefaultDock` → `RecentAppsScanner`）：
   归一化时把**启动台补在第一位**（不然冻结的原生 Dock 会少了启动台）；config.json 只存
   `defaultDockAppCount`。**所以冻结模式下，启动对齐默认会真写一次 Dock**——单测里
   start() 之后先 `waitForIdle`，再取 writeCount 基线，别以为"启动时一次都不写"。
4. **测试夹具的时序坑**：makeState 里在 start 之前调 `updateSettings`（解冻），会**存盘，把
   预置的 config.json 盖掉**——要在 start() 前预置配置的用例，得在 makeState **之后**再 save。
5. **迁移时存盘的顺序**：`loadConfiguration` 迁移完马上 `persistConfiguration()`，会把
   `self.bindings`（这时还是空的）写进去，桌面名就丢了——要先把归一化后的 bindings 赋给
   实例属性，再存盘。
6. **去掉外观后，`DockController.entries` 成了纯函数**，标了 `nonisolated`（DockController 是
   `@MainActor`，静态方法默认跟着继承隔离，非隔离的测试就调不到它）。
7. **face == nil（自动隐藏）时，判断次级条「附着 vs 独立贴边」，要拿 `lastFaceOrientation`
   兜底**——不然本该跟着 Dock 隐藏的附着条，会在 Dock 滑走的一瞬间误判成独立贴边、"常驻"在屏上
   （`SecondaryDockController.applyCurrentState` 的 `rememberedAttached` 分支）。
8. **环境变了（台前调度 / 原生 Dock 的位置），系统不发通知**，只能轮询：`AppState` 每 2 s 查一次
   （`EnvironmentReading`：读一次 CFPreferences + 扫一次 NSScreen，开销可以忽略），
   打开设置窗口时再马上查一次。**别等通知**——压根没有；也别为这个去要权限。

### 2026-10-06 手势预隐藏的新坑（实验 27：type 30 → 切桌面前一拍隐藏次级条）

1. **`window.animator().alphaValue` 在 `SecondaryDockWindow` 上会随机悄悄失效**——动画组
   跑完，alpha 停在 0.0，不报错也没异常（26e 实测：九次超时渐回，七次卡住；26d 的「MC/Launchpad 后
   条永久消失」也是这个原因，当时还没有安全网能救）。**本 App 所有 alpha 渐变都分步直接设**
   （`fadeAlpha`：6 步 × 20 ms，一步步写 `alphaValue`），别改回 animator；frame 的 animator
   （0.12 s 升起）实测靠得住，留着。分步任务被取消时 alpha 会停在半路——调用方
   （预隐藏/拉回）马上会把它置 0，不留残影。
2. **listen-only `CGEventTap` 什么情况下不用授权（15.8.1 实测）**：mask 里**不带键盘事件**
   （type 10/11/12），`tapCreate` 就能成功，也不弹权限框；`.listenOnly` + `.cghidEventTap` +
   主 run loop `.commonModes` → 回调一定在主线程（`MainActor.assumeIsolated` 很稳）。mask
   故意只放 bit 30 这一位——29 是每秒约 ~200 条的环境采样流，加进来回调会被刷爆。系统会因为超时
   把 tap 禁掉，回调里要处理 `.tapDisabledByTimeout`，自己恢复；创建失败就 3 s 后重试。
3. **type 30 是三指/四指切桌面之前的手势特征**：翻转前 ~620 ms 内一定出现（13 次手势次次都有），
   用 ⌃→ 键盘切换时一个 30 都没有；两指滚动（22）、翻页（31）、MC 捏合（29 带 110=32）都不会触发。
   **别按字段设门槛**——138 像是手指数（三指=3，四指可能=4），按字段过滤会漏掉手势。真正的切换
   发生在最后一个 30 之后 550–650 ms，**600 ms 的超时别缩短**；连着做手势时，每来一个新的 30 就重新挂超时。
4. **安全网的条件不能跟模式挂钩**：独立贴边半露时，frame 本来就在屏幕外，**不能拿「frame
   出屏」当故障**；只看两个信号：`!isOnActiveSpace`，以及「非预隐藏 && alpha < 0.99」。
   预隐藏时这两个信号都不算（翻转前窗口还在当前空间，α=0 本来就是预期状态，30 也一直在续命）。静默期
   250 ms，连续没恢复就把退避翻倍（500 ms）。拉回复位用 `intendedFrame`（`setFrame` 时记下的
   目标位置，包括动画终点）——安全网出手时，`window.frame` 恰好是沉下去时的废值，别用它。
5. **预隐藏和现有路径怎么配合**：预隐藏时不响应 hover（`hoverChanged` 开头 guard 掉）；
   `hide()` 要清掉预隐藏状态，把 alpha 分步拉回 1，不然下次 `orderFront` 拿到的是个隐形窗口；
   `spaceDidChange` 翻转时，要取消超时任务，清掉预隐藏标记和退避计数。

### 2026-10-06 次级条右键菜单的新坑（屏幕位置快捷切换）

1. **`NSMenuItem` 的 target 是 assign（不持有）**——拿临时对象当 target，菜单还没弹出它就
   释放了，点了没反应，也不报错（编译通过，其他单测全绿）。target 要放在窗口的存储属性里一直拿着
   （`SecondaryDockWindow.menuTarget`）；「菜单装没接上」这类断线，靠走真实 target/action
   分发链的见证测试来防（`SecondaryDockContextMenuTests`）。
2. **`NSHostingView` 上的右键走 AppKit 原来的路子**——SwiftUI 手势只管左键（`onTapGesture`），
   别在内容层里找右键的办法；最稳的是子类化 hosting view，接管 `rightMouseDown`，自己 popUp
   （这个窗口 `canBecomeKey = false`，而 `popUpContextMenu` 不需要 key window，实测能用）。
   菜单要**每次右键时现做**——当前位置的勾、台前调度时避开左边，都看当时的状态，缓存一份会过期。
3. **返回可选值的闭包字面量，赋给可选闭包属性时，不会自动包成可选**：属性是 `(() -> NSMenu)?`，
   字面量写 `{ self?.make() }`，会报「cannot convert NSMenu? to NSMenu」。别强转——把属性声明成
   `(() -> NSMenu?)?`，调用时先在辅助方法里把双重可选摊平，再 `guard let`（见
   `SecondaryDockHostingView.menuForRightClick`）。

### 2026-10-06 应用栏交互修订的新坑（栏不固定 App / NameField）

1. **`normalizedApps` 和 `barApps` 规则不同，别混着用**：前者给**默认 Dock** 用
   （启动台一定补在第一位，空数组也要有个启动台）；后者给 **Dock 栏**用（只去重，可以为空）。
   用混了，栏会变成"永远至少有个启动台"，或者默认 Dock 的启动台丢了。
2. **`NSViewRepresentable` 默认占满能用的宽度**：自绘的 `NameField` 放在 HStack / LabeledContent
   里时，要用 `.fixedSize()` 钉住，不然名称框会拉成一整行（看快照才发现）。
3. **截断超长名字时，要避开输入法组字**：在 `controlTextDidChange` 里先查
   `field.currentEditor().hasMarkedText()`——有 marked text 时改 `stringValue`，会打断候选词。
   截断按**字素簇** `prefix(10)` 来（组合 emoji 不会被劈开）；提交时还是要过一遍 `DesktopNaming.normalize`。
4. **别想着直接给 `NSTextField` 调内边距**：它没有 `textInsets` 这种东西（那是 UIKit 的）——
   内边距得靠容器视图在 `layout()` 里摆放子视图（`NameFieldContainer`）。

### 2026-10-06 去掉「最近添加的应用」的新坑（原生 Dock 归用户）

1. **「默认 Dock」这个概念已经删干净了，别再把它带回来**：`RecentAppsScanner`、`AppSettings.defaultDockAppCount`、
   `rebuildDefaultDock` / `setDefaultDockAppCount` / `reestablishFrozenDockIfNeeded` /
   `waitForFrozenDockAlignment` 全删了。`AppState.effectiveConfig(for:)` 现在**返回可选值**：
   `nil` = 这个桌面没绑栏 = **本 App 没东西可写**（不是"空配置"，而是"不写"）。
2. **冻结的意思变了（读代码别照旧的去猜）**：`freezeNativeDockSwitching = true`（产品默认）
   现在表示**本 App 不再改原生 Dock** —— 打开开关**什么都不写**（旧版会"对齐默认 Dock"，
   启动时也补一次）；关掉开关，才重新按桌面写绑定的栏。启动流程里**已经没有对齐这一步**，只留了自愈。
3. **测试夹具跟着要改（这次踩到的）**：凡是靠"注入最近应用"来造出「有东西可写」的夹具
   （`recentAppsProvider` 参数），都改成**先绑一根栏，再 `applyActiveDesktopDock()`**；
   自愈类的夹具，provider 里还得有**真实的活动桌面**（不然绑定落不到任何桌面上，`isApplying` 永远是 false）。
   断言里「启动台 + N」的计数一律减 1（不再补启动台了）。
4. **`normalizedApps` / `makeLaunchpadTile` / `isLaunchpad` / `finderPath` / `launchpadPath`
   都没了**：内容归一化只剩 `barApps`（去重、保持顺序、可以为空）。测试里要启动台条目，就自己用
   `DockTile.makeFileTile(url: /System/Applications/Launchpad.app…)` 造一个，当**普通数据**用。

### 2026-10-06 拆五页 + 锁屏式名称展示的新坑

1. **分组 `Form` 里，`TextField` 的标题会变成行首的加粗标签**（系统设置那种样式）——
   想保留"框里的占位文字"，就得用 `TextField("", text:, prompt: Text("…"))`，标题字符串
   必须是空的（`DesktopsTab` 的桌面名输入框踩过）。行标签想放左边，就把整行包成
   `LabeledContent { 控件 } label: { … }`，别用 HStack 硬拼 Form 的行。
2. **窗口改名后，要全局搜一遍调用点**：`DesktopNameToastWindow` → `HudToastWindow` 改完，
   还剩一处旧名（`ScreenMatching.screen`），编译时才冒出来——协议或类型改名后，`rg` 全仓查一遍。
3. **toast 有两条通路，收起只管当前这条**（`ToastPresenter.currentSink`）：换通路时，旧窗口
   马上 `hide()`（不然旧窗口挂在那里，等不到计时器）；`dismissNow` 不能顺手把两条都关掉——
   测试 `testDismissNowHidesOnlyCurrentSink` 盯着这条。
4. **锁屏大字的投影别用 `NSShadow`**：`NSShadow` 画在 cell 里，方向和模糊的含义跟图层
   不一样，很反直觉；用 `label.layer.shadow*`（按字形位图的 alpha 生成，跟着字形走）。
   位置计算写成纯函数 `frameOrigin`，好单测，别把 `visibleFrame` 的计算埋在 `show()` 里。

### 2026-10-06 应用图标生成的新坑（scripts/make-app-icon.swift）

1. **CGContext 的混合模式，只在源图画到的区域里起作用**：想做"整幅黑底 × 美术体 alpha"
   的剪影，「填黑 → `.destinationIn` 叠图」会在 drawRect 以外留下一整片黑（那块没参与混合）。
   顺序要反过来：「先画图（其余透明）→ `.sourceIn` 全幅填色」。要单独验证，就另写个
   10 行的脚本把中间位图导出来看，别在完整流程里瞎猜。
2. **`CIColorMatrix` 的向量是线性组合，不是"给通道乘个系数"**：黑剪影想用
   `aVector=(0.29,0,0,0)` 压 alpha，结果是全透明（算的是 `0.29×R`，而黑图的 R=0）。
   想整体调透明度，先 `CGContext.setAlpha` 再 draw，最省事。
3. **macOS 图标网格（实测 Notes/Music/Weather 的 1024 渲染图）**：美术体（alpha>127）
   **824×824 居中**（四边各留 100）；系统投影 = 剪影做高斯模糊，**σ≈10px、透明度 29%、
   下移 10px**（底边正下方 64、侧边外 37，往外 ~12px 降到 <8）——逐点对得上。生成脚本
   照这个对齐：源图先裁到 alpha>127 的 bbox（外扩 2px，留住抗锯齿边），再缩放。
4. **源图边上可能有低 alpha 的噪点**（这次是 1–3/255，散在画布边缘）：生成前先把 alpha<8
   的像素清零，不然 bbox 会一直量到画布边上。

### 2026-10-06 原生固定 App 排除的新坑（自定义栏不重复显示）

1. **排除集只在冻结模式下才用**。没冻结时，原生 Dock 里的东西就是**我们写进去的栏内容** ——
   拿它当"原生固定的 App"去排除，会把栏自己清空（自己吃自己）。所以没冻结时，`refreshNativeDockPinnedApps`
   把集合清空，提前返回；`setFreezeNativeDockSwitching` 开、关两个方向都要重算。
2. **判断是不是同一个 App，用 bundle id 或路径，别用 `normalizedKey`**。`normalizedKey` 里有 `file-label`
   和 URL 类型 —— 同一个 App，在原生条目和栏条目里的 label 可能不一样（用户改过名，或者系统语言不同）。
   身份键看 `DockTile.appIdentityKeys`（两个前缀 `bundle:` / `path:`；路径转小写、去掉末尾斜杠，
   因为 macOS 的卷不分大小写，原生域里的路径带末尾斜杠，`makeFileTile` 也带）。两个信号对上一个就算同一个。
3. **剔除结果要存盘，而且入口不止一个**。`dockBarEdited`（存盘闸门）、载入配置、导入配置、
   手动改动的回调、展示路径（`secondaryDockContent`）这五处都要过一遍 —— 漏了展示路径，
   外部改过的配置会先在条上冒出来，过一会儿才被剔掉。测试在 `NativeDockExclusionTests`。
4. **读不到偏好域，就别剔除**。`captureLiveConfig()` 返回 nil（域读不出来）时直接返回：
   没拿到事实，就不做有破坏性的决定（跟"不会误判"这条老规矩一致）。

### 2026-10-06 双语支持的新坑（中 / 英）

1. **Info.plist 里声明了 `CFBundleLocalizations`，`Bundle.main.preferredLocalizations`
   才有意义**：不声明的话它永远是 `en`（探针 App 实测），中文系统上也是满屏英文。
   `Support/Info.plist` 里 `CFBundleLocalizations = [en, zh-Hans]` +
   `CFBundleDevelopmentRegion = en`（开发区域决定**其他语言**落到哪种：日语、法语系统会
   拿到 `en`，所以设 en，不设 zh）。`L10nTests.testInfoPlistDeclaresBothLocalizations`
   盯着这三项。
2. **`swift test` 和裸二进制没有本地化元数据**（`Bundle.main.localizations` 是空的）——
   这种情况下 `L10n.resolvedLanguage` **固定用中文**。别"顺手"改成 `Locale.preferredLanguages`：
   那样测试进程会随系统语言变来变去，400+ 条中文断言和 `docs/` 的 grep 判据全都会受影响。
3. **`L()` 里的插值会算两次**（两种语言各算一次）。只能放没有副作用的表达式；
   要拼有副作用或开销大的值，先在局部算好，存进变量，再传进 `L("…\(x)…", "…\(x)…")`。
4. **新加的用户可见文案，一律写成 `L("中文", "English")`**，不然英文界面里会冒出中文 ——
   `L10nTests.testEveryChineseStringLiteralSitsInsideL` 会按词法区间扫源码，把漏掉的拦下来
   （跳过注释，`L` 可以跨行，插值里嵌套的字面量也算）。**技术标识不翻译**
   （SIGHUP / kickstart / 键名 / 路径）；**用户数据不翻译**（自定义的桌面名、栏名）。

### 2026-10-06 菜单栏标题对齐的新坑（图标 + 数字）

1. **`button.title = " \(n)"` 里的数字会偏高 ~1.2pt**：数字没有下伸部（descent），而
   `NSStatusBarButton` 按整个行盒垂直居中 → 数字看上去比图标高。改法是 `attributedTitle` +
   `.baselineOffset`（线上的值是 `MenuBarController.titleBaselineOffset = -0.75`）。
   **别退回 `button.title`**（回归守卫：`MenuBarControllerTests`）。
2. **这个偏移量会按像素取整，要"扫一段区间"，别去算零点**：实测最好的区间是 `-0.55 … -1.0`
   （剩下的偏差都是 -0.48px@2x，不到半个像素；到 `-1.1` 就翻成 +0.52）。改了字号或图标尺寸要重测——
   脚本是 `scripts/measure-menubar-baseline.swift`（真实 NSStatusItem 离屏渲染，按 alpha 加权
   求墨迹中心，不要权限；`swift scripts/measure-menubar-baseline.swift -0.5 -0.75 -1.0` 可指定候选）。
3. **`attributedTitle` 里别写 `foregroundColor`**：不写，按钮会跟着菜单栏的亮/暗自动上色
   （aqua 黑 / darkAqua 白，验证过）；写死一个颜色，换到另一种菜单栏就看不清了。
   `.font` 也一样别写死——用 `button.font`，拿不到再退回系统字号。

### 2026-10-06 红绿灯对齐的新坑（设置窗口）

1. **改 `standardWindowButton` 的 frame 管用，但窗口一缩放就被打回系统默认位置**：直接改 frame，
   渲染、点击、hover 都正常（实测），可**只要 resize（包括 `setFrame`），AppKit 就会把
   三个按钮摆回 (7,6)/(27,6)/(47,6)**。所以 `SettingsWindow` 每次 `layoutIfNeeded()` 之后
   都重新摆一次（换算是幂等的；不是"设一次就完事"，不然用户一拖窗口就变回去——回归守卫：
   `SettingsChromeLayoutTests.testTrafficLightsRenderAlignedAndStayPutAcrossResize`）。
2. **对齐和"左边距=上边距"是绑在一起的，动一个另一个必坏**：侧边栏图标列的中心 x = 26（系统
   List 的行内边距是固定的），圆点半径 6 → 左边距 = 20；用户又要上边距 = 左边距 → 上边距 = 20。
   `TrafficLightLayout.edgeMargin` 必须一直等于 `iconColumnCenterX − dotRadius`，
   别"顺手"把哪一个调得好看点——守卫测试盯着这个等式。
3. **圆点下沿离顶边 32 pt，比系统标题栏（28 pt）低**：不加长的话，点圆点下半截
   会点穿到侧边栏（hit-test 实测）。改法是把标题栏视图和它的容器各往下加长 12 pt
   （`titlebarGrowth`）；加长的部分是透明的，SwiftUI 安全区实测没变，唯一的副作用是顶部 40 pt
   都能拖动窗口。**别只加长 titlebar 不加长容器**（容器不加长，点击一样会丢，实测）。
4. **全屏时不重新摆**：全屏时 titlebar 是藏起来的，摆了也没用；`styleMask.contains(.fullScreen)`
   时直接 return，退出全屏时那次布局会补回来。
5. **怎么量**：`SettingsChromeLayoutTests`（4 个纯几何用例默认就跑；1 个扫真实窗口墨迹的用例
   要在 `MULTIDOCK_UI_SNAPSHOT=1` 下跑——用 `cacheDisplay` 离屏渲染，不要权限，扫圆点的对比度 ink bbox
   和侧边栏图标列，别光信 frame）。

### 2026-10-06 输入框宽度与位置下拉的新坑（应用栏）

1. **`NSTextFieldCell` 自带左右各 2pt 的内边距，算框宽时要算进去**：`NameField` 要放下
   「10 个中文字宽」，起初按「文本实测宽 129 + 容器内边距 14」给了 146pt，**画出来还是差 1pt，被截成
   省略号**（`ten-cjk` 探针实测）；`cell.cellSize(forBounds:)` 算 10 个字要 133pt，比文本宽
   多 4pt。最后定成 148pt。守卫 `NameFieldTests` 直接拿运行时的 `cellSize` 核对这个算式 ——
   **别再手调这个数**，字体度量变了，就该让测试变红。
2. **位置选项"灰掉"不等于"过滤掉"**：`DockBarPosition.available(...)` 是过滤后的集合
   （给运行时逻辑用），UI 上要用的是 `DockBarPosition.choices(current:available:)`
   （三条边都列出来 + `isEnabled`）—— 2026-10-06 用户规格写明了「不能用的 option 灰掉」。
   设置页的下拉和条上的右键菜单**必须共用 choices**（吃过亏：两处规则分了岔，
   右键菜单还在过滤，设置页已经灰掉了）。当前值就算不能用也打勾（能改走，改不回来）。
3. **下拉的勾选状态用 `Menu` + `Toggle` 做**：`Picker` 收起时和菜单行共用一个视图，也没有勾选状态；
   单选用 `Binding<Bool>` 实现（get 里比较，set 只在 `isOn` 时生效）——跟桌面下拉是同一套。

### 2026-10-06 名称展示背景效果（霓虹自绘）的新坑

**用户澄清过（重要）**：效果加在**展示背景**上，不是加在字上 —— 第一版做成了"渐变裁进字形"
（文字自己发光），用户指出不对。现在文字始终是同一个 label，效果只画在背景上。

1. **`NSView` 的 `deinit` 是 nonisolated，碰不到 `@MainActor` 的 `Timer` 属性**（Swift 6
   下直接编译不过）。定时器的生命周期跟着**窗口**走（`show()` 开表，`hide()` 停表），
   别指望 `deinit` 去清理；展示窗口和 App 活得一样久，不会剩下孤儿定时器。
2. **`cacheDisplay` 只走视图的 `draw()`，CoreAnimation 图层的内容抓不全**（带 mask 的尤其如此）——
   所以背景效果用自绘（CoreGraphics 每帧重画），不用 CA 图层动画，这样快照和真机跑的才是同一份渲染代码。
3. **背景层要明确插在文字下面**：`addSubview(_:positioned:.below, relativeTo: label)`。
   `NSVisualEffectView` 是容器（不是普通的 NSView），子视图顺序一错，文字就被盖住了 ——
   快照里"文字不见了"，多半是这个原因，不是画的问题。
4. **光带最亮处的不透明度要压住**：上面是白字，光带太亮就把字冲淡了。配方里 `bandAlpha ≤ 0.65`，
   测试钉死了这条（顺便钉了底线：底色 sRGB 亮度 < 0.25 —— 白字看得清的前提）。
5. **快照里要能把相位定住**：动画在跑时，每帧的相位都不一样，抓下来是哪一帧说不准。快照用例
   明确设一个固定相位（0.45），停表后再抓（`snapshotCanvas`）；动画本身另有测试盯着："跑 0.2 s RunLoop，
   看相位有没有往前走"（记着 rules 里那条「DispatchSourceTimer 在本项目一次都不 fire」的教训，
   定时器一律用 `Timer` + `.common`）。
6. **相位 1.0 绕回来就是 0**（`1 mod 1 = 0`）：写扫动位置的测试时，别拿 `phase: 1` 当终点
   （拿到的是起点的值，测试会假失败）。用 0.99 去逼近终点，或者直接断言"已扫出面板外侧"。

### 2026-10-06「启动台」页的新坑（读 SQLite + 搬运）

1. **测试夹具里，`sqlite3_bind_text` 一定要用 `SQLITE_TRANSIENT`**：Swift 的 `String` 传给
   C API 时是个**临时的** C 串，析构符给 `nil`（`SQLITE_STATIC`）的话，到 `step` 之前它就失效了 ——
   实测的表现是**所有文本悄悄变成空串**（文件夹名、App 名全是 `""`），夹具坏得非常隐蔽。
   正确写法：`unsafeBitCast(-1, to: sqlite3_destructor_type.self)`；blob 用
   `sqlite3_bind_blob(statement, n, [UInt8](data), Int32(data.count), transient)`。
2. **启动台的顺序绝不能靠 rowid 或扫表的顺序**：`items` 的 rowid 跟屏幕上的顺序没关系，
   层级里还夹着 `type 3` 的页（一个文件夹可以有好几页）。得递归拼出
   `printf('%09d.', ordering)` 路径，再按它排序；夹具故意**倒着插入**文件夹，好让这条能测出来。
3. **`confstr(_CS_DARWIN_USER_DIR)` 拿到的路径能用，但 `String(cString:)` 在这个 SDK
   上已经弃用了**（项目要求零警告）：`buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }`
   再 `String(decoding:as: UTF8.self)`。另外，`NSTemporaryDirectory()` 给的是 `/var/folders/…`，
   `FileManager.enumerator` 给的却是解析过符号链接的 `/private/var/…` —— 断言路径时
   要先 `resolvingSymlinksInPath()` 统一一下再比（不然会假失败）。
4. **启动台的 bookmark 是标准 CFURL bookmark**（`book` 魔数），
   用 `URL(resolvingBookmarkData:options:[.withoutUI,.withoutMounting])` 直接就能解，真机 160/160；
   `.withoutMounting` 一定要带（别让要挂载卷的 bookmark 拖住）。解出来的路径照样可能**过时**
   （App 已经删了），所以还要 `fileExists` 检查一遍，再拿 bundle id 索引兜底。
5. **扫 bundle id 索引时一定要 `skipsPackageDescendants`**：别钻进 App 包里面，不然 Xcode 这类
   巨型 App 里内嵌的一堆 helper .app 会混进索引（同一个 bundle id 会对到内嵌的副本上）。
6. **按"替换"处理时，失败了也不许清空目标栏**：启动台文件夹里没东西可搬，就返回失败，
   目标栏**原样不动**（`guard !apps.isEmpty` 放在写回**之前**）；只有成功了才写。
   这就是项目里"不做破坏性动作"的规矩，用在搬运这条路上。
7. **UI 快照里的启动台数据，一定要用注入的夹具**：`LaunchpadLoader` 的三个闭包都能注入
   （`isSystemSupported` / `loadRecords` / `resolve`）；不注入，快照就会读**用户自己的
   启动台**，结果不再固定，还会跟着用户的改动变。

---

# 已解决问题台账（D1–D26，留档别重复查；编号接 AGENTS.md §6.3）
| **D. 已解决（留档，别重复查）** | | | |
| D1 | ~~外观键 `show-process-indicators` / `autohide-delay` / `autohide-time-modifier` 本机不存在~~ | "设置页能改、Dock 没反应" | ✅ 真缺的只有 `show-process-indicators`；另两个读回来是 nil，进不了写入集合。UI 照这个禁用控件 |
| D2 | ~~SIGTERM 有约 255 ms 退出清理窗口，Dock 可能回写覆盖我们的写入~~ | 应用不生效 | ✅ `DockController` 写完读回来校验，对不上就再试一次。实测主路径每次都一次过（`verifyAttempts == 1`） |
| D3 | ~~`LifecycleController.restoreHandler` 是空实现~~ | 无痕原则落不了地 | ✅ P2 已经接上，而且只在 `sessionChangedDock` 时才还原 |
| D4 | ~~`Tests/` 要测"合并（防抖）、还原逻辑"~~ | 覆盖不全 | ✅ 防抖有 `testRapidRequestsCollapseIntoOneApply` 等测试覆盖；还原有 `AppStateDockTests` 覆盖 |
| D5 | ~~toast 窗口的 `ignoresMouseEvents` / `canBecomeKey = false` 未实测~~ | 抢焦点 | ✅ 验证过：连弹两次，期间每 100 ms 采一次 `lsappinfo front`，MultiDock 一次都没跑到前台 |
| D6 | ~~自定义名要替换所有 `displayName` 调用点~~ | 菜单栏和设置页的名字对不上 | ✅ 复查过，UI 和日志都走 `AppState.displayName(for:)` |
| D7 | ~~toast 距顶 80 pt 的观感未调~~ | 偏高/偏低 | ✅ 实测 `y=80`，好不好看由用户拍板 |
| D8 | ~~toast 在"用户手动切桌面"时是否也弹未实测~~ | 符不符合直觉 | ✅ 验证过：别的进程切桌面时，toast 照样弹 |
| D9 | ~~`DockWatcher` 会把自己的写入误判成用户改动~~ | 配置被弄脏 | ✅ **P3 实测来回切换 20 次，误判 0 次**（`DockAcceptanceTests`） |
| D10 | ~~预应用会不会导致 Dock 重启两次~~ | 切一次桌面闪两次 | ✅ 实测每次切换**只写一次**（`request()` 只有一个槽位，预应用和 observer 回调会合成一次） |
| D11 | ~~启动自愈还原（强杀/崩溃后写回基准）没做~~ | 用户强杀后，Dock 回不到原来的样子 | ✅ P4 做了：有残留标记 → 启动后自动还原，并弹 toast 提示。**真实 Dock 验收连开三次，结果一样**（`testSelfHealIsIdempotentAcrossThreeLaunches`） |
| D12 | ~~人为杀掉 Dock 后没有自动拉回~~ | Dock 没了只能等系统来管 | ✅ P4 做了：`DockPresenceMonitor` 连续缺到阈值就 `kickstart`。**实测 SIGKILL 后 1072 ms 回来**（上限 3 s） |
| D13 | ~~备份轮转保留 20 份但没有恢复 UI~~ | 用户没法从备份里挑一份来还原 | ✅ P4 做了：设置 → 通用 → 备份与还原，列出最近 5 份，带二次确认。**只写白名单键** |
| D14 | ~~`mru-spaces = 1` 打乱桌面顺序~~ | 切桌面的顺序不合直觉 | ✅ P4 做了：设置 → 通用 → 桌面行为，给了明确的开关，改完自动重启 Dock 生效。**用户自己点了才改** |
| D15 | ~~退出还原可能被排队的应用覆盖~~ | 退出后 Dock 还是错的 | ✅ P4 修了：还原前先 `await prepareForTermination()`（停 watcher/监视器 + 等自愈 + 等 `waitForIdle`） |
| D16 | ~~还原失败后自愈能力丢失~~ | 下次启动不再试着还原 | ✅ P4 修了：失败时留下标记 + `pid = 0` + `needsSelfHeal`，下次启动接着还原。有单测覆盖 |
| D17 | ~~README 停在 P1 状态~~ | 用户照着做会被带错 | ✅ P5 整篇重写了，写了彻底卸载的三步 |
| D18 | ~~编辑条竖排未实现~~ | 位置改到左/右后，编辑条和实际 Dock 对不上 | ✅ P5 做了 |
| D19 | ~~孤儿绑定不清理不提示~~ | 配置越堆越多 | ✅ P5 做了横幅 + 手动清理（**不自动删**） |
| D20 | ~~回存不存历史版本~~ | 误判回存后，旧配置找不回来 | ✅ P5 做成内存里的撤销栈 + 「撤销自动回存」，故意不存盘 |
| D21 | ~~全屏过滤只有单测~~ | 每次进全屏都可能误切 Dock | ✅ P5 真机回归通过（自己造一个全屏空间，不要权限） |
| D22 | ~~切桌面想要"左右滑动"的动画~~ | 点菜单栏切桌面是硬切 | ✅ **已经定了"不做"（2026-09-18）**：用代码切空间实测只要 0–6 ms；能想到的四条路全走不通（粘滞的状态位 / 写了读不回来的会话开关 / 签名不明、一调就段错误的 `SLSWillSwitchSpaces` / 合成事件被拦）。**不要权限又要无痕，就没解。别再试了** —— 详见 §4 和 `docs/spikes.md` 实验 7 |
| D23 | ~~菜单栏只能"切下一个"，往回切要开菜单~~ | 切过头只能绕去菜单 | ✅ **已解决（2026-09-18）**：`⇧+左键 = 切上一个桌面`，和"下一个"走同一条预应用链路（`switcher.target(.previous)`），到头了就绕回去；下拉菜单里也加了「上一个桌面」，并附上等价操作的提示。单测 `testPreviousDesktopPreAppliesItsOwnDock` |
| D24 | ~~逐桌面 Dock 的桌面在**回存**时会白重启一次 Dock~~ | 用户手拖图标进 Dock → 回存 → Dock 闪一下（约 50 ms），而逐桌面 Dock 恰恰是本 App 最常见的用法 | ✅ **已解决（2026-09-18）**：`DockController.apply` 原来只有一条短路，比的是「我们上次写下去的那份」（`appliedFingerprint`）—— 一有外部改动它就**过期**了，于是"应用一份跟真实 Dock 一模一样的配置"会白写一遍、白重启一次。实测 `PID 68667 → 68672`；**默认 Dock 那条路没事**（回存只写配置，不应用），所以只有 override 中招。修法：加第 1b 条短路 `liveAlreadyMatches`，**用 `verify` 那同一套比较**（跳过 ≡ 写完立刻验过）。修完实测 `68995 → 68995`。回归：`DockControllerTests` 4 条（`testSkipsWhenLiveDockAlreadyMatchesDespiteStaleFingerprint` / `testSkipAdoptsLiveDockSoWriteBackGateOpens` / `testDoesNotSkipWhenLiveDockDiffersFromConfig` / `testForceBypassesLiveMatchShortCircuit`）。**教训：光靠单测发现不了** —— 旧单测里 `appliedFingerprint` 和真实域永远是同步的，两边各自都说得通 |
| D25 | ~~切一次桌面 → Dock / 壁纸 / 触控板手势一起没了"几分钟"~~ | 用户以为系统卡死了；其实是 **Dock 进程消失了 60–126 秒**（壁纸和空间手势都是 Dock 管的） | ✅ **根因找到了，也修好了（2026-09-19，`docs/spikes.md` 实验 9）**：三条会自我放大的链路叠在了一起 —— ① launchd 退避时，`kickstart()` 里的 `waitUntilExit()` **把主线程冻住几十秒**（实测 54/60/64 s，证据是 500 ms 一轮的监视器两分钟只留下一行日志）；② 重载超时 5 s，比退避的时长短 → 慢恢复被当成失败 → 升级成 `SIGTERM` + `kickstart -k`；③ 监视器 1 s 就动手、每 2 s 催一次 `-k`，把 launchd 刚拉回来的 Dock 又杀掉。**修法**：kickstart 不阻塞、不许叠着发，超时 30 s，监视器 4 s/30 s/60 s。顺手修了 `DockWatcher` 在 Dock 不在时把残缺的域（3 个图标，真实是 15 个）回存进配置的问题 —— 但**已经写坏的两条 override 得用户重新抓**（见 §3 那一节第 6 条和 §6.3 A6）。回归测试 5 条；⚠️ 真机复验等用户做（A6） |
| D26 | ~~每次菜单栏右键退出 → 没有 Dock / 没有壁纸 / 触控板失效几分钟~~ | 用户以为机器卡死了；实测两次退出各要 **53–54 秒** | ✅ **根因找到了，也修好了（2026-09-19，`docs/spikes.md` 实验 10）**：① 退出还原用的是完整的降级链（等回来 30 s → SIGTERM → kickstart → 再等 30 s）；② `prepareForTermination` 里那两处「带上限的等」其实**没有上限**（`withTaskGroup` 会等取消不了的 `await task.value` 收尾 —— 返回值对，墙钟错）；③ 我们自己重启 Dock 时，存活监视器抢着补刀。**修法**：`reloadForQuit`（发一次 + 1.5 s 看一眼，不升级，不 kickstart）、`apply(forQuit:)` 不重试、`dropPendingRequests()`、两处等待改成轮询看得见的标志、监视器加 `isReloading` 闸门、没等到干净就留标记。顺手把 `FileLogSink` 改成了注入参数（单测曾经往用户的诊断日志里灌了 3 000 行假记录）。回归测试 13 条，**308 全绿**；⚠️ 真机复验等用户做（A7） |

# MultiDock — 项目长期记忆

## 项目性质

macOS 多桌面工具，为每个 Space 绑定一套**原生 Dock** 配置。个人自用、本地运行、不公证不上架、ad-hoc 签名。
界面中文，代码与标识符英文。

## 用户明确的硬约束（不可推翻）

1. **无痕原则**：App 绝不永久改变用户的 Dock。首次运行存基准快照，退出还原，强杀后下次启动自愈。
2. 只用原生 Dock，不实现替代品。
3. 菜单栏：左键=切下一个桌面，右键/⌥+左键=下拉菜单。
4. 设置窗口两个 Tab：通用（默认 Dock）/ 桌面（逐桌面）。
5. **不需要任何系统权限**（辅助功能、屏幕录制、root 都不用）。若某方案开始要求这些权限，先问用户。
6. **桌面命名 + 切换提示**：设置-桌面里每个桌面可起名，**最长 10 个字符**（仅存本地）；**切换桌面后在屏幕中上部弹 1 秒 toast 显示该名字**，不抢焦点、不挡点击。已于 2026-09-18 完成（P2.5）。

## 权威文档（改代码前先读）

- `docs/PLAN.md` —— 设计与进度的权威副本，实现有变化必须同步更新。
- `docs/spikes.md` —— 5 个实验的实测结论，**含对 PLAN.md 多处假设的推翻**，动架构细节前必读。**实验 5 有两个要命发现**（launchd 重启节流、`NSRunningApplication` 返回 -1）。
- `AGENTS.md` —— 交接说明：现状 / 约定 / 下一步 / 待确认问题 / 会话记录。

## 用户要求的固定工作流（每次对话结束前必做）

1. **更新项目文档**，保证任何其他 agent 读完就能接着干：
   - `AGENTS.md` §3 进度、§6 待确认问题与未解决的技术项、§4 环境事实、**§8 会话记录（append-only，最新在最上面）**
   - 设计有变化 → 同步 `docs/PLAN.md`；有新实测结论 → 写进 `docs/spikes.md`
2. **`git commit` 一次**，提交信息说清"这次做了什么"。

## 已定死的技术决策

- **Dock 没有热重载**，改配置必须重启 Dock 进程。主路径 `kill -HUP`（约 101 ms 不可用），兜底 `kill -TERM` + `launchctl kickstart`（约 395 ms）。**绝不用 AppleEvent 优雅退出**（`SuccessfulExit=0` 时 launchd 不会拉回 Dock）。
- **launchd 有重启节流**：距上次重启**不足约 1 秒**时再重启，Dock 要 **约 1070 ms** 才归位；间隔 ≥ 1 秒只要 **约 70 ms**。`DockReloader.minimumSpacing`（默认 1 s）先等满窗口再重启 —— **等待期间 Dock 可用**，所以"等"严格优于"立刻重启"。实测把 Dock 不可用时长从约 1030 ms 压到 **45–90 ms**。`ReloadOutcome.elapsed` 只算真不可用，`spacingWait` 单独记。
- ⚠️ **`NSRunningApplication` 在 Dock 重启窗口会返回 `processIdentifier == -1`**（实测复现）。`kill(-1, sig)` = 发给**当前用户全部进程**，`kill(0, sig)` = 整个进程组 —— 会毁掉图形会话。**发信号前必须**：拒绝 `pid <= 0`，并用 `proc_name` 确认进程名是 `Dock`。测试在 `DockProcessSafetyTests`（用**信号 0** 断言，闸门坏了是测试失败而非打死测试进程）。
- **查 Dock PID 别用 `pgrep`**（子进程单次约 **110 ms**，放进 15 ms 轮询热路径会拖慢一个量级）。用 `proc_listpids(PROC_ALL_PIDS)` + `proc_name`（**0.02 ms**）；`NSRunningApplication` 是 0.6–1.4 ms。
- **程序化切桌面不触发空间变化通知** → `SpaceObserver` 用 300 ms 轮询为主、通知为辅；自己发起的切换必须预应用。
  - 「预应用」的准确含义是"**发起**应用与切空间同一拍、不等轮询"，**不是**"切空间前完成重启"——重启 101 ms > `setCurrentSpace` 20 ms，物理上做不到。别按字面"修正"顺序。
- **Finder 在 plist 中无任何表示** → 钉住无需代码，也不要给它拖拽手柄。
- 空间字典键名是 **`uuid`**（不是 `ManagedSpaceUUID`）。
- 写 Dock 偏好：读**全量**域 → 只覆盖白名单键 → 单次原子写回，绝不整域替换。**只写当前域里真实存在的键**（本机缺 `show-process-indicators`；`autohide-delay`/`autohide-time-modifier` 压根不在域里）。写完读回校验，不一致**最多重试一次**。
- **退出还原有门槛**：只在本次运行真的改过 Dock（会话标记里 `appliedFingerprint != nil`）时才还原 —— 否则会抹掉用户在运行期间自己拖的图标。还原前比一次白名单键，已与基准一致就跳过。
- **`DockWatcher` 回存也有门槛**：只在"本次运行写过 Dock"后才回存（`appliedComparableFingerprint != nil`），且判据是"可比指纹变了、且不等于我们写下去的那份"。`handleDockOutcome` 在 `.applied` 时 `acknowledge` 一次，回存期间停 watcher —— 都是为了不把自己的写入当成用户改动。
- 菜单栏用 `NSStatusItem` 而非 `MenuBarExtra`；`DockTile.raw` 用 `[String: PlistValue]` 而非 `[String: Any]`。
- **`AppState` 的依赖全部可注入**（`dockController` / `configStore` / `baselineStore` / `provider`），且 AppState 内部**不直接调 `DockPreferences.readDomain()` 这类静态入口** —— 会绕过注入点，测试里读到真实系统的偏好域。要读就走 `DockController.readDomain()` / `captureLiveConfig()`。
- **编辑器一律"只改内存 + 一次提交"**：`setDockConfigInMemory` / `setDockAppearanceInMemory` 不落盘，`dockEdited(_:reason:)` 才落盘 + 按开关应用。滑杆只在**松手**时提交（`DockAppearanceEditor.onCommit`），否则拖一次滑杆重启几十次 Dock。默认 Dock 与逐桌面 override 共用 `DockEditTarget` 一套入口。
- **`DesktopBinding.updating(_:for:_:)` 是绑定列表的唯一改法**（改名与改 override 共用），改完若"既无名字又无 override"就删掉，不留空行。
- `.app` 条目的 `_CFURLString` **必须带尾斜杠**（`file:///Applications/X.app/`）；用户 App `dock-extra=true`，启动台 `file-type=169` + `dock-extra=false`。启动台条目要**复用真实域里已有的**（保住 `GUID`/`book`），不要无条件重建。

## 开发环境

macOS 15.7.9 (24G830) / x86_64 / 单显示器 / Swift 6.2.4。换机器需重新验证 `AGENTS.md` §4 的环境事实表。

## 验收纪律

- 不接受"编译通过就算完成"，每个功能都要实测。
- **`swift build` / `swift test` 必须加 `--disable-sandbox`**：SwiftPM 自己的 `sandbox-exec` 在本机报 `sandbox_apply: Operation not permitted`，manifest 编译失败，错误信息 `error: 'multi-dock': Invalid manifest` 看着像 Package.swift 坏了，其实是环境问题。
- **不能用截图验证**（本机无屏幕录制权限，`screencapture` 只返回壁纸）。用 `multidock.log`、调试面板，或"Dock 是否给 tile 补 GUID"这类客观信号。
- 保持零警告构建（`swift build -c release --disable-sandbox --build-path /tmp/...` 可绕过 safe-delete 做全新构建）。`String(cString:)` 已废弃，别用。
- **动 Dock 的改动跑真实验收**：`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`（会真的改 `com.apple.dock` 并重启 Dock 几十次，跑完自动还原）。**跑之前先 `defaults export com.apple.dock` 备份，中途别手动改 Dock**（会报假失败）。
- **`DockReloader` 的单测都要传 `minimumSpacing: .zero`**，否则每个用例白等 1 秒。
- **Dock 回写 `GUID` 是异步的**：apply 返回后立刻读还是 `nil`，轮询 200 ms 内出现 → 判据必须配轮询。
- **Dock 重启一次 `mod-count` 就 +1、`recent-apps` 也会变**（不在白名单、我们从不写）→ 验收判据是「差异只能落在白名单键或 `{mod-count, recent-apps, trash-full}` 上」。
- **`plutil -p` + `diff` 比对长数组会错位产生假差异**：判断「成员/顺序」抽标签序列比，判断「值」用结构化比较。
- **测"这次操作写了几次"不能用累计计数器**，要用事件流（准备阶段也写过，累计值会多）。
- **测 Dock 重启耗时别用 `pgrep` 轮询**：单次 110 ms 会把结果整个污染（实测把 70 ms 测成 400 ms）。
- **嵌套在 `@MainActor` 测试类里的替身类要显式标 `@MainActor`**（嵌套类型不继承外层隔离）。

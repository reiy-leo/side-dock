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
- `docs/spikes.md` —— P0 实测结论，**含对 PLAN.md 三处假设的推翻**，动架构细节前必读。
- `AGENTS.md` —— 交接说明：现状 / 约定 / 下一步 / 待确认问题 / 会话记录。

## 用户要求的固定工作流（每次对话结束前必做）

1. **更新项目文档**，保证任何其他 agent 读完就能接着干：
   - `AGENTS.md` §3 进度、§6 待确认问题与未解决的技术项、§4 环境事实、**§8 会话记录（append-only，最新在最上面）**
   - 设计有变化 → 同步 `docs/PLAN.md`；有新实测结论 → 写进 `docs/spikes.md`
2. **`git commit` 一次**，提交信息说清"这次做了什么"。

## 已定死的技术决策

- **Dock 没有热重载**，改配置必须重启 Dock 进程。主路径 `kill -HUP`（约 101 ms 不可用），兜底 `kill -TERM` + `launchctl kickstart`（约 395 ms）。**绝不用 AppleEvent 优雅退出**（`SuccessfulExit=0` 时 launchd 不会拉回 Dock）。
- **程序化切桌面不触发空间变化通知** → `SpaceObserver` 用 300 ms 轮询为主、通知为辅；自己发起的切换必须预应用。
- **Finder 在 plist 中无任何表示** → 钉住无需代码，也不要给它拖拽手柄。
- 空间字典键名是 **`uuid`**（不是 `ManagedSpaceUUID`）。
- 写 Dock 偏好：读**全量**域 → 只覆盖白名单键 → 单次原子写回，绝不整域替换。**只写当前域里真实存在的键**（本机缺 `show-process-indicators`；`autohide-delay`/`autohide-time-modifier` 压根不在域里）。写完读回校验，不一致**最多重试一次**。
- **退出还原有门槛**：只在本次运行真的改过 Dock（会话标记里 `appliedFingerprint != nil`）时才还原 —— 否则会抹掉用户在运行期间自己拖的图标。还原前比一次白名单键，已与基准一致就跳过。
- 菜单栏用 `NSStatusItem` 而非 `MenuBarExtra`；`DockTile.raw` 用 `[String: PlistValue]` 而非 `[String: Any]`。
- **`AppState` 的依赖全部可注入**（`dockController` / `configStore` / `baselineStore`），且 AppState 内部**不直接调 `DockPreferences.readDomain()` 这类静态入口** —— 会绕过注入点，测试里读到真实系统的偏好域。要读就走 `DockController.readDomain()` / `captureLiveConfig()`。
- `.app` 条目的 `_CFURLString` **必须带尾斜杠**（`file:///Applications/X.app/`）；用户 App `dock-extra=true`，启动台 `file-type=169` + `dock-extra=false`。启动台条目要**复用真实域里已有的**（保住 `GUID`/`book`），不要无条件重建。

## 开发环境

macOS 15.7.9 (24G830) / x86_64 / 单显示器 / Swift 6.2.4。换机器需重新验证 `AGENTS.md` §4 的环境事实表。

## 验收纪律

- 不接受"编译通过就算完成"，每个功能都要实测。
- **不能用截图验证**（本机无屏幕录制权限，`screencapture` 只返回壁纸）。用 `multidock.log`、调试面板，或"Dock 是否给 tile 补 GUID"这类客观信号。
- 保持零警告构建（`swift build -c release --build-path /tmp/...` 可绕过 safe-delete 做全新构建）。
- **动 Dock 的改动跑真实验收**：`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests`（会真的改 `com.apple.dock` 并重启 Dock，跑完自动还原）。**跑之前先 `defaults export com.apple.dock` 备份，中途别手动改 Dock**（会报假失败）。
- **Dock 回写 `GUID` 是异步的**：apply 返回后立刻读还是 `nil`，轮询 200 ms 内出现 → 判据必须配轮询。
- **Dock 重启一次 `mod-count` 就 +1、`recent-apps` 也会变**（不在白名单、我们从不写）→ 验收判据是「差异只能落在白名单键或 `{mod-count, recent-apps, trash-full}` 上」。
- **`plutil -p` + `diff` 比对长数组会错位产生假差异**：判断「成员/顺序」抽标签序列比，判断「值」用结构化比较。

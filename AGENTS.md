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

**提交前先确认 1Password 在运行。** 本机 git 全局配置了 `commit.gpgsign = true`，
`gpg.format = ssh`、`gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign`，
签名密钥由 1Password 托管。**1Password 没启动时 commit 会失败**，报
`error: 1Password: Could not connect to socket. Is the agent running?` / `fatal: failed to write commit object`。
此时 `open -a 1Password` 拉起它再重试即可（暂存区不会丢）。**不要用 `--no-gpg-sign` 绕过签名。**

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
- **v3.2（当前，2026-09-18）**：新增**桌面命名（≤10 字符，仅本地）**与**切换桌面的中上部 toast（1 秒自动消失，零权限）**。因为完全不碰 Dock，单列为 P2.5、可插队先做。规格见 `docs/PLAN.md` §3.10。

---

## 3. 当前进度

**P0（实验）与 P1（骨架 + 识别 + 菜单栏）已完成并实测通过。下一步是 P2（编辑条 + 应用），也可以先插队做 P2.5（桌面命名 + 切换 toast，不写 Dock）。**

### 已完成

| 项 | 位置 | 状态 |
| --- | --- | --- |
| SwiftPM 包 | `Package.swift` | 执行目标 `MultiDock` + **测试目标 `MultiDockTests`**，`platforms: [.macOS(.v14)]` |
| 程序入口 | `Sources/MultiDock/MultiDockApp.swift` | `@main` + `NSApplication`（**不是** SwiftUI `App`，原因见下） |
| App 委托 | `App/AppDelegate.swift` | 组装状态、菜单栏、窗口；退出流程交给 `LifecycleController` |
| 全局状态 | `App/AppState.swift` | `@MainActor @Observable`，空间值转发给 observer（不复制） |
| 日志落盘 | `App/FileLogSink.swift` | 追加写 `multidock.log`，512 KB 上限 |
| 生命周期 | `App/LifecycleController.swift` | 启动自检 + 会话标记；**还原动作是空实现（P4 接上）** |
| SkyLight 桥 | `Spaces/SkyLightBridge.swift` | `dlopen` + `dlsym`，符号缺失即降级 |
| 桌面枚举 | `Spaces/SpaceProvider.swift` | 协议 + 私有 API 实现 + 降级实现 |
| 桌面观察 | `Spaces/SpaceObserver.swift` | **300 ms 轮询为主 + 通知为辅**，`type != 0` 过滤，按桌面身份去重 |
| 桌面切换 | `Spaces/SpaceSwitcher.swift` | 同显示器内循环取下一个/上一个，两端循环 |
| 配置模型 | `Dock/DockConfig.swift` | `PlistValue` / `DockTile` / `DockAppearance` / `DockConfig` / `DesktopBinding` / `AppSettings` |
| Dock 偏好 | `Dock/DockPreferences.swift` | 白名单 + 全量域读 + 原子写（**写路径 P1 未接线**） |
| 配置持久化 | `Store/ConfigStore.swift` | 原子写 `config.json` |
| 基准快照 | `Store/BaselineStore.swift` | 基准 + 会话标记 + 备份轮转（保留 20 份） |
| 菜单栏 | `UI/MenuBarController.swift` | `NSStatusItem`，区分左右键，标题显示当前桌面序号 |
| 调试面板 | `UI/DebugPanelView.swift` | 当前 spaceUUID/id64/type、桌面列表、实时日志 |
| 设置窗口 | `UI/SettingsView.swift` | 通用 / 桌面 两个 Tab（Dock 编辑条等 P2/P3 部分明确标注待实现） |
| P0 实验脚本 | `scripts/spike-*.{sh,swift}` | 重载策略 / 切桌面 / 停机时长 / 探测 |
| 打包脚本 | `scripts/build-app.sh` | 编译 → 组装 `.app` → ad-hoc 签名 |
| 测试 | `Tests/MultiDockTests/` | **37 个测试，全绿** |
| 设计文档 | `docs/PLAN.md` | 已按 P0 结论修订 |
| P0 结论 | `docs/spikes.md` | 三个实验的原始数据与决定 |

### 未完成（计划里已定义、代码里还没有）

- `Dock/DockController.swift`（应用流水线、防抖合并、内容相同跳过）、`Dock/DockReloader.swift`（SIGHUP 主 + SIGTERM 兜底）、`Dock/DockWatcher.swift`（手动改动回存）—— **全部属于 P2/P3**。
- `UI/DockStripEditor.swift`（P2）、`UI/DesktopListView.swift`（P3）。
- **`UI/ToastPresenter.swift`（纯逻辑 toast 调度）+ `UI/DesktopNameToast.swift`（AppKit 窗口）、`AppState.displayName(for:)` 与 `normalizeDesktopName`、桌面页改名输入框、`scripts/check-toast-window.sh` —— 属于 P2.5，见下。**
- `docs/PLAN.md` §2 列出的 `Tests/` 里的"合并、还原逻辑"测试：合并（防抖）随 `DockController` 一起做；还原逻辑目前只测了 `BaselineStore` 层。

### 可选插队：P2.5（桌面命名 + 切换 toast，不写 Dock）

**这一阶段完全不碰 Dock，风险为零，而且用户已经明确要了**（`AGENTS.md` §2.6 / `docs/PLAN.md` §3.10）。如果不想先啃 P2 的写路径，可以直接做这个，做完就是肉眼可见的功能。

1. `normalizeDesktopName(_:)`：trim + 去换行 + 按**字素簇**截到 10 个字符，纯函数，先写单测。
2. `AppState.displayName(for: DesktopSpace)`：有 `customName` 用自定义名，否则回落「桌面 N」。**替换所有调用点**（`MenuBarController`、桌面页、toast、日志）。
3. 桌面页列表加就地改名输入框（`n/10` 计数）+ 设置里的「切换桌面时显示桌面名称」开关（默认开）。改名只写 `DesktopBinding.customName`，**不动 `override`**。
4. `ToastPresenter`（协议 + 可注入时钟，纯逻辑）+ `DesktopNameToast`（无边框 `NSWindow`）。窗口属性表见 `docs/PLAN.md` §3.10，**`collectionBehavior` 里的 `.canJoinAllSpaces` 和 `canBecomeKey = false` 漏了就是 bug**。
5. 触发点只接 `SpaceObserver.onActiveSpaceChanged`，且只在「用户桌面 → 另一个用户桌面」时弹（上一次通知值也必须非 nil）→ 启动不弹、从全屏退回不弹。
6. 调试面板加「测试 toast」按钮；`multidock.log` 记 `toast 显示「X」` / `toast 隐藏`。
7. 验收：`scripts/check-toast-window.sh` 看到 layer 25 / alpha 1 / 水平居中贴顶的窗口，1 秒后消失；连切 5 次只显示最终名字；**全程 `defaults read com.apple.dock` 无任何变化**。

### 下一步：P2（编辑条 + 应用）

P0 已把 §3.5 的主路径定死为 **SIGHUP**。P2 要做的第一件事是把写路径接起来：

1. `DockReloader`：`kill(dockPID, SIGHUP)`，等 Dock 归位（轮询 PID 变化 + 上限 5 s），未归位则 `launchctl kickstart -k gui/$(id -u)/com.apple.Dock.agent` 兜底。**绝不用 AppleEvent 优雅退出**（`SuccessfulExit=0` 时 launchd 不会拉回 Dock）。
2. `DockController`：读全量域 → 只覆盖白名单键 → 单次原子写 → 触发重载 → **校验指纹，不一致重试一次**（SIGTERM 清理窗口的竞态，见 spikes.md）。
3. `UI/DockStripEditor`：拖入/拖出/排序，Finder 与 Launchpad 锁定在最前。**Finder 不需要写进 plist**（P0 已确认无法表示），Launchpad 是普通条目、保证它存在即可。
4. 通用 Tab 接上编辑条与「立即应用」「立即还原到原始 Dock」按钮。
5. 验收：`defaults read com.apple.dock` 与操作前 diff，**除白名单键外无任何差异**；点还原后逐键等于 baseline。

⚠️ **P2 首次写外观键前必须实测键名**：本机 34 个键里**没有** `show-process-indicators`、`autohide-delay`、`autohide-time-modifier`。白名单里保留了它们，但写之前要确认当前系统上这些键真的有效，否则会出现"设置页能改、Dock 没反应"。

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
| 主动切桌面 | `CGSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID)` **可用**，约 **20 ms** 生效，带系统自带动画；无动画时长控制符号 |
| Dock 热重载 | **不存在**。post `com.apple.dock.prefchanged`（darwin 与分布式两种都试过）完全无效 |
| Dock 重启 | `kill -HUP`：进程消失于 +13 ms、归位 +101 ms（**总不可用约 101 ms**）。`kill -TERM`：Dock 先做约 255 ms 清理，总不可用 **约 367–395 ms**。**主路径选 SIGHUP** |
| Dock 进程守护 | `/System/Library/LaunchAgents/com.apple.Dock.plist` 为 `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}` → 必须信号致死才会被拉起；**优雅退出（exit 0）不会重启，用户会当场失去 Dock** |
| **Dock 是否应用了写入** | 判据：写入的 tile 不带 `GUID`，Dock 真正读取并应用后会**补上 `GUID`**。实测正负两种情形都验证过 |
| Finder | `persistent-apps` 里没有 Finder；**全量域 34 个键里没有任何 Finder 相关键或值** → 写偏好无法删除它，"钉住"天然成立，无需代码 |
| Dock 偏好域 | 34 个键；`persistent-apps` 15 项（首项 Launchpad）、`persistent-others` 1 项。**没有** `show-process-indicators` / `autohide-delay` / `autohide-time-modifier` |
| 多显示器空间 | `com.apple.spaces spans-displays` 不存在 → 默认"显示器各自独立空间"，映射键需 `(displayUUID, spaceUUID)` |
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
swift build -c release      # 编译
swift test                  # 37 个测试（已可用，见下）
./scripts/build-app.sh      # 组装 build/MultiDock.app（ad-hoc 签名）
open build/MultiDock.app    # 运行（必须在 .app 里跑，菜单栏图标才正常）
```

- **`swift test` 现在可用了**：`Package.swift` 已加 `MultiDockTests` 测试目标。（旧版这里写的"会报 no tests found"已过时。）
- 打包脚本用的是 `codesign --force --sign -`，不是计划原文写的 `--deep`（Apple 已废弃 `--deep`）。
- 也可以直接用 Xcode 打开 `Package.swift`，但**不要**手写 `.xcodeproj`。
- **仓库已初始化**（`git init -b main`，首个 commit `e3e359a`，见 §8）。提交签名走 1Password，**提交前先确认 1Password 在跑**（见 §0）。
- **不要用 `rm -rf .build/...` 清缓存**：本机有 safe-delete 保护会拦截。要全新构建请用
  `swift build -c release --build-path /tmp/multidock-build`。

### 代码约定

- `swift-tools-version: 6.0` → **Swift 6 语言模式、严格并发检查**已开启。当前构建**零警告零错误**，保持住。
- `@Observable` + `@MainActor` 用于状态类。**不要把空间状态在 `AppState` 里复制一份**——转发给 `SpaceObserver`，否则两份会不同步。
- `@convention(c)` 函数指针类型如果声明为 `private`，顶层 `let` 引用它时必须也标 `private`，否则报 "uses a private type"。
- 私有 API 一律用 `dlopen` + `dlsym` 运行时加载，**不要链接私有框架**。
- 写 Dock 偏好用 `CFPreferences` API，不要拼 `defaults` 命令行。写入策略：读**全量**域 → 只覆盖白名单键 → 单次原子写回，绝不整域替换。
- 代码不写解释性注释；只在"为什么"不显然时才写。
- 新增功能必须有对应的实测验证，不接受"编译通过就算完成"。

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
| 1 | **「桌面」页里每个桌面的"位置"指什么？** 目前理解为 Dock 在屏幕上的位置（下/左/右）+ 大小，与「通用」页同一套含义、未设置时继承默认 | **P3 桌面页**，做之前必须问清 | ⏳ **用户仍未回答**（`docs/PLAN.md` §6 也记着） |
| 2 | toast 在桌面**没有自定义名**时显示「桌面 N」还是不显示？ | 不阻塞（P2.5 按"显示「桌面 N」"实现） | ⏳ 待确认，见 `docs/PLAN.md` §6 第 2 条 |
| 3 | "屏幕中上部"的具体位置（现定：距可见区顶部 80 pt、水平居中） | 不阻塞（P2.5 先按 80 pt） | ⏳ 待确认，见 `docs/PLAN.md` §6 第 3 条 |
| 4 | 10 个字符按**字素簇**还是按**视觉宽度**（中文 2 / 英文 1）算？ | 不阻塞（P2.5 按字素簇） | ⏳ 待确认，见 `docs/PLAN.md` §6 第 4 条 |

### 6.2 已解决（留档，别重复问）

- ~~是否 `git init` 并提交首个 commit~~ → **已解决**：用户 2026-09-18 明确要求每次对话后 commit，仓库已初始化。
- ~~P0 三个实验的结果未知~~ → 已解决，见 `docs/spikes.md`。
- ~~Dock 是否有热重载 / 能否主动切桌面 / Finder 怎么钉住~~ → 已解决，见 `docs/spikes.md`。

### 6.3 未解决的技术项（不阻塞，但要知道）

| # | 事项 | 影响 | 何时处理 |
| --- | --- | --- | --- |
| 1 | **外观键 `show-process-indicators` / `autohide-delay` / `autohide-time-modifier` 在本机 34 个键里不存在** | 可能出现"设置页能改、Dock 没反应" | P2 首次写外观键前逐个实测键名 |
| 2 | **SIGTERM 有约 255 ms 退出清理窗口**，Dock 可能回写自己的状态覆盖我们的写入（实测未发生，但不能假设永远安全） | 应用不生效 | P2：写完校验指纹，不一致重试一次。SIGTERM 只作兜底 |
| 3 | **手动移除 Finder 是否落键**未验证 | 若有新键需纳入白名单 | 可选，30 秒。步骤见 `docs/spikes.md` 实验 3。风险低 |
| 4 | **用户手动切桌面时 `activeSpaceDidChange` 通知是否触发**未知 | 只影响"能否把跟随延迟从 300 ms 降到接近 0"，不影响可用性 | P5 回归时顺手测 |
| 5 | **`LifecycleController.restoreHandler` 是空实现**，会话标记的 `appliedFingerprint` 恒为 nil | 无痕原则目前靠"根本不写 Dock"实现，而非靠还原 | P4 接上还原全链路 |
| 6 | `docs/PLAN.md` §2 提到 `Tests/` 要测"合并（防抖）、还原逻辑" | 覆盖不全 | 合并随 `DockController` 在 P2 做；还原逻辑目前只测到 `BaselineStore` 层 |
| 7 | **toast 窗口的 `ignoresMouseEvents` / `canBecomeKey = false` 效果未实测** | 万一抢焦点，用户切过去打字会打进 toast | P2.5 实现后实测：切桌面后立刻在目标 App 里敲键盘，字符必须进 App |
| 8 | **自定义名要替换所有 `DesktopSpace.displayName` 调用点**（`MenuBarController`、`AppState` 日志、`SettingsView`、`DebugPanelView`） | 漏一处就会出现"菜单栏和设置页名字不一样" | P2.5：先全量 grep `displayName` 再改 |
| 9 | toast 距顶 80 pt 的观感未调 | 可能偏高/偏低 | P2.5 实测后调数值（`docs/PLAN.md` §6.3） |
| 10 | **toast 在"用户手动切桌面"时是否也弹**未实测 | 影响是否符合直觉 | 轮询与切换来源无关，理论上会弹；P2.5 用触控板手势实测确认 |

---

## 7. 给下一个 session 的建议顺序

1. 读本文件 → `docs/PLAN.md`（§3 核心机制、**§3.10 桌面命名与 toast**、§4 阶段与验收）→ `docs/spikes.md`（P0 结论，**含对计划的三处修正**）。
2. 和用户确认 §6.1（做 P3 前必须）。
3. 跑一次基线：`swift build -c release && swift test && ./scripts/build-app.sh`，确认全绿（应为 37 个测试通过、零警告）。
4. **可选插队：做 P2.5（桌面命名 + 切换 toast）**。完全不写 Dock、风险为零、用户已明确要，做完立刻可见。步骤见 §3 的「可选插队」。
5. 做 P2：`DockReloader` → `DockController` → `DockStripEditor` → 通用 Tab 接线 → 验收（`defaults read` diff 除白名单外无差异）。
6. 收尾：按 §0 更新本文档 + `git commit`。

---

## 8. 会话记录

> append-only，**最新在最上面**。每条记录：这次做了什么 / 当前进度 / 未解决的事。

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

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

macOS 多桌面（Space）工具：为每个桌面绑定一套**原生 Dock** 配置，切换桌面时自动把 Dock 切换成对应配置。菜单栏常驻一个图标，单击即切到下一个桌面，`⇧`+单击切上一个。

- 用户：个人自用，本地运行，**不做公证、不上 Mac App Store、不签名**（ad-hoc 签名即可）。
- 语言：界面中文，代码与标识符英文。
- 不替换原生 Dock，不自己画 Dock 栏。

---

## 2. 硬约束（用户明确要求，不要擅自推翻）

1. **无痕原则**：App 绝不永久改变用户的 Dock。首次运行把当时的 `com.apple.dock` 全量存为**基准快照**；退出时还原到该基准；被强杀或崩溃则下次启动检测并还原。安装后不做任何配置时，Dock 必须与安装前完全一致。
2. **用原生 Dock**：不实现替代品，只改写 Dock 偏好 + 触发重载。
3. **菜单栏交互**：左键单击 = 切到下一个桌面（循环）；**⇧+左键 = 切到上一个桌面**；右键 / ⌥+左键 = 下拉菜单（桌面列表 + 上一个/下一个 + 设置 + 退出）。左键行为可在设置里改成"打开菜单"（此时 ⇧+左键也一并打开菜单，不留隐形的第二行为）。**切桌面过程本身没有动画，且做不到** —— 见 §4 与 `docs/spikes.md` 实验 7，别再试。
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
  详见 `docs/PLAN.md` §3.3 / §3.9 与 §5。
- **v3.5（当前，2026-09-19，两次真机故障后修正）**：实验 9 与实验 10 是同一个故障的两个触发点。
  ① **切桌面**（实验 9）：`kickstart` 同步等 launchctl 会把主线程冻几十秒、重载超时 5 s 短于 launchd 退避、
  监视器 1 s 就动手 —— 三条叠起来把 100 ms 滚成 60–126 秒的 Dock 死亡；
  ② **退出**（实验 10）：退出还原复用完整降级链 → 实测每次 **53–54 秒**。
  修法是**给退出单开一条窄路**（`reloadForQuit` 一发信号 + 1.5 s 看一眼、写入不重试、待办直接丢、
  监视器在 `isReloading` 期间闭嘴、等不到干净就留标记）。
  ③ **v3.4 第 ① 条被修正**：不是"等排队的应用跑完"，而是"**丢掉没起跑的 + 带上限等真正在飞的**"。
  ④ **两处"带上限的等"其实没有上限**（`withTaskGroup` 与不可取消的 `await task.value` 赛跑，
  返回值对、墙钟错），改成轮询可观察标志 —— 这是本次最深的发现，见 §5 与 `docs/spikes.md` 实验 10。
  ⑤ **测试不再写用户的 `multidock.log`**（`FileLogSink` 进 `AppState.init` 注入点）：
  那份日志是用户核对真机行为的唯一凭据，之前被单测灌了几千行假记录。

---

## 3. 当前进度

**P0（实验）、P1（骨架 + 识别 + 菜单栏）、P2.5（桌面命名 + 切换 toast）、P2（编辑条 + 应用）、P3（桌面页 + 自动切换）、P4（无痕与自愈）、P5（收尾）已完成并实测通过。**

> P5 里唯一还欠的是**多显示器热插拔的真机实测**（本机单显示器，必须用户插一台外接屏）。
> 全屏过滤已经真机回归过了 —— 做法是**自己造一个全屏空间**，见 §4 与 `scripts/check-fullscreen-filter.swift`。

> ⚠️ **从 P2 起，代码真的会改用户的 Dock 了。** 写路径已接线：设置页「立即应用」→ `DockController` → 写偏好 + 重启 Dock。无痕原则靠 `LifecycleController` 的退出还原 + 会话标记兜底（见 §3 的 P2 小节）。

> ⚠️ **2026-09-20 状态检查 + 三个控制实验**：实验 9 / 10 的修复**已被真机日志确认有效**
> （退出还原 53–54 s → **0.01 s**；切桌面最坏值 60–126 s → **26–31 s**，正常路径稳定 35–126 ms）。
> 但另有一次 **26–31 s** 的偶发慢重启。它一度被归因到 `minimumSpacing`（"launchd 有 10 s uptime 门槛"），
> **该归因已被实验 12–14 逐个推翻** —— 详见 `docs/spikes.md` **实验 11.6**。
> **`minimumSpacing` 保持 1 s 不动**，根因未定（§6.3 A8）。
> ✅ **2026-09-20 已给慢重启装上取证仪表**（`docs/spikes.md` 实验 15）：慢于 1 秒的重载会采样
> `pidProbe()` 的两条探测路径答案，写进那一行 `Dock 应用成功` 日志的 `慢重启取证：…` 段。
> 正常路径**一次都不调用**，零开销。下次偶发时照实验 15 的判定规则读日志即可定案。
> ⚠️ **但仪表一开始是坏的，2026-09-20 才发现**（实验 15.2）：`RealDockProcessControl.pidProbe()`
> 的返回类型写成非可选，撞上 Swift 的**协议见证位协变陷阱** → **通过协议调用永远拿到 nil**，
> 生产路径上仪表完全是死的，而 6 条替身单测全绿。已修 + 加**故意走 `any` 协议**的回归守卫。
> ✅ **第六个假说也被证伪**（实验 15.3）：定向测量 6 轮，`dockPID()` 的 LS 优先造成的
> **危险窗口恒为 0 ms**。**"我们的 bug"这一侧已经没有候选了**，`dockPID()` 的路径选择不要改。
> 数据侧的那条**已结案**：默认 Dock（3 个图标 + `orientation = right`）是用户有意配的；
> 两条 override 的图标与它相同**不构成损坏**，而且因为 override 的 `orientation` 是 `bottom`、
> 清掉会让那两个桌面的 Dock 跑到右侧，**`config.json` 原样保留**（§6.3 A9）。
> ⚠️ **本节在 2026-09-20 被更正过两次**：先写错"三个 override 全空"（读取脚本用错 JSON 键名），
> 再写错"两条 override 与默认重复、可以清成沿用默认"（忽略了 override 是整体替换）。**看 §5 那条约定。**

### 已完成

| 项 | 位置 | 状态 |
| --- | --- | --- |
| SwiftPM 包 | `Package.swift` | 执行目标 `MultiDock` + **测试目标 `MultiDockTests`**，`platforms: [.macOS(.v14)]` |
| 程序入口 | `Sources/MultiDock/MultiDockApp.swift` | `@main` + `NSApplication`（**不是** SwiftUI `App`，原因见下） |
| App 委托 | `App/AppDelegate.swift` | 组装状态、菜单栏、窗口；接线 toast、`onDockApplied`、`restoreHandler` |
| 全局状态 | `App/AppState.swift` | `@MainActor @Observable`，空间值转发给 observer（不复制）；**依赖全部可注入**（`DockController` / 两个 Store），所以按钮路径能单测 |
| 日志落盘 | `App/FileLogSink.swift` | 追加写 `multidock.log`，512 KB 上限 |
| 生命周期 | `App/LifecycleController.swift` | 启动自检 + 会话标记 + **退出还原（已接线）**；**只在本次会话可能让 Dock 变脏时才还原**（`appliedFingerprint` 或继承来的 `needsSelfHeal`）；还原前先 `prepareForTermination()` 等待办清空；**还原失败保留标记**交给下次自愈 |
| Dock 存活监视 | `Dock/DockPresenceMonitor.swift` | 轮询 `dockPID()`，连续缺失达阈值就 `kickstart` 拉回；归位后记恢复次数；**持续拉不回来（默认 12 轮 ≈ 6 秒）回调 `onPersistentlyDown` 一次 → UI 报警**，回来时 `onRevived`。**纯逻辑 + 注入式进程控制**，可脱离真实 Dock 单测 |
| 登录启动 | `App/LoginItem.swift` | `SMAppService.mainApp` 为主，失败退回写 `~/Library/LaunchAgents/local.multidock.loginitem.plist`；**非 `.app` 环境明确报"不可用"**，不做假开关 |
| SkyLight 桥 | `Spaces/SkyLightBridge.swift` | `dlopen` + `dlsym`，符号缺失即降级 |
| 桌面枚举 | `Spaces/SpaceProvider.swift` | 协议 + 私有 API 实现 + 降级实现 |
| 桌面观察 | `Spaces/SpaceObserver.swift` | **300 ms 轮询为主 + 通知为辅**，`type != 0` 过滤，按桌面身份去重 |
| 桌面切换 | `Spaces/SpaceSwitcher.swift` | 同显示器内循环取下一个/上一个，两端循环 |
| 配置模型 | `Dock/DockConfig.swift` | `PlistValue` / `DockTile` / `DockAppearance` / `DockConfig` / `DesktopBinding` / `AppSettings`（`AppSettings` 手写解码，见下） |
| 图标条规则 | `Dock/DockStripRules.swift` | 启动台必须在首位（已有则原样保留，不覆盖 `GUID`/`book`）、Finder 只是幻影、从 `.app` 造条目、取图标 |
| Dock 偏好 | `Dock/DockPreferences.swift` | 白名单 + 全量域读 + 原子写；**写路径已接线** |
| Dock 重载 | `Dock/DockReloader.swift` | `DockProcessControlling` 协议 + 真实实现；SIGHUP 主路径 → SIGTERM → `launchctl kickstart` 三级降级；**重启节流错开**（`minimumSpacing`）；**发信号前的安全闸门**（见 §4 的 `-1` 陷阱） |
| 应用流水线 | `Dock/DockController.swift` | **双重短路**（内容与上次写下去的一致 / **真实 Dock 已经就是这份内容**）→ 备份 → 读全量域 → 只覆盖白名单键 → 原子写 → 重启 → 读回校验（**不一致重试一次**）；`request()` 带防抖合并；`comparableFingerprint` / `adoptLiveDockAsApplied` / `isApplying` |
| 手动改动回存 | `Dock/DockWatcher.swift` | 轮询真实域的可比指纹，识别用户手动改动 → 回存到当前桌面的绑定（受开关控制）；**纯逻辑 + 注入式读写**，可脱离真实 Dock 单测 |
| 回存撤销栈 | `Dock/DockEditHistory.swift` | 回存前的旧配置暂存（**内存**，每目标 5 层），供电桌面页/通用页的「撤销自动回存」。刻意不落盘，理由见 §3 的 P5 第 6 条 |
| 全屏过滤回归脚本 | `scripts/check-fullscreen-filter.swift` | 把本进程自己的窗口切成全屏 → SkyLight 多出 `type=4` 空间 → 真机验证过滤。**零权限** |
| 配置持久化 | `Store/ConfigStore.swift` | 原子写 `config.json` |
| 基准快照 | `Store/BaselineStore.swift` | 基准 + 会话标记 + 备份轮转（保留 20 份） |
| 菜单栏 | `UI/MenuBarController.swift` | `NSStatusItem`，区分左右键，标题显示当前桌面序号；下拉含桌面列表 / 下一个桌面 / **用当前 Dock 重置本桌面配置** / 刷新 / **立即还原到原始 Dock** / 调试面板 / 设置 / **退出并还原 Dock** |
| 图标条编辑器 | `UI/DockStripEditor.swift` | 拖入/拖出/排序、从访达拖 `.app` 进来、垃圾桶移除、从当前 Dock 抓取；**Finder 与启动台锁在最前** |
| 外观编辑器 | `UI/DockAppearanceEditor.swift` | 位置/大小/放大/自动隐藏/最小化特效/最小化到应用图标/运行指示点；**本机不支持的键禁用并说明原因**；`onCommit` 只在**松手/值变化**时提交，不逐帧落盘 |
| 桌面列表页 | `UI/DesktopListView.swift` | 左列表（改名输入框 + 独立/沿用徽标 + 当前桌面标记）+ 右详情（沿用开关 / 完整图标条 + 外观 / 立即应用 / 抓取 / 重置为默认） |
| 调试面板 | `UI/DebugPanelView.swift` | 当前 spaceUUID/id64/type、桌面列表、实时日志、「测试 toast」按钮 |
| 设置窗口 | `UI/SettingsView.swift` | **顶部报警横幅**（Dock 拉不回来 / 桌面切换不可用）+ 通用（默认 Dock 编辑条 + 外观 + 立即应用 / 立即还原 / 设为新基准 + 本机不支持）/ 桌面（`DesktopListView`）两个 Tab |
| 桌面命名 | `Spaces/DesktopNaming.swift` | 归一化（≤10 字素簇）、显示名解析、改名/改 override 规则；**纯函数，全部有单测** |
| toast 调度 / 窗口 | `UI/ToastPresenter.swift`、`UI/DesktopNameToast.swift` | 纯逻辑调度 + 无边框窗口；跨空间、不抢焦点、零权限 |
| toast 验收工具 | `scripts/check-toast-window.sh` | 用 `CGWindowListCopyWindowInfo` 读窗口元数据（零权限），`--watch` 报告出现/消失时刻 |
| toast 外观预览器 | `scripts/preview-toast.swift` | 在假壁纸上画亮/深色胶囊并输出 PNG（`cacheDisplay` 抓自己的视图，**零权限**）。⚠️ 它是 `DesktopNameToast.swift` 的**副本**，改了那边要同步这里，否则预览骗人 |
| P0 实验脚本 | `scripts/spike-*.{sh,swift}` | 重载策略 / 切桌面 / 停机时长 / 探测（含显示器 UUID 映射） |
| LS 滞后测量脚本 | `scripts/measure-launchservices-lag.swift` | 定向测量 `NSRunningApplication` 在 Dock 重启窗口里**抱着旧 PID 多久**（1 ms 采样、两路同问）。**只读 + 发 SIGHUP**，用来证伪 A8 的第六个假说，见 `docs/spikes.md` 实验 15.3 |
| 打包脚本 | `scripts/build-app.sh` | 编译 → 组装 `.app` → ad-hoc 签名 |
| 显示器名解析 | `Spaces/ScreenNaming.swift` | `displayUUID → NSScreen.localizedName`；**纯解析可单测**，映射不到时如实说"未识别"而不回落成错的屏。桌面页据此按显示器分组 |
| 其他项（文件夹/堆栈）编辑 | `Dock/DockStripRules.swift`、`UI/DockStripEditor.swift` | **只搬不造**：显示 / 排序 / 移除；拖入文件夹时明确拒绝并给替代做法（`DockItemRejection`）。**不能新建**的实测依据见 `docs/spikes.md` 实验 8 |
| 测试 | `Tests/MultiDockTests/` | **319 个测试，全绿**（其中 8 个真实 Dock 验收默认跳过，需显式开启） |
| 设计文档 | `docs/PLAN.md` | 已按 P0 结论修订 |
| 实验结论 | `docs/spikes.md` | **15 个实验**的原始数据与决定（**实验 5 是 P3 挖出的两个要命发现；实验 8 是"其他项不能新建"；实验 9 是"切一次桌面黑屏几分钟"的根因；实验 10 是"每次退出都卡住"—— 同一条链，外加一个让所有"上限"静默失效的写法；实验 11 是用户真机日志复盘；实验 12–14 把"uptime 门槛"等四个假说逐个证伪；实验 15 给未解故障装取证仪表，15.2 是仪表自己的 bug（协议见证位协变陷阱），15.3 把第六个假说也证伪**） |

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

### 未完成

**代码层面：计划里已定义的功能全部落地，但 2026-09-20 的真机日志复盘挖出一条必须再修的。** 剩下的分三类：

- ⚠️ **A8：Dock 重启偶发慢到 26–31 秒，根因未定**（`spikes.md` 实验 11.6 与 12–15）。
  **五个假说已被实测逐个推翻**（uptime 门槛 / 探测路径分叉 / 连发退避 / 写偏好诱因 / **LS 滞后**），
  **不要按任何一个去改代码**；`minimumSpacing` 保持 1 s，`dockPID()` 的 LS 优先也不要动。
  ✅ **已装取证仪表**（2026-09-20，实验 15）：慢重启（> 1 s）时 `DockReloader` 会采样
  `pidProbe()` 的两条路径答案并写进那一行 `Dock 应用成功` 日志（正常路径零开销）。
  下次复现时读 `慢重启取证：…` 就能区分「探测分叉（我们的 bug）」与「Dock 真的没回来（launchd）」。
  **判定规则见 `docs/spikes.md` 实验 15。别为了复现去反复折腾用户的 Dock。**
  ⚠️ **已试过第五次复现并失败**（实验 15.1）：真机验收 20 轮连切（Dock 年龄正好 ~1 s，与故障同构）
  **最坏 74 ms、慢重启 0 次**。→ 成因不在"连续重启"这个形状里，只在真实 App 的完整上下文里。
  ⚠️ **仪表本身曾整个是死的**（实验 15.2，已修）：非可选返回类型撞上协议见证位协变陷阱 →
  通过协议调用永远拿 nil。**已由真机验收测试 + 走 `any` 协议的守卫测试覆盖。**
  ⚠️ **"我们没在看"这个洞已补**（实验 15.4）：`elapsed` 是墙钟、轮询跑在 `@MainActor` 上，
  主线程被冻住时我们会把"没观察"记成"Dock 慢"。现在跟着慢重启日志一起记
  **`轮询 N 次，最长间隔 M ms`** —— M 秒级就是观察窗口断了，不是 Dock 的事。
  ⚠️ **最后一个"我们的 bug"候选（LS 滞后）已证伪**（实验 15.3）：危险窗口 6/6 = 0 ms。
  剩下只有 launchd / Dock 归位本身。**别再顺着这条线改探测代码。**
- ✅ **A9 已结案（2026-09-20）**：用户确认默认 Dock 的 3 个图标（启动台 / FlClash / WorkBuddy AI，
  `orientation = right`）是**他有意配的**。`config.json` **原样保留、一个字节没动**。
  ⚠️ 两条 override（`计划 任务` / `密码 邮件`）的 `appearance.orientation` 是 `"bottom"`，
  与默认的 `"right"` **不同** —— 所以它们**不是**默认的精确副本，**不能"清成沿用默认"**
  （`effectiveConfig(for:)` 是整体替换，不是逐字段合并，清掉会让那两个桌面的 Dock 跑到屏幕右侧）。
  详见 §6.3 A9 与 `docs/spikes.md` 11.4。
- **多显示器热插拔的真机实测**（§6.3 B5）：映射键、插拔后自动刷新、toast 定位、桌面页的显示器名分组都已实现，
  但**本机只有一台显示器，必须用户插一台外接屏才能验**。
- **真人手测 5 条**（§6.3 A 组）：改名输入框、两个按钮、图标条拖拽、菜单栏连击，外加
  **真人把一个文件夹拖进 Dock**（新的「其他项」回存路径最贴切的检验）。
- **注销/关机还原**（B9）、**LaunchAgent 退回**（B10）要真注销 / 重登录一次。

**已完成、可以销账的**：

- ✅ **A6（切桌面黑屏）** 与 **A7（退出卡住）** 的实验 9 / 10 修复**已被用户真机日志覆盖**：
  退出还原 **53–54 s → 0.01 s**；切桌面的最坏值 **60–126 s → 26–31 s**（残余部分转为 A8）。

**明确"不做"的（都有实测依据，别再试）**：

- Dock 里**新建**文件夹 / 普通文件条目 —— Dock 不认领自拼的目录条目，坏形状会让它 SIGABRT（实验 8）。
- 切桌面的左右滑动动画（实验 7）。

**原先的两处"做了但没做全"已在 2026-09-18 补掉**（设置窗口顶部报警横幅，见 §3 的「已完成：P5+」）：
Dock 拉不回来时会红字报警并给「再试一次拉回 / 立即还原到原始 Dock」；`spaceProviderWarning` 会在同一处显示橙色横幅。

### 下一步：P5 已做完，只剩多显示器真机实测

P5 的三条都已落地（README ✅、全屏过滤真机回归 ✅、多显示器加固 ✅），详见 §3 的「已完成：P5」。
剩下的只有一条，而且**只能用户动手**：

1. **多显示器 / 热插拔实测**（§6.3 B5）：`(displayUUID, spaceUUID)` 映射在插拔外接显示器后不能串。
   本机是单显示器，**这条只能靠用户插一台外接屏实测**，别硬编造结论。
   核对手段已备好：调试面板显示「显示器数量」和每个桌面的 `displayUUID` 前 8 位；
   插拔后 App 会自动刷新桌面列表并记一条 `显示器配置变化：桌面列表已刷新（N → M 个）`。

### 用户必须手测的 5 条（无法脚本化，见 §6.3 A 组）

A4 的**逻辑侧已自动化**（`DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop`），
真人拖拽降级为"建议补一次"；剩下 A1–A3 / A5 仍只有单测覆盖，等用户手点。

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
| **toast 窗口几何** | 水平居中、顶边距可见区顶部 80 pt（不变）。**2026-09-19 起改为定高胶囊**：高 32、宽 = 文字宽 + 2×14、下限 76。⚠️ 旧实测值 `w=87 h=39` / `w=193 h=39` 是**改版前**（字号 15、内边距 20/10）的数，**新几何待真机重测**（`scripts/check-toast-window.sh --watch`；它的判别式是 `height >= 30`，32 仍命中）。`layer=25`、`alpha=1.00` 不变 |
| **toast 外观（2026-09-19 改版）** | 从"固定黑底 0.78 + 白字"换成**跟随系统外观的原生 HUD 胶囊**：`NSVisualEffectView`（`material = .popover`、`blendingMode = .behindWindow`、`state = .active`）+ `maskImage` 裁圆角（**`NSVisualEffectView` 没有 `cornerRadius`**，那是 UIKit 的）+ 1 px 动态描边（亮色黑 0.12 / 深色白 0.16）+ 文字 `labelColor`、14 pt semibold。零权限不变 |
| **无屏幕录制权限也能看到自己的视图长什么样** | `NSView.bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` 抓**自己窗口**的内容不需要任何权限（`screencapture` 拍整屏才需要）。`scripts/preview-toast.swift` 就是这么出亮/深两张预览图的。代价：预览用 `.withinWindow` 模糊窗口内的假壁纸，真机用 `.behindWindow` 模糊屏幕内容 —— **材质色调/圆角/描边/字体一致，模糊的实际画面不一致** |
| **`orderOut` 后窗口会在 CG 窗口列表里滞留** | 窗口被 `orderOut` 后 `kCGWindowIsOnscreen` 立刻变 false，但那条记录**还会在列表里留好几秒**才真正消失。用窗口元数据核对「消失」时刻时**必须滤掉 `onscreen == false`**，否则时长会晚报 |
| **`CGWindowListCopyWindowInfo` 读元数据零权限** | 实测在无屏幕录制权限下能读到 `kCGWindowLayer` / `kCGWindowAlpha` / `kCGWindowBounds` / `kCGWindowIsOnscreen`（**读不到 `kCGWindowName`**，那是被系统抹掉的）。所以窗口类验收完全不需要权限 |
| 菜单栏图标（补充） | 自动隐藏菜单栏时状态栏窗口在 `y=-24`、`onscreen=false`、约 51×24 —— 与 toast（`y=80`、高 32、水平居中）天然可区分 |
| 主动切桌面 | `CGSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID)` **可用**，**实测 0–6 ms 生效（瞬时提交，没有动画）** |
| **切桌面没有动画，且做不到**（2026-09-18 复核，`spikes.md` 实验 7） | 程序化切空间是**硬切**：3 轮实测 **6 / 0 / 0 ms**。想加"左右滑动"的四条路全断：① `SLSManagedDisplaySetIsAnimating` 是**粘滞状态位**（置位后 600 ms 内 **101/101** 次采样仍为 true，不会自复位），**且它的返回值是 void ABI 残留寄存器** —— 同一次运行 8 次调用恒为 `-785121165`，换一次运行变成 `-2752379`，**不能当成功标志**；② 会话级开关 `SLSSetSessionSwitchCubeAnimation`（值 `cube`/`transition`/`none`/`""`，对应 `kSLSSessionSwitchTransitionType*`）**只有 set 没有 get**，偏好域里也没有（`CGSessionCopyCurrentDictionary()` 仅 11 个键，全审计/用户/登录态），扫遍 `__TEXT` 5,037,056 字节只有函数名本身 → **改了还原不回去，破无痕原则**；③ `SLSWillSwitchSpaces` 按 `(cid, CFArray)` 试直接 **SIGSEGV**（`array_call_as_integer_list`），签名未知，**别再拿图形会话试错**；④ 合成按键事件被拦（`CGPreflightPostEventAccess()` 返回 true，但**阳性对照合成 `Cmd+Tab` 也不生效**）。真正的过渡在 WindowServer 内部的 `Transition{Slide,Cube,Flip,Blend,Shrink,Spiral,Drop,RadialBlur}Metal`，只服务用户手势 |
| **枚举私有框架导出符号的方法** | `nm` 在磁盘上找不到 SkyLight（框架在 dyld 共享缓存里，磁盘无实体文件）。要在**进程内**解析：`_dyld_get_image_header` 拿镜像 → 遍历 `LC_SEGMENT_64` 取 `__LINKEDIT`/`__TEXT` → **`LC_SYMTAB.symoff`/`stroff` 是共享缓存内的文件偏移**，必须先经 `__LINKEDIT` 换算成 vmaddr 再取指针，直接当指针用会 SIGSEGV。脚本 `scripts/spike-symbols.swift`，本机 SkyLight 共 **23,474** 个导出符号 |
| Dock 热重载 | **不存在**。post `com.apple.dock.prefchanged`（darwin 与分布式两种都试过）完全无效 |
| Dock 重启 | `kill -HUP`：进程消失于 +13 ms、归位 +101 ms（**总不可用约 101 ms**）。`kill -TERM`：Dock 先做约 255 ms 清理，总不可用 **约 367–395 ms**。**主路径选 SIGHUP** |
| **launchd 的重启节流**（P3 实测，`spikes.md` 实验 5） | 距上一次重启**不足约 1 秒**时再次重启，Dock 要 **约 1070 ms** 才归位；间隔 **≥ 1 秒**只要 **约 70 ms**。阈值在 0.6–1.0 s 之间。⚠️ **不是"隐式节流"** —— `com.apple.Dock.plist` 里**本来就写着 `ThrottleInterval = 1`**（`launchctl print gui/501/com.apple.Dock.agent` 显示 `minimum runtime = 1`）。→ `DockReloader.minimumSpacing` 默认 1 s 先等再重启（等待期间 Dock 可用），实测 Dock 不可用时长 **45–90 ms** |
| ⚠️ **别被"uptime 门槛"骗了 —— 那个假说已被实测推翻**（2026-09-20，`spikes.md` 实验 11→12） | 真机日志里 uptime 6.5 s / 1 s 的两次重启花了 **26 046 / 31 039 ms**，而 uptime ≥ 30 s 的 4 次只要 50–126 ms，看起来就是"launchd 有 ~10 s 的 crash-uptime 门槛"。**但控制实验直接证伪**：uptime 6.0 / 12.0 / 20.0 s 各测一次 + 60 s 与 81 486 s 两个对照，**归位耗时 37–68 ms，一次都没被罚**。`com.apple.Dock.plist` 里写的本来就是 `ThrottleInterval = 1`（`launchctl print gui/501/com.apple.Dock.agent` 显示 `minimum runtime = 1`）。→ **`minimumSpacing` 不要动**。26–31 s 属偶发、根因未定，见 §6.3 A8 |
| **节流窗口的判据是 Dock 进程的年龄，不是我们的记忆**（P4 实测修正） | 节流是**按服务**算的，与我们记不记得自己重启过无关。P4 验收里前一条用例刚重启完 Dock，紧接着新建的 `DockReloader`（`lastRestartAt` 为 nil）直接重启，被节流到 **1030 ms** —— 用户会看到 Dock 消失一秒多。→ 改成用 `proc_pidinfo(PROC_PIDTBSDINFO)` 读 `pbi_start_tvsec/tvusec` 算进程年龄（实测返回 **136 字节 = 结构体大小**，读得到）。改完 P3 第一轮从 **1030 ms → 45 ms**。拿不到年龄才退回内存记忆 |
| **`kill -9` 掉 Dock 后的恢复** | ⚠️ **不是个常数，取决于 Dock 当时的年龄**。2026-09-18 首次实测 **1072 ms**（那时 Dock 刚被重启过，吃了一次隐式节流）；2026-09-20 真机验收里再测一次只要 **56 ms**（`69452 → 69457`，那时 Dock 已经活了约 1 秒、节流窗口已过）。→ **判据按"3 秒内必须出现新的正数 PID"给**，别按某个具体毫秒数写断言。`DockPresenceMonitor` 是兜底：**连续缺失 8 轮（默认 500 ms 一轮 = 4 秒）才动手**，之后每 60 轮（30 秒）才重试一次 `kickstart`（反复催只会加深 launchd 退避） |
| **`NSRunningApplication` 会返回 `processIdentifier == -1`** | Dock 重启窗口里 `runningApplications(withBundleIdentifier: "com.apple.dock")` 会返回一个**正在退出**的实例，其 PID 是 **-1**（实测复现）。`kill(-1, sig)` = 发给**当前用户全部进程**，`kill(0, sig)` = 整个进程组。**必须过滤 `> 0`，并在发信号前用 `proc_name` 确认进程名是 `Dock`** |
| **查 Dock PID 的代价** | `NSRunningApplication` **0.6–1.4 ms**；`/usr/bin/pgrep -x Dock` **109–112 ms**（子进程，绝不能放进轮询热路径）；`proc_listpids(PROC_ALL_PIDS)` + `proc_name` **0.02 ms** |
| Dock 进程守护 | `/System/Library/LaunchAgents/com.apple.Dock.plist` 为 `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}` → 必须信号致死才会被拉起；**优雅退出（exit 0）不会重启，用户会当场失去 Dock** |
| **Dock 是否应用了写入** | 判据：写入的 tile 不带 `GUID`，Dock 真正读取并应用后会**补上 `GUID`**。实测正负两种情形都验证过。**回写是异步的**：P2 验收里 apply 返回后立刻读还是 `nil`，轮询 200 ms 内就出现了 → 判据要配轮询，别读完就断言 |
| **只写白名单键：已实测成立** | P2 验收（2026-09-18）：apply 一次（改 `tilesize` + `magnification` + 加一个 Calculator 条目）后与操作前全量域 diff，**变化只有 `magnification` / `persistent-apps` / `tilesize`**，白名单外的键一个都没动 |
| **别的进程写的 Dock 偏好，本进程立刻读得到** | 2026-09-18 实测：`/usr/bin/defaults write com.apple.dock tilesize -float 72` 之后，`CFPreferencesCopyMultiple` 立刻读到 72.0（无需轮询、无需等 Dock 重启）。这条让「用户手拖图标」这件事**可以脚本化复现** —— `DockWatcher` 的判据是"可比指纹变了、且不等于我们写下去的那份"，而用户拖动本来就是 Dock 进程写同一个域，两种来源在偏好域层面**无法区分也不需要区分**。所以 `DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop` 用 `defaults write` + 真实 `DockReloader().reload()` 就等价于一次真人拖动，A4 从"只能手测"变成自动化回归 |
| **写外观键真的生效** | `tilesize` 36 → 52、`magnification` 翻转，写入后域里的值就是新值，且 Dock 重启（PID 变化）。`persistent-apps` 的新条目被补上 `GUID`（实测 `i:1414651200` 等，每次不同）→ Dock 确实按新偏好重建了 Dock |
| **本机白名单键的可用性（逐键实测）** | **可用**：`persistent-apps` `persistent-others` `orientation` `tilesize` `magnification` `largesize` `autohide` `mineffect` `minimize-to-application`。**不存在**：`show-process-indicators`（域里没有）。`autohide-delay` / `autohide-time-modifier` 域里也没有，且 `DockAppearance.read` 读回来是 nil → 压根不进写入集合。结论：**只写"域里已有的键"这条规则就够了**，不需要额外黑名单 |
| **Dock 自己会改的键** | 重启一次 Dock，`mod-count` 就 +1；`recent-apps` 也会变。这两个**不在白名单里、我们从不写**，所以验收时"还原后仍有差异"是正常的。判据是：**差异只能落在白名单键或 `{mod-count, recent-apps, trash-full}` 上** |
| **SIGHUP 实测耗时（P2 复测）** | 连续多次 apply 都是 **125–138 ms**，与 P0 的 101 ms 同一量级。还原路径同样 136–138 ms |
| **非 `.app` 环境里查 Dock 的兜底** | `NSRunningApplication.runningApplications(withBundleIdentifier:)` 在非 `.app` 进程（`swift test` 的 xctest runner）里可能查不到 → `RealDockProcessControl.dockPID()` 兜底走 `scanForDockPID()`（`proc_listpids` + `proc_name`）。⚠️ 文档里旧写法的"用 `pgrep -x Dock` 兜底"**早已不是实现**（`pgrep` 单次 110 ms，见上一行） |
| Finder | `persistent-apps` 里没有 Finder；**全量域 34 个键里没有任何 Finder 相关键或值** → 写偏好无法删除它，"钉住"天然成立，无需代码 |
| Dock 偏好域 | 34 个键；`persistent-apps` 15 项（首项 Launchpad，`file-type=169`、`dock-extra=false`、`bundle-identifier=com.apple.launchpad.launcher`）、`persistent-others` 1 项（下载文件夹）。用户 App 是 `file-type=41`、`dock-extra=true`。**没有** `show-process-indicators` / `autohide-delay` / `autohide-time-modifier` |
| **`.app` 的 `_CFURLString` 带尾斜杠** | 真实域里是 `file:///System/Applications/Launchpad.app/`。`URL(fileURLWithPath:).absoluteString` **不带**尾斜杠 → 必须自己补（`DockTile.directoryURLString(for:)`） |
| **写偏好会不会污染别的键：不会** | `CFPreferencesSetMultiple` + 全量域读回 + 只覆盖白名单键，实测 `mru-spaces` / `wvous-*` / `mod-count` / `recent-apps` 全部原样 |
| **`plutil -p` 比对长数组会错位** | 用 `diff` 比对 `plutil -p` 导出的文本时，数组元素行数不同会导致后面整体错位，产生**假差异**。要判断"成员/顺序变了"就抽出标签序列比，要判断"值变了"就用 `PlistValue` 结构比较（验收测试里 `differences(between:and:)` 就是这么做的） |
| **测试窗口期内别手动改 Dock** | 实测踩过：验收跑到一半 Dock 被外部改动（`persistent-others` 从 4 项变 1 项），"还原后仍有差异"报了假失败 |
| **全屏过滤的真机回归（2026-09-18 实测通过）** | 用 `scripts/check-fullscreen-filter.swift` **把本进程自己的一个窗口切成全屏**（零权限）→ SkyLight 多出一个 **`type=4`、id64=537** 的空间，活动 id64 从 6 变成 537。实测：① 它**没有**被算进用户桌面（type=0 仍是 2 个）；② 活动空间**不再命中**任何用户桌面 → `SpaceObserver` 返回 nil；③ 退出全屏后空间数与活动桌面都回到原样。MultiDock 日志同步印证：`活动空间不是用户桌面（可能是全屏 App），不触发切换`，且从全屏退回桌面**没有**弹 toast。**做法记住**：不用辅助功能也能造出全屏空间 —— 切自己的窗口就行 |
| 多显示器空间 | `com.apple.spaces spans-displays` 不存在 → 默认"显示器各自独立空间"，映射键需 `(displayUUID, spaceUUID)`。**插拔外接屏后必须重读桌面列表**（已接 `NSApplication.didChangeScreenParametersNotification`）；本机单显示器，真机验证仍需用户插屏 |
| **`SMAppService.mainApp` 只在 `.app` 里可用** | `swift test` / `swift run` 的进程不是 bundle（`Bundle.main.bundlePath` 不以 `.app` 结尾），拿不到有效的登录项句柄。所以 `LoginItem.isAvailable` 先看 bundle，不可用时 UI 直接显示原因 —— **不要**在非 bundle 环境里调 `SMAppService.mainApp.status` |
| **历史备份的命名** | `~/Library/Application Support/MultiDock/backups/dock-yyyyMMdd-HHmmss.plist`，最多 20 份。`BaselineStore.listBackups()` 从文件名解析时刻；解析不出来（用户改过名）就退回文件修改时间 |
| **`persistent-others` 的目录条目形状**（2026-09-18 实测） | 真实域里是 `directory-tile`，`tile-data` = `file-data`(`_CFURLString` 带尾斜杠) + `file-label` + `file-type`(**2**) + `arrangement`(2) + `displayas`(0) + `showas`(1) + `preferreditemsize`(字符串 `"-1"`) + `is-beta`(0) + `book`(656 字节书签) + `file-mod-date` / `parent-mod-date` / `GUID`(由 Dock 补) |
| **自拼的目录条目 Dock 不认领**（`spikes.md` 实验 8） | 自己拼 `directory-tile` 写进域后 Dock **不补 `GUID`**（等 4 秒 / 8 秒都不补）；补全展示字段、甚至自己用 `URL.bookmarkData()` 生成 `book` 也一样 → 沿用"没有 GUID = Dock 没读进去"的判据。**且字段不全的形状会让 Dock 直接 SIGABRT**（本机 7 份崩溃报告，launchd 反复拉起 → 崩溃循环，用户当场失去 Dock）。→ 结论：**其他项只搬不造**，要加文件夹必须由用户在访达里自己拖进 Dock |
| **`persistent-others = []` 无害**（实验 8） | 写入空数组 + SIGHUP → Dock **0.6 s** 归位。所以「移除最后一项」不需要设限 |
| **反复杀 Dock 会触发 launchd 递增退避**（2026-09-18 实测） | 连续多次信号致死 + kickstart 之后，`launchctl print` 显示 `state = spawn scheduled`，Dock **几十秒不回来**（正常 SIGHUP 约 100 ms），`kickstart` 也被同一段退避挡住；**静置等待比反复催更快**（实测停手后 8 秒内回来）。⚠️ 原先写的"App 正常使用不受影响"**已被 2026-09-19 实验 9 证伪** —— 正常使用就会踩，见下面两行 |
| **`launchctl kickstart` 会阻塞几十秒**（2026-09-19 实测） | launchd 在退避里时这条命令**直到服务真被拉起才返回**（日志空白实测 54 / 60 / 64 秒）。所以它**绝不能 `waitUntilExit()`** —— 那会把 `@MainActor` 冻住那么久，整个 App（监视器、桌面轮询、toast、设置窗口）全部停摆。判据：500 ms 一轮的存活监视器在两分钟里只留一行日志 |
| **Dock 进程不在时偏好域读回来是残缺的**（2026-09-19 实测） | Dock 死掉的窗口里 `CFPreferencesCopyMultiple` 读到「3 个图标、0 个其他项」，而真实 Dock 是 **15 + 1**。所以任何"读真实 Dock"的路径都要先看 Dock 在不在（`DockController.isDockAlive`），否则会把残缺内容写进配置。本条直接写坏了 `config.json` 里两条 override（见 §3 的「已完成：修掉「切一次桌面黑屏几分钟」」第 6 条） |
| ⚠️ **重载期间 `DockPresenceMonitor` 是刻意静默的**（2026-09-20 复盘） | `tick()` 第一行就是 `guard !isReloading() else { return }` —— 我们自己正在重载时它**不计数、不记日志**（两条控制回路抢同一个服务会把 1 秒滚成两分钟，见实验 8.5）。**代价**：慢重启窗口里日志一片空白，看起来像"监视器没工作"，其实是设计如此。**排查慢重启时别把这段空白当成证据** —— 想知道 Dock 在不在，只能靠 `DockReloader` 自己的取证（实验 15） |
| ⚠️ **`grep -a` 找不到 release 二进制里的短 ASCII 字符串字面量**（2026-09-20 实测） | Swift 对 ≤ 15 字节的字符串字面量用**小字符串（small string）**表示，字节被直接编进指令/寄存器，**不以连续字节序列存在于文件里**。实测：`"LS="`（3 B）、`"scan="`（6 B）、`"nil"`（3 B）在 release 二进制里 `grep -ac` 都是 **0**，而同一个二进制里 `"慢重启取证："`（21 B）和 `"Dock 不可用"`（在一条长格式串里）都能找到。→ **别用 `grep` 判断"新代码有没有进包"**，用字节级搜索（`python3 -c` 里 `open(p,'rb').read().count(b'...')`），或干脆查一个长中文字面量。本次差点因此误判"包是旧的" |
| **release 构建会把只被间接引用的类型名优化掉**（2026-09-20 实测） | 同一个二进制里 `DockPIDProbe`（类型名）计数为 **0**，debug 里为 1 —— 所以"符号不在"不等于"代码没进去"。同上，判据要用行为或长字面量 |
| ⚠️⚠️ **协议要求返回 `T?` 时，具体实现的返回类型必须逐字写成 `T?`**（2026-09-20 实测，代价极大） | 写成非可选的 `T` 时 Swift **不做返回类型协变匹配**，而是把它当成**另一个重载**，协议要求的**见证位由扩展里的默认实现满足**（返回 `nil`）。于是 `Real().method()` 有值、`(Real() as any P).method()` **恒为 nil**，**生产路径静默失效**（`DockReloader` 持有的是 `any DockProcessControlling`），而**替身单测全绿**（替身自己签的是 `T?`）。本次让 A8 的取证仪表**完全没接线**，直到写真机验收才发现。→ **有默认实现的协议要求，必须再写一条"走 `any` 协议"的守卫测试**；替身单测证明不了生产路径接通。守卫见 `DockProcessSafetyTests.testRealControlIsWiredAsTheProtocolWitness`，完整复盘见 `spikes.md` 实验 15.2 |
| ⚠️ **"Dock 不可用 26046 ms" 可能是假的 —— 必须同时看"我有没有在看"**（2026-09-20，`spikes.md` 实验 15.4） | `DockReloader.waitForRestart` 的 `elapsed` 是**墙钟**，而轮询循环跑在 `@MainActor` 上：主线程被别的东西冻住时，循环跑不动 → 我们**根本没在看**，却照样把整段时间记成"Dock 不可用"。**"Dock 慢"与"我们瞎了"在旧日志里长得一模一样。** → 已补 **`waitPolls` + `waitLongestGapMS`**，跟着慢重启那一句日志出来：`… Dock 不可用 26046 ms；轮询 1738 次，最长间隔 18 ms；慢重启取证：…`。判据：次数 ≈ `elapsed / 15 ms` = 一直在看（launchd 侧）；次数远低、最长间隔**秒级** = 观察窗口断了（我们的 bug）。只在 `elapsed > 1` 时记，**快路径日志行一个字节不变**。⚠️ 别再引用 11.6 / 15 里那句"主线程是活的、不是假测量" —— 它**只覆盖 26 秒窗口的前 10 秒**（toast 证据到 `05:32:28.388` 为止） |
| **`NSRunningApplication` 在 Dock 重启窗口里"松手早、认领晚"**（2026-09-20 实测，6 轮） | 发 SIGHUP 后：LS 在 **11–29 ms** 就不再报旧 PID，但直到 **70–93 ms** 才认得新 PID；内核进程表（`proc_listpids`）**26–33 ms** 就看到新 Dock。→ 因为 `dockPID()` 是 **LS 优先 + nil 回退扫进程表**，这半段"认领晚"**完全被回退吃掉**：`dockPID()` 感知到重启的时刻 = 进程表时刻（26–33 ms），**危险窗口（进程表已知新、`dockPID()` 还报旧）6/6 = 0 ms**。附带：有几轮在 400–550 ms 处 LS 又短暂 `nil` 一次（丢掉已认领的 Dock），同样被回退吃掉。→ **A8 的第六个假说（LS 滞后）据此证伪；`dockPID()` 的 LS 优先不要改。** 测量脚本 `scripts/measure-launchservices-lag.swift`，见 `spikes.md` 实验 15.3 |
| ⚠️ **配置损坏会自我固化，不会自愈**（2026-09-20 真机日志复盘，`spikes.md` 实验 11.4） | 残缺的 override 被 apply 到真实 Dock → 真实 Dock 真的变成 3 个图标 → `DockWatcher` **合法地**把这 3 个图标当成"用户的手动改动"回存 → 配置被自己钉死。日志原文：`05:32:12.243 写入 9 个键` → `05:32:12.401 检测到真实 Dock 上的手动改动：3 个图标、0 个其他项` → `05:32:12.422 计划 任务：回存手动改动：3 个图标`。**所以"看 Dock 在不在"的闸门只挡住了 Dock 死掉那一段，挡不住"Dock 活着但我们刚把它写成残缺的"。** 修数据只能用户手动「从当前 Dock 抓取」 |
| **显示器名怎么取** | `NSScreen.localizedName`（如「内建视网膜显示器」）；与 SkyLight `displayUUID` 的换算沿用 `CGDisplayCreateUUIDFromDisplayID`（本文件上文已实测逐字符相同）。**解析不到时不要回落成某台真实屏的名字**，要如实说"未识别显示器（UUID 前 8 位…）" |
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
swift test --disable-sandbox               # 319 个测试（含 8 个默认跳过的真实 Dock 验收）
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
| 9 | **其他项（文件夹 / 堆栈）不能在 App 里新建**（实测所限，见 `docs/spikes.md` 实验 8）：编辑器里只能**排序 / 移除**已有的，要加文件夹必须先去访达自己拖一次。这个折中接受吗？ | 不阻塞 | ⏳ 2026-09-18 已按"**只搬不造 + UI 里写明替代做法**"实现，等用户点头 |

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
| A4 | **P3 验收里"在真实 Dock 手动拖入一个图标，切走再切回仍在"**（真人拖拽是纯 UI 操作，脚本化要辅助功能权限，与硬约束冲突） | 这条是 `DockWatcher` **回存路径的唯一真实检验** | ✅ **逻辑侧已自动化（2026-09-18）**：`DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop` 用 `defaults write` + 真实 `DockReloader().reload()` 复现"外部改动"，走**真实 2 秒轮询**（不手动 `tick()`），两种落点（默认 Dock / 逐桌面 override）都覆盖，并断言回存期间 **Dock PID 不变**。真人拖一次仍建议做（验证拖拽 UI 本身），但已不再是唯一检验 |
| A5 | **「连切 5 次只显示最终名字」只做了单测**，没做真机连击 | 真机是否闪烁未实测 | 单测 `testRapidSwitchKeepsOnlyLatestTextAndHidesOnce` 覆盖调度逻辑；真机需手动快速点菜单栏 |
| A6 | **「切桌面不再黑屏几分钟」还没真机复验**（实验 9 的修复只过了单测） | 这是用户报的最严重故障之一，没复验等于没确认修好 | ⚠️ **2026-09-20 复盘用户真机日志：大部分通过。** 05:02 打包的二进制（**晚于**实验 9 / 10 两个 commit）跑出 6 次真实 apply：**正常路径全是 50–126 ms**（57 / 126 / 84 / 50 ms）。但另两次是 **26 046 ms 与 31 039 ms**。⚠️ **那两次的"原因"一度被归到 `minimumSpacing` 上，已被实验 12–14 证伪**（见 A8）。结论：**60–126 s 那一档没了，26–31 s 这一档偶发、根因未定。** 复核口径：连切十次桌面后，`Dock 不可用` 应稳定在 100 ms 量级 |
| A7 | **「退出不再卡住几分钟」没做真机复验**（实验 10 的修复只过了单测） | 用户报的最严重故障，且是**每次**退出都中招 | ✅ **2026-09-20 复盘用户真机日志：通过。** `05:58:46.001 退出还原流程结束，用时 0.01s`（旧版 **53.12 s / 54.05 s**），整条退出约 2 s，其中 2 s 是 `prepareForTermination` 的等待窗口、**不是 Dock 缺失**。唯一尾巴：这次走了 `!settled` 分支（`还原未完成（退出时还有一次应用没落地），已留下标记`）→ `session.state` 留 `needsSelfHeal = true, pid = 0`，属预期兜底；但**副作用见 A8 第 2 条** |
| A8 | **Dock 重启偶发慢到 26–31 秒**（2026-09-20 真机日志挖出，根因**未定**） | 偶发；正常路径稳定 35–126 ms，所以影响远小于实验 9 的 60–126 s | ⚠️ **五个假说已被实测逐个推翻，别按它们改代码**（`spikes.md` 实验 11.6 / 12–14 / **15.3**）：① ~~launchd 有 10 s uptime 门槛~~ → 实验 12：uptime 6/12/20/60 s **全 37–68 ms**；② ~~`NSRunningApplication` 返回陈旧实例导致探测不到~~ → 实验 13：两条路径 41–116 ms 同量级、无分叉；③ ~~连续快速重启累积退避~~ → 实验 13：6 次连发（间隔 2 s）**全正常**；④ ~~写偏好是诱因~~ → 实验 14：幂等写 + SIGHUP **5 轮 35–46 ms**；⑤ ~~LS 抱着旧 PID 不放导致 `dockPID()` 看不见重启~~ → **实验 15.3：定向测量 6 轮，危险窗口 6/6 = 0 ms**（LS 在 11–29 ms 就松手，早于进程表看到新 Dock 的 26–33 ms）。**→ `minimumSpacing` 保持 1 s、`dockPID()` 的 LS 优先都不要动**（plist 里本来就是 `ThrottleInterval = 1`）。⚠️ **11.6 / 15 里那句"主线程是活的、不是假测量"只对前 10 秒成立**（2026-09-20 复核更正，实验 15.4）：toast 定时器准时开合的证据只到 `05:32:28.388`，而窗口是 `05:32:18.675 → 05:32:44.735`，**后 16.35 秒毫无存活性证据**。→ 仪表已补 **`waitPolls` + `waitLongestGapMS`**（见 §4）。**→ 2026-09-20 已装取证仪表**（`spikes.md` 实验 15）：慢于 1 秒的重载会采样 `pidProbe()`（`NSRunningApplication` vs `proc_listpids`）并写进那一行日志的 `慢重启取证：…` 段，**正常路径一次都不调用**（`testFastRestartDoesNotProbeAtAll` 守着）。下次复现时按实验 15 的判定规则读：早期条目 `scan=<新 PID>` 而 `LS=<旧 PID>` = 探测分叉（我们的 bug）；两条都 `nil` = Dock 真的没回来（launchd 的事）—— **但要先看 `轮询 N 次，最长间隔 M ms`：M 是秒级就说明我们没在看，上面两条都不成立**（实验 15.4）。⚠️ **别为了复现去反复折腾用户的 Dock** —— 偶发故障（那天 6 次中 2 次），等它自己出现。**第五次尝试（2026-09-20 真机验收 20 轮连切，实验 15.1）也没复现**：Dock 年龄正好 ~1 s、与故障同构，结果 **最坏 74 ms、慢重启 0 次** → 成因只在真实 App 的完整上下文里，不在"连续重启"这个形状里。⚠️ **仪表自己一开始也是坏的**（实验 15.2，已修 + 加走 `any` 协议的守卫测试）：非可选返回类型撞上协议见证位协变陷阱 → 通过协议调用永远拿 nil。**至此"我们的 bug"这一侧已经没有候选了。** |
| A9 | ~~两条桌面 override 与默认 Dock 的图标相同 = 坏数据~~ | ~~切过去会得到 3 图标的 Dock~~ | ✅ **已结案（2026-09-20）**：**用户确认默认 Dock 那 3 个图标（启动台 / FlClash / WorkBuddy AI）+ `orientation = right` 是他有意配的** → "图标相同"不再构成损坏证据，他完全可能给那两条也配了同一组。⚠️ **而且它们不能清成「沿用默认」**：override 的 `orientation = "bottom"`，默认是 `"right"`，而 `effectiveConfig(for:)` 是**整体替换**（`binding(for:)?.override ?? settings.defaultDock`）→ 清掉会让那两个桌面的 Dock **跑到屏幕右侧**，是可见的行为改变。**结论：`config.json` 原样保留，要改由用户在 UI 里自己改。** ⚠️ 本节数字在 2026-09-20 被更正过两次，第一次是我读取脚本用错 JSON 键名（`apps`/`others` ≠ 真实键 `pinnedApps`/`otherItems`）读出的假象 —— 见 §5 那条约定 |
| A10 | ~~`session.state` 的假欠账会在下次启动抹掉用户自己加的 Qoder CN~~ | ~~用户的 Dock 改动被无声回退~~ | ✅ **已解决（2026-09-20）**：那笔债是假的 —— 日志里 `05:58:45.991 开始还原到原始 Dock：15 个图标` 之后 Dock 确实回到了基准态，`needsSelfHeal` 只是 `prepareForTermination` 发现"有排队中的 apply 没落地"留下的兜底标记。已备份后移除 `session.state`（`session.state.bak-20260920-044624`）。**注意 `impliesDirtyDock` 是 `appliedFingerprint != nil \|\| needsSelfHeal == true`，只清 `needsSelfHeal` 不够** |
| **B. 待做的功能（已排期）** | | | |
| B5 | **多显示器仍未真机实测**（P5 唯一剩下的）：映射键、插拔后自动刷新、toast 的 `displayUUID → NSScreen` 定位都实现了，但本机只有一台显示器 | 插外接显示器后映射可能串 | **只能靠用户插一台外接屏实测**。调试面板已加「显示器数量」与每个桌面的 `displayUUID` 前 8 位，核对时用 |
| B6 | ~~全屏 App 空间的过滤只有单测覆盖~~ | 每次进全屏可能误切 Dock | ✅ **已解决（2026-09-18）**：真机回归通过，见 §4 的「全屏过滤的真机回归」与 `scripts/check-fullscreen-filter.swift` |
| B7 | **用户手动切桌面时 `activeSpaceDidChange` 通知是否触发**未知 | 只影响"能否把跟随延迟从 300 ms 降到接近 0" | P5 顺手测 |
| B8 | **手动移除 Finder 是否落键**未验证 | 若有新键需纳入白名单 | 可选，30 秒。步骤见 `docs/spikes.md` 实验 3，风险低 |
| B9 | **注销/关机路径只能尽力还原**（系统不给等待时间） | 关机瞬间可能来不及写完基准 | 已按"先留债务标记、下次启动自愈"处理，见 §3 的 P4 第 9 条。真要验证得注销一次机器 |
| B10 | **登录启动的 LaunchAgent 退回方案没在真机跑过**（本机 SMAppService 那条路没触发过退回） | 未签名场景下可能开了没用 | 需要真的重登录一次验证。逻辑侧只有 plist 内容有单测 |
| B11 | ~~README 还停在 P1 状态~~ | 用户照 README 操作会得到错误信息 | ✅ **已解决（2026-09-18，P5）**：整篇重写，含完全卸载三步与整域还原命令 |
| B12 | ~~编辑条竖排未实现~~ | 位置改成左/右后，编辑条与实际 Dock 长得不一样 | ✅ **已解决（2026-09-18，P5）**：`DockStripEditor.isVertical` + `SlotSizing` |
| B13 | ~~孤儿绑定不清理也不提示~~ | 配置越积越多、看不出哪些还有效 | ✅ **已解决（2026-09-18，P5）**：桌面页横幅 + 「清理」按钮 + 二次确认。**绝不自动删**（拔外接屏会误伤） |
| B14 | ~~`DockWatcher` 回存前不存历史版本~~ | 用户手改被误判时，旧配置找不回来 | ✅ **已解决（2026-09-18，P5）**：改成内存撤销栈 `DockEditHistory` + UI 上的「撤销自动回存」。**刻意不落盘** —— 落盘一堆没有恢复入口的文件是花架子 |
| **C. 参数与取舍（记录在案）** | | | |
| C1 | **`DockWatcher` 轮询周期 2 s 是拍的**，没有实测依据 | 用户手动改 Dock 后最长 2 s 才被回存 | 按用户体感调 |
| C2 | **一次切换的应用总耗时约 1 秒**（其中 Dock 只消失 45–90 ms，其余是主动错开节流的等待） | 切桌面后 Dock 配置生效有一秒延迟，但期间 Dock 可用 | 按"宁等不闪"处理，见 §6.1 第 6 条 |
| C3 | **「立即还原」与退出还原都只比白名单键**，`mod-count` / `recent-apps` 不会被还原 | 这两个是 Dock 自己的计数器，还原它们没意义 | 有意为之 |
| C4 | **`DockWatcher` 只在"本次运行写过 Dock"后才回存**（`appliedFingerprint != nil`） | 启动后没应用过任何配置时，用户手动改 Dock 不会被回存 | 有意为之：否则会把用户原来的 Dock 当成"该回存的改动" |
| C5 | **节流窗口按 Dock 进程年龄算**（`proc_pidinfo`），不再只依赖内存里的 `lastRestartAt` | 拿不到进程年龄时会退回内存记忆，那种情况下"别人刚重启过 Dock"仍可能让我们吃一次 1 秒节流 | 有意为之：进程年龄是事实，内存是猜测。见 §4 的"节流窗口判据" |
| C6 | **自愈在启动后异步执行**，不阻塞启动 | 启动瞬间 Dock 可能还是脏的，约 1 秒后恢复 | 有意为之：阻塞启动比晚一秒更糟 |
| C7 | **其他项（文件夹 / 堆栈）只能排序 / 移除，不能新建**（`spikes.md` 实验 8） | 用户没法在 App 里给 Dock 加文件夹，只能先去访达拖一次 | 有意为之：Dock 不认领自拼的目录条目，做了就是假开关；字段不全的形状还会让它 SIGABRT。替代做法已写进 UI 文案 |
| C8 | **显示器名解析不到时不回落成主屏名** | 极端情况下列表标题显示"未识别显示器（UUID 前 8 位…）" | 有意为之：显示一个错的屏比显示"未识别"更糟（toast 那边仍按"回落主屏"处理，因为提示必须弹出来） |
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

---

## 7. 给下一个 session 的建议顺序

1. 读本文件 → `docs/PLAN.md`（§3 核心机制、§3.10 桌面命名与 toast、§3.11 无痕与自愈、§3.3 退出流程、§4 阶段与验收）→ `docs/spikes.md`（**15 个实验结论，含对计划的多处修正；实验 5 有两个要命发现，实验 6 是节流窗口的判据修正，实验 7 是一条"别再做"的动画结论，实验 8 是"其他项不能新建"，实验 9 是"切桌面黑屏几分钟"的根因，实验 10 是"每次退出都卡住几分钟"的根因 + 那条 `withTaskGroup` 的静默失效，实验 11 是真机日志复盘，实验 12–14 把它的四个假说全部证伪，实验 15 是给未解故障装取证仪表 —— 15.2 仪表自己的 bug，15.3 第六个假说也被证伪**）。
2. 跑一次基线：`swift build -c release --disable-sandbox && swift test --disable-sandbox && ./scripts/build-app.sh`，确认全绿（应为 **319 个测试通过、零警告**）。
3. **动 Dock 相关代码前先读 §4 的七条**："launchd 重启节流"、"节流窗口判据"、"`-1` PID 陷阱"、
   "查 Dock PID 的代价"、"**`launchctl kickstart` 会阻塞几十秒 → 绝不能 `waitUntilExit()`**"、
   "**`withTaskGroup` 当"赛跑"用会让上限静默失效**"、"**协议要求 `T?` 时实现必须逐字写 `T?`**"。
   踩到节流会让 Dock 消失一秒多；踩到 `-1` 会杀掉用户的全部进程；踩到同步 `kickstart` 会把整个 App 冻住两分钟
   （见 `docs/spikes.md` 实验 9）；踩到任务组那个坑会写出一堆"看着有上限、其实没有"的等待（实验 10）；
   踩到见证位那个坑会让整条功能**静默不接线而单测全绿**（实验 15.2）。
4. 需要动 Dock 的改动，验收用 `MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`；**跑之前先 `defaults export com.apple.dock` 备份，且中途别手动改 Dock**。
   ✅ **2026-09-20 实跑通过：8 个用例全绿、40.7 s**，跑完 Dock 域与备份逐键一致（只差 `mod-count`）。
   ⚠️ **退出码可能是非 0，那不是测试失败** —— 是 SwiftPM 报的
   `[sandbox] … /Users/apple/.swiftpm/security (file-write-unlink)` 拦截消息。判据看
   `Executed N tests, with 0 failures`。`testSwitchingBetweenTwoDesktopConfigsIsStable` 会把
   **慢重启（≥300 ms）连同取证时间线单独打印**，是抓 A8 最省事的入口。
   ⚠️ **`testSlowProbeTimelineWorksAgainstTheRealDock` 的阈值必须是 `.zero` 而不是 `1 ms`** ——
   后者有竞态（探测机会在第二轮轮询，Dock 若在那之前回来就先返回、一条不记），实测一次空三次有。见实验 15.2。
5. **只剩 A8 一条待攻**（2026-09-20 第 22 次更新；A6 / A7 已由用户真机日志销账，**A9 已由用户结案**）：
   - ✅ **A9 已结案**：默认 Dock 的 3 个图标是用户有意配的；两条 override 的 `orientation = "bottom"`
     与默认的 `"right"` 不同，**不是副本、不能清成沿用默认**（整体替换语义）。
     `config.json` 已按用户意愿原样保留，**别去动它**。
   - ✅ **A10 已处理**：`session.state` 那笔假欠账已清（备份在 `session.state.bak-20260920-044624`），
     下次启动不会再把用户自己加的 Qoder CN 抹掉。
   - ⚠️ **A8**：Dock 重启偶发慢到 **26–31 s**，**根因未定**。`spikes.md` 实验 11.6 已列清**五个被推翻的假说**
     （含"把 `minimumSpacing` 提到 10 s"那条，以及实验 15.3 的"LS 滞后"）—— **别再试这五个方向**。
     **"我们的 bug"这一侧已经没有候选了**：仪表已真机验过（15.2 修好后 4/4 稳定产出时间线），
     探测路径的两条答案在正常重启下**不分叉**（危险窗口 0 ms），
     **"我们没在看"这个洞也补上了**（15.4：`轮询 N 次，最长间隔 M ms`）。
     **下一步不是去复现，而是等它自己出现**：取证仪表已装进 `build/MultiDock.app`（实验 15），
     真机下一次偶发时 `multidock.log` 里那一行会出现 `慢重启取证：…` 与 `轮询 N 次…`，
     照实验 15 / 15.4 的判定规则读即可定案。**读的时候先看 `最长间隔 M ms`** ——
     M 是秒级就说明观察窗口断了，别急着归到 launchd 头上。
     ⚠️ 排查时记住：慢重启窗口里 `DockPresenceMonitor` **刻意静默**（§4 有一条），日志空白是预期。
   - 真要再跑真机复验时：⚠️ **改了代码一定要重新 `./scripts/build-app.sh` 才算装上去** ——
     A6 已经在 2026-09-19 被"跑了一个修复前的二进制"骗过去一次。复验前**先把 `multidock.log` 转走**（旧版单测把它灌满了假记录，
     真历史已被 512 KB 环形截断挤掉；新版测试不再写它了）。
6. 其余只能人点的：A1–A3、A5（改名框、两个按钮、图标条拖拽、菜单栏连击），
   外加 **A4 建议补一次真人拖文件夹进 Dock**、B9（注销/关机）、B10（LaunchAgent 退回）。
7. **多显示器实测**：请用户插一台外接屏，用调试面板的「显示器数量」+ 每个桌面 `displayUUID` 前 8 位核对有没有串。
8. ~~可选的两处收尾：Dock 拉不回时的 UI 提示、降级报警横幅进设置页~~ → ✅ 都已在 P5+ 做完
   （设置窗口顶部的 `WarningBanner`）。
9. 收尾：按 §0 更新本文档 + `git commit`。

> ⚠️ **给写代码的 agent 的一条工程提醒**：同一个文件**不要在同一条消息里发两个编辑** ——
> 实测会静默丢掉其中一个（本次会话踩了三次，都是靠编译错误才发现）。一个文件一次改一处。

---

## 8. 会话记录

> append-only，**最新在最上面**。每条记录：这次做了什么 / 当前进度 / 未解决的事。

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

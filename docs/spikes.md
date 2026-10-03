# P0 实验结论

> 执行日期：2026-09-18（实验 1–16 于 macOS 15.7.9 完成；实验 17–22 于 2026-10-03/04、macOS 15.8.1 完成）
> 机器：x86_64 / 单显示器 / Swift 6.2.4。本文结论直接决定 `docs/PLAN.md` 的主路径与事件源设计。
> 原始数据留在 `/tmp/multidock-spike/`（临时目录，不随项目走）；可复现脚本见 `scripts/spike-*.{sh,swift}`。

---

## 摘要：结论

> 实验 1–3 是 P0 阶段的原始三问；实验 4–7 是后续阶段落地时**挖出来的新发现**，其中实验 5、6 各推翻了
> `docs/PLAN.md` 的一处假设，实验 7 是一条**明确的不做项**（别再去试）；实验 8 是一条**明确的不做项**（其他项不能新建）；
> 实验 9、10 是同一条自我放大链的两个触发点（切桌面 / 退出）；实验 11 是**用户真机日志**复盘，修正了实验 5 的节流阈值；
> **实验 12–14 是三个控制实验，把实验 11 提出的四个假说全部证伪**；**实验 15 是给这个未解故障
> 装取证仪表**；**实验 16 落地修法（不等，催）并把代价从 26–31 s 压到 ~1–3.5 s**；
> **实验 17：CoreDock MIG 通道探路（条目键无第三方通道，B15 结案）**；**实验 18：真人手势切换 5/5
> 触发通知（B7 结案）**；**实验 19：系统更新到 15.8.1，GUID 回填判据失效并版本化**；
> **实验 20：自动隐藏三明治（重启不可见）**；**实验 21：次级条几何源（Dock 条不是独立 CG 窗口）**；
> **实验 22：Dock 实际显隐没有零权限直读信号（同步显隐的启发式由此而来）**。共 **22 个实验**。

1. **不存在热重载**。写偏好后无论 post 什么通知，Dock 都不会重新读取——必须重启 Dock 进程。
2. **重启很快**：SIGHUP 后 Dock 仅约 **101 ms** 不可用；SIGTERM 约 **395 ms**（Dock 收到 TERM 会先做约 255 ms 清理再退出）。→ **主路径定为 SIGHUP**，SIGTERM + kickstart 作兜底。
3. **程序化切桌面可用且极快（P0 粗测 20 ms，后经实验 7 精测为 0–6 ms），但不触发 `NSWorkspaceActiveSpaceDidChangeNotification`**。→ SpaceObserver 必须以**轮询为主**，通知只能当优化。
4. **切桌面的"左右滑动动画"做不到**（实验 7）：程序化切空间是硬切（0–6 ms），SkyLight 不暴露带过渡的入口；唯一像入口的会话级开关**写后读不回**、碰了就破无痕原则；`SLSWillSwitchSpaces` 签名未知、猜错直接段错误。**零权限 + 无痕下无解，不要再试。**
5. **其他项（文件夹 / 堆栈）不能由 App 新建**（实验 8）：自拼的 `directory-tile` Dock 不认领（不补 `GUID`），字段不全的形状还会让 Dock **SIGABRT 进崩溃循环**。→ 只搬不造。
6. ⚠️ **"Dock 重启被罚几十秒"的四个假说已被逐个实测推翻**（实验 11 提出，实验 12–14 证伪）：
   真机日志里 uptime 6.5 s / 1 s 的两次重启花了 26 s / 31 s，而 uptime ≥ 30 s 的 4 次只要 50–126 ms。
   看起来像"uptime 门槛"，但**控制实验一次都没复现**：
   | 假说 | 实验 | 结果 |
   | --- | --- | --- |
   | launchd 有 ~10 s 的 uptime 门槛 | 实验 12 | ❌ uptime 6 / 12 / 20 / 60 s **全部 37–68 ms** |
   | `dockPID()` 优先走 `NSRunningApplication` 会拿到陈旧实例 | 实验 13 | ❌ 两条路径 41–116 ms 同量级，无分叉 |
   | 连续快速重启触发退避 | 实验 13 | ❌ 6 次连发（间隔 2 s）**全部正常** —— ⚠️ 但**间隔 2 s 根本没构成违规**（`ThrottleInterval` = 1 s），这条"证伪"站不住，**实验 16.2 用 10 轮零间隔重测才算真的证伪** |
   | 写偏好这一步是诱因 | 实验 14 | ❌ 幂等写 + SIGHUP，5 轮 **35–46 ms** |
   → **`minimumSpacing` 不要动**（`com.apple.Dock.plist` 里 `ThrottleInterval` 本来就是 1）。26–31 s 属**偶发、根因未定**。
   ⚠️ **实验 16：修法已落地，代价从 26–31 s 压到 ~1–3.5 s** —— 关键在于真机日志里一直被忽略的那半截：
   `05:33:16` 那次 **SIGHUP 等满 30 s 没等到，紧接着一发 `kickstart` 只用 0.5 s 就把它拉回来了**。
   于是 `kickstart` 从"30 秒后的兜底"提到"**500 ms 后的催办**"（`nudgeAfter`），`timeout` 30 s → 3 s。
   配套实测：① **连续零间隔重启 10 轮，延迟恒为 ~1016 ms、不累积**（假说 ③ 至此真证伪，
   那 ~1 s 是**硬顶**不是斜坡）；② `kickstart`（不带 `-k`）对**运行中**的 Dock 是无害 no-op
   （PID `80643 → 80643`）；③ 顺手修掉"对刚归位的 Dock 补 SIGTERM 会把它再杀一次"这个潜伏 bug。
   机制推断：`KeepAlive = {SuccessfulExit: 0}` 只在**异常退出**时自动拉起，Dock 若干净退出就**不会**
   被重新调度，直到有东西**显式要求** —— `kickstart` 正是那个要求。**成因本身仍未直接观测到**
   （系统日志在沙箱里读不到），预测与下一次复现的读法见实验 16.4 / 16.8。
   ⚠️ **剩下的两种病因旧日志分不出来**（"探测分叉" vs "Dock 真的没回来"），因为重载期间
   `DockPresenceMonitor` 刻意静默、`waitForRestart` 只记结果不记过程 →
   **实验 15 已给慢路径装上取证仪表**（`DockPIDProbe` / `probeTimeline`，正常路径零开销）。
   下一次偶发时看那一行日志就能定案。判定规则见实验 15。
   ⚠️ **实验 15.1：真机验收 20 轮连切（Dock 年龄正好 ~1 s，与故障同构）最坏 74 ms、慢重启 0 次**
   —— 这已是**第五次没复现**，说明成因不在"连续重启"这个形状里，而在真实 App 的完整上下文。
   ⚠️ **实验 15.2：仪表本身一开始是坏的** —— `RealDockProcessControl.pidProbe()` 的返回类型写成
   非可选，撞上 Swift 的**协议见证位协变陷阱**，于是**通过协议调用永远拿到 nil**，生产路径上的
   仪表完全是死的，而 6 条替身单测全绿。已修 + 加回归守卫（**故意走 `any` 协议**）。
   ⚠️ **实验 15.3：第六个假说（LS 滞后）也被证伪** —— 定向测量 6 轮：`dockPID()` 的 LS 优先
   造成的**危险窗口恒为 0 ms**（LS 在 ~25 ms 就松手，早于进程表看到新 Dock）。`dockPID()` 不要改。
   ⚠️ **实验 15.4：补上最后一个洞** —— 11.6 / 15 里那句"主线程是活的、不是假测量"**只覆盖了
   26 秒窗口的前 10 秒**（toast 定时器的证据到 `05:32:28.388` 为止），后 16 秒毫无存活性证据。
   仪表已补 **"轮询次数 + 最长间隔"**：次数 ≈ `elapsed / 15 ms` = 一直在看（launchd 侧）；
   次数远低、最长间隔秒级 = **我们没在看**（我们的 bug）。
   → **"我们的 bug"这一侧已经没有候选了**，剩下只有 launchd / Dock 归位本身。
7. **实验 9 与实验 10 的修复已被真机覆盖**：退出还原 **53–54 s → 0.01 s**（整条退出约 2 s）；
   切桌面的最坏值 **60–126 s → 26–31 s**。**正常路径稳定在 35–126 ms**，且连续 6 次快速重启也不慢。
8. **切桌面不再需要重启 Dock**（2026-10-04 起的默认形态，实验 20–22）：**冻结模式**（原生 Dock = 默认 Dock，
   切桌面零写入零重启）+ **次级 Dock 条**（随桌面换图标、固定几何、与原生 Dock 同步显隐）。
   仍需重启时（未冻结模式 / 手动应用 / 启动对齐）走 SIGHUP + **自动隐藏三明治**，**重启不可见**（无黑屏闪烁）。

---

## 实验 1：Dock 重载策略（决定 §3.5）

脚本：`scripts/spike-reload.sh`（配套 `scripts/spike-probe.swift` 取客观信号）

### 判据怎么来的

截图验证不可行：本机未授予屏幕录制权限，`screencapture` 只返回壁纸（无菜单栏、无窗口）。这也符合项目「不申请系统权限」的约束，所以改用两个**无需任何权限**的客观信号：

| 信号 | 含义 | 可信度 |
| --- | --- | --- |
| **tile 的 `GUID` 是否被补全** | 写入的 tile 故意不带 `GUID`。Dock 一旦真正读取并应用 `persistent-apps`，会规范化并回写 `GUID` | **决定性**：重启后实测从 `guid=NO` 变 `guid=yes`，已验证正负两种情形 |
| Dock 进程 PID 是否变化 | 区分「热重载」与「进程重启」 | 决定性 |

### 结果

每级都在上一级基础上叠加，逐级升级触发强度。写入内容：① 向 `persistent-apps` 追加一个 Calculator tile；② `tilesize` 36 → 72。

| 级别 | 做法 | PID 变化 | tile 生效（GUID） | 判定 |
| --- | --- | --- | --- | --- |
| **T0** | 只写偏好，不触发（观察 8s） | 不变 | `guid=NO` | ❌ 无效 |
| **A** | 写偏好 + post 通知 | 不变 | `guid=NO` | ❌ 无效 |
| **B** | `kill -HUP` | **535 → 18757** | `guid=yes` | ✅ 生效，但**是重启不是热重载** |
| **C** | `kill -TERM`（launchd 自动拉回） | **20952 → 23628** | `guid=yes` | ✅ 生效（重启） |

A 级测了两种通知，**都无效**：

- `notifyutil -p com.apple.dock.prefchanged` 与 `notifyutil -p AppleNoRedisplayAppearancePreferenceChanged`（darwin 通知）
- 以及用 `NSDistributedNotificationCenter.postNotificationName(..., deliverImmediately: true)` 真·分布式通知 post 同名两个通知

> ⚠️ 计划 §3.5 曾推测「Dock 二进制导入了 `_signal` 与 `DispatchSource.makeSignalSource`，存在无重启热重载的可能」。**实测证伪**：Dock 确实响应信号，但响应方式是**直接退出**，不是重载。A/B 的"零闪烁"预期不成立。

### 停机时长实测（毫秒级采样，`scripts/spike-dock-downtime.swift`）

| 信号 | 进程消失于 | Dock 归位 | 进程消失→归位 | **总不可用窗口** |
| --- | --- | --- | --- | --- |
| SIGHUP | +12.7 ms | +100.7 ms | 88 ms | **约 101 ms** |
| SIGTERM | +271.4 ms | +367.4 ms | 96 ms | **约 367 ms** |
| SIGTERM（复现） | +254.9 ms | +394.8 ms | 140 ms | **约 395 ms** |

**SIGHUP 比 SIGTERM 快约 4 倍**：SIGTERM 可被捕获，Dock 会先做约 255 ms 的退出清理；SIGHUP 则几乎立即终止。

### 决定

> **§3.5 主路径 = SIGHUP（原 B），兜底 = SIGTERM + `launchctl kickstart -k gui/$UID/com.apple.Dock.agent`（原 C）。**

- 原计划把 B 定位为"热重载、零闪烁"是错的，但**它仍是最优解**——只是收益从"零闪烁"降级为"闪烁仅约 100 ms"。
- 计划里 C 的 0.3–1 s 闪烁预估**偏悲观**，实测 367–395 ms。
- **launchd 配置已验证**：`KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}`。SIGHUP/SIGTERM 都是信号致死，launchd 都会拉回；**绝不能用 AppleEvent 优雅退出**（exit 0 不会被拉回，用户会当场失去 Dock）。
- UI/README 的措辞可从"Dock 会短暂刷新"细化为"**约 0.1 秒**"。

### 残留风险（P1/P2 需处理）

- **SIGTERM 的 255 ms 清理窗口存在竞态**：我们写偏好 → Dock 在退出前回写自己的状态，理论上可能覆盖我们的写入。本次实测未发生（写完立刻 TERM，重启后 `guid=yes`），但**不能假设永远安全**。建议：应用后校验指纹，不一致则重试一次。
- 选 SIGHUP 等于放弃 Dock 的退出清理，理论上可能打断它正在写的其他状态。由于我们**只覆盖白名单键**且每次写前全量备份，风险可接受。

---

## 实验 2：主动切桌面（决定 §3.1 事件源）

脚本：`scripts/spike-switch.swift`

### 结果

| 项 | 实测 |
| --- | --- |
| `CGSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID)` | **可用**，活动 space 真的从 id64=6 变到 7 |
| 生效耗时 | **20 ms**（首次采样即已切换）—— 这是**当时的采样粒度**，不是真实耗时。实验 7 用 500 µs 粒度重测得到 **6 / 0 / 0 ms** |
| 切回原桌面 | 正常 |
| 切换动画 | ⚠️ **本行原写"有系统自带动画"，2026-09-18 复核证伪** —— 是**瞬时硬切，没有动画**，见实验 7。不过"无动画时长控制符号"这半句是对的（`CGSSetWorkspaceAnimationDuration` 等均不存在） |
| **`NSWorkspaceActiveSpaceDidChangeNotification`** | **未触发，0 次**（观察窗口 2.5 s，程序化切换） |

### 通知为 0 是真实结论，不是环境问题

做了对照实验：同一个 CLI 进程里注册 `NSWorkspace` 的多个通知，然后用 `NSWorkspace.openApplication` 启动 Calculator —— `didActivateApplication` 与 `didLaunchApplication` **都正常收到**。说明通知通道本身工作正常。

> **结论：程序化切换桌面不会触发 `activeSpaceDidChange` 通知。** 该通知大概率只在**用户主动切换**（Ctrl+←/→、Mission Control、点击 Dock 上的窗口）时发出。

### 决定

> **§3.1 的事件源主次必须反转：轮询为主（建议 300 ms），通知为辅（若用户主动切换时确实会触发，则可作为"快速通道"降低延迟）。**

- 计划原文写「`NSWorkspaceActiveSpaceDidChangeNotification`（主）+ 1 秒轮询（兜底）」，**对程序化切换完全不成立**，必须改。
- 轮询间隔从 1 s 收紧到 **300 ms**：因为切桌面本身只要 0–6 ms，1 s 的检测延迟会让"切桌面 → Dock 更新"明显滞后。300 ms 轮询的开销可忽略（一次 `CGSGetActiveSpace` + `CGSCopyManagedDisplaySpaces` 是纯内存调用）。
- **我们自己发起的切换必须走"预应用"**（先改 Dock 再切空间，见 §3.4 第 8 条）——现在这条从"优化"升级为**必需**，因为切换后我们收不到任何通知。
- **待用户确认的开放项**：用户手动切桌面时通知是否触发。验证方法（P1 验收时顺便做）：
  ```bash
  # 终端 A：监听 30 秒，期间用 Ctrl+→ 手动切几次桌面
  swift scripts/spike-switch.swift 0   # 或直接看 App 调试面板的日志
  ```
  这个结果只影响"能否把延迟从 300 ms 降到接近 0"，不影响可用性。

### 附带发现：空间字典的真实键名

`CGSCopyManagedDisplaySpaces` 返回的 space 字典实际键为：

```
uuid / ManagedSpaceID / id64 / type / WindowManagerInfo
```

**没有 `ManagedSpaceUUID`**——`docs/PLAN.md` §1 与 `AGENTS.md` §4 里记的这个键名是错的，已同步更正。另外 display 字典里有 `Current Space` 键可直接取当前空间。

---

## 实验 3：Finder 图钉（决定 §3.6）

### 结果

对全量域 34 个键做递归扫描（含所有嵌套值与数组元素），搜 `finder` / `com.apple.finder`：

```
无任何 Finder 相关键或值
```

`persistent-apps` 共 15 项，首项是 Launchpad（`file:///System/Applications/Launchpad.app/`），**列表中没有 Finder**。按名字猜测的控制键也不存在（只有 `persistent-apps` / `persistent-others`）。

### 决定

> **Finder 完全由 Dock 隐式渲染，在 plist 里没有任何表示 → 写偏好无法删除它 → "钉住 Finder"天然成立，无需任何代码。**

三条推论：

1. `DockStripEditor` 里 Finder 以**锁定项**渲染在最前，但**不需要也不能**把它写进 `persistent-apps`。
2. Finder **无法被排序**——它永远在最左（或最上）。UI 上不要给它拖拽手柄。
3. **不需要**把任何新键加入白名单。

### 残留未知（需手动验证一次）

计划原文要求「从真实 Dock 移除 Finder，看 `com.apple.dock` 是否新增键」。这一步**无法脚本化**：把 Finder 从 Dock 拖出是纯 UI 操作，脚本化需要辅助功能权限，与「不需要任何系统权限」的硬约束冲突。

**手动验证步骤**（30 秒，随时可做，做完告诉我结果）：

```bash
# 1. 快照
defaults export com.apple.dock /tmp/dock-before-finder-removal.plist
# 2. 手动：按住 Finder 图标拖出 Dock，松手
# 3. 对比
defaults export com.apple.dock /tmp/dock-after-finder-removal.plist
diff <(plutil -p /tmp/dock-before-finder-removal.plist) <(plutil -p /tmp/dock-after-finder-removal.plist)
```

- 若 `diff` 为空 → 确认 Finder 移除**不落任何键**，结论闭环。
- 若新增了键 → 该键需纳入白名单并强制保持固定态，我会回来改 §3.6 与白名单。

风险等级低：即便存在该键，我们的实现从不写它，用户也只在"手动把 Finder 拖出"时才会遇到。

---

## 实验 4（P2 落地复测，2026-09-18）：写入白名单键 + Dock 是否真的读进去

P0 只验到了"信号能让 Dock 重启、`GUID` 会被补全"。P2 把写路径真的接起来后，又复测了一轮**端到端**行为。全部由 `Tests/MultiDockTests/DockAcceptanceTests.swift` 自动执行（默认跳过，`MULTIDOCK_DOCK_ACCEPTANCE=1` 开启），跑完自动把操作前的全量域写回去。

**做法**：读全量域 → 构造一套不同的配置（`tilesize` 36→52、翻转 `magnification`、追加一个**不带 `GUID`** 的 Calculator 条目）→ 写偏好 + `kill -HUP` → 读回校验 → 与操作前 diff → 还原 → 再 diff。

| 观测项 | 结果 |
| --- | --- |
| SIGHUP 耗时 | **125–138 ms**（与 P0 的 101 ms 同一量级），`verifyAttempts == 1`（不需要重试） |
| 变化的键 | **只有 `["magnification", "persistent-apps", "tilesize"]`** —— 白名单外的键（`mru-spaces` / `wvous-*` / `mod-count` / `recent-apps` …）一个都没动 ✅ |
| Dock 是否真的读进去了 | **是**。写入时故意不给 `GUID`，Dock 重启后给补上了（实测 `i:1414651200` / `i:2713705933` / `i:1414651200`，每次不同） |
| **`GUID` 回写的时机** | **异步**。`apply` 返回后立刻读还是 `nil`，轮询 200 ms 内出现。**判据必须配轮询**，否则会误判成"写入没生效"（第一轮验收就是这么误报的） |
| 还原后 | 图标顺序逐项回到原样、白名单键逐键一致、键集合一致（34 键）。**仅剩 `["mod-count", "recent-apps"]`** |
| **Dock 自己会改的键** | 重启一次 Dock，`mod-count` 就 +1；`recent-apps` 也会变。这两个不在白名单里、我们从不写 → 验收时"还原后仍有差异"是**正常的**。判据放宽成：差异只能落在白名单键或 `{mod-count, recent-apps, trash-full}` 上 |
| 本机白名单键可用性 | **可用**：`persistent-apps` `persistent-others` `orientation` `tilesize` `magnification` `largesize` `autohide` `mineffect` `minimize-to-application`。**域里不存在**：`show-process-indicators`。`autohide-delay` / `autohide-time-modifier` 域里也没有，且读回来是 nil → 压根不进写入集合。→ **"只写域里已有的键"这条规则就够了**，不需要额外黑名单 |
| `.app` 的 URL 形式 | 真实域用**带尾斜杠**的目录 URL：`file:///System/Applications/Launchpad.app/`。`URL(fileURLWithPath:).absoluteString` **不带**尾斜杠 → 必须自己补 |
| 用户 App vs 启动台的 tile 形状 | 用户 App：`file-type=41`、`dock-extra=true`。启动台：`file-type=169`、`dock-extra=false`、`bundle-identifier=com.apple.launchpad.launcher` |
| 进程查找兜底 | 非 `.app` 进程（`swift test` 的 xctest runner）里 `NSRunningApplication.runningApplications(withBundleIdentifier:)` 可能查不到 Dock → `pgrep -x Dock` 兜底可用 |

**踩到的两个验证陷阱（写验收脚本时必须避开）**：

1. **`plutil -p` + `diff` 比对长数组会错位**：数组元素行数不同会导致后面整体错位，产生**假差异**。判断"成员/顺序变了"要抽出标签序列单独比；判断"值变了"要用结构化比较（`PlistValue` 相等）。
2. **验收窗口期内别手动改 Dock**：实测有一次跑到一半 Dock 被外部改动（`persistent-others` 从 4 项变 1 项），"还原后仍有差异"报了假失败。

---

## 实验 5（P3 落地复测，2026-09-18）：重启节流，以及一个能毁掉图形会话的 PID 陷阱

P3 把"切桌面自动应用 + 预应用"接起来后，用 `DockAcceptanceTests` 做 20 次来回切换。第一次跑出来每轮耗时约 **1080 ms**，与 P0/P2 实测的 101/125–138 ms 差了近 10 倍。查下去挖出两件都要命的事。

### 5.1 launchd 的重启节流：间隔 < 1 秒时 Dock 要 1 秒才回来

**做法**：连续 SIGHUP 重启 Dock，只改变两次重启之间的间隔，用 `NSRunningApplication`（0.6 ms/次）测"新 PID 出现"耗时。

| 两次重启的间隔 | Dock 归位耗时 |
| --- | --- |
| 0.3 s | **约 1070 ms** |
| 0.6 s | **约 1066–1159 ms** |
| 1.0 s | **76 ms** |
| 1.5 s | 68 ms |
| 2.0 s | 73–86 ms |
| 3.0 s | 68–74 ms |
| 5.0 s | 83–138 ms |

**结论：阈值在 0.6–1.0 s 之间。** 距上一次重启不足约 1 秒时再次重启，Dock 要等 **约 1.07 s** 才归位；间隔满 1 秒以上只要 **约 70 ms**。

- `com.apple.Dock.plist` 里**没有** `ThrottleInterval`，`launchctl print` 也不报 —— 是 launchd 的隐式节流，不是 Dock 自己的启动开销（否则不会精确到 1.07 s）。
- 1.07 s 这个值高度一致（1020–1187 ms，20 次），不像负载导致，像固定退避。

**对策（已实现）**：`DockReloader` 加 `minimumSpacing`（默认 1000 ms）。距上次**归位**不足 1 秒时，先睡到满 1 秒再重启。

> 为什么"等"严格优于"立刻重启"：等待期间 **Dock 还活着、还能用**；而立刻重启会让 Dock 消失 1 秒多。
> 等待只推迟我们自己的重启时机，不延长用户能感知的不可用时间。

**效果（P3 验收实测，20 次来回切换）**：

| | 修复前 | 修复后 |
| --- | --- | --- |
| **Dock 不可用时长** | 约 1030 ms | **45–90 ms**（最坏 90 ms） |
| 一次应用总耗时 | 约 1030 ms | 约 1050 ms（多出来的是**主动等待**，期间 Dock 可用） |

所以 `ReloadOutcome` 把两个数分开记：`elapsed` 只算 Dock 真正不可用的时间，`spacingWait` 单独记等待时长（日志里注明"期间 Dock 可用"），避免日志吓人。

### 5.2 `NSRunningApplication` 会返回 `processIdentifier == -1`

**怎么发现的**：写探测脚本时，一次重启后打印出 `48049 → 48100 → -1`。`-1` 不是笔误 —— `NSRunningApplication.runningApplications(withBundleIdentifier:)` 在 Dock 重启的窗口里会返回一个**正在退出**的实例，它的 `processIdentifier` 就是 `-1`。

**为什么致命**：

| 用法 | 语义 | 后果 |
| --- | --- | --- |
| `kill(-1, sig)` | 发给**当前用户的全部进程** | 用户当场丢掉所有 App，可能整个图形会话 |
| `kill(0, sig)` | 发给**整个进程组** | 同上，范围稍小 |

原实现的 `dockPID()` 直接 `runningApplications(...).first?.processIdentifier`，于是：

1. `waitForRestart` 看到 `-1 != oldPID` → 立刻"成功"，`ReloadOutcome` **谎报 Dock 已回来**（其实 Dock 不在）；
2. 兜底路径 `let dyingPID = process.dockPID() ?? oldPID; process.signal(dyingPID, SIGTERM)` 会拿到 `-1` → **`kill(-1, SIGTERM)`**。

第 2 条是能毁掉用户整个图形会话的。**不是理论风险**：P3 期间实测复现了 `-1`。

**修复（三道防线，都在 `DockReloader.swift`）**：

1. `dockPID()` 过滤 `!isTerminated && processIdentifier > 0`；
2. `RealDockProcessControl.signal(_:_:)` **拒绝 `pid <= 0`**，并再用 `proc_name` 确认这个 PID 的进程名真的是 `Dock` 才发信号；
3. `DockReloader.waitForRestart` 只接受 `pid > 0`。

守这条不变量的测试在 `Tests/MultiDockTests/DockProcessSafetyTests.swift`，全部用**信号 0**（空信号，只做存在性检查，不投递）断言 —— 这样万一闸门被改坏，测试是**失败**而不是把测试进程自己打死。

### 5.3 `pgrep` 单次 110 ms，不能放进轮询热路径

原实现用 `/usr/bin/pgrep -x Dock` 作 `NSRunningApplication` 查不到时的兜底。实测：

| 查询方式 | 单次耗时 |
| --- | --- |
| `NSRunningApplication.runningApplications(withBundleIdentifier:)` | **0.6–1.4 ms** |
| `/usr/bin/pgrep -x Dock`（子进程） | **109–112 ms** |
| `proc_listpids` + `proc_name`（libproc，直接调） | **0.02 ms** |

重启判定是 15 ms 一轮的轮询，每次 110 ms 会把"等 Dock 回来"拖慢一个量级。已改成 `proc_listpids(PROC_ALL_PIDS)` 扫进程表 + `proc_name` 比对名字，**不再起子进程**。`DockProcessSafetyTests` 里有一条测试专门守这个（平均耗时必须 < 20 ms）。

> 注意：这一项**不是** 5.1 那 1 秒的原因。改掉之后每轮仍是约 1030 ms —— 但它是真的浪费，且和 5.1 的修复叠在一起才让 Dock 不可用时长降到 45–90 ms。

### 5.4 附带确认：写入确实生效，还原干净

| 观测项 | 结果 |
| --- | --- |
| 20 次来回切换 | 全部 `.applied`，`verifyAttempts == 1`，主路径全是 SIGHUP |
| 每次切换后真实域 | `tilesize` / `magnification` 逐次等于目标那份 |
| `DockWatcher` 误判 | **0 次**（我们自己的写入 + Dock 的 GUID 回写，都没被当成用户手动改动） |
| 两桌面配置相同时 | `.skippedIdentical`，`reload == nil`，`mod-count` 不变 → 确实没重启 Dock |
| 还原后 | 差异键 **`[]`**（连 `mod-count` 都没差），图标顺序逐项一致，键集合一致（34 键） |

---

## 实验 6：节流窗口的判据是「Dock 进程年龄」，不是我们的记忆（2026-09-18，P4 验收中意外挖出）

### 6.1 现象

第一次跑 P4 验收时，**P3 那条 20 次来回切换的用例第一轮报了 1030 ms 的 Dock 不可用**：

```
[P3 验收] Dock 不可用时长（ms）：[1030, 52, 50, 55, 46, 50, 48, 70, 60, 43, ...]  最坏 1030 ms
```

只有**第一轮**是 1030 ms，后面 19 轮全是 43–70 ms。P3 的代码没改过，而它上一次（第 6 次会话）跑的时候 20 轮全是 45–90 ms。

### 6.2 根因

`DockReloader` 把"上一次重启归位"的时刻记在**自己的成员变量** `lastRestartAt` 里，重启前先睡到
`lastRestartAt + minimumSpacing`。这套逻辑有两个盲区：

1. **launchd 的节流是按服务算的，不是按进程、更不是按我们的对象算的。**
   同一个测试进程里，前一条用例（P4 的还原）刚重启完 Dock；紧接着 P3 用例
   **新建了一个 `DockReloader`** —— 它的 `lastRestartAt` 是 `nil`，于是认为自己"从没重启过"，
   直接发 SIGHUP，结果吃满整段节流：**1030 ms**。
2. **别人的重启我们也看不见**：用户 `killall Dock`、别的 Dock 定制 App、甚至**我们自己的
   `DockPresenceMonitor` 拉回**（`kickstart` 不走 `DockReloader`）都会重启 Dock，
   而 `lastRestartAt` 一无所知。下一次切桌面就会让 Dock 消失一秒多。

### 6.3 判据改成「进程年龄」

节流窗口是 **Dock 进程年龄**的函数 —— 它刚起来不到 1 秒，launchd 就不愿意马上再拉一次。
所以直接读进程的启动时刻：

```swift
var info = proc_bsdinfo()
let size = MemoryLayout<proc_bsdinfo>.size          // 136
let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
guard written == Int32(size) else { return nil }     // 尺寸对不上就放弃，别读错字段
let start = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
```

实测（本机 macOS 15.7.9 / x86_64）：

| 观测项 | 结果 |
| --- | --- |
| `proc_pidinfo(PROC_PIDTBSDINFO)` 返回字节数 | **136 = `MemoryLayout<proc_bsdinfo>.size`** ✅ |
| Dock 的 `pbi_start_tvsec/tvusec` | 读得到，换算出的年龄与真实情况相符（实测 66.91 s） |
| 拿不到时（替身进程 / 结构体布局变化） | 返回 `nil` → `DockReloader` **退回内存里的 `lastRestartAt`**，行为与改之前一致 |

### 6.4 结果

| 观测项 | 改之前 | 改之后 |
| --- | --- | --- |
| P3 验收第一轮 Dock 不可用 | **1030 ms** | **45 ms** |
| P3 验收 20 轮 Dock 不可用 | `[1030, 52, 50, …]` | `[45, 54, 55, 58, 49, 47, 48, 47, 52, 55, 50, 52, 50, 84, 51, 50, 48, 49, 46, 49]`，最坏 **84 ms** |
| 还原路径的 `spacingWait` 上报 | 新建的 reloader 一律报 0（明明等了却不说） | 如实上报（如"先等了 925 ms 错开节流，期间 Dock 可用"） |

> **顺带的好处**：`DockPresenceMonitor` 的 `kickstart` 与"用户自己 `killall Dock`"这两种重启
> 现在也能被正确错开了 —— 改之前它们会让紧接着的一次桌面切换把 Dock 藏一秒多。

> ⚠️ **别把这条改回内存记忆**：内存里的是**猜测**（可能被外部重启打脸），进程年龄是**事实**。
> 单元测试用"报告启动时刻的替身"钉住了它（`DockReloaderTests` 的
> `testFreshReloaderStillWaitsWhenTheDockIsYoung` / `testProcessAgeWinsOverStaleInMemoryWindow`）。

### 6.5 附带确认：`kill -9` 掉 Dock 后多久恢复

| 观测项 | 结果 |
| --- | --- |
| `SIGKILL` Dock 后归位 | **1072 ms**（`KeepAlive` 让 launchd 拉起它，但会先吃一次隐式节流，所以不是 100 ms 级） |
| 判据 | 3 秒内必须出现**新的正数 PID**（`testKillingDockRecoversWithinThreeSeconds`） |
| 恢复后 | 白名单键与键集合都与杀之前一致 |

---

## 实验 7：切桌面能不能有「左右滑动」动画（2026-09-18，结论：**做不到，别再试**）

**动机**：用户要求"点菜单栏图标切桌面时要有左右滑动的动画，当前是硬切"。

**结论先行**：在**零权限 + 无痕**两条硬约束下**没有可用入口**。程序化切空间是瞬时的，
真正的过渡动画由 WindowServer 的 `Transition*Metal` 内部类驱动、只服务于**用户手势**。
下面四条证据，以及一条**不要走的路**。

### 7.1 现象确认：程序化切空间确实是硬切

`CGSManagedDisplaySetCurrentSpace` 从发起到活动空间真的变了：

| 轮次 | 耗时 |
| --- | --- |
| 1 | **6 ms** |
| 2 | 0 ms |
| 3 | 0 ms |

（轮询间隔 500 µs，3 个用户桌面，显示标识 `AB24BB32-…`）
**0–6 ms 里不可能塞进一段过渡动画** —— 用户的观察是对的。

### 7.2 `SLSManagedDisplaySetIsAnimating` 不是动画触发器，是粘滞状态位

这个符号名字最像"打开动画"，但它不是：

| 观测项 | 结果 |
| --- | --- |
| `SLSManagedDisplayIsAnimating`（调用前） | `false` |
| `SLSManagedDisplaySetIsAnimating(cid, display, true)` | **返回 `-785121165`**（同一次运行内 8 次调用值完全一致；换一次运行变成 `-2752379`） |
| 置位后 600 ms 内采样 | **101/101 次仍为 `true`**，不会自己复位 |
| 复位调用 | 生效，读回 `false` |
| 对 WindowServer / Dock 的 CPU 占用 | 无可测影响 |
| 对切空间耗时 | 无可测影响 |

> ⚠️ **返回值不能当成功标志。** 同一个调用在两次运行里给出**两个不同的稳定值**（`-785121165` / `-2752379`），
> 这是 **void ABI 的残留寄存器**，不是 `CGError`。上一轮我把 `-2752379` 记成"返回成功"，**是错的**，
> 这里更正。判断这个调用有没有生效只能看**读回值**，不能看返回值。

字符串表里还有一句 `"The display has a nil transition type."` —— 说明"显示 → 过渡类型"这个映射
在本机是 **nil**。没有过渡类型就没有过渡对象，那个 `IsAnimating` 位只是个孤立标志位。

### 7.3 会话级开关存在，但**写后读不回** → 按无痕原则不能碰

符号表里确实有整套"会话切换过渡类型"：

| 符号 | 值 / 含义 |
| --- | --- |
| `SLSSetSessionSwitchCubeAnimation` | 会话级设置器（**只有 set，没有 get**） |
| `kSLSSessionSwitchTransitionTypeCube` | `"cube"` |
| `kSLSSessionSwitchTransitionTypeKey` | `"transition"`（现代的左右滑动） |
| `kSLSSessionSwitchTransitionTypeNone` | `"none"` |
| `kSLSSessionSwitchTransitionTypeUnset` | `""` |

看起来很对症 —— 但：

1. **没有 getter**（`SLSGetSessionSwitchCubeAnimation` / `SLSCopySessionSwitchTransitionType` 都不存在）。
2. **偏好域里也没有它**：`CGSessionCopyCurrentDictionary()` 只有 11 个键（全是审计/用户/登录态），
   不含过渡类型；`defaults read com.apple.spaces` 与 `com.apple.dock` 里也没有对应键。
3. 扫遍 SkyLight 的 `__TEXT`（5,037,056 字节）里所有可打印字符串，
   含 `SwitchCube` / `SessionSwitch` 的**只有函数名 `SetSessionSwitchCubeAnimation` 本身**，没有任何偏好键。

→ 它是 **WindowServer 进程内的会话级内存值**。我们**改了就还原不回去**（读不到原值），
**这直接违反"绝不永久改变用户状态"的无痕原则**，所以即使它能生效也不能用。

### 7.4 ⚠️ 不要走的路：`SLSWillSwitchSpaces` 会段错误

合理猜测是"Dock 做动画切换前会先 `SLSWillSwitchSpaces` 通知 WindowServer，再提交"。
按 `(cid, CFArray<NSNumber>)` 试：

```
SkyLight  0x…  array_call_as_integer_list + 70
SkyLight  0x…  SLSWindowServerClientWillSwitchSpaces + 139
→ SIGSEGV
```

**签名猜错，进程直接死在 SkyLight 内部。** `SLSBridgedWillSwitchSpacesOperation` 只有
`initWithSpaces:`，看不出到底带不带 `cid`、数组元素是 `NSNumber` 还是别的结构体。

> **停止线**：继续猜签名去戳 WindowServer，风险是**把用户的图形会话搞挂**。
> 收益（一个动画）与风险完全不成比例。**这条线到此为止，不要再往前试。**

### 7.5 真正的动画在哪

符号表里过渡实现是一整套 Metal 类，**都在 WindowServer 内部**：

`TransitionSlideMetal`、`TransitionCubeMetal`、`TransitionFlipMetal`、`TransitionBlendMetal`、
`TransitionShrinkMetal`、`TransitionSpiralMetal`、`TransitionDropMetal`、`TransitionRadialBlurMetal`，
配套 `new_transition(CGXConnection*, CGSTransitionStyle, CGSTransitionFlags, CGXWindow*, CGXSession*, const float*, Transition**)`、
`CGXInvokeTransition`、`CGXMarkTransitionStart/End`、`CGSTransitionStyle` / `CGSTransitionFlags` 枚举。

**驱动它们的是 Dock**（Mission Control 属于 Dock），入口是**用户手势**（触控板横扫 / `Ctrl+←`）。
没有任何一处对外暴露"给我带动画地切到某个空间"。

### 7.6 合成按键事件这条路也堵死了（补测）

绕道思路是"模拟 `Ctrl+←` 让 Dock 自己去做动画切换"。**在本机不通**：

| 观测项 | 结果 |
| --- | --- |
| `CGPreflightPostEventAccess()` | **`true`**（看起来有权限） |
| 热键 `Ctrl+←` / `Ctrl+→` 是否启用（`com.apple.symbolichotkeys` 79/80/81） | `enabled = 1` |
| 试过的 tap | `cghidEventTap` / `cgSessionEventTap` / `cgAnnotatedSessionEventTap` |
| 试过的 `CGEventSource` 状态 | `.hidSystemState` / `.combinedSessionState` / `.privateState` |
| **阳性对照**：合成 `Cmd+Tab`，看前台 App 有没有变 | **没变** |
| 结论 | 合成事件在本机被拦，**不是** tap 或 state 选错 |

> **阳性对照是关键**：`Cmd+Tab` 是最稳的合成事件用例，它都不动，说明问题在"事件投递被拦"这一层，
> 而不是我们的参数。以后再遇到"合成事件没反应"，**先跑阳性对照**，别在参数上反复试。

### 7.7 决定

- **不做真动画。** 在零权限 + 无痕下没有安全入口，硬做要动 WindowServer 内部状态。
- **不改需求、也不做假动画**：不自己画跨屏浮层假装滑动 —— 那既不是真的切桌面动画，
  又要在多显示器 / 全屏空间下处理一堆边界，收益远低于成本。
- **替代方案（已确认可行、且已实现）**：`⇧+左键` 切上一个桌面，并在下拉菜单里给出等价入口，
  让"往回切"这件事至少不需要绕过菜单。见 `docs/PLAN.md` §3.7。
- 若将来 macOS 暴露了带过渡的切空间 API，再回来做；`docs/PLAN.md` §5 风险表里留了这条。

---

## 实验 8：其他项（文件夹 / 堆栈）能不能由 App 自己造（2026-09-18，结论：**不能，别再试**）

**为什么做**：计划 §3.6 要求编辑条支持「从 Finder 拖 .app / **文件夹** / 文件进来」，
而 `persistent-others`（文件夹 / 堆栈，本机只有「下载」）此前在本 App 里**没有任何编辑入口**：
`DockStripEditor` 只渲染 `persistent-apps`，拖文件夹进来会静默失败（`tile(forAppAt:)` 只认 `.app`）。
要补这个缺口，第一件事是确认「自己拼一条目录条目」会不会被 Dock 接受。

### 8.1 实验 1：最小目录 tile + 普通文件 tile → **Dock 崩溃循环**

写进域（`defaults write -array-add`）+ `kill -HUP` 之后：

```
persistent-others 条目数：3（原「下载」+ 我造的目录 tile + 我造的文件 tile）
Dock：进程消失，launchctl 显示 com.apple.Dock.agent 退出码 -6，无 PID
崩溃报告：Dock-2026-09-18-0753*.ips / 0754*.ips 共 7 份，
         termination = {"namespace":"SIGNAL","indicator":"Abort trap: 6"}，
         exception = EXC_CRASH / SIGABRT，asi = {"libsystem_c.dylib": ["abort() called"]}
```

- 两条自造 tile 在域里**原样保留**（Dock 没认领、也没清除），但 Dock 反复 abort，
  launchd 在崩溃循环里一次次把它拉起来 —— 也就是说**这一版形状能让用户没有 Dock 用**。
- 恢复：`defaults import com.apple.dock <备份>` + `launchctl kickstart gui/$UID/com.apple.Dock.agent`。
  （`defaults import` 之后 launchd 需要一会儿才拉回，别急着判定失败。）

这一条本身就足以定案：**形状不全的目录条目是危险写入**。

### 8.2 实验 2 / 3 / 4：补全字段也好、自己生成 `book` 也好，Dock **都不认领**

| 实验 | 写入形状 | Dock 存活 | Dock 补 `GUID`? |
| --- | --- | --- | --- |
| 2 | 目录 tile + `arrangement`/`displayas`/`showas`/`preferreditemsize`/`is-beta`，路径 `/tmp`（符号链接） | ✅ 存活 | ❌ 4 秒后仍无 |
| 3 | 同上，但改成真实非符号链接目录 `/Users/apple/Documents/Swift` | ✅ 存活 | ❌ 8 秒后仍无 `GUID` / `book` |
| 4 | 再加**自己生成的 `book`**（`URL.bookmarkData()`，908 字节，魔数 `book` + 长度头，与真实 656 字节的「下载」同族） | ✅ 存活 | ❌ 8 秒后仍无 |

对照组（P2 实测、已入验收）：**App 的 file-tile 会在 200 ms 内被 Dock 补上 `GUID`** ——
所以"没有 GUID"就是"Dock 没读进去"，而不是"观测太早"。

`book` 是 Dock 自己算的文件夹书签（本机「下载」656 字节，前 12 字节 `62 6f 6f 6b 90 02 00 00 00 00 04 10`），
我们自己生成的同族数据并不能替代它。

### 8.3 实验 5：`persistent-others = []`（=「移除最后一项」的形状）**无害**

```
写入空数组 → kill -HUP → 0.6 秒后新的 Dock PID 出现
```

所以「移除其他项」这条路径不需要设限（空数组是 Dock 自己也会写的正常状态）。

### 8.4 决定（已落进 `docs/PLAN.md` §3.6 / §3.7 与代码）

1. **不提供"新建文件夹 / 普通文件条目"**。Dock 不认领自造目录条目（实验 2–4）→ 做了就是**假开关**；
   形状不对时还会让 Dock 进崩溃循环（实验 1）→ 更是**危险写入**。
2. **替代做法写进 UI**：让用户在访达里把文件夹自己拖到 Dock 上 —— Dock 会写完整条目（含 `book`），
   `DockWatcher` 随后把它回存进当前桌面的配置，之后就能在编辑器里排序 / 移除。
   拖文件夹进编辑器时**明确拒绝并给出这段话**（`DockItemRejection.message`），不留静默失败。
3. **其他项只"搬"不"造"**：编辑器只做显示 / 排序 / 移除，写回去的就是 Dock 自己写的
   dict（`GUID` / `book` 原样保留）。真机验收 `DockAcceptanceTests.testOtherItemsRemovalAndReapplyKeepsDockHealthy`
   钉死两件事：移除后 Dock 仍存活、`GUID`/`book` 一个都不丢。
4. **`normalizedOthers` 只去重、不插固定项**（`persistent-apps` 才需要保证启动台在首位）。
5. 回归守卫：`DockStripRulesTests.testDockItemRejectionClosesTheFolderAndFilePaths`
   断言这条路是**关着**的，防止以后有人"顺手"把它打开。

### 8.5 附带观测：反复 kill / HUP Dock 会让 launchd 进入**递增退避**

实验期间（1 次崩溃循环 + 多次 HUP + 多次 kickstart）观察到：

```
launchctl print gui/$UID/com.apple.Dock.agent
  state = spawn scheduled      # launchd 已排好重启，但在等退避窗口
  job state = exited
  runs = 346                   # 含崩溃循环里的每一次 abort
```

表现是 **Dock 几十秒不回来**（正常 SIGHUP 只要约 100 ms），
`DockReloader` 的 kickstart 兜底也会被同一段退避挡住。
**结论**：写验收脚本时不要连续杀 Dock 几十次；真机验收最好在 Dock 稳定运行几分钟之后跑。
这条只影响验收节奏，不影响 App 逻辑（App 一次切换只重启一次）。

---

## 实验 9：切一次桌面为什么"黑屏几分钟"（2026-09-19，结论：**我们自己在续 launchd 的退避**）

用户报告：桌面 1 → 桌面 2 之后没有 Dock、没有壁纸、触控板切桌面的手势也失效，持续几分钟。
先定性：**Dock 进程就是壁纸与空间手势的实现者**，所以"三样一起没"不是系统卡死，而是 **Dock 进程长时间不在**。

### 9.1 证据一：每次切换的 Dock 缺失被记成 60–126 秒

`multidock.log`（同一台机器、同一个 App，00:55 起）：

| 时刻 | 动作 | 报告的手段 | Dock 不可用 |
| --- | --- | --- | --- |
| 01:29:47 | 启动自愈还原 | SIGHUP | **100 ms** |
| 01:31:56 | 切到 计划 任务 | kickstart | **119 438 ms** |
| 01:33:00 | 切到 LLM | SIGTERM | 63 033 ms |
| 01:35:09 | 切到 密码 邮件 | kickstart | **119 481 ms** |
| 01:37:40 | 切到 LLM | SIGHUP | **125 ms** |
| 01:39:49 | 切到 密码 邮件 | kickstart | **125 284 ms** |
| 01:40:47 | 切到 LLM | SIGHUP | **55 ms** |

同一条路径一会儿 55 ms 一会儿 125 s → 不是"这台机器慢"，是**有东西在中间反复打断**。
排除崩溃：今天 **0 份** Dock 崩溃报告（`DiagnosticReports` 里只有 2026-09-18 实验 8 那批，已进 `Retired/`）。

### 9.2 证据二：整个 App 被冻住了，不是只在等

存活监视器每 500 ms 一轮、缺失达阈值后每 4 轮（2 s）催一发，所以一次 2 分钟的缺失**应该留下约 60 行日志**。
实测每次缺失只有**一行**，且永远是「连续 **2** 次」：

```
01:29:56.730 切换到 计划 任务            ← SIGHUP，Dock 消失
             ……55 秒完全空白：监视器、桌面轮询、toast、回存全部停摆……
01:30:51.829 检测到 Dock 不在（连续 2 次），已用 launchctl 拉回
01:31:56.183 Dock 应用成功：kickstart 成功 … Dock 不可用 119438 ms
```

主线程被同步阻塞 —— 全代码库只有一个这样的调用：`RealDockProcessControl.kickstart()` 里的
`process.waitUntilExit()`。它的返回时刻正好就是空白结束的时刻（两发分别阻塞约 54 s 与 64 s，
00:56 那次是 59 s）。**launchd 在退避时，`launchctl kickstart` 会阻塞到它真能把服务拉起来为止。**

### 9.3 根因：两条自我放大的链路叠在一起

1. `DockReloader` 的超时是 **5 s**。launchd 的退避尺度是**几十秒**，于是一次正常的慢拉起被判成
   "SIGHUP 失败" → 升级 `SIGTERM` + `launchctl kickstart -k`。
2. `DockPresenceMonitor` 缺失 **1 s** 就动手、之后**每 2 s** 再补一发 `kickstart -k`。

`-k` 的语义是"先杀现有的再拉"。Dock 刚刚被 launchd 拉回来，我们就又杀一次，并**重置 launchd 的退避计时**
（8.5 早写过：静置等待比反复 `kickstart` 更快）。于是 1 秒的节流被滚成两分钟的 Dock 死亡。
触发条件就是"某一次恢复稍微慢了一点"（本机 `kill -9` 后归位要 1072 ms，正常 SIGHUP 只要 100 ms），
一旦跨过 5 s / 1 s 这两条线就自持。

### 9.4 附带挖出的第二个 bug：缺失期间读偏好域，把配置写坏了

```
01:30:51.909 [Dock 正 dead] 检测到真实 Dock 上的手动改动：3 个图标、0 个其他项
01:30:51.923 [Dock 正 dead] 密码 邮件：回存手动改动：3 个图标
```

真实 Dock 是 **15 个图标 + 1 个其他项**。Dock 进程不在时偏好域读回来是**残缺内容**，
`DockWatcher` 却把它当成"用户的手动改动"回存 —— `config.json` 里 `密码 邮件` 与 `计划 任务`
的 override 已被写成 3 个图标（`LLM` 那条是对的）。

### 9.5 决定（已落进代码与 `docs/PLAN.md` §3.4 / §3.8 / §3.9）

| 改什么 | 从 | 到 | 为什么 |
| --- | --- | --- | --- |
| `kickstart()` | `waitUntilExit()` 同步等 | 发完就走，子进程由 `LaunchctlParking` 持有到退出 | 不再冻主线程；返回值仍只表示"命令发出去了" |
| 同一发 launchctl | 可叠加 | **在飞的没结束就不再补** | 重复 `-k` 是退避的成因 |
| `DockReloader.timeout` | 5 s | **30 s** | 必须明显长于 launchd 的退避尺度，否则慢恢复被误判成失败 |
| 监视器 `missThreshold` | 2 轮 = 1 s | 8 轮 = **4 s** | 让 launchd 自己先拉，别抢 |
| 监视器 `kickstartEvery` | 4 轮 = 2 s | 60 轮 = **30 s** | 稀疏催，与 8.5 的"静置更快"一致 |
| `persistentFailureThreshold` | 12 轮 = 6 s | 120 轮 = **60 s** | 几十秒缺失在本机是"正在恢复"，那时报警等于报故障 |
| `DockWatcher` | 任何时候都采样 | **Dock 进程不在就不采样**；回来后的第一次读只用来对齐基线 | 9.4 |

回归：`DockPresenceMonitorTests` 两条钉死新默认值（缺失 3.5 s 不动手 / 满 4 s 才补一发 / 之后 30 s 不催 /
59.5 s 不报警）、`DockWatcherTests` 两条（缺失期间不采样、回来后先对齐基线再照常回存）、
`DockReloaderTests` 一条（`isDockAlive` 跟随进程控制且不认 -1）。**295 个测试全绿、零警告。**

**尚未实测的部分**：这次修复要靠真机反复切桌面才能验（本会话没有再动用户的 Dock ——
那会连带触发他的逐桌面应用）。核对手段现成：日志里 `Dock 不可用` 应稳定回到 100 ms 量级，
且不再出现「连续 2 次…已用 launchctl 拉回」。

---

## 实验 10：每次右键退出都"卡住几分钟"（2026-09-19，结论：**实验 9 那条链在退出路径上原样成立，而且我们的"上限"从一开始就是假的**）

用户报告：菜单栏右键 → 退出，**每一次**都会出现"没有 Dock、桌面背景不显示、触控板也不能用"，
持续几分钟。这个描述与实验 9 的故障一模一样 —— 因为**它就是同一个故障**，只是触发点从"切桌面"换成了"退出"。

### 10.1 先确认：用户跑的是修复前的二进制

- `build/MultiDock.app/Contents/MacOS/MultiDock` 的时间戳 **09-19 01:07**；
  实验 9 的修复 commit `47defb5` 落在 **02:11**。也就是说用户退出时跑的那份代码里
  `kickstart()` 还是同步 `waitUntilExit()`、监视器还是 1 s 动手 / 每 2 s 补一发 `-k`、
  重载超时还是 5 s。**实验 9 的修复从未被真机跑过。**
- 日志里能找到的**两次真实退出**：`退出还原流程结束，用时 54.05s` 与 `用时 53.12s`，
  各自前面都有一次 **100–122 秒**的 Dock 缺失，而那条
  `检测到 Dock 不在（连续 2 次），已用 launchctl 拉回` 的打印时刻，正好就是被阻塞的
  `launchctl kickstart -k` 返回的时刻（实验 9.2 的判据一模一样）。
- ⚠️ 这两行现在已经**不在** `multidock.log` 里了 —— 见 10.5：单测把那 512 KB 的环形文件整个灌满了假记录。
  数字是本会话早些时候从文件里读到的原始值。

### 10.2 退出路径上的三个放大器

| 放大器 | 位置 | 后果 |
| --- | --- | --- |
| 退出还原走的是**完整重载 ladder** | `restoreToBaseline()` → `apply` → `reload()`：发信号 → 等归位（30 s）→ SIGTERM → `kickstart` → 再等 30 s | 一次"我们马上就不在了"的写操作，等满整条链 = 53–54 s |
| 存活监视器跟我们自己的退出重载抢节奏 | 500 ms 一轮，看到 Dock 不在就补 `kickstart` | launchd 刚拉回来又被杀 → 退避续期 |
| `prepareForTermination(settleLimit:)` 的"2 秒上限"**不生效** | 见 10.3 | 上限写在参数里，没人受它约束 |

### 10.3 核心发现：`withTaskGroup` 赛跑做不出「带上限的等待」

两处"带上限地等"（`DockController.waitForIdle(upTo:)`、`AppState.settle(_:within:)`）都写成：

```swift
await withTaskGroup(of: Bool.self) { group in
    group.addTask { await task.value; return true }      // ← 不可取消
    group.addTask { try? await Task.sleep(for: limit); return false }
    let settled = await group.next() ?? false
    group.cancelAll()                                     // ← 对第一种子任务毫无作用
    return settled
}
```

**任务组在闭包返回时会等所有子任务收尾。** 而 `await task.value` 这种子任务没有取消处理器
（`Task<Void, Never>`，`cancelAll()` 只是把 `isCancelled` 置位），所以它一路等到那笔应用跑完才结束。
于是：

- `group.next()` 确实在 20 ms 就返回了 `false` —— **返回值看着是对的**；
- 但整个 `withTaskGroup` 闭包要到 **625 ms**（正好是替身那条降级链的总时长）才返回。

实测数字（把降级链做成必然慢：`reloadStrategy = .sigterm`，上限给 20 ms）：

| 位置 | 上限 | 任务组写法的实际墙钟 | 轮询写法 |
| --- | --- | --- | --- |
| `DockController.waitForIdle(upTo:)` | 20 ms | **625 ms**（正好是降级链的总时长） | 200 ms 断言内通过 |
| `AppState.settleSelfHeal(within:)` | 20 ms | **224.7 ms**（回归用例打出来的） | 200 ms 断言内通过 |

**这就是为什么"每次退出都卡住"在代码里查不出来**：`settleLimit` 传的是 2 秒，
读代码的人看到"有上限"，测试也只断言 Bool —— 只有墙钟会露馅。在 launchd 退避的尺度上，
被放大的是**几十秒**，因为降级链里那一发同步 `kickstart` 自己就要阻塞几十秒。

**修法**：不用任务组，改轮询一个"活干完了"的可观察标志。

```swift
func waitForIdle(upTo limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while drainTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return drainTask == nil
}
```

`AppState` 那侧需要一个 `selfHealFinished` 标志（自愈任务跑完时置位），理由相同：
`performSelfHeal` 是**直接 `await dockController.apply(...)`**，不经过 `drainTask`，
所以 `waitForIdle` 代理不了它的进度。

**回归守卫的写法**（关键）：必须断言**墙钟**，不能只断言 Bool。
`testWaitForIdleReportsTimeout` 与 `testPrepareForTerminationBoundsTheSelfHealWait`
都带 `XCTAssertLessThan(elapsed, .milliseconds(200))`。把 `settleSelfHeal` 临时改回任务组写法，
后者如实失败：`("0.224659361 seconds") is not less than ("0.2 seconds")`，
而同一条用例里 `XCTAssertFalse(settled)` **仍然通过** —— 这就是这个 bug 的隐蔽程度。

### 10.4 决定（已落进代码与 `docs/PLAN.md` §3.3 / §3.9）

| 改什么 | 从 | 到 | 为什么 |
| --- | --- | --- | --- |
| 退出时的重载 | 复用 `reload()`（等归位 30 s → 升级 → kickstart → 再等） | **`reloadForQuit()`**：一发信号 + 最多 1.5 s 看一眼，**不等节流、不升级、不 `kickstart`** | 我们马上就不在了：等归位换不到任何**可行动**的信息（校验读的是偏好域，不是 Dock 界面），而升级正是把 100 ms 滚成两分钟的那一步 |
| 退出时的写入 | `apply` 正常路径（不一致重试一次） | **`apply(..., forQuit: true)`**：一次写入 + 一发信号 + 一次校验，**不重试** | 重试 = 再发一发信号 = 再吃一次退避 |
| 还没起跑的待办 | 一并等完 | **`dropPendingRequests()` 直接丢** | 它的目标马上会被"还原到基准"取代，等它毫无意义 |
| 退出前的等待 | 两个假的"带上限" | **轮询标志** + 真上限（默认 2 s，可注入） | 10.3 |
| 存活监视器 | 无条件轮询 | **`isReloading` 闸门**：我们自己正在重载 Dock 时不采样 | 我们的重启不是故障 |
| 等不到干净时 | 直接清标记 | **`!settled` → `keepMarkerAndFinish`**（留债务，下次启动自愈去看真实域） | 那笔在飞的写入可能落在还原**之后** |

**"不等归位为什么是安全的"**（这条论证要留在文档里，否则以后有人会把 ladder 加回去）：

1. 偏好是**原子写**进 `com.apple.dock` 域的，我们退出之后它还在；
2. Dock 每次启动都重读这个域 —— launchd 把它拉回来那一刻，读到的就是基准；
3. 唯一能纠正"升级也没用"的手段是**下次启动的自检**，而它不看这次等了多久。
   所以"多等 30 秒"换来的只是一条我们无从补救的日志。

### 10.5 附带挖出的第三个问题：单测把用户的诊断日志灌满了假记录

`AppState` 里 `private let fileLog = FileLogSink()` 用的是默认路径
（`~/Library/Application Support/MultiDock/multidock.log`），**测试没有注入点**。
后果（实测）：文件里 02:37 之后的 3 000 多行**全是**单测产物（假 PID `100 → 1001`、假的
「开始退出还原…」），而实验 9 引用的真实证据行与那两次 53–54 s 的退出记录，
已经被 512 KB 的环形截断挤了出去。

这直接打掉了 A6 的核对手段 —— 用户要看的正是这份日志（无屏幕录制权限、`log show` 在沙箱里读不到）。
修法：`FileLogSink` 变成 `AppState.init` 的注入参数，测试统一走 `makeTestFileLog()`（临时目录）。
验证：改动后跑一次全量 `swift test`，用户那份日志行数 **3060 → 3060**（纹丝不动）。

### 10.6 验收

- `swift build -c release --disable-sandbox` → **零警告**；`swift test --disable-sandbox` →
  **308 个测试全绿**（7 个真实 Dock 验收默认跳过），本次 +13。
- 新增：`DockReloaderTests` 4 条（`reloadForQuit` 只发一发 / 不升级且墙钟 < 1 s / 无视 `minimumSpacing` /
  Dock 不在时一发都不发）、`DockControllerTests` 4 条（退出路径不重试不升级 / 带回收场方式 /
  `waitForIdle` 真上限 / `dropPendingRequests`）、`DockPresenceMonitorTests` 2 条（`isReloading` 闸门）、
  `StartupSelfHealTests` 3 条（退出还原只写一次并读回基准 / `!settled` 的如实上报 / 自愈等待的真上限）。
- ⚠️ **真机复验仍未做**（本会话没有再动用户的 Dock）。核对口径见 AGENTS.md §6.3 A6/A7。
  注意：**先转走被测试灌脏的那份日志**，否则核对的是假记录。

---

## 对 `docs/PLAN.md` 的修订清单

| 位置 | 原内容 | 修订为 |
| --- | --- | --- |
| §1 环境事实表 | `ManagedSpaceUUID` | `uuid`（另附 `Current Space` 可直取当前空间） |
| §3.1 | 通知为主 + 1 s 轮询兜底 | **轮询为主（300 ms）+ 通知为辅**；预应用升级为必需 |
| §3.5 | A/B 可能零闪烁；C 闪 0.3–1 s | A 彻底无效；B 实为重启但仅 ~100 ms 不可用；**主路径 = B**，C 兜底（~395 ms） |
| §3.6 | 合成 tile 用 `dock-extra:0` | 用户 App 用 `true`、启动台用 `false`（按真实域）；`_CFURLString` 必须带尾斜杠 |
| §4 P0 行 | 三实验并列 | 已完成，结论见本文 |
| §4 P2 行 | 待做 | ✅ 已完成（见本文实验 4 与 AGENTS.md §8 第 5 次记录） |
| §4 P3 行 | 待做 | ✅ 已完成（见本文实验 5 与 AGENTS.md §8 第 6 次记录） |
| §3.5 | SIGHUP 约 101 ms 不可用 | 补上**重启节流**：距上次重启不足约 1 s 时再重启要 **约 1070 ms**；`DockReloader.minimumSpacing` 错开它，实测把 Dock 不可用时长压回 **45–90 ms** |
| §3.4 第 8 条 | "先 apply 再切空间" | 措辞修正为"**发起**应用与切空间同一拍，不等轮询"。切空间前完成重启物理上做不到（重启 101 ms > 切空间 0–6 ms），见 PLAN §3.4 的 P3 实现记录 |
| §6 | 桌面"位置"含义待确认 | ✅ 已确认：Dock 屏幕位置 + 大小（2026-09-18） |
| §3.5 / §3.9 | 节流窗口靠 `DockReloader.lastRestartAt`（内存记忆）错开 | 改成按 **Dock 进程年龄**（`proc_pidinfo(PROC_PIDTBSDINFO)`）推算，拿不到年龄才退回内存记忆。理由：launchd 的节流**按服务**算，别人的重启我们看不见。见本文实验 6 |
| §4 P4 行 | 待做 | ✅ 已完成（见本文实验 6 与 AGENTS.md §8 第 7 次记录）。**只有第 ③ 条"注销/重启后 Dock 为 baseline"未实测**（要真注销一次机器） |
| §3.9 | "必要时还原基准"没写清时机 | 补上：自愈**启动后异步执行**，不阻塞启动；债务跨会话继承（`needsSelfHeal`）；还原失败要保留标记并标 `pid = 0` |
| §3.9 | 登录项退回 `~/Library/LaunchAgents/local.multidock.plist` | 文件名实际是 `local.multidock.loginitem.plist`，且**刻意不设 `KeepAlive`**（登录启动项不是守护进程） |
| §3.1 / §3.7 | 菜单栏左键 = 切下一个桌面 | 补上 **`⇧+左键` = 切上一个桌面**（下拉菜单同时给「上一个桌面」项 + 等价提示），左键行为仍可改成"打开菜单"。见本文实验 7.7 |
| §3.1 / §5 | （无）切桌面动画 | **新增一条明确的不做项**：程序化切空间是硬切（0–6 ms），SkyLight 不暴露带过渡的入口；会话级开关写后读不回、违反无痕原则；`SLSWillSwitchSpaces` 签名未知且试错会段错误。**结论见本文实验 7** |
| §3.6 | 拖入支持「.app / 文件夹 / 文件」 | 改成**只接受 `.app`**：文件夹与普通文件**明确拒绝并给出替代做法**（在访达里自己拖到 Dock 上，由 `DockWatcher` 回存）。理由见本文**实验 8**：自造的目录条目 Dock 不认领（不补 `GUID`），形状不全时还会让 Dock SIGABRT 进崩溃循环 |
| §3.6 / §3.7 | 其他项（`persistent-others`）没有任何编辑入口 | 编辑条新增「其他项」一条：**只搬不造**（显示 / 排序 / 移除），写回的就是 Dock 自己的 dict（`GUID` / `book` 原样保留）。真机验收 `testOtherItemsRemovalAndReapplyKeepsDockHealthy` |
| §3.4 第 6 条 | 应用摘要"调试面板可见" | ✅ 调试面板新增「最近一次应用」：结果摘要 + 内容指纹 + 写入时刻 + 「本次运行改过 Dock」+ 回存闸门 |
| §3.7 | 桌面列表：显示器名 + 名字 + 当前绑定状态 | ✅ 列表**按显示器分组**（`ScreenNaming`），详情加一行显示器名；映射不到时如实说"未识别显示器（UUID 前 8 位…）"，**不回落成一台错的屏** |
| §3.4 / §3.9 | 重载超时 5 s；存活监视器 1 s 动手、每 2 s 催一发 `kickstart -k`；`kickstart` 同步等 launchctl 退出 | 全部改掉：超时 **30 s**、**4 s** 才动手、每 **30 s** 才催一发、报警阈值 **60 s**、`kickstart` **非阻塞且不允许叠加**。理由：这几条叠在一起会把一次正常的慢恢复自我放大成 60–126 秒的 Dock 死亡，而且同步的 `launchctl` 会冻住主线程。见本文**实验 9** |
| §3.8 | Watcher 只在"还原期间"停止 | 再加一条边界：**Dock 进程不在时一律不采样**，回来后的第一次读只用来对齐基线。缺失期间域里是残缺内容（实测 3 个图标 vs 真实 15 个），照抄会写坏桌面配置。见本文 9.4 |
| §3.3 正常退出流程 | "等待重载完成（Dock 归位确认，最长 5 s）" | 改成**退出专用的窄路径**：一发信号 + 最多 1.5 s 看一眼，不等节流、不升级、不 `kickstart`；写入不重试；待办直接丢；等待带**真**上限（轮询标志，默认 2 s）。理由：那 5 s 上限实际是"等完整条 ladder"，在 launchd 退避期间是 53–54 秒。见本文**实验 10** |
| §3.9 P4 实现记录 第 4 条 | "等自愈跑完 + `waitForIdle()`（无上限）" | 两条等待都改成**带上限且上限真的生效**；等不到干净时**保留会话标记**（`!settled` → `keepMarkerAndFinish`）。原先的"带上限"是 `withTaskGroup` 赛跑写法，静默失效（返回值对、墙钟不对） |
| §5 风险表 | "退出还原被排队的应用覆盖 → `await waitForIdle()`" | 补一条同级风险：**带带上限的等待必须轮询可观察标志**，用 `await task.value` 做赛跑等于没上限；回归守卫要断言墙钟 |

---

## 实验 11：快速连切桌面时 Dock 仍会消失 26–31 秒（2026-09-20，结论：**`minimumSpacing = 1 s` 的阈值定错了，launchd 判"崩溃"的门槛是 uptime ≈ 10 s**）

数据来源：**用户真机跑出来的日志**（不是脚本实验），2026-09-19 05:02 启动 → 05:58 退出，
二进制 `build/MultiDock.app` 时间戳 **05:02**，**晚于**实验 9（commit `47defb5` 02:11）与实验 10（commit `8ab35f8` 03:21）
→ **这份日志是修复后的代码跑出来的**，两条修复都已被真机覆盖到。

### 11.1 先确认好消息：退出路径修好了

```
05:58:43.981 [INFO] 开始退出还原…
05:58:45.991 [INFO] 开始还原到原始 Dock：15 个图标
05:58:46.001 [INFO] 退出还原流程结束，用时 0.01s
```

对比实验 10 记录的 **53.12 s / 54.05 s**，实验 10 的修复**真机成立**（整条退出 ≈ 2 s，
其中 2 s 是 `prepareForTermination` 的等待窗口，不是 Dock 缺失）。**A7 可以销账。**
唯一的尾巴：这次退出走了 `!settled` 分支（`还原未完成（退出时还有一次应用没落地），已留下标记`），
于是 `session.state` 里留下 `needsSelfHeal = true, pid = 0` —— 属预期兜底，但见 11.4 的副作用。

### 11.2 坏消息：切桌面仍会吃到几十秒的退避

本次会话里 6 次真实 apply 的 Dock 不可用时长：

| 时刻 | 结果 | Dock 不可用 | 上一任 Dock 的 uptime |
| --- | --- | --- | --- |
| 05:02:44 | SIGHUP 成功 | **57 ms** | 约 29 分钟 |
| 05:03:18 | SIGHUP 成功 | **126 ms** | 34 s |
| 05:32:12 | SIGHUP 成功 | **84 ms** | 约 29 分钟 |
| 05:32:44 | SIGHUP 成功 | **26046 ms** | **约 6.5 s** |
| 05:33:16 | SIGHUP 超时 30 s → kickstart | **31039 ms**（含先等 1032 ms 错开节流） | **约 1 s** |
| 05:58:19 | SIGHUP 成功 | **50 ms** | 约 25 分钟 |

**相关性是干净的：uptime ≥ 30 s 的 4 次全部 50–126 ms；uptime 6.5 s 与 1 s 的 2 次是 26 s 与 31 s。**

### 11.3 相关性与因果：看起来像"uptime 门槛"，**但这是错的**（见 11.6）

实验 5 记的是"间隔 < 1 s → 1070 ms，≥ 1 s → 70 ms"。真机数据看起来在说：
那条只在"上次重启很久以前"成立，真正的判据是 **Dock 进程的 uptime**。
本机 6.5 s 触发、34 s 未触发，落在经典的 **10 s crash-uptime** 附近 —— **这个解释很顺，但它是错的。**

**11.6 记录了对它的证伪。** 控制实验（实验 12）直接测了 uptime 6 / 12 / 20 / 60 s 的重启，
**全部 37–68 ms**，一次都没被罚。所以 11.2 那张表里的相关性**不是因果**：
真正区分好坏两组的不是 uptime，而是别的东西（尚未找到）。

> → **实验 15 接着往下走了一步**：把真机日志那两行逐字重读，发现"重载期间监视器静默"导致
> 旧日志里**没有任何过程记录**，两种病因分不出来；于是给慢路径装了取证仪表。
> **定案要等下一次真机复现。**

### 11.4 顺带记录：两条 override 与默认 Dock 图标相同 —— **不是损坏，已结案**（但留了两个教训）

> ⚠️ **这一节在 2026-09-20 被更正过两次，两次都是我自己错。**
> **第一次**：初版写的是"三个桌面 override 全部为空"—— 错。当时的读取脚本用错了 JSON 键名
> （写 `apps` / `others`，真实键是 `pinnedApps` / `otherItems`），于是把有内容的 override 读成了空。
> **教训：核对配置前先 `print(list(d.keys()))` 把真实键名打出来**，不要凭记忆写字段名；
> 一个字段名写错就能把"3 项"读成"0 项"，并据此得出完全错误的结论。
> **第二次**：改完初版后我提议"把这两条 override 清成沿用默认，反正切过去看到的 Dock 一样"—— 也错。
> 它们**不是**默认的精确副本（见下文 `orientation`），清掉是可见的行为改变。
> **教训：「内容看起来一样」不等于「等价」；判断可替换性要读*取用语义*，不能靠肉眼比列表。**

`~/Library/Application Support/MultiDock/config.json`（2026-09-19 05:32 写）**用正确的键名重读**后的真实状态：

| 目标 | `pinnedApps` | `otherItems` | 内容 |
| --- | --- | --- | --- |
| 默认 Dock | **3** | 0 | 启动台 / FlClash / WorkBuddy AI |
| `密码 邮件` | **3** | 0 | 启动台 / FlClash / WorkBuddy AI ← **与默认逐项相同** |
| `计划 任务` | **3** | 0 | 启动台 / FlClash / WorkBuddy AI ← **与默认逐项相同** |
| `LLM` | **15** | 1 | 启动台 / 滴答清单 / Chrome / … / OrbStack ← 正常 |

而**真实 Dock 是健康的**：`persistent-apps` **16 项**、`persistent-others` 1 项、`tilesize 36` / `orientation bottom` / `autohide false`。
基准快照是 15 项（用户后来自己加了 Qoder CN，所以真实是 16）。

**"坏"在哪 —— 已结案（2026-09-20）**：两条 override 的**图标**与默认 Dock 逐项相同
（都是启动台 / FlClash / WorkBuddy AI），当时看起来像"被默认内容覆盖"的指纹。
但**用户已确认默认 Dock 那 3 个图标是他故意配的**，所以"图标相同"这件事本身**不再构成损坏证据** ——
他完全可能就是给这两条也配了同一组图标。**没有独立证据能区分这两种可能，因此不再当作故障处理。**

⚠️ **而且它们不是精确副本，不能清成「沿用默认」**：两条 override 的 `appearance.orientation = "bottom"`，
默认 Dock 是 `"right"`。`effectiveConfig(for:)` 是 `binding(for:)?.override ?? settings.defaultDock`
（**整体替换**，不是逐字段合并），所以清掉 override 会让那两个桌面的 Dock **跑到屏幕右侧** ——
是一次可见的行为改变，不是等价操作。**结论：`config.json` 原样保留（一个字节没动），要改由用户在 UI 里自己改。**

**默认 Dock 的 3 个图标 + `orientation = right` 是用户有意为之**（2026-09-20 确认），**任何 agent 都不要擅自改**。

日志里能看到一条**会把 override 钉死的正反馈路径**（这是实验 9.4 那个 bug 的续集）——
**机制本身是真的、仍然危险**，只是这次是否真的伤到了数据无法判定：

```
05:32:12.243 Dock 应用成功：切到 计划 任务；SIGHUP 成功…写入 9 个键
05:32:12.401 检测到真实 Dock 上的手动改动：3 个图标、0 个其他项
05:32:12.422 计划 任务：回存手动改动：3 个图标
```

即：残缺的 override 被 apply 到真实 Dock → 真实 Dock 变成 3 个图标 → `DockWatcher` **合法地**
把这 3 个图标当成"用户的手动改动"回存 → 配置被自己钉死。**这是正反馈，不会自愈。**

⚠️ **另一条待爆的副作用（2026-09-20 已处理）**：`session.state` 里 `needsSelfHeal = true` **且**
`appliedFingerprint != nil`（`impliesDirtyDock` 两条都命中）→ 下次启动会"还原到基准（15 项）"，
**把用户后来自己加的 Qoder CN 抹掉**。

但这笔债是**假的**：日志里 `05:58:45.991 开始还原到原始 Dock：15 个图标` 之后 Dock 确实回到了基准态
（用户后来才加的 Qoder CN，所以现在是 16 项）。`needsSelfHeal` 是因为 `prepareForTermination`
发现有排队中的 apply 没落地才留下的兜底标记，**还原本身成功了**。
→ 已备份后移除 `session.state`（`session.state.bak-20260920-044624`），让这笔不存在的债失效。

### 11.5 数据修复（只能手动）

`config.json` 的损坏只能用户自己修：设置 → 桌面 → 每个桌面「从当前 Dock 抓取」；通用页同样重抓一次默认 Dock。
**代码修好不会自动修数据。** 逐桌面的 override 内容已经丢了（Dock 域一次只装得下一套配置，备份里也没有），
恢复不了，只能重抓。

### 11.6 ⚠️ 后续实验把这个结论**证伪了**（2026-09-20，实验 12–14）

11.3 那个"uptime 门槛"解释很顺，所以在改 `DockReloader.minimumSpacing` 之前先做了控制实验 ——
**结果三次全是否定，不要按 11.3 去改代码。**

| # | 脚本 | 假说 | 结果 |
| --- | --- | --- | --- |
| 12 | `scripts/spike-restart-spacing.swift` | launchd 有 ~10 s 的 uptime 门槛 | ❌ **推翻**。uptime 6.0 / 12.0 / 20.0 s 各测一次，加上 60 s 与 81 486 s 两个对照，**归位耗时 37–68 ms**，一次都没被罚 |
| 13 | `scripts/spike-pid-detection.swift` | `dockPID()` 优先走 `NSRunningApplication` 会在重启窗口里返回陈旧实例，导致 `waitForRestart` 看不见已经回来的 Dock | ❌ **推翻**。A 路径（`proc_listpids`）41–63 ms、B 路径（`NSRunningApplication`）78–116 ms，**同量级、无分叉** |
| 13 | 同上 | 连续快速重启会累积退避 | ❌ **推翻**。**6 次连发、间隔 2 s**，归位全部 41–116 ms |
| 14 | `scripts/spike-preference-write.swift` | 慢的是「写偏好 + 重启」这个组合（App 会先写偏好，而前两个实验只发信号） | ❌ **推翻**。**幂等写**白名单 9 个键（值原样写回，事后核对域零变化）再 SIGHUP，5 轮 **35–46 ms** |

**所以 11.2 那张表里的相关性不是因果。** 真正区分好坏两组的变量还没找到。
四条被排除的假说连同原始数字一起留在这里，**免得下一个 agent 再花一轮去试**。

**当下的立场**：

- **不要改 `minimumSpacing`。** `com.apple.Dock.plist` 里写的本来就是 `ThrottleInterval = 1`
  （`launchctl print gui/501/com.apple.Dock.agent` 显示 `minimum runtime = 1`），
  实验 12 也证明 6 s 的 uptime 完全够用。把它提到 10 s 只会让配置生效白白晚 10 秒，换不到任何东西。
- 26–31 s 是**偶发**，正常路径（单次重启、uptime 充足）稳定在 **35–126 ms**，连续 6 次快速重启也不慢。
  它对用户的实际影响远小于实验 9 那个 60–126 s。
- 下一步要复现它，得带上**真实 App 的完整上下文**（GUI 应用 + `DockWatcher` / `DockPresenceMonitor` / `SpaceObserver` 三个轮询同时跑），
  而不是继续加控制实验 —— 已经排除的四个方向别再试。
- ⚠️ **一条曾经被当成"已排除"的观察，2026-09-20 复核后打了折**：真机那两次慢重启期间，
  同一窗口 toast 的 1 秒定时器**准时开合了 4 组**（`05:32:20.566 显示` → `…21.597 隐藏`，
  一直到 `05:32:27.364 显示` → `05:32:28.388 隐藏`），说明**主线程在那段时间是活的**。
  **但它只覆盖 26 秒窗口的前 10 秒**（apply 起于 `05:32:18.675`，结束于 `05:32:44.735`）——
  后 **16.35 秒日志完全空白**，**没有任何存活性证据**。原来的写法"所以不是主线程被冻住导致的
  假测量"是**过度概括**，已更正。→ 见 **实验 15.4**：仪表已补上"轮询次数 + 最长间隔"来封这个洞。

### 11.7 实验脚本

```bash
swift scripts/spike-restart-spacing.swift 20 12 6      # 实验 12：uptime 门槛（已证伪）
swift scripts/spike-pid-detection.swift 6 2            # 实验 13：两条探测路径 + 连发重启
swift scripts/spike-preference-write.swift 5 2         # 实验 14：写偏好 + SIGHUP
```

三个脚本都**只重启 Dock、不改语义**（实验 14 是幂等写），跑完会确认 Dock 活着；
实验 14 会写 `com.apple.dock`，跑前先 `defaults export com.apple.dock <备份路径>`。

---

## 实验 15：给「偶发慢重启」装取证仪表（2026-09-20，**未定案，等下一次真机复现**）

### 起因：把真机日志那两行逐字读一遍

实验 11.6 已经证伪四个假说，但**没有定案**。这次回去把两行日志逐字重读：

```
2026-09-19 05:32:44.735 [INFO] Dock 应用成功：applied：切到 LLM；SIGHUP 成功：PID 39129 → 39143，
                                        Dock 不可用 26046 ms；写入 10 个键；总耗时 26060 ms
2026-09-19 05:33:16.817 [INFO] Dock 应用成功：applied：切到 计划 任务；kickstart 成功：PID 39143 → 39164，
                                        Dock 不可用 31039 ms（先等了 1032 ms 错开节流，期间 Dock 可用）；
                                        写入 10 个键；总耗时 32079 ms
```

两条新事实（之前没注意）：

1. **第一次慢重启的时间窗是 05:32:18.675 → 05:32:44.735**（`26046 ms` 倒推）。
   而 `05:32:18.668 切换到 LLM` —— **慢重启正好始于那次切换**。
2. **第二次慢重启紧接第一次**：`05:33:16.817 − 32.079 s = 05:32:44.738`，与第一次结束的
   `05:32:44.735` 只差 3 ms。即"第一次刚回来，第二次立刻开始"，而第二次 **30 秒的 SIGHUP 等待
   全烧光了才升级到 `kickstart`**。

### 为什么旧日志无法定案

这 26 秒窗口里**一行日志都没有**。看起来像"监视器没工作"，其实是**设计如此**：

```swift
// DockPresenceMonitor.tick()
guard !isReloading() else { return }   // 我们自己正在重载 → 这一轮不计数、不记日志
```

`DockReloader` 正在重载时监视器刻意闭嘴（`docs/spikes.md` 实验 8.5：两条控制回路抢同一个服务
会把 1 秒滚成两分钟）。**代价就是慢重启窗口里没有旁观者。**

同样地，`waitForRestart` 只记录**结果**（`elapsed`），不记录**过程**（那 26 秒里 `dockPID()`
到底返回了什么）。于是两种完全不同的病因都能套上去：

| 病因 | 现象 | 该谁修 |
| --- | --- | --- |
| **探测分叉** | `procScan` 早就看到新 Dock，`launchServices` 迟迟返回旧 PID → `waitForRestart` 以为"还没回来" | **我们**（`dockPID()` 的路径选择） |
| **Dock 真的没回来** | 两条路径都只看到 `nil` | launchd（我们改不了） |

**曾以为"已排除"的观察，2026-09-20 复核后打了折**：那 26 秒里 toast 定时器准时开合了 4 组
（`05:32:20.566 显示` → `…21.597 隐藏`，直到 `05:32:27.364 显示` → `05:32:28.388 隐藏`，
每组正好约 1.02 s）→ 主线程在那 10 秒里确实是活的。
**但它只覆盖窗口的前 10 秒**（apply 起于 `05:32:18.675`，止于 `05:32:44.735`），
**后 16.35 秒毫无存活性证据**。见 **15.4**。

### 做法：只在慢路径上取证，答案变化才记

`DockProcessControlling` 加了 `pidProbe() -> DockPIDProbe?`（带默认实现返回 `nil`，
所以测试替身不受影响）。`DockPIDProbe` 同时带两条路径的答案：

```swift
struct DockPIDProbe { var launchServices: pid_t?; var procScan: pid_t? }
```

`waitForRestart` 的规则：

- **正常路径零开销** —— 等待不超过 `slowProbeThreshold`（默认 **1 秒**）就一次都不调用 `pidProbe()`。
  这是硬要求：正常重启只要几十毫秒，而 `NSRunningApplication` 单次 0.6–1.4 ms，白花这笔钱没道理。
- 超过 1 秒后每 `probeInterval`（100 ms）采一次，但**只在答案变化时记一条**（外加首尾各一条强制记录）。
  一次 30 秒的慢重启通常只留 **2–4 条**，不是 300 条。
- 条数另有 `probeSampleCap`（24）兜底。
- 时间线挂在**已有的那一行日志**里（`ReloadOutcome.description`），不新增日志行：

```
… Dock 不可用 26046 ms；慢重启取证：1000ms LS=39129 scan=nil｜26046ms LS=39143 scan=39143
```

### 判定规则（下次真机复现时照着读）

| 时间线长什么样 | 结论 | 下一步 |
| --- | --- | --- |
| 早期条目 `scan=<新 PID>` 而 `LS=<旧 PID>` | **探测分叉**，`dockPID()` 的路径选择有 bug | 把 `procScan` 提到首选（它 0.02 ms，且是内核事实） |
| 早期条目 `LS=nil scan=nil` | **Dock 真的不在** | 转去查 launchd 侧（退避 / 系统负载），别改我们的探测 |
| 两条路径同时看到新 PID，但就是很晚 | 探测没问题，是**归位本身慢** | 同上 |

### 状态

- **未定案。** 仪表已随 `./scripts/build-app.sh` 装进 `build/MultiDock.app`（2026-09-20 05:02），
  下一次偶发时会自己把过程写进 `multidock.log`。
- 单测 6 条（`DockReloaderTests` 的「慢重启取证」一节）：快路径零开销、两条路径都记、
  只在变化时记、条数封顶、替身不支持取证时照常工作、**超时未归位也要带时间线**。
- ⚠️ **别为了"复现"去反复折腾用户的 Dock。** 这个故障偶发（那天 6 次里中 2 次），
  真要复现得带上真实 App 的完整上下文（GUI + 三个轮询同时跑），成本高、收益不确定 —— 等它自己出现。

### 15.1 第五次尝试复现：**真机验收 20 轮连切，没复现**

2026-09-20 05:11 跑了完整真机验收（`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`），
其中 `testSwitchingBetweenTwoDesktopConfigsIsStable` 就是**同一个形状**的负载：
两套配置（`tilesize` 40/60 + `magnification` 反相）**来回切 20 次**，每次都是一次真实的 SIGHUP 重启，
而且因为 `DockController` 默认带 `minimumSpacing = 1 s`，**每次重启时 Dock 的年龄都正好在 1 秒左右** ——
与真机那次 `39143` 只活了 **1.03 s** 就被重启的情形**同构**。

结果：

```
[P3 验收] Dock 不可用时长（ms）：[47, 49, 46, 47, 74, 56, 61, 52, 31, 59, 47, 61, 54, 32, 32, 53, 67, 65, 53, 52]　最坏 74 ms
[P3 验收] 慢重启（≥ 300 ms）共 0 次：无
```

**20 轮全部 31–74 ms，一次都没慢。** 加上实验 12–14，这已经是**第五次没复现出来**。

结论：**A8 不是"连续重启"这个形状本身能触发的。** 剩下的差异只有"真实 App 的完整上下文"：
GUI 事件循环 + `DockWatcher`（2 s 读偏好域）+ `DockPresenceMonitor`（500 ms 查 PID）+
`SpaceObserver`（300 ms 查空间）+ 用户真实切桌面。**所以不再加码尝试复现，等它自己出现。**

> 顺带：`testKillingDockRecoversWithinThreeSeconds` 这次实测 **56 ms** 归位（`69452 → 69457`），
> 而不是文档里那个 1072 ms。见 §4 的那行修正 —— **`kill -9` 的归位时间取决于 Dock 当时的年龄**，
> 不是个常数。

### 15.2 ⚠️ 仪表本身是坏的：Swift 的**协议见证位协变陷阱**（2026-09-20，已修）

**这一节比仪表本身更值得读。** 仪表装好、6 条单测全绿、App 也重新打包了 —— 但它**在生产路径上
完全是死的**，而且**只有真机验收能发现**。

#### 怎么发现的

给仪表写了一条真机验收测试（`DockAcceptanceTests/testSlowProbeTimelineWorksAgainstTheRealDock`），
它的第一个断言就是"直读一次探针，必须是非 nil"。**第一条就炸了**：

```
XCTUnwrap failed: expected non-nil value of type "DockPIDProbe" - pidProbe() 返回 nil —— 取证仪表是坏的
```

#### 根因：默认实现抢走了见证位

协议要求与实现分别是：

```swift
protocol DockProcessControlling {
    func pidProbe() -> DockPIDProbe?          // 可选返回
}
extension DockProcessControlling {
    func pidProbe() -> DockPIDProbe? { nil }  // 替身默认：不支持取证
}
struct RealDockProcessControl: DockProcessControlling {
    func pidProbe() -> DockPIDProbe { ... }   // ⚠️ 非可选 —— 协变
}
```

Swift **不做返回类型协变匹配**：`-> DockPIDProbe` 不被认为是 `-> DockPIDProbe?` 这个要求的实现，
编译器把它当成**另一个重载**（两个函数都存在于类型上）。于是协议要求的见证位**由扩展里的默认实现满足**。

后果是精确的、而且是静默的：

```swift
RealDockProcessControl().pidProbe()            // ✅ 有值（直接派发到具体方法）
(RealDockProcessControl() as any DockProcessControlling).pidProbe()  // ❌ nil（默认实现）
```

而 `DockReloader` 持有的是 `any DockProcessControlling` —— **它永远拿到 nil**。
`sample()` 里的 `guard let probe = process.pidProbe() else { return }` 于是每次直接返回，
时间线恒为空数组，行为与"没装仪表"完全一样。

编译器其实给了提示（在被调用的那一侧才会出现）：

```
warning: comparing non-optional value of type 'Probe' to 'nil' always returns false
```

#### 为什么 6 条单测全是绿的

因为**替身是对的**：`FakeDockProcess` 自己声明的是 `func pidProbe() -> DockPIDProbe?`，
签名与协议要求逐字相同，见证位正常。单测验的是"`DockReloader` 拿到探针答案后会怎么记"，
**从来没验过"真货有没有接到那根线上"**。

> **教训：替身单测证明不了生产路径接通。** 有默认实现的协议要求，必须**再写一条走 `any` 协议
> 的守卫测试**，断言默认实现没被选中。

#### 修法与回归守卫

- 返回类型改成逐字相同：`func pidProbe() -> DockPIDProbe?`（`DockReloader.swift` 里带了最小复现注释）。
- 新增 `DockProcessSafetyTests.testRealControlIsWiredAsTheProtocolWitness`：
  `let viaProtocol: any DockProcessControlling = RealDockProcessControl()` → 断言 `pidProbe()` 非 nil
  且 `procScan == 真实 Dock PID`。**关键是它故意不直接用具体类型。**

#### 这一类 bug 的全仓审计（2026-09-20）

修完不能收工 —— 这是**一类**bug，不是一次事故。**凡"有默认实现的协议要求"都有同一个静默失效面**。
把 `Sources/` 里全部 4 个协议过了一遍，**只有 2 个扩展带默认实现**：

| 协议 | 带默认实现的要求 | 真实实现签名 | 结论 |
|---|---|---|---|
| `DockProcessControlling` | `pidProbe() -> DockPIDProbe?` | 已修成 `?` | ✅ 已修 + 守卫 |
| `DockProcessControlling` | `startTime(of:) -> TimeInterval?` | `TimeInterval?`，**逐字一致** | ⚠️ **签名对，但当时没有守卫** → 补上 |
| `DockPreferenceAccessing` | `readMRUSpaces() -> Bool?` | 转调**必需**的 `readDomain()` | ✅ 构造上安全 |

`startTime(of:)` 为什么"签名对也要补守卫"：它一旦被写成非可选，**节流窗口的判据会静默从"进程年龄"
退回"我们记不记得自己重启过"**。这个退化**有实测代价** —— P3 验收里同一场景从 **45 ms 变成 1030 ms**
（用户看到 Dock 消失一秒多），而**没有任何测试能发现**，因为 5 个替身
（`FakeDockProcess` ×2、`RevivableDock`、`FlakyDock`、`LyingProcess`）全靠这个默认实现活着。
→ 补 `testRealStartTimeIsWiredAsTheProtocolWitness()`，同样**经 `any` 协议调用**。

默认实现**保留不删**：那 5 个替身里有 3 个只关心别的行为，不想被迫实现全部要求；删掉只会把陷阱
从"默认值"挪到"替身自己写错"。守卫测试才是对的修法。

**排查配方**（3 条 `rg` + 一张判定表）已写进 skill `macos-dock-space-probe`，下次加协议要求前先跑一遍。

#### 附带的第二个坑：这条验收测试自己有竞态

阈值先写成 `1 ms`（"正常重启几十毫秒，必然该有取证"）。**实测一次空、三次有**：

```
# 偶发失败
[A8 取证] 真机重载：SIGHUP 成功：PID 69602 → 71491，Dock 不可用 37 ms
[A8 取证] 取证条数：0（上限 8）
```

原因是**探测机会出现在第二轮轮询里**（第一轮 `now` 还没越过窗口），而循环里的顺序是
`dockPID()` 判定 **在** `sample()` **之前** —— 只要 `Task.sleep(15 ms)` 被拖长一点、
Dock 恰好在第二轮之前回来，就会**先返回、一条不记**。

修法：阈值改 `.zero`，让**第一轮就必然采样**，与轮询抖动解耦。改完连跑 4 次，每次都稳定 2 条。

> **教训：验收测试里的"必然"要小心。** 只要断言依赖"某件事发生在某轮轮询之前"，
> 它就是个竞态，与机器负载耦合。

#### 修好之后真机长什么样

```
[A8 取证] 探针直读：LS=72409 scan=72409　dockPID()=72409
[A8 取证] 真机重载：SIGHUP 成功：PID 72409 → 72516，Dock 不可用 37 ms；
          慢重启取证：0ms LS=72409 scan=nil｜36ms LS=nil scan=72516
```

**这一行立刻产出了新线索**：发完 SIGHUP 后，`NSRunningApplication` 还在报**旧** Dock，
而内核进程表已经空了 —— 见 15.3。

### 15.3 第六个假说（LaunchServices 滞后）也被证伪 —— 定向测量（2026-09-20）

#### 假说从哪来

15.2 修好后第一次真机取证就显示 `0ms LS=<旧 PID> scan=nil`。这正好命中
`RealDockProcessControl.dockPID()` 的结构：

```swift
func dockPID() -> pid_t? {
    if let pid = launchServicesDockPID() { return pid }   // ⚠️ LS 优先
    return scanForDockPID()                               // 只有 LS 给不出才扫进程表
}
```

而 `DockReloader.waitForRestart()` 的判据是 `pid != oldPID`。
**如果 LS 在重启窗口里持续返回那个正在退出的旧 Dock，`dockPID()` 就会一直返回 `oldPID`，
等待方根本看不见重启已经发生** —— 它会一直等到 LS 松手。若 LS 的滞后能到秒级，这就是 A8。

（这正好是实验 13 没测到的角度：实验 13 测的是"两条路径**答案是否一致**"，
这次要测的是"**LS 什么时候放弃旧答案**"。）

#### 测量

新增脚本 `scripts/measure-launchservices-lag.swift`（**只读 + 发 SIGHUP**，与产品代码同构的安全闸门）：

```bash
swiftc -O -o /tmp/md-ls-lag scripts/measure-launchservices-lag.swift && /tmp/md-ls-lag 6
```

每轮：读 old PID → 发 SIGHUP → 每 **1 ms** 同时问两条路径，直到两路都看到新 PID 或超时 1.5 s。

#### 结果（6 轮，全部一致）

| 量 | 实测 |
| --- | --- |
| 进程表看到新 PID | 26–33 ms |
| **LS 松手（不再报旧 PID）** | **11–29 ms** |
| LS 看到新 PID | 70–93 ms |
| `dockPID()`（LS 优先）感知到重启 | 26–33 ms |
| **危险窗口（进程表已知新、`dockPID()` 还报旧）** | **6/6 = 0 ms** |
| LS 相对进程表"看到新 PID"的滞后 | min 41 / 中位 57 / max 63 ms |

#### 结论：**假说证伪，而且机制上不成立**

关键在于 LS 的两件事是**分开的**：

- **松手很早**（~11–29 ms）：SIGHUP 之后它很快就不再报旧 Dock；
- **认领很晚**（~70–93 ms）：它要晚 ~50 ms 才认得新 Dock。

而 `dockPID()` 是 **LS 优先 + nil 就回退扫进程表** —— LS 松手的那一刻回退就接管了，
所以"认领晚"这半段**完全被回退吃掉**。危险窗口恒为 0：LS 放弃旧答案的时刻总是**早于**
进程表看到新 Dock 的时刻（~25 ms vs ~30 ms）。

> 附带观测：有几轮在 **400–550 ms** 处又出现一次 `LS=nil`（LS 短暂丢掉了已经认领的 Dock），
> 随后恢复。同样被回退吃掉，无害。

**意义**：这是第六个被证伪的假说，而且很可能是**最后一个"我们的 bug"候选**。
剩下的解释只有 launchd / Dock 侧的"归位本身慢"。

⚠️ **`dockPID()` 的路径选择不要改。** 判定规则表第 1 行说"把 `procScan` 提到首选"，
**前提是时间线真的显示分叉** —— 15.3 已经证明正常重启下不会分叉。
别再"顺手"把 scan 提到前面（那会让 `dockPID()` 在 LS 本来更快的时候变慢，且没有任何证据支持）。

⚠️ **本测量的边界**：测的是**正常重启**（26–33 ms 归位）。A8 时 Dock 归位要 26 s ——
但要让危险窗口成立，LS 得**抱着旧 PID 不放 26 秒**，与实测的 ~25 ms 差三个数量级。

### 15.4 补上最后一个洞：**"Dock 真的不在" 也可能是 "我们没在看"**（2026-09-20）

#### 起因：复核 11.6 里那条"已排除"的观察

11.6 与 15 都写过"那 26 秒里主线程是活的，所以不是假测量"。复核真机日志原文后发现**这是过度概括**：

```
05:32:18.675  第一笔 apply 开始（= 44.735 − 26.060 s）
05:32:20.549  活动桌面 → 计划 任务
05:32:20.566  toast 显示「计划 任务」
05:32:21.597  toast 隐藏           ← 1.03 s，准时
…             共 4 组 toast 准时开合，最后一组是 27.364 显示 → 28.388 隐藏
05:32:28.388  toast 隐藏
              ↓ 16.35 秒完全空白
05:32:44.735  Dock 应用成功：Dock 不可用 26046 ms
```

toast 的 4 组开合只覆盖 **18.675 → 28.388（前 10 秒）**。**后 16.35 秒日志一片空白。**

而这段空白**两种解释都成立**：
- Dock 真的不在 → 没东西可记；
- 主线程被冻住 → 想记也记不了（`DockPresenceMonitor` 在重载期间本来就被 `guard !isReloading()` 静音，
  所以它连"我还在跑"都不会说）。

#### 这个洞是结构性的，不是这一次的巧合

`DockReloader.waitForRestart` 的 `elapsed` 是**墙钟**，而轮询循环跑在 `@MainActor` 上。
主线程一旦被别的东西冻住，循环就跑不动 —— 我们会**根本没在看**，
却照样在恢复后把整段时间记成 `Dock 不可用 26046 ms`。
**"Dock 慢" 与 "我们瞎了" 在旧日志里长得一模一样。**

#### 做法：把存活性变成数字

`waitForRestart` 每轮记两个数，跟着慢重启那一句日志一起出来：

```
… Dock 不可用 26046 ms；轮询 1738 次，最长间隔 18 ms；慢重启取证：…
```

| 读数 | 结论 |
| --- | --- |
| 轮询次数 ≈ `elapsed / pollInterval`（默认 15 ms）、最长间隔十几毫秒 | **我们一直在看** → Dock 真的不在（launchd 侧） |
| 次数远低于预期、最长间隔**秒级** | **观察窗口断了** → 是我们的 bug，与 Dock 无关 |

只在 `elapsed > 1` 时记，**快路径的日志行一个字节都不变**（有单测钉着）。
两个计数器都是整数运算，零开销可忽略。

单测 3 条（`DockReloaderTests` 的「存活性」一节）：快路径不记、慢重启记上、
**替身在第 3 次 `dockPID()` 上阻塞 80 ms → 最长间隔必须体现出来**（并与未阻塞的对照）。

> **教训**：任何"某段时间里 X 没发生"的结论，都要先问一句 ——
> **那段时间里，我有能力观察到 X 吗？** 观测者自身的存活性也是证据的一部分。


---

## 实验 16：A8 的修法 —— **别等，催**（2026-09-20）

用户说「解决 A8 剩余的问题」。前面六条"我们的 bug"候选全被证伪、只剩 launchd 一侧，于是这轮
**不再找新假说，而是回到真机日志里那条一直没被当回事的线索**，并顺手把一条"证伪"重新验了一遍。

### 16.1 ⚠️ 先纠正一条：假说 ③ 的"证伪"站不住

实验 13 把「连续快速重启触发退避」判成 ❌，依据是 **"6 次连发（间隔 2 s）全部正常"**。

**可是 `com.apple.Dock.plist` 里 `ThrottleInterval` 本来就是 1 s** ——
**间隔 2 s 的重启根本不构成节流违规**。也就是说这条假说**从来没在真正的违规条件下被测过**。
真机那两次失败恰好落在这个没测过的形状上：故障前后的重启是**挤在一起**的（05:32:12 一次、
05:32:18 又要在 6.5 s 内再来一次），而不是隔开 2 秒。

### 16.2 补测：把 Dock 的存活时间压到 1 秒以内，连打 10 轮

脚本：`scripts/measure-launchd-backoff.swift`（新增）。轮与轮之间**不等待**，
每轮记旧 Dock 的存活时长、SIGHUP → 看到新 PID 的延迟，超过 3 s 未归位就自动催一发 `kickstart`。

```
[A8 退避] 第  1 轮：旧 PID 87395（存活 82.1s）→ 87686　延迟 30 ms
[A8 退避] 第  2 轮：旧 PID 87686（存活 0.0s）→ 87687　延迟 1012 ms
[A8 退避] 第  3 轮：旧 PID 87687（存活 0.0s）→ 87688　延迟 1016 ms
[A8 退避] 第  4 轮：旧 PID 87688（存活 0.0s）→ 87689　延迟 1019 ms
[A8 退避] 第  5 轮：旧 PID 87689（存活 0.0s）→ 87691　延迟 1017 ms
[A8 退避] 第  6 轮：旧 PID 87691（存活 0.0s）→ 87692　延迟 1019 ms
[A8 退避] 第  7 轮：旧 PID 87692（存活 0.0s）→ 87693　延迟 1016 ms
[A8 退避] 第  8 轮：旧 PID 87693（存活 0.0s）→ 87694　延迟 1013 ms
[A8 退避] 第  9 轮：旧 PID 87694（存活 0.0s）→ 87695　延迟 1016 ms
[A8 退避] 第 10 轮：旧 PID 87695（存活 0.0s）→ 87696　延迟 1021 ms

延迟序列（ms）：[30, 1012, 1016, 1019, 1017, 1019, 1016, 1013, 1016, 1021]
最小 30　中位 1016　最大 1021
需要 kickstart 的轮数：0 / 10
```

**两条结论，都很干净：**

1. **存活时间 < 1 s 时，launchd 恒定把归位压到 ~1016 ms —— 不累积、不增长、不漂移。**
   → 假说 ③ 到这一刻才算**真的被证伪**（在正确的实验条件下）。
2. **那 ~1 s 是一个硬顶，不是斜坡的起点。** 所以 26–31 s **不可能**是节流累积出来的。

> ⚠️ 附带：`launchctl kickstart` **不能**绕过这 1 秒节流。真机验收里 `nudgeAfter: 0`
> 那一发催在 SIGHUP 之后 0 ms，Dock 仍然到 **1037 ms** 才回来。催办解决的不是节流，
> 是**"launchd 压根没打算把它拉起来"**（见 16.4）。

### 16.3 真机日志里那半截一直被忽略了：**催一发就活**

回头逐字看 `05:33:16` 那次：

```
05:33:16.817 kickstart 成功：PID 39143 → 39164，Dock 不可用 31039 ms（先等了 1032 ms 错开节流）
```

`31039 ms` 里 **30000 ms 是 SIGHUP 那条路等满的超时**、500 ms 是 SIGTERM 的宽限，
**剩下的约 540 ms 才是 `kickstart` 发出去之后 Dock 归位的时间**。

也就是说：**SIGHUP 等 30 秒等不到的东西，`kickstart` 0.5 秒就拿到了。**
前面几轮一直在争论"launchd 为什么慢"，却没人问一句 —— **我们手里本来就有一条能立刻拿到它的通道，
只是把它排在了 30 秒之后。**

### 16.4 机制（推断，附可检验的预测）

`/System/Library/LaunchAgents/com.apple.Dock.plist` 的 KeepAlive 是
`{AfterInitialDemand: 1, SuccessfulExit: 0}`。`man launchd.plist`：

> `SuccessfulExit`：为真时，**只要程序正常退出**就重新拉起；为假时，**只要程序异常退出**
> （被信号杀死）就重新拉起。

所以：

- Dock **被 SIGHUP 打死**（异常退出）→ launchd 自动拉起，~1 s（16.2 实测）。
- Dock **干净退出**（exit 0）→ launchd **不会**重新调度它，直到**有东西显式要求**。
  而这个"要求"可以是任何 XPC 客户端去连它的服务 —— **什么时候来、来不来，都不由我们决定**。
  这就是"偶发"的来源。

`launchctl kickstart`（不带 `-k`）正是那个**显式的"现在就跑"要求**，所以一发就活。

**可检验的预测**（真机复现时一步就能定案）：在那段"一直没归位"的窗口里执行

```bash
/bin/launchctl print gui/501/com.apple.Dock.agent | grep -E "state|runs|last terminating"
```

- 干净退出那一路 → `state` 不是 `running`，且 **`last terminating signal` 缺失**；
- 正常（被信号打死）那一路 → `last terminating signal = Hangup: 1`（**这是本机现在的值**）。

本实验在**正常重启窗口**里采到的样子（`launchctl print` 单次约 0.5 s，只能在窗口里抓一两发）：

```
state = xpcproxy            ← 正在被拉起（xpcproxy 是 launchd 的 trampoline）
minimum runtime = 1
runs = 778
immediate reason = semaphore
last terminating signal = Hangup: 1
```

### 16.5 顺手排除的两条

| 检查 | 结果 |
| --- | --- |
| Dock 是不是在**崩溃循环**（自拼 tile 那类会让它 SIGABRT） | ❌ `~/Library/Logs/DiagnosticReports/` 与 `/Library/Logs/DiagnosticReports/` **都没有 Dock 的崩溃报告** |
| 能不能读**系统日志**看 launchd 的原话 | ❌ 不行。`/usr/bin/log show` 一律 `log: Cannot run while sandboxed`；**即使申请脱离沙箱也一样**（`log` 自己做了 `sandbox_check`）。`launchd` 那句 `Service only ran for … Pushing respawn out by …` 拿不到，只能靠 `launchctl print` 侧写 |

### 16.6 修法（`DockReloader`）

一句话：**把 `kickstart` 从"30 秒后的兜底"提到"500 毫秒后的催办"。**

| 改动 | 值 | 为什么 |
| --- | --- | --- |
| 新增 `nudgeAfter` | `500 ms` | 到点还没见到新 Dock 就催一发 `kickstart`。正常路径 35–126 ms，永不触发 |
| 新增 `nudgeInterval` | `1 s` | 重复催。⚠️ **尽力而为**：`LaunchctlParking.hasOutstanding` 闸门会吞掉叠发的（真机验收实测到第二发被吞） |
| `timeout` | **30 s → 3 s** | 原值 30 s 的理由是"launchd 的退避尺度是几十秒"（实验 8.5）—— 16.2 证明那个尺度是 **1 s**，理由不成立了。3 s ≈ 正常值的 24 倍，足够宽容 |
| 新增 `kickstartTimeout` | `30 s` | 真正需要耐心的那一段挪到这里：**催完之后**再给 30 s |
| **PID 守卫** | 新增 | 兜底原本是 `let dyingPID = process.dockPID() ?? oldPID` 再对 `dyingPID` 发 SIGTERM —— 如果 launchd 恰好在超时前后把 Dock 拉回来了，读到的就是**新** PID，那一发 SIGTERM 会把刚恢复的 Dock **再杀一次**。超时缩短后这个窗口更容易撞上，必须挡住 |
| 失败路径的取证 | 修 | 原来只带最后一段（`kicked`）的时间线，**把最有用的主路径那段丢了**（催办记录就在里面）。现在三段拼接并标段名 |

安全性前提是**实测**过的，不是推理：

```
$ launchctl kickstart gui/501/com.apple.Dock.agent    # Dock 正在运行
kickstart 前 Dock PID = 80643
kickstart 退出码 = 0
kickstart 后 Dock PID = 80643        ← 未变
⇒ 对运行中的 Dock 是无害的 no-op
```

### 16.7 验证

| 项 | 结果 |
| --- | --- |
| 全量单测 | **327 个测试、9 跳过、0 失败**（320 → 327，+7） |
| 真机验收 | **9/9 绿、43.1 s**（新增 `testPrematureNudgeIsHarmlessAgainstTheRealDock`） |
| 真机催办实测 | `nudgeAfter: 0` → `0ms 催 kickstart #1`，重载照常成功，**Dock 只换了一次 PID**（800 ms 后仍是同一只）—— 催早了不引起第二次弹跳 |
| Dock 域 | 与备份逐字节一致（只差 `mod-count`）；`config.json` SHA1 未变 |

新增/改动的用例：`testSlowRestartIsNudgedWithKickstart`、`testNudgeRepeatsWhileTheDockStaysAway`、
`testFastRestartIsNeverNudged`、`testNudgeDoesNotFireWhenTheDockReturnsFirst`、
`testProductionDefaultsNudgeEarlyEnough`（钉住生产默认值）、
`testFallbackNeverSignalsAFreshlyRestartedDock`（PID 守卫）。

### 16.8 这轮之后 A8 还剩什么

**修好的是"代价"，不是"成因"。**

- ✅ 最坏情况从 **26–31 s** 压到 **~1–3.5 s**：不再干等 30 s，500 ms 就把那条"显式要求"通道打开。
- ✅ 顺手修掉一个真实潜伏 bug（对刚归位的 Dock 补 SIGTERM）。
- ❌ **launchd 为什么偶尔不调度那次重新拉起，仍未直接观测到**（16.4 是机制推断 + 可检验预测）。
  系统日志拿不到（16.5），只能等下一次真机复现时用 `launchctl print` 侧写。

**下一次复现时的读法（顺序很重要）：**

1. 先看 `轮询 N 次，最长间隔 M ms` —— **M 是秒级就说明我们没在看**（实验 15.4），下面都不用看。
2. 再看时间线里的 `催 kickstart #n` —— 有它说明催办真的开了火。
3. 最后跑一次 `launchctl print … | grep -E "state|last terminating"`：
   **`last terminating signal` 缺失 = 干净退出 = 16.4 的机制成立**；仍是 `Hangup: 1` 就说明还有第三个成因。


---

## 实验 17：CoreDock 私有 API 通道 —— 「热重载不存在」被**部分推翻**（2026-10-03）

**问题**：能否不重启 Dock 就替换图标们（`persistent-apps` / `persistent-others` + 外观）？
实验 1 的结论是「不存在热重载」——但那次只测了 **notifyd 路径**（`notifyutil` / `NSDistributedNotificationCenter`）。
本实验把另一条路（**MIG → `com.apple.dock.server`**）挖了出来并实测。结论先行：

> **通道存在、无权限闸门；外观键实时生效已实锤（一次意外命中）；条目热替换未打通（三种载荷全被 Dock 静默拒绝）。**
> **「post 通知无效」依然成立；「必须重启 Dock 进程」不再成立。**

### 17.1 通道是怎么找到的（纯静态分析，零写入）

| 步骤 | 做法 | 发现 |
| --- | --- | --- |
| 1 | `launchctl print gui/501/com.apple.Dock.agent` | Dock 挂着 **`com.apple.dock.server`** 等 14 个 launchd 端点（注意：`sed` 截取会漏，必须完整列出） |
| 2 | `strings` Dock 二进制 | 有 `com.apple.dock.server` / `com.apple.dock.prefchanged` / `com.apple.dock.add-item` |
| 3 | `nm -u` **Finder** 二进制 | Finder 导入 **`_CoreDockAddFileToDock`**、**`_CoreDockSendNotification`**、`_CoreDockSetTrashFull`（垃圾桶满就是"外部进程让 Dock 实时变化"的活例） |
| 4 | `dyld_info -imports Finder` | 这些符号 **(from ApplicationServices)** → 实体在 **HIServices**（经 ApplicationServices 重导出，**不用 dlopen，直接可链**） |
| 5 | `dyld_info -exports HIServices` | 完整 API 面：Add/Remove/Set/Get/CopyPreferences/SendNotification 等约 60 个 `CoreDock*` 函数 |
| 6 | 排除干扰 | `DockKit.framework` 是 MagSafe 配件框架（`DockAccessoryManager`），与 Dock 条目无关；System Settings 二进制里没有 `com.apple.dock.server` 字符串（走的是框架内部）；旧 `Dock.prefPane` 是无二进制的资源壳 |

### 17.2 签名恢复（lldb 反汇编 HIServices 桩函数，全部核实过）

Dock 二进制符号被裁（`nm -U` 只剩 9 个 C++ typeinfo），但 HIServices 的桩函数在，`lldb -b -o "target create <探针>" -o "disassemble -n <函数名>"` 直接看。

| 函数 | 真实签名（反汇编还原） | 要点 |
| --- | --- | --- |
| `CoreDockSendNotification` | `(CFStringRef name, Int32 flags) -> OSStatus` | 序列化 CFString → `_DSSendNotification(port, 0x7D0, data, len, flags)` |
| `CoreDockAddFileToDock` | `(CFTypeRef file, Int32 flags) -> OSStatus` | 同一 msgid 0x7D0，载荷换成序列化 CFType —— **Dock 端按载荷类型分派** |
| `CoreDockSetPreferences` | `(CFDictionary) -> OSStatus` | msgid **0xBB8(3000)**，单参数 |
| `CoreDockCopyPreferences` | `(CFTypeRef request, CFTypeRef *out) -> OSStatus` | **两个参数**；request 传 nil 会崩（SerializeCFType 不判空）——第一次探针的 SIGSEGV 就是它 |
| `CoreDockGetTileSize` | `() -> Float`（xmm0 返回） | 无参数、返回 float；读到的 0.17857143 与域里的 36.0 对不上，**数值语义未定** |
| `CoreDockSetTileSize` | `(Int32) -> OSStatus` | `sendSetFloatValue(1, value)` —— **参数按 float 位型解释**（见 17.3） |
| `CoreDockRemoveItem` | `(Int32) -> OSStatus` | 底层叫 `_DSRemoveWindow`，参数是 Dock 内部窗口/tile ID，**不是数组下标** |
| `CoreDockIsDockRunning` | `() -> Bool` | 读的是 HIServices 自己的缓存标志 `sDockRunning`，没注册客户端时恒 false，**不代表 Dock 没跑** |
| `getDockPort` | bootstrap 查 `com.apple.dock.server` | **无权限闸门**：无特权 CLI 进程实测拿到 status=0 与真实 orientation/pinning 值 |

### 17.3 实测结果矩阵（每轮：`defaults export` 备份 → 触发 → 轮询 GUID/PID/域 → 强制还原）

| 尝试 | status | Dock 行为 | 判定 |
| --- | --- | --- | --- |
| `SendNotification("com.apple.dock.prefchanged", 0)`（写好无 GUID 测试 tile 后） | 0 | 5 s 内 GUID 不补、PID 不变 | ❌ Dock 不因这条消息重读偏好 |
| `SetPreferences(整份域 35 键, tilesize=37)` | 0 | 域 tilesize 不变 | ❌ 整域字典不被接受 |
| `AddFileToDock(CFURL(Calculator), 0)` | 0 | apps 数不变 | ❌ CFURL 载荷不触发（也可能要求客户端注册/别的类型） |
| **`SetTileSize(999999)`**（本意"无副作用自检"，**实际是真调用**） | 0 | **域 `tilesize` 36.0 → 16.0，PID 不变，mod-count 不动** | ✅ **实时生效 + 持久化实锤**（999999 按 float 位型 ≈ 1.4e-39 → 被钳到最小 16） |
| `SetTileSize(0x42100000=36.0f 位型)` / `64` / `36` | 0 | 域不再变化 | ⚠️ 数值语义未定（为何 36.0 位型无效），**别按现理解上生产** |

### 17.4 意外与恢复（诚实记录）

1. **我误发了 `SetTileSize(999999)`** —— 把它当"无副作用自检"，实际它就是一次真实调用。用户 Dock 图标当场变小。已用 `defaults write com.apple.dock tilesize -float 36` + SIGHUP 恢复。教训：**"自检"调用也必须用无副作用模式，不能拿写函数试编译**。
2. 三轮实验共重启 Dock 5 次（还原路径），PID 链 `493→47938→48072→48206→48395→48484`，全部健康；终态与实验前全量 diff **为空**（除 mod-count 等 Dock 自有键）。
3. **沙箱坑（新增）**：本会话沙箱里 `CFPreferencesCopyMultiple(nil, …)` **只回 1 个键**，逐键 `CFPreferencesCopyAppValue` 完全正常 → 探针的观察手段必须逐键读，否则会把"观察坏了"误判成"实验失败"（第一轮就因此白跑）。
4. `defaults` CLI 在沙箱里读到的是**真实域**（18057 字节 / 35 键），与探针的 CFPreferences 视图不一致 —— 两者观察口径不同，别混用。

### 17.5 结论与下一步

1. **修正实验 1 的表述**：`com.apple.dock.prefchanged` 在 Dock 二进制里大概率是它**对外广播**的方向（自己改了偏好时发给别人），不是收；Dock 不监听任何 notifyd 通知这件事没变。
2. **外观键的热重载通道已实锤存在**（`CoreDockSetTileSize` 一次成功：改域 + 持久化 + 不重启），但**数值语义未定**，不能上生产。
3. **条目热替换未打通** —— 三种载荷全被静默拒绝。缺口在 Dock 端 msgid 2000/3000 处理器的分派逻辑：可能要求 `CoreDockRegisterClientWithRunLoop` 注册、可能要求特定 CFType（CFString 路径而非 CFURL）、也可能校验发送方 audit token。
4. **下一步（实验 17 续，全部只读）**：
   - 反汇编 Dock 端 handler：Dock 二进制在磁盘上（10 MB），`otool -tV` 全量反汇编后找 0x7D0/2000 消息分派表与 `com.apple.dock.prefchanged` / `com.apple.dock.add-item` 的 xref；
   - `CoreDockRegisterClientWithRunLoop` 先注册再重试三种载荷；
   - 试 `AddFileToDock(CFString 路径, 0)`；
   - 看 Finder「在 Dock 中保留」时谁发什么（`dyld_info -fixups Finder` 或给 Finder 的 `cmdAddToDock:` 附近反汇编——lldb attach Finder 可能被 hardened runtime 拒）。
5. 若条目路径最终打通：`DockController.apply` 可升级为「写域 + 实时推送」，SIGHUP 降级为兜底；A8 的暴露面（launchd 节流/退避）将从应用主路径上**整体消失**。若打不通：外观键 setter 也可以先把"仅外观变化"的 apply 从重启降为零重启（但要先解决 17.3 的数值语义）。

### 17.6 Finder 是怎么用的（B15 收口的基准，2026-10-04）

Finder 自己就有 `cmdAddToDock:` / `validateAddToDock:`（ObjC 元数据：IMP 分别为 `0x100677275` / `0x1000b7ad0`，符号已裁、从 otool -oV 拿）。
lldb 反汇编 `cmdAddToDock:`：**对每个选中项调用 `CoreDockAddFileToDock(<NSURL>, 0)`** ——
第一个参数是 item 转出的 NSURL（`NodeCopySFNodeRef` / `SFNodeCopyMountPoint` / `-fileURL` 一族），
第二个参数实打实是 `xorl %esi, %esi` = **0**；调用后**不发任何通知**，失败才走错误提示。
⇒ 我们的探针 `(CFURL, 0)` 与 Finder 的调用**逐参数相同**。

### 17.7 判别电池（2026-10-04，带备份/看门狗/还原）

| 尝试 | 结果 |
| --- | --- |
| `CoreDockRegisterClientWithRunLoop` | ❌ 未调用：反汇编证明它是**接收端**注册（建 `_DCXDockClientDefs_subsystem` 的 MIG server source，收 Dock→客户端消息，还要求先有 client message proc），与发送授权无关 ——「先注册再发」排除 |
| `CopyPreferences("com.apple.dock", &out)` | **status = -4956**、out=nil —— 读请求被**明确拒绝**（不是无声忽略） |
| `SendNotification(prefchanged, flags=1)` | status=0，无效果（与 flags=0 相同） |
| `AddFileToDock(CFString 路径, 0)` | status=0，条目不变（与 CFURL 载荷相同） |

**结论（B15 结案为「不做」）**：

1. **外观 typed setter**（`SetTileSize` 一族）对第三方开放；**所有携带对象的 MIG 消息**（SendNotification / SetPreferences / AddFileToDock / CopyPreferences）对第三方要么报错、要么无声忽略。
2. Finder **同样的调用**能工作 ⇒ Dock 按**发送方**放行（Apple 平台二进制），或要求已注册的客户端会话。我们**不伪造发送方身份**（违反零权限硬约束的精神）。
3. 系统设置的实时滑杆**不走 CoreDock**（SystemSettings 主二进制与 Settings / PreferencePanesSupport 框架都不导入 CoreDock）；而 Dock 导入了 `_SLSCoordinatedLocalNotificationCenter` 一族 —— 它的实时通道大概率是 **SkyLight 协调通知中心**。未展开：收益低（SIGHUP 只有 100 ms）。
4. ⇒ 「不重启换图标」在 macOS 15 上的最终答案：**外观键可行但 `SetTileSize` 语义未定；条目键无第三方通道**。若未来 Apple 官方开放，B15 可重开。

---

## 实验 18：真人手势切桌面会触发 activeSpaceDidChange（B7 结案，2026-10-04）

**问题（B7）**：用户手动切桌面时 `NSWorkspaceActiveSpaceDidChangeNotification` 是否触发？
只影响"能否把跟随延迟从 300 ms 降到接近 0"。

**工具**：`scripts/spike-space-notify-watch.swift`——同时观察公开通知与 SkyLight 活动空间
**50 ms 高频轮询**（只读），每次轮询发现切换就回看 ±0.5 s 有没有通知伴随。
零权限、零写入、不切桌面；后台跑 240 s 窗口，用户以 ⌃←/⌃→ 手势切换。

**结果**：轮询观察到 **5 次切换**（id64 6↔7），**5/5 伴随通知**，且**通知比轮询早 2–30 ms**
（例：`01:37:49.994 NOTIFY` vs `01:37:49.996 POLL`）。

**结论（B7 结案）**：

1. P0 的表述要精确化：**程序化**切桌面（`CGSManagedDisplaySetCurrentSpace`）不触发通知；
   **真人手势**切桌面**触发**（5/5，且通知先于 50 ms 轮询到达）。
2. `SpaceObserver` 的通知快速通道（通知到达即 `refresh()`，读码确认已接线）**实测有效**——
   手势切换的跟随延迟本来就是 ≈0，**不需要任何代码改动**；轮询继续作为程序化切换的兜底。
3. 附带精确化 `docs/facts.md` 的「桌面切换通知」行。

---

## 实验 19：macOS 更新到 15.8.1 —— GUID 回填判据失效（2026-10-04）

**发现路径**：真机 Dock 验收（15.7.9 时代 9/9 绿）首跑即红：`testApplyThenRestoreLeavesDockUntouched`
断言「Dock 给无 GUID 的条目回填 GUID」失败（复跑再失败）。诊断显示 apply 链路完全正常：
SIGHUP 重启（PID 329→755、60 ms）、10 键写入、条目进 Dock、还原后仅差 `mod-count`。

**根因**：系统已从 **15.7.9 (24G830) 更新到 15.8.1 (24H32)**（Dock 二进制 09-23 重建；
实验 1–17 全部在 15.7.9 上完成）。新系统的 Dock 重启时 **mod-count 照常 +1**（证明重启 +
重读发生），但 **persistent-apps 一个字节都不改写** —— 不再给外部写入的条目回填 GUID。

**处理与影响**：

1. 验收用例加版本条件：15.7.x 保留 GUID 判据；15.8+ 降级为「条目跨 Dock 重启仍在」。
   重跑 **9/9 绿、40 s**（15.8.1 上首次全绿验收）。
2. `docs/facts.md`：「Dock 是否应用了写入」与实验 8 行加注。实验 8 的 **SIGABRT 结论不依赖
   该判据**，「其他项只搬不造」维持；"不认领"的证据方法在 15.8+ 过时。
3. **对产品无影响**：`DockController` 的 verify / 指纹短路、`DockWatcher`、无痕基线都不依赖
   GUID 回写——GUID 从来只是验收观测量。
4. 环境事实：`docs/facts.md` 开发机行已更新为 15.8.1 (24H32)；实验 18（通知观测）在更新后
   的系统上完成，其余实验（1–17）为 15.7.9 时代数据。

---

## 实验 20：自动隐藏三明治 —— 重启整个藏进「滑走 → 隐形 → 滑入」里（2026-10-04，**已实现**）

**用户诉求**：「切换桌面不用重启 Dock（会先黑屏再出现 Dock 栏），而是平滑地感觉不到」。
搜索过 GitHub（中英文两轮）：**没有**现成仓库做到免重启换 Dock 内容；社区对重启闪烁的
共识缓解手段恰恰是"开自动隐藏"。而我们手里有被实验 20 证实可用的typed setter 通道。

**GO/NO-GO 实测**（`CoreDockSetAutoHideEnabled` / `GetAutoHideEnabled`，lldb 反汇编签名：
`sendSetBooleanValue(id=3)`，与实测可用的 `SetTileSize` 同族）：

| 判据 | 结果 |
| Set(true) | ✅ 实时生效（PID 不变）、**Dock 自己持久化到域**（autohide=true） |
| 隐藏状态下 SIGHUP | ✅ 新 Dock 以隐藏态回来（PID 30611→30724）——重启不可见 |
| Set(false) | ✅ 实时滑回 + 域还原 false |
| CGWindowList 观测 | ⚠️ 15.8.1 的窗口列表**看不到 Dock 的容器窗口**（owner=Dock 零条目）——"窗口离屏"不可观测，改用 Get/域值做客观信号 |

**实现**（`DockAutoHide.swift` + `DockReloader` 三明治）：

1. `DockAutoHideControlling` 协议 + `HIServicesDockAutoHide`（`dlsym(RTLD_DEFAULT)`，无默认实现的协议要求——无见证位陷阱面；符号缺失时构造 nil，优雅降级为老路径）。
2. `DockReloader.reload(strategy:sandwichRevealAutoHideTo:)`：非 nil 时包住 `reloadCore`——
   **Set(true) 滑走 → 等 300 ms 动画 → SIGHUP（隐形重启）→ 等归位 → Set(reveal) 滑回**；
   任何返回路径都恢复可见性（失败重试一次，仍失败记 `revealFailed`，下次 apply 自愈——
   reveal 值来自**配置**而非当时的域，所以能自愈）。
3. `DockController.apply` 只在非退出路径、且 `config.appearance.autohide == false` 时传参
   （配置本就要求隐藏的话，重启后的 Dock 天然以隐藏态出现，不会闪）。
4. 失败语义：Set(true) 失败 → 老路径闪一次；整体重载失败 + reveal 失败 → Dock 隐藏待下次
   apply 恢复（Dock 本来就没回来，可见结果相同）。

**验收**：单测 333 全绿（+5 条三明治时序/降级/失败路径用例）；真机行为等用户重建重启后
切桌面看日志（`隐藏中重启（无闪烁）`）与体感。⚠️ 实验 19 教训：改代码必须重新
`./scripts/build-app.sh` 才算装上。

---

## 实验 21：次级 Dock 条的几何源 —— Dock 条不是独立 CG 窗口（2026-10-04，**已实现**）

**背景**：用户拍板做「贴原生 Dock、半露、hover 滑出」的次级条（见 `docs/PLAN.md` §3.12）。
原计划用 CGWindowList 按 Dock PID 找「Dock 条窗口」量几何。

**实测（`scripts/spike-probe.swift` + 一次性全窗口 dump）**：

| 观测量 | 值 |
| --- | --- |
| Dock 进程的全部窗口（`.optionAll`） | **只有两个全屏 layer-20 窗口**（1920×1200，一个 onscreen 一个 offscreen） |
| Dock 条自身的窗口 | **不存在** —— 条画在全屏容器窗口里（15.8.1；实验 20 也见过 owner=Dock 零条目的容器） |
| 屏幕 | 1920×1200，`visibleFrame = (0, 53, 1920, 1147)`（菜单栏自动隐藏，顶部无内缩） |
| 当前偏好 | `orientation=bottom`、`autohide=0`、`tilesize=36` |
| config.json | 默认与全部 3 条绑定都是 `bottom`（A9 时代的"默认 right"已过时，用户已改） |

**结论与决定**：

1. **几何源改用 `NSScreen.visibleFrame` 的排他内缩** —— 它就是系统为原生 Dock 预留位置的
   权威表达，随 Dock 方位/大小/自动隐藏自动更新，且天然跨 Dock 重启窗口（CGWindowList 在
   Dock 重启的 45–90 ms 里是空的）。`visibleFrame` 只有 top 是菜单栏的，left/right/bottom
   三向内缩即 Dock。
2. **摆放力学统一为「贴内侧、半露藏身后」**：条贴 Dock 内侧面（bottom→上方、right→左侧、
   left→右侧，与用户 msg3 的三方位一致）；半露 = 向 Dock 方向平移半个条厚，本条窗口层级
   **19 < 20**，滑进去的部分被原生 Dock 像素挡住，hover 向屏幕内侧滑出全条。
   这个力学**不依赖侧边 Dock 的垂直锚定**，三方位几何完全同构。
3. **点击/hover 的事件通路**：全屏 Dock 容器窗口在条的区域上方（层级 20 > 19），但它在
   条区域外必然事件穿透（否则全屏所有普通窗口都收不到点击）——真机窗口核验见下，点击手感
   归入用户手测（A 组）。

**真机验收（`build/MultiDock.app`，04:45）**：window-dump 读到次级条窗口
`layer=19 x=600 y=1115 w=720 h=56`（CG 坐标）——换算回 AppKit 即 y 29–85：
下半截 29–53 在 Dock 条后、上半截 53–85 从 Dock 顶边探出，水平居中，720 宽 = 16 条目
（访达 + 15 配置图标），与设计逐像素吻合。日志出现
`次级 Dock 条：Dock 几何变化 → bottom 内缩 (0.0, 53.0, 1920.0, 1147.0)`。

**测试**：+27 条（几何三方位/半露/clamp、内容构建 Finder 置首 + 运行指示、状态机
hover 防抖/安全网/全屏隐藏、冻结闸门、旧配置解码）——**355 全绿**，快照
`secondary-dock-{light,dark}.png` 人工核对通过。

---

## 实验 22：Dock 实际显隐的零权限观测信号 —— typed setter 只翻旗标不改 work area（2026-10-04，**已实现**）

**背景**：用户要求次级条与原生 Dock 的显隐同步（「原生 Dock 隐藏了次级条也 hide，show 则同步 show」）。
需要回答：Dock 的**实际**在屏与否，有没有零权限信号可读？

**实测（`scripts/spike-secondary-dock-sync.swift`）**：三路采样（`visibleFrame` 内缩 /
探针窗口 `occlusionState` / CGWindowList），`CoreDockSetAutoHideEnabled` 翻旗标 +
`CGWarpMouseCursorPosition` 甩光标到底边触发临时显出。

| 观测量 | 结果 |
| --- | --- |
| `SetAutoHideEnabled(true)` 后 **inset** | **纹丝不动（47）** —— 旗标翻了（Get=true、域已持久化）但 Dock **没有真的滑走**，work area 不变。⚠️ 修正实验 20 的理解：「实时生效」只是**旗标级**；sandwich 的「隐藏」来自**重启后的 Dock 读旗标**，不是实时滑走 |
| `Set(false)` 的**显出**方向 | 实时生效（对齐流程日志：重启后隐藏态 inset≈0「探测不到」→ Set(false) 后 0.7 s 内回到 47）—— 与 hide 方向不对称 |
| 探针窗口 `occlusionState`（level 19、Dock 腹地、alpha 0.05） | **不可用**：基线（Dock 在屏）就在 是/否 之间抖动，无稳定判据 |
| CGWindowList（dock 在屏时） | owner=Dock 在屏 0 个 / 全部 0 个 —— 15.8.1 依旧完全看不见 Dock 窗口（同实验 20） |
| `CGWarpMouseCursorPosition` | err=0（光标真的动了），但本实验里 Dock 从未进入隐藏态（旗标不生效），无法据此判定显出 |

**结论与决定**：

1. **Dock 实际显隐没有零权限直读信号**。可用的事实只有两个：`visibleFrame` 内缩跟随 Dock
   **实际**占位（真机对齐日志：隐藏态「探测不到」、恢复后内缩 47——与实验 21 一致）；
   自动隐藏的**显出触发**= 光标碰屏幕边（Dock 自己的机制，无 API）。
2. **同步显隐的实现** = face（inset）为主信号 + 「光标在显出带」启发式补自动隐藏态：
   face != nil → 条显示；face == nil（自动隐藏生效中/重启瞬态）→ 光标在最近一次 Dock 占用
   条带（略外扩 8 pt）里 = Dock 在屏或即将显出 → 条同步显示；离开显出带 → 400 ms 宽限后收回。
   几何轮询 1 s → **200 ms**（跟得上 Dock 的滑入滑出）。
3. **别再试的路**：探针 occlusionState、CGWindowList 找 Dock 窗口、指望 typed setter 的
   旗标翻转反映视觉状态——三条都已实测不通。

**测试**：+6 条（dockArea 三方位、显出带内保持/带外宽限收回/回归再显、sizingSlots 固定
frame、冻结模式固定几何 + 图标尺寸取默认 Dock）——**364 全绿**。

---

## 复现方法

```bash
# 重载策略（会真实重启 Dock，脚本自带备份与还原）
./scripts/spike-reload.sh

# 只生成实验用偏好、不动系统
./scripts/spike-reload.sh --dry-run

# 探测当前桌面 / Dock 状态
swift scripts/spike-probe.swift

# 切桌面实验（会真的切桌面，结束自动切回）
swift scripts/spike-switch.swift 1

# 停机时长
swiftc -O scripts/spike-dock-downtime.swift -o /tmp/downtime && /tmp/downtime HUP

# 枚举 SkyLight 的导出符号（只读、零权限，用于查「有没有对应的私有 API」）
swift scripts/spike-symbols.swift
swift scripts/spike-symbols.swift Transition Cube

# Dock 重启间距 / PID 探测路径 / 写偏好 + 重启（实验 12–14，都会真的重启 Dock）
swift scripts/spike-restart-spacing.swift 20 12 6
swift scripts/spike-pid-detection.swift 6 2
swift scripts/spike-preference-write.swift 5 2

# launchd 重启延迟会不会随连续快速重启累积（实验 16，轮间不等待、会反复重启 Dock）
swiftc -O -o /tmp/md-backoff scripts/measure-launchd-backoff.swift && /tmp/md-backoff 10

# LaunchServices 在重启窗口里滞后多久（实验 15.3）
swiftc -O -o /tmp/md-ls-lag scripts/measure-launchservices-lag.swift && /tmp/md-ls-lag 6

# CoreDock 通道探针（实验 17）
#   read / notify / state / domain 是只读；settilesize / setprefs / addfile 会真的动 Dock —— 必须先备份再跑
swiftc -O -o /tmp/coredock-probe scripts/spike-coredock-probe.swift && /tmp/coredock-probe read

# 自动隐藏 typed setter（实验 20：三明治的安全性前提；会真的改 autohide 旗标并持久化）
/tmp/coredock-probe getautohide
/tmp/coredock-probe setautohide 1      # 记得 setautohide 0 还原

# 真人手势切桌面会不会触发通知（实验 18，只读；跑 240 s 等你自己切几次）
swiftc -O -o /tmp/md-space-notify scripts/spike-space-notify-watch.swift && /tmp/md-space-notify 240

# 次级条与原生 Dock 的显隐信号三路采样（实验 22；⚠️ 会临时翻转 autohide 旗标，脚本结束还原）
swift scripts/spike-secondary-dock-sync.swift
```

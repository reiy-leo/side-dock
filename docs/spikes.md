# P0 实验结论

> 执行日期：2026-09-18（实验 1–16 在 macOS 15.7.9 上做完；实验 17–22 在 2026-10-03/04、macOS 15.8.1 上做完）
> 机器：x86_64 / 单显示器 / Swift 6.2.4。`docs/PLAN.md` 的主路径和事件源怎么设计，直接看这里的结论。
> 原始数据在 `/tmp/multidock-spike/`（临时目录，不跟项目走）；复现脚本见 `scripts/spike-*.{sh,swift}`。

---

## 摘要：结论

> 实验 1–3 是 P0 阶段原本要回答的三个问题；实验 4–7 是后面各阶段落地时**挖出来的新发现**。其中实验 5、6 各推翻了
> `docs/PLAN.md` 的一处假设，实验 7 是一条**明确的不做项**（别再去试）；实验 8 也是一条**明确的不做项**（其他项不能新建）；
> 实验 9、10 是同一条自我放大链的两个触发点（切桌面 / 退出）；实验 11 复盘的是**用户真机日志**，修正了实验 5 的节流阈值；
> **实验 12–14 是三个控制实验，实验 11 提出的四个假说全被证伪**；**实验 15 给这个没解决的故障
> 装上取证仪表**；**实验 16 落地修法（不干等，主动催），代价从 26–31 s 压到 ~1–3.5 s**；
> **实验 17：探 CoreDock MIG 通道（条目键没有第三方通道，B15 结案）**；**实验 18：真人手势切换，5/5
> 都触发了通知（B7 结案）**；**实验 19：系统升到 15.8.1，GUID 回填判据失效，改成按版本区分**；
> **实验 20：自动隐藏三明治（重启时用户看不到）**；**实验 21：次级条的几何从哪来（Dock 条不是独立的 CG 窗口）**；
> **实验 22：零权限下读不到 Dock 实际显没显示（同步显隐只能靠启发式，原因在此）**；
> **实验 23：`.canJoinAllSpaces` 会让窗口跟着空间过渡动画走（修法已实现；但「纯 `.stationary` 能钉住」这个结论被实验 24 的真人手势实测推翻了）**；
> **实验 24：零权限下没法让次级条不滑动——窗口层级 / Dock tags / 私有 API / 多窗口全试过了，只能退一步用 `.moveToActiveSpace`「消失再出现」**。一共 **24 个实验**。

1. **没有热重载**。写完偏好，不管 post 什么通知，Dock 都不会重新读——只能重启 Dock 进程。
2. **重启很快**：发 SIGHUP 后，Dock 只有约 **101 ms** 用不了；SIGTERM 约 **395 ms**（Dock 收到 TERM 会先花约 255 ms 清理再退出）。→ **主路径定为 SIGHUP**，SIGTERM + kickstart 兜底。
3. **程序化切桌面能用，而且极快（P0 粗测 20 ms，后来实验 7 精测是 0–6 ms），但不会触发 `NSWorkspaceActiveSpaceDidChangeNotification`**。→ SpaceObserver 必须**以轮询为主**，通知只能当优化。
4. **切桌面做不出"左右滑动动画"**（实验 7）：程序化切空间是硬切（0–6 ms），SkyLight 没给带过渡的入口；唯一像入口的会话级开关**写进去读不回来**，一碰就破坏无痕原则；`SLSWillSwitchSpaces` 签名未知，猜错直接段错误。**零权限 + 无痕的前提下没有解，别再试。**
5. **App 不能新建其他项（文件夹 / 堆栈）**（实验 8）：自己拼的 `directory-tile` Dock 不认（不补 `GUID`），字段不全的形状还会让 Dock **SIGABRT，进入崩溃循环**。→ 只搬，不造。
6. ⚠️ **"重启 Dock 会被罚几十秒"的四个假说，已经一个个实测推翻了**（实验 11 提出，实验 12–14 证伪）：
   真机日志里，uptime 6.5 s / 1 s 的两次重启花了 26 s / 31 s，uptime ≥ 30 s 的 4 次只要 50–126 ms。
   看着像有个"uptime 门槛"，但**控制实验一次都没复现出来**：
   | 假说 | 实验 | 结果 |
   | --- | --- | --- |
   | launchd 有 ~10 s 的 uptime 门槛 | 实验 12 | ❌ uptime 6 / 12 / 20 / 60 s **全部 37–68 ms** |
   | `dockPID()` 先走 `NSRunningApplication`，会拿到过期的实例 | 实验 13 | ❌ 两条路径都是 41–116 ms，同一量级，没有分叉 |
   | 连续快速重启会触发退避 | 实验 13 | ❌ 连发 6 次（间隔 2 s）**全都正常** —— ⚠️ 但**间隔 2 s 根本不算违规**（`ThrottleInterval` = 1 s），这条"证伪"站不住；**实验 16.2 用 10 轮零间隔重测，才算真证伪** |
   | 诱因是写偏好这一步 | 实验 14 | ❌ 幂等写 + SIGHUP，5 轮 **35–46 ms** |
   → **别动 `minimumSpacing`**（`com.apple.Dock.plist` 里 `ThrottleInterval` 本来就是 1）。26–31 s 是**偶发的，根因没定**。
   ⚠️ **实验 16：修法已落地，代价从 26–31 s 压到 ~1–3.5 s** —— 关键在真机日志里一直被忽略的后半截：
   `05:33:16` 那次 **SIGHUP 等满 30 s 都没等到，紧接着补一发 `kickstart`，0.5 s 就把 Dock 拉回来了**。
   所以 `kickstart` 从"30 秒后兜底"提前成"**500 ms 后催一下**"（`nudgeAfter`），`timeout` 从 30 s 改成 3 s。
   配套实测：① **零间隔连续重启 10 轮，延迟一直是 ~1016 ms，不累积**（假说 ③ 到这里才真证伪，
   这 ~1 s 是**硬上限**，不是越来越慢）；② `kickstart`（不带 `-k`）对**正在跑**的 Dock 没有副作用，什么也不做
   （PID `80643 → 80643`）；③ 顺手修掉一个潜伏 bug：对刚回来的 Dock 补 SIGTERM，会把它再杀一次。
   机制推断：`KeepAlive = {SuccessfulExit: 0}` 只在**异常退出**时自动拉起。Dock 要是干净退出，launchd 就**不会**
   再调度它，直到有人**明确要它起来** —— `kickstart` 就是这个要求。**成因本身还没直接看到**
   （沙箱里读不到系统日志），预测和下次复现时怎么读日志，见实验 16.4 / 16.8。
   ⚠️ **剩下两种病因，旧日志分不出来**（"探测分叉"还是"Dock 真没回来"）。原因是重载期间
   `DockPresenceMonitor` 故意不出声，`waitForRestart` 只记结果、不记过程 →
   **实验 15 已经给慢路径装了取证仪表**（`DockPIDProbe` / `probeTimeline`，正常路径零开销）。
   下次偶发时看那一行日志就能定案，判定规则见实验 15。
   ⚠️ **实验 15.1：真机验收连切 20 轮（Dock 年龄正好 ~1 s，和故障一个形状），最坏 74 ms，慢重启 0 次**
   —— 这已经是**第五次没复现**。说明成因不在"连续重启"这个形状里，而在真实 App 的完整上下文里。
   ⚠️ **实验 15.2：仪表一开始自己就是坏的** —— `RealDockProcessControl.pidProbe()` 的返回类型写成了
   非可选，踩中 Swift 的**协议见证位协变陷阱**：**走协议调用永远拿到 nil**。生产路径上的
   仪表完全没起作用，6 条替身单测却全绿。已修，并加了回归守卫（**故意走 `any` 协议**）。
   ⚠️ **实验 15.3：第六个假说（LS 滞后）也证伪了** —— 定向测了 6 轮：`dockPID()` 先查 LS
   带来的**危险窗口一直是 0 ms**（LS 在 ~25 ms 就放手，比进程表看到新 Dock 还早）。`dockPID()` 别改。
   ⚠️ **实验 15.4：补上最后一个洞** —— 11.6 / 15 里那句"主线程是活的、不是假测量"**只覆盖了
   26 秒窗口的前 10 秒**（toast 定时器的证据只到 `05:32:28.388`），后 16 秒完全没有存活证据。
   仪表补上了 **"轮询次数 + 最长间隔"**：次数 ≈ `elapsed / 15 ms`，说明我们一直在看（问题在 launchd 那边）；
   次数远少于这个数、最长间隔到秒级，说明**我们没在看**（是我们的 bug）。
   → **"我们的 bug"这边已经没有候选了**，只剩 launchd / Dock 归位本身。
7. **实验 9 和实验 10 的修复已经过真机验证**：退出还原从 **53–54 s → 0.01 s**（整个退出约 2 s）；
   切桌面的最坏值从 **60–126 s → 26–31 s**。**正常路径稳定在 35–126 ms**，连续快速重启 6 次也不慢。
8. **切桌面不用再重启 Dock 了**（2026-10-04 起的默认形态，实验 20–22）：**冻结模式**（原生 Dock = 默认 Dock，
   切桌面不写入、不重启）+ **次级 Dock 条**（跟着桌面换图标、几何固定、和原生 Dock 同步显隐）。
   还要重启的场合（没开冻结模式 / 手动应用 / 启动时对齐）走 SIGHUP + **自动隐藏三明治**，**用户看不到重启**（没有黑屏闪烁）。

---

## 实验 1：Dock 重载策略（决定 §3.5）

脚本：`scripts/spike-reload.sh`（配合 `scripts/spike-probe.swift` 拿客观信号）

### 判据怎么来的

截图验证走不通：本机没给屏幕录制权限，`screencapture` 只拍得到壁纸（没有菜单栏、没有窗口）。这也合项目「不申请系统权限」的约束，所以改用两个**不需要任何权限**的客观信号：

| 信号 | 含义 | 可信度 |
| --- | --- | --- |
| **tile 的 `GUID` 有没有被补上** | 写进去的 tile 故意不带 `GUID`。Dock 只要真读了、用了 `persistent-apps`，就会规范化并回写 `GUID` | **决定性**：重启后实测从 `guid=NO` 变成 `guid=yes`，正反两种情形都验过 |
| Dock 进程 PID 变没变 | 分清是「热重载」还是「进程重启」 | 决定性 |

### 结果

每一级都在上一级的基础上加码，逐级提高触发强度。写入内容：① 往 `persistent-apps` 末尾加一个 Calculator tile；② `tilesize` 36 → 72。

| 级别 | 做法 | PID 变化 | tile 生效（GUID） | 判定 |
| --- | --- | --- | --- | --- |
| **T0** | 只写偏好，不触发（观察 8s） | 不变 | `guid=NO` | ❌ 无效 |
| **A** | 写偏好 + post 通知 | 不变 | `guid=NO` | ❌ 无效 |
| **B** | `kill -HUP` | **535 → 18757** | `guid=yes` | ✅ 生效，但**这是重启，不是热重载** |
| **C** | `kill -TERM`（launchd 自动拉回） | **20952 → 23628** | `guid=yes` | ✅ 生效（重启） |

A 级试了两种通知，**都没用**：

- `notifyutil -p com.apple.dock.prefchanged` 和 `notifyutil -p AppleNoRedisplayAppearancePreferenceChanged`（darwin 通知）
- 再用 `NSDistributedNotificationCenter.postNotificationName(..., deliverImmediately: true)` 发真正的分布式通知，同名两个都发了

> ⚠️ 计划 §3.5 曾推测「Dock 二进制导入了 `_signal` 与 `DispatchSource.makeSignalSource`，存在无重启热重载的可能」。**实测证伪**：Dock 确实响应信号，但它的响应是**直接退出**，不是重载。A/B"零闪烁"的预期落空。

### 停机时长实测（毫秒级采样，`scripts/spike-dock-downtime.swift`）

| 信号 | 进程消失于 | Dock 归位 | 进程消失→归位 | **总不可用窗口** |
| --- | --- | --- | --- | --- |
| SIGHUP | +12.7 ms | +100.7 ms | 88 ms | **约 101 ms** |
| SIGTERM | +271.4 ms | +367.4 ms | 96 ms | **约 367 ms** |
| SIGTERM（复现） | +254.9 ms | +394.8 ms | 140 ms | **约 395 ms** |

**SIGHUP 比 SIGTERM 快约 4 倍**：SIGTERM 能被捕获，Dock 会先花约 255 ms 做退出清理；SIGHUP 几乎是立刻终止。

### 决定

> **§3.5 主路径 = SIGHUP（原 B），兜底 = SIGTERM + `launchctl kickstart -k gui/$UID/com.apple.Dock.agent`（原 C）。**

- 原计划把 B 当成"热重载、零闪烁"，这是错的，但**它仍然是最优解**——只是好处从"零闪烁"降成"只闪约 100 ms"。
- 计划里估 C 会闪 0.3–1 s，**估得偏悲观**，实测 367–395 ms。
- **launchd 配置已核实**：`KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}`。SIGHUP/SIGTERM 都是被信号杀死，launchd 都会拉回；**千万不能用 AppleEvent 让它优雅退出**（exit 0 不会被拉回，用户当场就没了 Dock）。
- UI/README 的说法可以从"Dock 会短暂刷新"写得更具体："**约 0.1 秒**"。

### 残留风险（P1/P2 要处理）

- **SIGTERM 那 255 ms 清理窗口有竞态**：我们写完偏好，Dock 退出前回写自己的状态，理论上可能盖掉我们的写入。这次实测没出现（写完立刻 TERM，重启后 `guid=yes`），但**不能假设永远安全**。建议：应用完校验指纹，对不上就重试一次。
- 选 SIGHUP 等于跳过 Dock 的退出清理，理论上可能打断它正在写的别的状态。好在我们**只覆盖白名单键**，每次写之前都全量备份，风险可以接受。

---

## 实验 2：主动切桌面（决定 §3.1 事件源）

脚本：`scripts/spike-switch.swift`

### 结果

| 项 | 实测 |
| --- | --- |
| `CGSManagedDisplaySetCurrentSpace(cid, displayUUID, spaceID)` | **能用**，活动 space 真从 id64=6 变成了 7 |
| 生效耗时 | **20 ms**（第一次采样就已经切过去了）—— 这是**当时的采样粒度**，不是真实耗时。实验 7 用 500 µs 粒度重测，得到 **6 / 0 / 0 ms** |
| 切回原桌面 | 正常 |
| 切换动画 | ⚠️ **这一行原来写"有系统自带动画"，2026-09-18 复核时证伪** —— 其实是**瞬间硬切，没有动画**，见实验 7。不过后半句"没有控制动画时长的符号"是对的（`CGSSetWorkspaceAnimationDuration` 这类符号都不存在） |
| **`NSWorkspaceActiveSpaceDidChangeNotification`** | **没触发，0 次**（观察 2.5 s，程序化切换） |

### 通知 0 次是真结论，不是环境问题

做了对照：在同一个 CLI 进程里注册 `NSWorkspace` 的几个通知，再用 `NSWorkspace.openApplication` 启动 Calculator —— `didActivateApplication` 和 `didLaunchApplication` **都正常收到了**。说明通知通道本身没问题。

> **结论：程序化切桌面不会触发 `activeSpaceDidChange` 通知。** 这个通知大概只在**用户自己切**（Ctrl+←/→、Mission Control、点 Dock 上的窗口）时才发。

### 决定

> **§3.1 的事件源必须主次颠倒：以轮询为主（建议 300 ms），通知为辅（要是用户手动切时确实会发，可以当"快速通道"降低延迟）。**

- 计划原文写的是「`NSWorkspaceActiveSpaceDidChangeNotification`（主）+ 1 秒轮询（兜底）」，**对程序化切换完全不成立**，必须改。
- 轮询间隔从 1 s 收紧到 **300 ms**：切桌面本身只要 0–6 ms，检测延迟 1 s 的话，"切桌面 → Dock 更新"会明显慢半拍。300 ms 轮询开销可以忽略（一次 `CGSGetActiveSpace` + `CGSCopyManagedDisplaySpaces` 都是纯内存调用）。
- **我们自己发起的切换必须"预应用"**（先改 Dock 再切空间，见 §3.4 第 8 条）——这条从"优化"升成了**必需**，因为切完我们收不到任何通知。
- **等用户确认的开放项**：用户手动切桌面时通知发不发。验证方法（P1 验收时顺手做）：
  ```bash
  # 终端 A：监听 30 秒，期间用 Ctrl+→ 手动切几次桌面
  swift scripts/spike-switch.swift 0   # 或直接看 App 调试面板的日志
  ```
  结果只影响"延迟能不能从 300 ms 降到接近 0"，不影响能不能用。

### 顺带发现：空间字典的真实键名

`CGSCopyManagedDisplaySpaces` 返回的 space 字典，实际的键是：

```
uuid / ManagedSpaceID / id64 / type / WindowManagerInfo
```

**没有 `ManagedSpaceUUID`**——`docs/PLAN.md` §1 和 `AGENTS.md` §4 里记的这个键名是错的，已经一起改正。另外 display 字典里有个 `Current Space` 键，可以直接拿到当前空间。

---

## 实验 3：Finder 图钉（决定 §3.6）

### 结果

把全量域的 34 个键递归扫了一遍（包括所有嵌套值和数组元素），搜 `finder` / `com.apple.finder`：

```
无任何 Finder 相关键或值
```

`persistent-apps` 一共 15 项，第一项是 Launchpad（`file:///System/Applications/Launchpad.app/`），**列表里没有 Finder**。按名字猜的控制键也不存在（只有 `persistent-apps` / `persistent-others`）。

### 决定

> **Finder 完全是 Dock 自己画上去的，plist 里没有它 → 写偏好删不掉它 → "钉住 Finder"天然成立，一行代码都不用写。**

三条推论：

1. `DockStripEditor` 把 Finder 当**锁定项**画在最前面，但**不需要、也不能**把它写进 `persistent-apps`。
2. Finder **没法排序**——永远在最左（或最上）。UI 上别给它拖拽手柄。
3. 白名单里**不用**加任何新键。

### 还剩的未知（要手动验证一次）

计划原文要求「从真实 Dock 移除 Finder，看 `com.apple.dock` 是否新增键」。这一步**没法写成脚本**：把 Finder 拖出 Dock 是纯 UI 操作，脚本化要辅助功能权限，和「不需要任何系统权限」这条硬约束冲突。

**手动验证步骤**（30 秒，随时能做，做完把结果告诉我）：

```bash
# 1. 快照
defaults export com.apple.dock /tmp/dock-before-finder-removal.plist
# 2. 手动：按住 Finder 图标拖出 Dock，松手
# 3. 对比
defaults export com.apple.dock /tmp/dock-after-finder-removal.plist
diff <(plutil -p /tmp/dock-before-finder-removal.plist) <(plutil -p /tmp/dock-after-finder-removal.plist)
```

- `diff` 为空 → 确认移除 Finder **不会留下任何键**，结论闭环。
- 多了键 → 这个键要加进白名单，并强制保持固定值，我回头改 §3.6 和白名单。

风险低：就算真有这个键，我们的实现从来不写它，用户也只有在"手动把 Finder 拖出去"时才会碰到。

---

## 实验 4（P2 落地复测，2026-09-18）：写白名单键，Dock 有没有真读进去

P0 只验证了"信号能让 Dock 重启、`GUID` 会被补上"。P2 把写路径真正接起来以后，又**端到端**复测了一轮。全程由 `Tests/MultiDockTests/DockAcceptanceTests.swift` 自动跑（默认跳过，设 `MULTIDOCK_DOCK_ACCEPTANCE=1` 才开），跑完自动把操作前的全量域写回去。

**做法**：读全量域 → 造一套不一样的配置（`tilesize` 36→52、翻转 `magnification`、末尾加一个**不带 `GUID`** 的 Calculator 条目）→ 写偏好 + `kill -HUP` → 读回来校验 → 和操作前 diff → 还原 → 再 diff。

| 观测项 | 结果 |
| --- | --- |
| SIGHUP 耗时 | **125–138 ms**（和 P0 的 101 ms 同一量级），`verifyAttempts == 1`（不用重试） |
| 变了的键 | **只有 `["magnification", "persistent-apps", "tilesize"]`** —— 白名单外的键（`mru-spaces` / `wvous-*` / `mod-count` / `recent-apps` …）一个没动 ✅ |
| Dock 有没有真读进去 | **有**。写的时候故意不给 `GUID`，Dock 重启后补上了（实测 `i:1414651200` / `i:2713705933` / `i:1414651200`，每次都不一样） |
| **`GUID` 什么时候回写** | **异步**。`apply` 返回后马上读，还是 `nil`；轮询 200 ms 以内出现。**判据必须带轮询**，不然会误判成"写入没生效"（第一轮验收就这么误报过） |
| 还原以后 | 图标顺序逐项回到原样，白名单键逐个一致，键集合一致（34 键）。**只剩 `["mod-count", "recent-apps"]` 有差异** |
| **Dock 自己会改的键** | Dock 每重启一次，`mod-count` 就 +1；`recent-apps` 也会变。这两个不在白名单里，我们从来不写 → 验收时"还原后还有差异"是**正常的**。判据放宽成：差异只能出现在白名单键或 `{mod-count, recent-apps, trash-full}` 上 |
| 本机白名单键能不能用 | **能用**：`persistent-apps` `persistent-others` `orientation` `tilesize` `magnification` `largesize` `autohide` `mineffect` `minimize-to-application`。**域里没有**：`show-process-indicators`。`autohide-delay` / `autohide-time-modifier` 域里也没有，读回来是 nil → 根本进不了写入集合。→ **有"只写域里已有的键"这一条规则就够了**，不需要另加黑名单 |
| `.app` 的 URL 形式 | 真实域里用的是**带尾斜杠**的目录 URL：`file:///System/Applications/Launchpad.app/`。`URL(fileURLWithPath:).absoluteString` **不带**尾斜杠 → 得自己补上 |
| 用户 App 和启动台的 tile 形状 | 用户 App：`file-type=41`、`dock-extra=true`。启动台：`file-type=169`、`dock-extra=false`、`bundle-identifier=com.apple.launchpad.launcher` |
| 找进程的兜底 | 在非 `.app` 进程（`swift test` 的 xctest runner）里，`NSRunningApplication.runningApplications(withBundleIdentifier:)` 可能找不到 Dock → 用 `pgrep -x Dock` 兜底可行 |

**踩到的两个验证陷阱（写验收脚本时一定要避开）**：

1. **用 `plutil -p` + `diff` 比长数组会错位**：数组元素的行数不一样，后面整片都会错开，冒出**假差异**。要判断"成员 / 顺序变没变"，就把标签序列单独抽出来比；要判断"值变没变"，就用结构化比较（`PlistValue` 相等）。
2. **验收窗口期里别手动改 Dock**：实测有一次跑到一半，Dock 被外部改了（`persistent-others` 从 4 项变成 1 项），"还原后还有差异"报了个假失败。

---

## 实验 5（P3 落地复测，2026-09-18）：重启节流，外加一个能毁掉图形会话的 PID 陷阱

P3 把"切桌面自动应用 + 预应用"接起来以后，用 `DockAcceptanceTests` 来回切了 20 次。第一次跑，每轮约 **1080 ms**，比 P0/P2 实测的 101/125–138 ms 慢了近 10 倍。往下查，挖出两件要命的事。

### 5.1 launchd 的重启节流：间隔不到 1 秒，Dock 要 1 秒才回来

**做法**：连续用 SIGHUP 重启 Dock，只改两次重启之间的间隔，用 `NSRunningApplication`（0.6 ms/次）测"新 PID 出现"花了多久。

| 两次重启的间隔 | Dock 归位耗时 |
| --- | --- |
| 0.3 s | **约 1070 ms** |
| 0.6 s | **约 1066–1159 ms** |
| 1.0 s | **76 ms** |
| 1.5 s | 68 ms |
| 2.0 s | 73–86 ms |
| 3.0 s | 68–74 ms |
| 5.0 s | 83–138 ms |

**结论：阈值在 0.6–1.0 s 之间。** 离上次重启不到约 1 秒就再重启，Dock 要等**约 1.07 s** 才回来；间隔超过 1 秒，只要**约 70 ms**。

- `com.apple.Dock.plist` 里**没有** `ThrottleInterval`，`launchctl print` 也不显示 —— 这是 launchd 的隐式节流，不是 Dock 自己启动慢（不然不会精确到 1.07 s）。
- 1.07 s 这个值非常稳定（1020–1187 ms，20 次），不像负载造成的，更像固定退避。

**对策（已实现）**：`DockReloader` 加了 `minimumSpacing`（默认 1000 ms）。离上次**归位**不满 1 秒，就先睡到满 1 秒再重启。

> 为什么"等一下"一定比"马上重启"好：等的时候 **Dock 还活着、还能用**；马上重启反而让 Dock 消失 1 秒多。
> 等待只是把我们自己的重启往后推，不会拉长用户感觉得到的不可用时间。

**效果（P3 验收实测，来回切 20 次）**：

| | 修复前 | 修复后 |
| --- | --- | --- |
| **Dock 不可用时长** | 约 1030 ms | **45–90 ms**（最坏 90 ms） |
| 一次应用总耗时 | 约 1030 ms | 约 1050 ms（多出来的是**主动等待**，这段时间 Dock 能用） |

所以 `ReloadOutcome` 把两个数分开记：`elapsed` 只算 Dock 真正用不了的时间，`spacingWait` 单独记等了多久（日志里注明"期间 Dock 可用"），免得日志看着吓人。

### 5.2 `NSRunningApplication` 会返回 `processIdentifier == -1`

**怎么发现的**：写探测脚本时，一次重启后打出了 `48049 → 48100 → -1`。`-1` 不是笔误 —— Dock 重启的那个窗口里，`NSRunningApplication.runningApplications(withBundleIdentifier:)` 会返回一个**正在退出**的实例，它的 `processIdentifier` 就是 `-1`。

**为什么致命**：

| 用法 | 语义 | 后果 |
| --- | --- | --- |
| `kill(-1, sig)` | 发给**当前用户的所有进程** | 用户当场丢掉所有 App，可能连整个图形会话都没了 |
| `kill(0, sig)` | 发给**整个进程组** | 同上，范围小一点 |

原来的 `dockPID()` 直接取 `runningApplications(...).first?.processIdentifier`，结果是：

1. `waitForRestart` 看到 `-1 != oldPID`，马上算"成功"，`ReloadOutcome` **谎报 Dock 已经回来了**（其实 Dock 不在）；
2. 兜底路径 `let dyingPID = process.dockPID() ?? oldPID; process.signal(dyingPID, SIGTERM)` 会拿到 `-1` → **`kill(-1, SIGTERM)`**。

第 2 条能毁掉用户整个图形会话。**这不是理论风险**：P3 期间实测复现过 `-1`。

**修复（三道防线，都在 `DockReloader.swift` 里）**：

1. `dockPID()` 只留 `!isTerminated && processIdentifier > 0`；
2. `RealDockProcessControl.signal(_:_:)` **拒绝 `pid <= 0`**，还要用 `proc_name` 确认这个 PID 的进程名真是 `Dock` 才发信号；
3. `DockReloader.waitForRestart` 只认 `pid > 0`。

守这条不变量的测试在 `Tests/MultiDockTests/DockProcessSafetyTests.swift`，全部用**信号 0**（空信号，只查进程在不在，不真投递）来断言 —— 这样哪天闸门被改坏，测试会**失败**，而不是把测试进程自己杀掉。

### 5.3 `pgrep` 一次 110 ms，不能放进轮询热路径

原来 `NSRunningApplication` 查不到时，用 `/usr/bin/pgrep -x Dock` 兜底。实测：

| 查询方式 | 单次耗时 |
| --- | --- |
| `NSRunningApplication.runningApplications(withBundleIdentifier:)` | **0.6–1.4 ms** |
| `/usr/bin/pgrep -x Dock`（子进程） | **109–112 ms** |
| `proc_listpids` + `proc_name`（libproc，直接调） | **0.02 ms** |

判定重启是 15 ms 一轮的轮询，每次花 110 ms，会让"等 Dock 回来"慢一个数量级。现在改成用 `proc_listpids(PROC_ALL_PIDS)` 扫进程表、用 `proc_name` 比名字，**不再起子进程**。`DockProcessSafetyTests` 里有一条测试专门守这个（平均耗时必须 < 20 ms）。

> 注意：这一项**不是** 5.1 那 1 秒的原因。改完以后每轮还是约 1030 ms —— 但这确实是浪费，而且要和 5.1 的修复叠在一起，Dock 不可用时长才降到 45–90 ms。

### 5.4 顺带确认：写入确实生效，还原也干净

| 观测项 | 结果 |
| --- | --- |
| 来回切 20 次 | 全是 `.applied`，`verifyAttempts == 1`，主路径全走 SIGHUP |
| 每次切完的真实域 | `tilesize` / `magnification` 每次都等于目标那份 |
| `DockWatcher` 误判 | **0 次**（我们自己的写入和 Dock 的 GUID 回写，都没被当成用户手动改的） |
| 两个桌面配置一样时 | `.skippedIdentical`，`reload == nil`，`mod-count` 不变 → 确实没重启 Dock |
| 还原以后 | 差异键 **`[]`**（连 `mod-count` 都没差），图标顺序逐项一致，键集合一致（34 键） |

---

## 实验 6：节流窗口要看「Dock 进程年龄」，不能靠我们自己记（2026-09-18，P4 验收时意外挖出）

### 6.1 现象

第一次跑 P4 验收时，**P3 那条来回切 20 次的用例，第一轮报 Dock 不可用 1030 ms**：

```
[P3 验收] Dock 不可用时长（ms）：[1030, 52, 50, 55, 46, 50, 48, 70, 60, 43, ...]  最坏 1030 ms
```

只有**第一轮**是 1030 ms，后面 19 轮都是 43–70 ms。P3 的代码没动过，它上一次（第 6 次会话）跑时 20 轮全是 45–90 ms。

### 6.2 根因

`DockReloader` 把"上次重启归位"的时刻记在**自己的成员变量** `lastRestartAt` 里，重启前先睡到
`lastRestartAt + minimumSpacing`。这套逻辑有两个盲区：

1. **launchd 的节流按服务算，不按进程算，更不按我们的对象算。**
   在同一个测试进程里，前一条用例（P4 的还原）刚重启完 Dock；紧接着 P3 用例
   **新建了一个 `DockReloader`** —— 它的 `lastRestartAt` 是 `nil`，以为自己"从没重启过"，
   直接发 SIGHUP，结果吃满整段节流：**1030 ms**。
2. **别人重启 Dock，我们也看不见**：用户 `killall Dock`、别的 Dock 定制 App，甚至**我们自己的
   `DockPresenceMonitor` 拉回**（`kickstart` 不经过 `DockReloader`）都会重启 Dock，
   `lastRestartAt` 却一无所知。下一次切桌面，Dock 就会消失一秒多。

### 6.3 判据改成「进程年龄」

节流窗口取决于 **Dock 进程年龄** —— Dock 刚起来不到 1 秒，launchd 就不肯马上再拉一次。
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
| `proc_pidinfo(PROC_PIDTBSDINFO)` 返回的字节数 | **136 = `MemoryLayout<proc_bsdinfo>.size`** ✅ |
| Dock 的 `pbi_start_tvsec/tvusec` | 读得到，算出来的年龄和实际相符（实测 66.91 s） |
| 拿不到时（替身进程 / 结构体布局变了） | 返回 `nil` → `DockReloader` **退回用内存里的 `lastRestartAt`**，行为和改之前一样 |

### 6.4 结果

| 观测项 | 改之前 | 改之后 |
| --- | --- | --- |
| P3 验收第一轮 Dock 不可用 | **1030 ms** | **45 ms** |
| P3 验收 20 轮 Dock 不可用 | `[1030, 52, 50, …]` | `[45, 54, 55, 58, 49, 47, 48, 47, 52, 55, 50, 52, 50, 84, 51, 50, 48, 49, 46, 49]`，最坏 **84 ms** |
| 还原路径上报的 `spacingWait` | 新建的 reloader 一律报 0（明明等了却不说） | 照实上报（比如"先等了 925 ms 错开节流，期间 Dock 可用"） |

> **顺带的好处**：`DockPresenceMonitor` 的 `kickstart` 和"用户自己 `killall Dock`"这两种重启，
> 现在也能正确错开了 —— 改之前，紧跟着的那次切桌面会让 Dock 消失一秒多。

> ⚠️ **别把这条改回靠内存记**：内存里记的是**猜的**（外部一重启就不准了），进程年龄才是**事实**。
> 单元测试用"会报告启动时刻的替身"把它钉住了（`DockReloaderTests` 里的
> `testFreshReloaderStillWaitsWhenTheDockIsYoung` / `testProcessAgeWinsOverStaleInMemoryWindow`）。

### 6.5 顺带确认：`kill -9` 掉 Dock 后多久能恢复

| 观测项 | 结果 |
| --- | --- |
| `SIGKILL` 掉 Dock 后归位 | **1072 ms**（`KeepAlive` 让 launchd 把它拉起来，但先要吃一次隐式节流，所以不是 100 ms 量级） |
| 判据 | 3 秒内必须出现**新的正数 PID**（`testKillingDockRecoversWithinThreeSeconds`） |
| 恢复以后 | 白名单键和键集合都和杀之前一致 |

---

## 实验 7：切桌面能不能有「左右滑动」动画（2026-09-18，结论：**做不到，别再试**）

**起因**：用户要求"点菜单栏图标切桌面时要有左右滑动的动画，当前是硬切"。

**先说结论**：在**零权限 + 无痕**这两条硬约束下，**没有能用的入口**。程序化切空间是瞬间完成的；
真正的过渡动画由 WindowServer 内部的 `Transition*Metal` 类驱动，只为**用户手势**服务。
下面是四条证据，外加一条**不要走的路**。

### 7.1 确认现象：程序化切空间确实是硬切

`CGSManagedDisplaySetCurrentSpace` 从调用到活动空间真正变掉：

| 轮次 | 耗时 |
| --- | --- |
| 1 | **6 ms** |
| 2 | 0 ms |
| 3 | 0 ms |

（轮询间隔 500 µs，3 个用户桌面，显示标识 `AB24BB32-…`）
**0–6 ms 里根本塞不进一段过渡动画** —— 用户没看错。

### 7.2 `SLSManagedDisplaySetIsAnimating` 不是动画开关，是个粘住的状态位

这个符号的名字最像"打开动画"，但它不是：

| 观测项 | 结果 |
| --- | --- |
| `SLSManagedDisplayIsAnimating`（调用前） | `false` |
| `SLSManagedDisplaySetIsAnimating(cid, display, true)` | **返回 `-785121165`**（同一次运行里调了 8 次，值完全一样；换一次运行就变成 `-2752379`） |
| 置位后 600 ms 内采样 | **101/101 次仍是 `true`**，不会自己复位 |
| 复位调用 | 生效，读回来是 `false` |
| 对 WindowServer / Dock 的 CPU 占用 | 测不出影响 |
| 对切空间耗时 | 测不出影响 |

> ⚠️ **返回值不能当成功标志。** 同一个调用，两次运行给出**两个不同的固定值**（`-785121165` / `-2752379`），
> 这是 **void ABI 留在寄存器里的残值**，不是 `CGError`。上一轮我把 `-2752379` 记成"返回成功"，**记错了**，
> 这里改正。这个调用生没生效，只能看**读回来的值**，不能看返回值。

字符串表里还有一句 `"The display has a nil transition type."` —— 说明本机上"显示 → 过渡类型"这个映射
是 **nil**。没有过渡类型就没有过渡对象，那个 `IsAnimating` 位只是个孤零零的标志位。

### 7.3 会话级开关确实有，但**写进去读不回来** → 按无痕原则不能碰

符号表里确实有一整套"会话切换过渡类型"：

| 符号 | 值 / 含义 |
| --- | --- |
| `SLSSetSessionSwitchCubeAnimation` | 会话级设置函数（**只有 set，没有 get**） |
| `kSLSSessionSwitchTransitionTypeCube` | `"cube"` |
| `kSLSSessionSwitchTransitionTypeKey` | `"transition"`（现在的左右滑动） |
| `kSLSSessionSwitchTransitionTypeNone` | `"none"` |
| `kSLSSessionSwitchTransitionTypeUnset` | `""` |

看起来正好对症 —— 但是：

1. **没有 getter**（`SLSGetSessionSwitchCubeAnimation` / `SLSCopySessionSwitchTransitionType` 都不存在）。
2. **偏好域里也没有它**：`CGSessionCopyCurrentDictionary()` 只有 11 个键（全是审计 / 用户 / 登录状态），
   没有过渡类型；`defaults read com.apple.spaces` 和 `com.apple.dock` 里也找不到对应的键。
3. 把 SkyLight `__TEXT`（5,037,056 字节）里所有可打印字符串扫了一遍，
   带 `SwitchCube` / `SessionSwitch` 的**只有函数名 `SetSessionSwitchCubeAnimation` 本身**，没有任何偏好键。

→ 它是 **WindowServer 进程内存里的会话级值**。我们**改了就还原不回去**（读不到原值），
**直接违反"绝不永久改变用户状态"的无痕原则**，所以就算它能生效也不能用。

### 7.4 ⚠️ 不要走的路：`SLSWillSwitchSpaces` 会段错误

合理的猜测是："Dock 做动画切换之前，会先调 `SLSWillSwitchSpaces` 通知 WindowServer，再提交"。
按 `(cid, CFArray<NSNumber>)` 去试：

```
SkyLight  0x…  array_call_as_integer_list + 70
SkyLight  0x…  SLSWindowServerClientWillSwitchSpaces + 139
→ SIGSEGV
```

**签名猜错，进程直接死在 SkyLight 里面。** `SLSBridgedWillSwitchSpacesOperation` 只有
`initWithSpaces:`，看不出到底带不带 `cid`，也看不出数组元素是 `NSNumber` 还是别的结构体。

> **到此为止**：接着猜签名去戳 WindowServer，风险是**把用户的图形会话搞崩**。
> 为了一个动画冒这个险，完全不划算。**这条线到这里停，别再往前试了。**

### 7.5 真正的动画在哪

符号表里，过渡的实现是一整套 Metal 类，**全在 WindowServer 内部**：

`TransitionSlideMetal`、`TransitionCubeMetal`、`TransitionFlipMetal`、`TransitionBlendMetal`、
`TransitionShrinkMetal`、`TransitionSpiralMetal`、`TransitionDropMetal`、`TransitionRadialBlurMetal`，
配套的有 `new_transition(CGXConnection*, CGSTransitionStyle, CGSTransitionFlags, CGXWindow*, CGXSession*, const float*, Transition**)`、
`CGXInvokeTransition`、`CGXMarkTransitionStart/End`，以及 `CGSTransitionStyle` / `CGSTransitionFlags` 两个枚举。

**驱动它们的是 Dock**（Mission Control 归 Dock 管），入口是**用户手势**（触控板横扫 / `Ctrl+←`）。
没有哪个地方对外开放"带动画切到某个空间"。

### 7.6 合成按键这条路也走不通（补测）

绕路的想法是"模拟 `Ctrl+←`，让 Dock 自己带动画切过去"。**本机上行不通**：

| 观测项 | 结果 |
| --- | --- |
| `CGPreflightPostEventAccess()` | **`true`**（看着像有权限） |
| 热键 `Ctrl+←` / `Ctrl+→` 开没开（`com.apple.symbolichotkeys` 79/80/81） | `enabled = 1` |
| 试过的 tap | `cghidEventTap` / `cgSessionEventTap` / `cgAnnotatedSessionEventTap` |
| 试过的 `CGEventSource` 状态 | `.hidSystemState` / `.combinedSessionState` / `.privateState` |
| **阳性对照**：合成 `Cmd+Tab`，看前台 App 变没变 | **没变** |
| 结论 | 本机拦掉了合成事件，**不是** tap 或 state 选错了 |

> **关键在阳性对照**：合成事件里 `Cmd+Tab` 最稳，它都没反应，说明问题出在"事件投递被拦"这一层，
> 和我们的参数无关。以后再碰到"合成事件没反应"，**先跑阳性对照**，别在参数上来回试。

### 7.7 决定

- **不做真动画。** 零权限 + 无痕下没有安全入口，硬做就得动 WindowServer 的内部状态。
- **不改需求，也不做假动画**：不自己画一个跨屏浮层假装在滑 —— 那既不是真的切桌面动画，
  还得处理多显示器 / 全屏空间下的一堆边界情况，成本远高于收益。
- **替代方案（确认可行，已经实现）**：`⇧+左键` 切到上一个桌面，下拉菜单里也给一个等价入口，
  这样"往回切"至少不用绕进菜单。见 `docs/PLAN.md` §3.7。
- 以后 macOS 要是开放了带过渡的切空间 API，再回来做；`docs/PLAN.md` §5 的风险表里留了这一条。

---

## 实验 8：其他项（文件夹 / 堆栈）App 能不能自己造（2026-09-18，结论：**不能，别再试**）

**为什么做**：计划 §3.6 要求编辑条支持「从 Finder 拖 .app / **文件夹** / 文件进来」。
可 `persistent-others`（文件夹 / 堆栈，本机只有「下载」）之前在本 App 里**根本没有编辑入口**：
`DockStripEditor` 只画 `persistent-apps`，拖文件夹进来会悄悄失败（`tile(forAppAt:)` 只认 `.app`）。
要补这个缺口，第一步得确认：「自己拼一条目录条目」，Dock 收不收。

### 8.1 实验 1：最小目录 tile + 普通文件 tile → **Dock 崩溃循环**

写进域（`defaults write -array-add`）再 `kill -HUP` 之后：

```
persistent-others 条目数：3（原「下载」+ 我造的目录 tile + 我造的文件 tile）
Dock：进程消失，launchctl 显示 com.apple.Dock.agent 退出码 -6，无 PID
崩溃报告：Dock-2026-09-18-0753*.ips / 0754*.ips 共 7 份，
         termination = {"namespace":"SIGNAL","indicator":"Abort trap: 6"}，
         exception = EXC_CRASH / SIGABRT，asi = {"libsystem_c.dylib": ["abort() called"]}
```

- 两条自造的 tile 在域里**原封不动**（Dock 既没认领，也没清掉），但 Dock 反复 abort，
  launchd 在崩溃循环里一遍遍把它拉起来 —— 换句话说，**这个形状能让用户没有 Dock 可用**。
- 恢复办法：`defaults import com.apple.dock <备份>` + `launchctl kickstart gui/$UID/com.apple.Dock.agent`。
  （`defaults import` 之后，launchd 要过一会儿才拉回来，别急着判失败。）

光这一条就够定案了：**形状不全的目录条目是危险写入**。

### 8.2 实验 2 / 3 / 4：字段补全也好，自己生成 `book` 也好，Dock **都不认**

| 实验 | 写入形状 | Dock 存活 | Dock 补 `GUID`? |
| --- | --- | --- | --- |
| 2 | 目录 tile + `arrangement`/`displayas`/`showas`/`preferreditemsize`/`is-beta`，路径 `/tmp`（符号链接） | ✅ 活着 | ❌ 4 秒后还没有 |
| 3 | 同上，但换成真实的、非符号链接的目录 `/Users/apple/Documents/Swift` | ✅ 活着 | ❌ 8 秒后还没有 `GUID` / `book` |
| 4 | 再加上**自己生成的 `book`**（`URL.bookmarkData()`，908 字节，魔数 `book` + 长度头，和真实 656 字节的「下载」同一类） | ✅ 活着 | ❌ 8 秒后还没有 |

对照组（P2 实测，已经进了验收）：**App 的 file-tile 200 ms 内就会被 Dock 补上 `GUID`** ——
所以"没有 GUID"就说明"Dock 没读进去"，不是"看得太早"。

`book` 是 Dock 自己算出来的文件夹书签（本机「下载」656 字节，前 12 字节是 `62 6f 6f 6b 90 02 00 00 00 00 04 10`），
我们自己生成的同类数据替代不了它。

### 8.3 实验 5：`persistent-others = []`（也就是「移除最后一项」的形状）**没有害处**

```
写入空数组 → kill -HUP → 0.6 秒后新的 Dock PID 出现
```

所以「移除其他项」这条路不用设限（空数组是 Dock 自己也会写的正常状态）。

### 8.4 决定（已经写进 `docs/PLAN.md` §3.6 / §3.7 和代码）

1. **不提供"新建文件夹 / 普通文件条目"**。Dock 不认自造的目录条目（实验 2–4）→ 做出来就是**假开关**；
   形状不对还会让 Dock 进崩溃循环（实验 1）→ 更是**危险写入**。
2. **把替代做法写进 UI**：让用户在访达里自己把文件夹拖到 Dock 上 —— Dock 会写出完整条目（带 `book`），
   随后 `DockWatcher` 把它存回当前桌面的配置，之后就能在编辑器里排序 / 移除。
   用户往编辑器里拖文件夹时，**明确拒绝，并给出这段说明**（`DockItemRejection.message`），不让它悄悄失败。
3. **其他项只"搬"不"造"**：编辑器只做显示 / 排序 / 移除，写回去的就是 Dock 自己写的
   dict（`GUID` / `book` 原样保留）。真机验收 `DockAcceptanceTests.testOtherItemsRemovalAndReapplyKeepsDockHealthy`
   钉死两件事：移除后 Dock 还活着；`GUID`/`book` 一个都不丢。
4. **`normalizedOthers` 只去重，不插固定项**（只有 `persistent-apps` 才要保证启动台排第一）。
5. 回归守卫：`DockStripRulesTests.testDockItemRejectionClosesTheFolderAndFilePaths`
   断言这条路是**关着的**，防止以后有人"顺手"把它打开。

### 8.5 顺带观测：反复 kill / HUP Dock，launchd 会进入**递增退避**

实验期间（1 次崩溃循环 + 多次 HUP + 多次 kickstart）看到：

```
launchctl print gui/$UID/com.apple.Dock.agent
  state = spawn scheduled      # launchd 已排好重启，但在等退避窗口
  job state = exited
  runs = 346                   # 含崩溃循环里的每一次 abort
```

表现是 **Dock 几十秒都不回来**（正常 SIGHUP 只要约 100 ms），
`DockReloader` 的 kickstart 兜底也会被这段退避挡住。
**结论**：写验收脚本别连着杀 Dock 几十次；真机验收最好等 Dock 稳定跑几分钟以后再做。
这条只影响验收节奏，不影响 App 逻辑（App 每切一次只重启一次）。

---

## 实验 9：切一次桌面为什么"黑屏几分钟"（2026-09-19，结论：**是我们自己在给 launchd 的退避续期**）

用户报告：从桌面 1 切到桌面 2 之后，没有 Dock、没有壁纸，触控板切桌面的手势也不灵了，持续好几分钟。
先定性：**壁纸和空间手势都是 Dock 进程实现的**，所以"三样一起没了"不是系统卡死，而是 **Dock 进程很长时间不在**。

### 9.1 证据一：每次切换，Dock 缺席被记成 60–126 秒

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

同一条路径，一会儿 55 ms，一会儿 125 s → 不是"这台机器慢"，是**中间有东西反复打断**。
排除崩溃：今天的 Dock 崩溃报告是 **0 份**（`DiagnosticReports` 里只有 2026-09-18 实验 8 那批，已经挪进 `Retired/`）。

### 9.2 证据二：整个 App 被冻住了，不只是在等

存活监视器每 500 ms 跑一轮，缺席到阈值后每 4 轮（2 s）催一次，所以缺席 2 分钟**应该留下约 60 行日志**。
实测每次缺席只有**一行**，而且永远是「连续 **2** 次」：

```
01:29:56.730 切换到 计划 任务            ← SIGHUP，Dock 消失
             ……55 秒完全空白：监视器、桌面轮询、toast、回存全部停摆……
01:30:51.829 检测到 Dock 不在（连续 2 次），已用 launchctl 拉回
01:31:56.183 Dock 应用成功：kickstart 成功 … Dock 不可用 119438 ms
```

主线程被同步卡住了 —— 整个代码库里只有一处这样的调用：`RealDockProcessControl.kickstart()` 里的
`process.waitUntilExit()`。它返回的时刻正好是空白结束的时刻（两次分别卡了约 54 s 和 64 s，
00:56 那次是 59 s）。**launchd 在退避时，`launchctl kickstart` 会一直卡着，直到它真能把服务拉起来。**

### 9.3 根因：两条会自我放大的链叠在了一起

1. `DockReloader` 的超时是 **5 s**，而 launchd 的退避是**几十秒**级别。于是一次正常的慢拉起被判成
   "SIGHUP 失败"，升级到 `SIGTERM` + `launchctl kickstart -k`。
2. `DockPresenceMonitor` 发现缺席 **1 s** 就出手，之后**每 2 s** 再补一发 `kickstart -k`。

`-k` 的意思是"先杀掉现有的再拉起"。launchd 刚把 Dock 拉回来，我们又杀一次，还**重置了 launchd 的退避计时**
（8.5 早就写过：静静等着比反复 `kickstart` 更快）。就这样，1 秒的节流被滚成了两分钟的 Dock 死亡。
触发条件只是"某一次恢复稍慢了一点"（本机 `kill -9` 后归位要 1072 ms，正常 SIGHUP 只要 100 ms），
一旦越过 5 s / 1 s 这两条线，它就会自己转下去。

### 9.4 顺带挖出第二个 bug：Dock 不在时读偏好域，把配置写坏了

```
01:30:51.909 [Dock 正 dead] 检测到真实 Dock 上的手动改动：3 个图标、0 个其他项
01:30:51.923 [Dock 正 dead] 密码 邮件：回存手动改动：3 个图标
```

真实 Dock 是 **15 个图标 + 1 个其他项**。Dock 进程不在的时候，偏好域读回来是**残缺的**，
`DockWatcher` 却把它当成"用户手动改的"存了回去 —— `config.json` 里 `密码 邮件` 和 `计划 任务`
的 override 已经被写成了 3 个图标（`LLM` 那条没问题）。

### 9.5 决定（已经写进代码和 `docs/PLAN.md` §3.4 / §3.8 / §3.9）

| 改什么 | 从 | 到 | 为什么 |
| --- | --- | --- | --- |
| `kickstart()` | `waitUntilExit()` 同步等 | 发完就走，子进程交给 `LaunchctlParking` 持有，直到它退出 | 不再冻住主线程；返回值仍然只表示"命令发出去了" |
| 同一发 launchctl | 可以叠加 | **上一发没结束就不再补** | 重复 `-k` 正是退避的成因 |
| `DockReloader.timeout` | 5 s | **30 s** | 必须明显长过 launchd 的退避时长，不然慢恢复会被误判成失败 |
| 监视器 `missThreshold` | 2 轮 = 1 s | 8 轮 = **4 s** | 让 launchd 自己先拉，别抢 |
| 监视器 `kickstartEvery` | 4 轮 = 2 s | 60 轮 = **30 s** | 隔久一点才催，和 8.5"静等更快"一致 |
| `persistentFailureThreshold` | 12 轮 = 6 s | 120 轮 = **60 s** | 在本机，缺席几十秒说明"正在恢复"，这时候报警等于误报故障 |
| `DockWatcher` | 随时采样 | **Dock 进程不在就不采样**；回来后的第一次读只用来对齐基线 | 见 9.4 |

回归：`DockPresenceMonitorTests` 两条钉死新默认值（缺席 3.5 s 不出手 / 满 4 s 才补一发 / 之后 30 s 内不催 /
59.5 s 不报警）、`DockWatcherTests` 两条（缺席期间不采样、回来后先对齐基线再照常回存）、
`DockReloaderTests` 一条（`isDockAlive` 跟着进程控制走，不认 -1）。**295 个测试全绿，零警告。**

**还没实测的部分**：这次修复要在真机上反复切桌面才能验证（本会话没再动用户的 Dock ——
一动就会连带触发他的逐桌面应用）。核对办法是现成的：日志里 `Dock 不可用` 应该稳定回到 100 ms 量级，
而且不再出现「连续 2 次…已用 launchctl 拉回」。

---

## 实验 10：每次右键退出都"卡住几分钟"（2026-09-19，结论：**实验 9 那条链在退出路径上照样成立，而且我们的"上限"从一开始就是假的**）

用户报告：菜单栏右键 → 退出，**每一次**都会"没有 Dock、桌面背景不显示、触控板也不能用"，
持续几分钟。这和实验 9 的故障一模一样 —— 因为**就是同一个故障**，只是触发点从"切桌面"换成了"退出"。

### 10.1 先确认：用户跑的是修复前的二进制

- `build/MultiDock.app/Contents/MacOS/MultiDock` 的时间戳是 **09-19 01:07**；
  实验 9 的修复 commit `47defb5` 是 **02:11** 提交的。也就是说，用户退出时跑的代码里，
  `kickstart()` 还是同步 `waitUntilExit()`，监视器还是 1 s 出手、每 2 s 补一发 `-k`，
  重载超时还是 5 s。**实验 9 的修复从没在真机上跑过。**
- 日志里能找到的**两次真实退出**：`退出还原流程结束，用时 54.05s` 和 `用时 53.12s`，
  前面各有一次 **100–122 秒**的 Dock 缺席。那条
  `检测到 Dock 不在（连续 2 次），已用 launchctl 拉回` 的打印时刻，正好是卡住的
  `launchctl kickstart -k` 返回的时刻（和实验 9.2 的判据完全一样）。
- ⚠️ 这两行现在已经**不在** `multidock.log` 里了 —— 见 10.5：单测往那个 512 KB 的环形文件里灌满了假记录。
  数字是本会话早些时候从文件里读到的原始值。

### 10.2 退出路径上的三个放大器

| 放大器 | 位置 | 后果 |
| --- | --- | --- |
| 退出还原走的是**完整的重载 ladder** | `restoreToBaseline()` → `apply` → `reload()`：发信号 → 等归位（30 s）→ SIGTERM → `kickstart` → 再等 30 s | 明明"我们马上就退出了"，一次写操作却等满整条链 = 53–54 s |
| 存活监视器和我们自己的退出重载抢节奏 | 500 ms 一轮，看到 Dock 不在就补 `kickstart` | launchd 刚拉回来又被杀 → 退避续期 |
| `prepareForTermination(settleLimit:)` 的"2 秒上限"**不起作用** | 见 10.3 | 上限写在参数里，却管不住任何东西 |

### 10.3 核心发现：用 `withTaskGroup` 赛跑做不出「带上限的等待」

两处"有上限地等"（`DockController.waitForIdle(upTo:)`、`AppState.settle(_:within:)`）都是这么写的：

```swift
await withTaskGroup(of: Bool.self) { group in
    group.addTask { await task.value; return true }      // ← 不可取消
    group.addTask { try? await Task.sleep(for: limit); return false }
    let settled = await group.next() ?? false
    group.cancelAll()                                     // ← 对第一种子任务毫无作用
    return settled
}
```

**闭包返回时，任务组要等所有子任务收尾。** 而 `await task.value` 这种子任务没有取消处理
（`Task<Void, Never>`，`cancelAll()` 只是把 `isCancelled` 置位），所以它会一直等到那次应用跑完才结束。
结果就是：

- `group.next()` 确实 20 ms 就返回了 `false` —— **返回值看着没错**；
- 但整个 `withTaskGroup` 闭包要到 **625 ms** 才返回（正好是替身那条降级链的总时长）。

实测数字（让降级链一定慢：`reloadStrategy = .sigterm`，上限给 20 ms）：

| 位置 | 上限 | 任务组写法的实际墙钟 | 轮询写法 |
| --- | --- | --- | --- |
| `DockController.waitForIdle(upTo:)` | 20 ms | **625 ms**（正好是降级链的总时长） | 在 200 ms 的断言内通过 |
| `AppState.settleSelfHeal(within:)` | 20 ms | **224.7 ms**（回归用例打出来的） | 在 200 ms 的断言内通过 |

**"每次退出都卡住"在代码里查不出来，原因就在这**：`settleLimit` 传的是 2 秒，
读代码的人看到"有上限"，测试也只断言 Bool —— 只有墙钟会露馅。放到 launchd 退避的尺度上，
被放大的是**几十秒**，因为降级链里那一发同步 `kickstart` 自己就要卡几十秒。

**修法**：不用任务组，改成轮询一个"活干完了"的可观察标志。

```swift
func waitForIdle(upTo limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while drainTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return drainTask == nil
}
```

`AppState` 那边也要一个 `selfHealFinished` 标志（自愈任务跑完就置位），道理一样：
`performSelfHeal` 是**直接 `await dockController.apply(...)`**，不走 `drainTask`，
所以 `waitForIdle` 替它看不了进度。

**回归守卫怎么写**（关键）：必须断言**墙钟**，光断言 Bool 不够。
`testWaitForIdleReportsTimeout` 和 `testPrepareForTerminationBoundsTheSelfHealWait`
都带了 `XCTAssertLessThan(elapsed, .milliseconds(200))`。把 `settleSelfHeal` 临时改回任务组写法，
后者老老实实失败了：`("0.224659361 seconds") is not less than ("0.2 seconds")`，
可同一条用例里的 `XCTAssertFalse(settled)` **照样通过** —— 这个 bug 就藏得这么深。

### 10.4 决定（已经写进代码和 `docs/PLAN.md` §3.3 / §3.9）

| 改什么 | 从 | 到 | 为什么 |
| --- | --- | --- | --- |
| 退出时的重载 | 复用 `reload()`（等归位 30 s → 升级 → kickstart → 再等） | **`reloadForQuit()`**：发一发信号，最多看 1.5 s，**不等节流、不升级、不 `kickstart`** | 我们马上就退出了：等它归位，换不来任何**能据此行动**的信息（校验读的是偏好域，不是 Dock 界面），而升级正是把 100 ms 滚成两分钟的那一步 |
| 退出时的写入 | 走 `apply` 正常路径（对不上就重试一次） | **`apply(..., forQuit: true)`**：写一次 + 发一发信号 + 校验一次，**不重试** | 重试 = 再发一发信号 = 再吃一次退避 |
| 还没开始的待办 | 一起等完 | **`dropPendingRequests()` 直接丢掉** | 它的目标马上会被"还原到基准"取代，等它没意义 |
| 退出前的等待 | 两个假的"有上限" | **轮询标志** + 真上限（默认 2 s，可注入） | 见 10.3 |
| 存活监视器 | 无条件轮询 | **`isReloading` 闸门**：我们自己正在重载 Dock 时不采样 | 我们自己的重启不是故障 |
| 等不到干净收尾时 | 直接清标记 | **`!settled` → `keepMarkerAndFinish`**（留下欠账，下次启动由自愈去看真实域） | 那次还在飞的写入，可能落在还原**之后** |

**"不等归位为什么安全"**（这段论证要留在文档里，不然以后会有人把 ladder 加回去）：

1. 偏好是**原子地**写进 `com.apple.dock` 域的，我们退出以后它还在；
2. Dock 每次启动都会重读这个域 —— launchd 把它拉回来的那一刻，读到的就是基准；
3. "升级也不管用"这种情况，唯一能纠正它的是**下次启动的自检**，而自检不管这次等了多久。
   所以"多等 30 秒"换来的只是一条我们没法补救的日志。

### 10.5 顺带挖出第三个问题：单测往用户的诊断日志里灌满了假记录

`AppState` 里的 `private let fileLog = FileLogSink()` 用的是默认路径
（`~/Library/Application Support/MultiDock/multidock.log`），**测试没有注入点**。
后果（实测）：文件里 02:37 以后的 3 000 多行**全是**单测留下的（假 PID `100 → 1001`、假的
「开始退出还原…」），实验 9 引用的真实证据，以及那两次 53–54 s 的退出记录，
都被 512 KB 的环形截断挤掉了。

这一下直接废了 A6 的核对手段 —— 用户要看的就是这份日志（没有屏幕录制权限，沙箱里也读不到 `log show`）。
修法：把 `FileLogSink` 改成 `AppState.init` 的注入参数，测试一律走 `makeTestFileLog()`（临时目录）。
验证：改完跑一遍全量 `swift test`，用户那份日志的行数 **3060 → 3060**（一行没变）。

### 10.6 验收

- `swift build -c release --disable-sandbox` → **零警告**；`swift test --disable-sandbox` →
  **308 个测试全绿**（7 个真实 Dock 验收默认跳过），这次新增 +13。
- 新增：`DockReloaderTests` 4 条（`reloadForQuit` 只发一发 / 不升级且墙钟 < 1 s / 不管 `minimumSpacing` /
  Dock 不在时一发都不发）、`DockControllerTests` 4 条（退出路径不重试、不升级 / 带回收场方式 /
  `waitForIdle` 的上限是真的 / `dropPendingRequests`）、`DockPresenceMonitorTests` 2 条（`isReloading` 闸门）、
  `StartupSelfHealTests` 3 条（退出还原只写一次并读回基准 / `!settled` 时照实上报 / 自愈等待的上限是真的）。
- ⚠️ **真机复验还没做**（本会话没再动用户的 Dock）。核对口径见 AGENTS.md §6.3 A6/A7。
  注意：**先把被测试灌脏的那份日志挪走**，不然核对的就是假记录。

---

## 对 `docs/PLAN.md` 的修订清单

| 位置 | 原内容 | 改成 |
| --- | --- | --- |
| §1 环境事实表 | `ManagedSpaceUUID` | `uuid`（另外 `Current Space` 可以直接拿到当前空间） |
| §3.1 | 通知为主 + 1 s 轮询兜底 | **轮询为主（300 ms）+ 通知为辅**；预应用升为必需 |
| §3.5 | A/B 可能零闪烁；C 闪 0.3–1 s | A 完全无效；B 其实是重启，但只有 ~100 ms 不可用；**主路径 = B**，C 兜底（~395 ms） |
| §3.6 | 合成 tile 用 `dock-extra:0` | 用户 App 用 `true`、启动台用 `false`（照真实域）；`_CFURLString` 必须带尾斜杠 |
| §4 P0 行 | 三个实验并列 | 已完成，结论见本文 |
| §4 P2 行 | 待做 | ✅ 已完成（见本文实验 4 和 AGENTS.md §8 第 5 次记录） |
| §4 P3 行 | 待做 | ✅ 已完成（见本文实验 5 和 AGENTS.md §8 第 6 次记录） |
| §3.5 | SIGHUP 约 101 ms 不可用 | 补上**重启节流**：离上次重启不到约 1 s 就再重启，要**约 1070 ms**；`DockReloader.minimumSpacing` 把它错开，实测 Dock 不可用时长压回 **45–90 ms** |
| §3.4 第 8 条 | "先 apply 再切空间" | 措辞改成"**发起**应用和切空间在同一拍，不等轮询"。切空间之前完成重启，物理上做不到（重启 101 ms > 切空间 0–6 ms），见 PLAN §3.4 的 P3 实现记录 |
| §6 | 桌面"位置"指什么待确认 | ✅ 已确认：Dock 的屏幕位置 + 大小（2026-09-18） |
| §3.5 / §3.9 | 靠 `DockReloader.lastRestartAt`（内存里记的）错开节流窗口 | 改成按 **Dock 进程年龄**（`proc_pidinfo(PROC_PIDTBSDINFO)`）推算，拿不到年龄才退回内存记录。理由：launchd 的节流**按服务**算，别人重启 Dock 我们看不见。见本文实验 6 |
| §4 P4 行 | 待做 | ✅ 已完成（见本文实验 6 和 AGENTS.md §8 第 7 次记录）。**只有第 ③ 条"注销 / 重启后 Dock 为 baseline"没实测**（得真注销一次） |
| §3.9 | "必要时还原基准"没说清什么时候 | 补上：自愈**在启动后异步跑**，不挡启动；欠账跨会话继承（`needsSelfHeal`）；还原失败要保留标记，并标 `pid = 0` |
| §3.9 | 登录项退回到 `~/Library/LaunchAgents/local.multidock.plist` | 实际文件名是 `local.multidock.loginitem.plist`，而且**故意不设 `KeepAlive`**（登录启动项不是守护进程） |
| §3.1 / §3.7 | 菜单栏左键 = 切到下一个桌面 | 补上 **`⇧+左键` = 切到上一个桌面**（下拉菜单里同时给「上一个桌面」项 + 等价提示），左键行为仍可改成"打开菜单"。见本文实验 7.7 |
| §3.1 / §5 | （无）切桌面动画 | **加一条明确的不做项**：程序化切空间是硬切（0–6 ms），SkyLight 没给带过渡的入口；会话级开关写进去读不回来，违反无痕原则；`SLSWillSwitchSpaces` 签名未知，试错会段错误。**结论见本文实验 7** |
| §3.6 | 拖入支持「.app / 文件夹 / 文件」 | 改成**只收 `.app`**：文件夹和普通文件**明确拒绝，并给出替代做法**（在访达里自己拖到 Dock 上，由 `DockWatcher` 存回来）。理由见本文**实验 8**：自造的目录条目 Dock 不认（不补 `GUID`），形状不全时还会让 Dock SIGABRT 进崩溃循环 |
| §3.6 / §3.7 | 其他项（`persistent-others`）没有任何编辑入口 | 编辑条加一行「其他项」：**只搬不造**（显示 / 排序 / 移除），写回去的就是 Dock 自己的 dict（`GUID` / `book` 原样保留）。真机验收 `testOtherItemsRemovalAndReapplyKeepsDockHealthy` |
| §3.4 第 6 条 | 应用摘要"调试面板可见" | ✅ 调试面板加了「最近一次应用」：结果摘要 + 内容指纹 + 写入时刻 +「本次运行改过 Dock」+ 回存闸门 |
| §3.7 | 桌面列表：显示器名 + 名字 + 当前绑定状态 | ✅ 列表**按显示器分组**（`ScreenNaming`），详情里多一行显示器名；对不上时照实写"未识别显示器（UUID 前 8 位…）"，**不退回成一台错的屏** |
| §3.4 / §3.9 | 重载超时 5 s；存活监视器 1 s 出手、每 2 s 催一发 `kickstart -k`；`kickstart` 同步等 launchctl 退出 | 全改掉：超时 **30 s**、**4 s** 才出手、每 **30 s** 才催一发、报警阈值 **60 s**、`kickstart` **不阻塞，也不许叠加**。理由：这几条叠在一起，会把一次正常的慢恢复自我放大成 60–126 秒的 Dock 死亡，而同步的 `launchctl` 还会冻住主线程。见本文**实验 9** |
| §3.8 | Watcher 只在"还原期间"停 | 再加一条边界：**Dock 进程不在时一律不采样**，回来后的第一次读只用来对齐基线。缺席期间域里是残缺内容（实测 3 个图标，真实是 15 个），照抄会写坏桌面配置。见本文 9.4 |
| §3.3 正常退出流程 | "等待重载完成（Dock 归位确认，最长 5 s）" | 改成**退出专用的窄路径**：发一发信号，最多看 1.5 s，不等节流、不升级、不 `kickstart`；写入不重试；待办直接丢；等待带**真**上限（轮询标志，默认 2 s）。理由：那个 5 s 上限实际上是"等完整条 ladder"，launchd 退避期间会拖到 53–54 秒。见本文**实验 10** |
| §3.9 P4 实现记录 第 4 条 | "等自愈跑完 + `waitForIdle()`（无上限）" | 两处等待都改成**有上限，而且上限真的管用**；等不到干净收尾时**保留会话标记**（`!settled` → `keepMarkerAndFinish`）。原来的"有上限"是 `withTaskGroup` 赛跑写法，悄悄失效了（返回值对，墙钟不对） |
| §5 风险表 | "退出还原被排队的应用覆盖 → `await waitForIdle()`" | 补一条同级风险：**有上限的等待必须轮询可观察标志**，拿 `await task.value` 赛跑等于没上限；回归守卫要断言墙钟 |

---

## 实验 11：快速连切桌面，Dock 还是会消失 26–31 秒（2026-09-20，结论：**`minimumSpacing = 1 s` 的阈值定错了，launchd 判"崩溃"的门槛是 uptime ≈ 10 s**）

数据来源：**用户真机跑出来的日志**（不是脚本实验），2026-09-19 05:02 启动 → 05:58 退出。
二进制 `build/MultiDock.app` 的时间戳是 **05:02**，**晚于**实验 9（commit `47defb5` 02:11）和实验 10（commit `8ab35f8` 03:21）
→ **这份日志是修复后的代码跑出来的**，两处修复都经过了真机。

### 11.1 先说好消息：退出路径修好了

```
05:58:43.981 [INFO] 开始退出还原…
05:58:45.991 [INFO] 开始还原到原始 Dock：15 个图标
05:58:46.001 [INFO] 退出还原流程结束，用时 0.01s
```

对比实验 10 记下的 **53.12 s / 54.05 s**，实验 10 的修复**在真机上成立**（整个退出 ≈ 2 s，
其中 2 s 是 `prepareForTermination` 的等待窗口，不是 Dock 缺席）。**A7 可以销账。**
唯一的尾巴：这次退出走了 `!settled` 分支（`还原未完成（退出时还有一次应用没落地），已留下标记`），
所以 `session.state` 里留下了 `needsSelfHeal = true, pid = 0` —— 这是预期中的兜底，不过副作用见 11.4。

### 11.2 坏消息：切桌面还是会吃到几十秒的退避

这次会话里 6 次真实 apply 的 Dock 不可用时长：

| 时刻 | 结果 | Dock 不可用 | 上一任 Dock 的 uptime |
| --- | --- | --- | --- |
| 05:02:44 | SIGHUP 成功 | **57 ms** | 约 29 分钟 |
| 05:03:18 | SIGHUP 成功 | **126 ms** | 34 s |
| 05:32:12 | SIGHUP 成功 | **84 ms** | 约 29 分钟 |
| 05:32:44 | SIGHUP 成功 | **26046 ms** | **约 6.5 s** |
| 05:33:16 | SIGHUP 超时 30 s → kickstart | **31039 ms**（含先等 1032 ms 错开节流） | **约 1 s** |
| 05:58:19 | SIGHUP 成功 | **50 ms** | 约 25 分钟 |

**相关性很干净：uptime ≥ 30 s 的 4 次全是 50–126 ms；uptime 6.5 s 和 1 s 的 2 次是 26 s 和 31 s。**

### 11.3 相关不等于因果：看着像"uptime 门槛"，**其实是错的**（见 11.6）

实验 5 记的是"间隔 < 1 s → 1070 ms，≥ 1 s → 70 ms"。真机数据看起来在说：
那条结论只在"上次重启是很久以前"时成立，真正的判据是 **Dock 进程的 uptime**。
本机 6.5 s 触发、34 s 不触发，正好落在经典的 **10 s crash-uptime** 附近 —— **这个解释很顺，但它是错的。**

**证伪过程记在 11.6。** 控制实验（实验 12）直接测了 uptime 6 / 12 / 20 / 60 s 时的重启，
**全部 37–68 ms**，一次都没被罚。所以 11.2 那张表里的相关性**不是因果**：
真正把好坏两组分开的不是 uptime，是别的东西（还没找到）。

> → **实验 15 又往前走了一步**：把真机日志那两行逐字重读，发现"重载期间监视器不出声"，
> 旧日志里**一点过程记录都没有**，两种病因分不出来；于是给慢路径装上了取证仪表。
> **要等下一次真机复现才能定案。**

### 11.4 顺带记一笔：两条 override 和默认 Dock 的图标一样 —— **不是损坏，已结案**（但留下两个教训）

> ⚠️ **这一节 2026-09-20 改正过两次，两次都是我自己错。**
> **第一次**：初版写的是"三个桌面的 override 全是空的"—— 错。当时的读取脚本用错了 JSON 键名
> （写成 `apps` / `others`，真实键是 `pinnedApps` / `otherItems`），于是把有内容的 override 读成了空。
> **教训：核对配置之前，先 `print(list(d.keys()))` 把真实键名打出来**，别凭记忆写字段名；
> 一个字段名写错，就能把"3 项"读成"0 项"，然后得出完全错误的结论。
> **第二次**：改完初版，我提议"把这两条 override 清成沿用默认，反正切过去看到的 Dock 一样"—— 也错。
> 它们**不是**默认的精确副本（见下文 `orientation`），清掉会带来看得见的行为变化。
> **教训：「内容看起来一样」不等于「等价」；能不能替换，要看*取用语义*，不能靠眼睛比列表。**

`~/Library/Application Support/MultiDock/config.json`（2026-09-19 05:32 写的）**用正确的键名重读**后，真实状态是：

| 目标 | `pinnedApps` | `otherItems` | 内容 |
| --- | --- | --- | --- |
| 默认 Dock | **3** | 0 | 启动台 / FlClash / WorkBuddy AI |
| `密码 邮件` | **3** | 0 | 启动台 / FlClash / WorkBuddy AI ← **和默认逐项相同** |
| `计划 任务` | **3** | 0 | 启动台 / FlClash / WorkBuddy AI ← **和默认逐项相同** |
| `LLM` | **15** | 1 | 启动台 / 滴答清单 / Chrome / … / OrbStack ← 正常 |

**真实 Dock 是健康的**：`persistent-apps` **16 项**、`persistent-others` 1 项、`tilesize 36` / `orientation bottom` / `autohide false`。
基准快照是 15 项（用户后来自己加了 Qoder CN，所以真实是 16）。

**"坏"在哪 —— 已结案（2026-09-20）**：两条 override 的**图标**和默认 Dock 逐项相同
（都是启动台 / FlClash / WorkBuddy AI），当时看着像"被默认内容盖掉"的指纹。
但**用户已经确认，默认 Dock 那 3 个图标是他故意配的**，所以"图标相同"本身**不再算损坏的证据** ——
他完全可能就是给这两条也配了同一组图标。**没有独立证据能分清这两种可能，所以不再当故障处理。**

⚠️ **而且它们不是精确副本，不能清成「沿用默认」**：两条 override 的 `appearance.orientation = "bottom"`，
默认 Dock 是 `"right"`。`effectiveConfig(for:)` 的逻辑是 `binding(for:)?.override ?? settings.defaultDock`
（**整体替换**，不是逐字段合并），所以清掉 override，那两个桌面的 Dock 就会**跑到屏幕右边** ——
这是看得见的行为变化，不是等价操作。**结论：`config.json` 原样保留（一个字节都没动），要改由用户自己在 UI 里改。**

**默认 Dock 的 3 个图标 + `orientation = right` 是用户有意设的**（2026-09-20 确认），**任何 agent 都别擅自改**。

日志里能看到一条**会把 override 钉死的正反馈路径**（这是实验 9.4 那个 bug 的续集）——
**机制本身是真的，仍然危险**，只是这次到底有没有伤到数据，判断不了：

```
05:32:12.243 Dock 应用成功：切到 计划 任务；SIGHUP 成功…写入 9 个键
05:32:12.401 检测到真实 Dock 上的手动改动：3 个图标、0 个其他项
05:32:12.422 计划 任务：回存手动改动：3 个图标
```

也就是说：残缺的 override 被应用到真实 Dock → 真实 Dock 变成 3 个图标 → `DockWatcher` **合法地**
把这 3 个图标当成"用户手动改的"存回去 → 配置被自己钉死。**这是正反馈，不会自己好。**

⚠️ **还有一个待爆的副作用（2026-09-20 已处理）**：`session.state` 里 `needsSelfHeal = true`，**而且**
`appliedFingerprint != nil`（`impliesDirtyDock` 两条都中）→ 下次启动会"还原到基准（15 项）"，
**把用户后来自己加的 Qoder CN 抹掉**。

但这笔欠账是**假的**：日志里 `05:58:45.991 开始还原到原始 Dock：15 个图标` 之后，Dock 确实回到了基准状态
（Qoder CN 是用户后来才加的，所以现在是 16 项）。留下 `needsSelfHeal`，是因为 `prepareForTermination`
发现还有一次排队的 apply 没落地，才留了兜底标记；**还原本身是成功的**。
→ 已经先备份、再删掉 `session.state`（`session.state.bak-20260920-044624`），让这笔不存在的欠账作废。

### 11.5 数据修复（只能手动）

`config.json` 坏掉的部分只能用户自己修：设置 → 桌面 → 每个桌面点「从当前 Dock 抓取」；通用页也照样重抓一次默认 Dock。
**代码修好了，数据不会自动修好。** 每个桌面原来的 override 内容已经丢了（Dock 域一次只装得下一套配置，备份里也没有），
恢复不了，只能重抓。

### 11.6 ⚠️ 后面的实验把这个结论**证伪了**（2026-09-20，实验 12–14）

11.3 那个"uptime 门槛"的解释很顺，所以改 `DockReloader.minimumSpacing` 之前，先做了控制实验 ——
**结果三次全是否定，别照 11.3 去改代码。**

| # | 脚本 | 假说 | 结果 |
| --- | --- | --- | --- |
| 12 | `scripts/spike-restart-spacing.swift` | launchd 有 ~10 s 的 uptime 门槛 | ❌ **推翻**。uptime 6.0 / 12.0 / 20.0 s 各测一次，再加 60 s 和 81 486 s 两个对照，**归位耗时 37–68 ms**，一次都没被罚 |
| 13 | `scripts/spike-pid-detection.swift` | `dockPID()` 先走 `NSRunningApplication`，在重启窗口里会返回过期实例，让 `waitForRestart` 看不见已经回来的 Dock | ❌ **推翻**。A 路径（`proc_listpids`）41–63 ms，B 路径（`NSRunningApplication`）78–116 ms，**同一量级，没有分叉** |
| 13 | 同上 | 连续快速重启会让退避越积越长 | ❌ **推翻**。**连发 6 次，间隔 2 s**，归位全是 41–116 ms |
| 14 | `scripts/spike-preference-write.swift` | 慢的是「写偏好 + 重启」这个组合（App 会先写偏好，前两个实验只发了信号） | ❌ **推翻**。**幂等写**白名单的 9 个键（值原样写回，事后核对域里零变化），再发 SIGHUP，5 轮 **35–46 ms** |

**所以 11.2 那张表里的相关性不是因果。** 真正把好坏两组分开的变量还没找到。
四条排除掉的假说连同原始数字都留在这里，**省得下一个 agent 再花一轮去试**。

**眼下的立场**：

- **别改 `minimumSpacing`。** `com.apple.Dock.plist` 里写的本来就是 `ThrottleInterval = 1`
  （`launchctl print gui/501/com.apple.Dock.agent` 显示 `minimum runtime = 1`），
  实验 12 也证明 6 s 的 uptime 完全够。把它提到 10 s，只会让配置白白晚 10 秒生效，什么也换不来。
- 26–31 s 是**偶发的**。正常路径（单次重启、uptime 充足）稳定在 **35–126 ms**，连续快速重启 6 次也不慢。
  它对用户的实际影响，比实验 9 那个 60–126 s 小得多。
- 下一步要复现它，得带上**真实 App 的完整上下文**（GUI 应用 + `DockWatcher` / `DockPresenceMonitor` / `SpaceObserver` 三个轮询同时跑），
  别再加控制实验 —— 已经排除的四个方向不要再试。
- ⚠️ **有一条曾被当作"已排除"的观察，2026-09-20 复核后打了折扣**：真机那两次慢重启期间，
  同一个窗口里 toast 的 1 秒定时器**准时开合了 4 组**（`05:32:20.566 显示` → `…21.597 隐藏`，
  一直到 `05:32:27.364 显示` → `05:32:28.388 隐藏`），说明那段时间**主线程是活的**。
  **但它只覆盖了 26 秒窗口的前 10 秒**（apply 从 `05:32:18.675` 开始，到 `05:32:44.735` 结束）——
  后面 **16.35 秒日志一片空白**，**没有任何存活证据**。原来那句"所以不是主线程被冻住造成的
  假测量"**说过头了**，已经改正。→ 见 **实验 15.4**：仪表补上了"轮询次数 + 最长间隔"，堵住这个洞。

### 11.7 实验脚本

```bash
swift scripts/spike-restart-spacing.swift 20 12 6      # 实验 12：uptime 门槛（已证伪）
swift scripts/spike-pid-detection.swift 6 2            # 实验 13：两条探测路径 + 连发重启
swift scripts/spike-preference-write.swift 5 2         # 实验 14：写偏好 + SIGHUP
```

三个脚本都**只重启 Dock，不改语义**（实验 14 是幂等写），跑完会确认 Dock 还活着；
实验 14 会写 `com.apple.dock`，跑之前先 `defaults export com.apple.dock <备份路径>`。

---

## 实验 15：给「偶发慢重启」装取证仪表（2026-09-20，**还没定案，等下一次真机复现**）

### 起因：把真机日志那两行一个字一个字重读

实验 11.6 已经推翻了四个假说，但**还没定案**。这次回头把两行日志一个字一个字重读了一遍：

```
2026-09-19 05:32:44.735 [INFO] Dock 应用成功：applied：切到 LLM；SIGHUP 成功：PID 39129 → 39143，
                                        Dock 不可用 26046 ms；写入 10 个键；总耗时 26060 ms
2026-09-19 05:33:16.817 [INFO] Dock 应用成功：applied：切到 计划 任务；kickstart 成功：PID 39143 → 39164，
                                        Dock 不可用 31039 ms（先等了 1032 ms 错开节流，期间 Dock 可用）；
                                        写入 10 个键；总耗时 32079 ms
```

读出两条之前没注意到的事实：

1. **第一次慢重启从 05:32:18.675 开始，到 05:32:44.735 结束**（用 `26046 ms` 倒推出来）。
   而 `05:32:18.668 切换到 LLM` 正好在这时 —— **慢重启就是从那次切换开始的**。
2. **第二次慢重启紧跟着第一次**：`05:33:16.817 − 32.079 s = 05:32:44.738`，和第一次结束的
   `05:32:44.735` 只差 3 ms。也就是"第一次刚回来，第二次马上开始"。第二次 **30 秒的 SIGHUP 等待
   全部用完，才升级到 `kickstart`**。

### 旧日志为什么定不了案

这 26 秒里**一行日志都没有**。看着像"监视器没干活"，其实**本来就这么设计**：

```swift
// DockPresenceMonitor.tick()
guard !isReloading() else { return }   // 我们自己正在重载 → 这一轮不计数、不记日志
```

`DockReloader` 重载时，监视器故意不出声（`docs/spikes.md` 实验 8.5：两条控制回路抢同一个服务，
会把 1 秒拖成两分钟）。**代价是慢重启那段时间没人在旁边看着。**

`waitForRestart` 也一样，只记**结果**（`elapsed`），不记**过程**（那 26 秒里 `dockPID()`
到底返回了什么）。所以两种完全不同的病因都说得通：

| 病因 | 现象 | 谁来修 |
| --- | --- | --- |
| **探测分叉** | `procScan` 早就看到新 Dock，`launchServices` 却一直返回旧 PID → `waitForRestart` 以为"还没回来" | **我们**（`dockPID()` 选哪条路径） |
| **Dock 真的没回来** | 两条路径都只看到 `nil` | launchd（我们改不了） |

**原来以为"已排除"的那条观察，2026-09-20 复核后要打折扣**：那 26 秒里 toast 定时器按时开合了 4 组
（`05:32:20.566 显示` → `…21.597 隐藏`，一直到 `05:32:27.364 显示` → `05:32:28.388 隐藏`，
每组正好约 1.02 s）→ 说明主线程那 10 秒确实活着。
**但这只管得到前 10 秒**（apply 从 `05:32:18.675` 开始，到 `05:32:44.735` 结束），
**后 16.35 秒没有任何证据说明它还活着**。见 **15.4**。

### 做法：只在慢路径上取证，答案变了才记

`DockProcessControlling` 加了 `pidProbe() -> DockPIDProbe?`（默认实现返回 `nil`，
测试替身不受影响）。`DockPIDProbe` 里同时装着两条路径的答案：

```swift
struct DockPIDProbe { var launchServices: pid_t?; var procScan: pid_t? }
```

`waitForRestart` 按这几条规则取证：

- **正常路径不多花一分开销** —— 等待没超过 `slowProbeThreshold`（默认 **1 秒**），就一次也不调 `pidProbe()`。
  这条是硬要求：正常重启只要几十毫秒，`NSRunningApplication` 调一次要 0.6–1.4 ms，没理由白花。
- 超过 1 秒后，每 `probeInterval`（100 ms）采一次样，但**答案变了才记一条**（开头和结尾各强制记一条）。
  一次 30 秒的慢重启一般只留 **2–4 条**，不会是 300 条。
- 另外用 `probeSampleCap`（24）给条数封顶。
- 时间线挂在**原有那一行日志**里（`ReloadOutcome.description`），不另起新行：

```
… Dock 不可用 26046 ms；慢重启取证：1000ms LS=39129 scan=nil｜26046ms LS=39143 scan=39143
```

### 判定规则（下次真机复现时照着看）

| 时间线长什么样 | 结论 | 下一步 |
| --- | --- | --- |
| 前面几条是 `scan=<新 PID>`，`LS=<旧 PID>` | **探测分叉**，`dockPID()` 选路径有 bug | 改成先用 `procScan`（它只要 0.02 ms，看的又是内核事实） |
| 前面几条是 `LS=nil scan=nil` | **Dock 真的不在** | 转去查 launchd 那边（退避 / 系统负载），别动我们的探测 |
| 两条路径同时看到新 PID，只是很晚 | 探测没问题，是**归位本身慢** | 同上 |

### 状态

- **还没定案。** 仪表已经用 `./scripts/build-app.sh` 打进 `build/MultiDock.app`（2026-09-20 05:02），
  下次偶发时会自己把过程写进 `multidock.log`。
- 单测 6 条（在 `DockReloaderTests` 的「慢重启取证」一节）：快路径不多花开销、两条路径都记、
  答案变了才记、条数有上限、替身不支持取证时照常工作、**超时没归位也要带上时间线**。
- ⚠️ **别为了"复现"反复折腾用户的 Dock。** 这个故障是偶发的（那天 6 次里中了 2 次）。
  真要复现，得带上真实 App 的完整环境（GUI + 三个轮询同时跑），成本高，收益说不准 —— 等它自己冒出来。

### 15.1 第五次试着复现：**真机验收连切 20 轮，没复现**

2026-09-20 05:11 跑了一遍完整的真机验收（`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`）。
里面的 `testSwitchingBetweenTwoDesktopConfigsIsStable` 负载**形状一样**：
两套配置（`tilesize` 40/60 + `magnification` 反过来）**来回切 20 次**，每次都真的用 SIGHUP 重启一次。
`DockController` 默认带 `minimumSpacing = 1 s`，所以**每次重启时 Dock 正好活了 1 秒左右** ——
和真机那次 `39143` 只活了 **1.03 s** 就被重启的情况**是同一个结构**。

结果：

```
[P3 验收] Dock 不可用时长（ms）：[47, 49, 46, 47, 74, 56, 61, 52, 31, 59, 47, 61, 54, 32, 32, 53, 67, 65, 53, 52]　最坏 74 ms
[P3 验收] 慢重启（≥ 300 ms）共 0 次：无
```

**20 轮全在 31–74 ms，一次都没慢。** 算上实验 12–14，这已经是**第五次没复现出来**。

结论：**光是"连续重启"这个形状触发不了 A8。** 剩下唯一的差别是"真实 App 的完整环境"：
GUI 事件循环 + `DockWatcher`（2 s 读一次偏好域）+ `DockPresenceMonitor`（500 ms 查一次 PID）+
`SpaceObserver`（300 ms 查一次空间）+ 用户真的在切桌面。**所以不再加大力度去复现了，等它自己冒出来。**

> 顺带一提：`testKillingDockRecoversWithinThreeSeconds` 这次实测 **56 ms** 就归位（`69452 → 69457`），
> 不是文档里写的 1072 ms。见 §4 那行修正 —— **`kill -9` 后多久归位，要看 Dock 当时活了多久**，
> 不是固定值。

### 15.2 ⚠️ 仪表自己是坏的：Swift 的**协议见证位协变陷阱**（2026-09-20，已修）

**这一节比仪表本身更值得读。** 仪表装好了，6 条单测全绿，App 也重新打了包 —— 可它**在生产路径上
根本没起作用**，而且**只有真机验收才发现得了**。

#### 怎么发现的

给仪表写了一条真机验收测试（`DockAcceptanceTests/testSlowProbeTimelineWorksAgainstTheRealDock`），
第一个断言就是"直接读一次探针，结果不能是 nil"。**第一条就挂了**：

```
XCTUnwrap failed: expected non-nil value of type "DockPIDProbe" - pidProbe() 返回 nil —— 取证仪表是坏的
```

#### 根因：默认实现占了见证位

协议要求和实现分别长这样：

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

Swift **不按返回类型协变去匹配**：编译器不认 `-> DockPIDProbe` 是 `-> DockPIDProbe?` 这条要求的实现，
而是把它当成**另一个重载**（类型上两个函数都在）。结果协议要求的见证位**由扩展里的默认实现占了**。

后果很确定，而且一点动静都没有：

```swift
RealDockProcessControl().pidProbe()            // ✅ 有值（直接派发到具体方法）
(RealDockProcessControl() as any DockProcessControlling).pidProbe()  // ❌ nil（默认实现）
```

`DockReloader` 拿着的是 `any DockProcessControlling` —— **所以它永远拿到 nil**。
`sample()` 里的 `guard let probe = process.pidProbe() else { return }` 每次都直接返回，
时间线永远是空数组，跟"没装仪表"一模一样。

其实编译器提醒过（只在调用的那一侧出现）：

```
warning: comparing non-optional value of type 'Probe' to 'nil' always returns false
```

#### 6 条单测为什么全绿

因为**替身写对了**：`FakeDockProcess` 自己声明的是 `func pidProbe() -> DockPIDProbe?`，
签名和协议要求一字不差，见证位没问题。单测验的是"`DockReloader` 拿到探针答案后怎么记"，
**从来没验过"真货有没有接上这根线"**。

> **教训：替身单测证明不了生产路径接通了。** 协议要求只要有默认实现，就得**再写一条走 `any` 协议
> 调用的守卫测试**，断言没选中默认实现。

#### 修法和回归守卫

- 返回类型改成一字不差：`func pidProbe() -> DockPIDProbe?`（`DockReloader.swift` 里附了最小复现注释）。
- 新加 `DockProcessSafetyTests.testRealControlIsWiredAsTheProtocolWitness`：
  `let viaProtocol: any DockProcessControlling = RealDockProcessControl()` → 断言 `pidProbe()` 不是 nil，
  而且 `procScan == 真实 Dock PID`。**关键在于它故意不直接用具体类型。**

#### 全仓排查这一类 bug（2026-09-20）

修完还不能收工 —— 这是**一类** bug，不是一次事故。**只要协议要求有默认实现，就可能这样悄悄失效**。
把 `Sources/` 里 4 个协议全过了一遍，**只有 2 个扩展带默认实现**：

| 协议 | 带默认实现的要求 | 真实实现的签名 | 结论 |
|---|---|---|---|
| `DockProcessControlling` | `pidProbe() -> DockPIDProbe?` | 已改成 `?` | ✅ 已修 + 守卫 |
| `DockProcessControlling` | `startTime(of:) -> TimeInterval?` | `TimeInterval?`，**一字不差** | ⚠️ **签名对，但当时没守卫** → 补上 |
| `DockPreferenceAccessing` | `readMRUSpaces() -> Bool?` | 转调**必须实现**的 `readDomain()` | ✅ 结构上就安全 |

`startTime(of:)` 签名对了为什么还要补守卫：它一旦被写成非可选，**节流窗口的判断依据会悄悄从"进程活了多久"
退回到"我们记不记得自己重启过"**。这个退化**实测有代价** —— P3 验收里同一个场景从 **45 ms 变成 1030 ms**
（用户看到 Dock 消失一秒多），而且**没有任何测试发现得了**，因为 5 个替身
（`FakeDockProcess` ×2、`RevivableDock`、`FlakyDock`、`LyingProcess`）全靠这个默认实现活着。
→ 补上 `testRealStartTimeIsWiredAsTheProtocolWitness()`，同样**走 `any` 协议调用**。

默认实现**留着不删**：那 5 个替身里有 3 个只关心别的行为，不想被迫把要求全实现一遍。删掉只会把陷阱
从"默认值"挪到"替身自己写错"。写守卫测试才是正确的修法。

**排查步骤**（3 条 `rg` + 一张判定表）已经写进 skill `macos-dock-space-probe`，以后加协议要求前先跑一遍。

#### 顺带的第二个坑：这条验收测试自己有竞态

阈值一开始写成 `1 ms`（"正常重启几十毫秒，肯定该有取证"）。**实测一次空、三次有**：

```
# 偶发失败
[A8 取证] 真机重载：SIGHUP 成功：PID 69602 → 71491，Dock 不可用 37 ms
[A8 取证] 取证条数：0（上限 8）
```

原因是**探测的机会出在第二轮轮询**（第一轮时 `now` 还没过窗口），而循环里
`dockPID()` 判定**排在** `sample()` **前面** —— 只要 `Task.sleep(15 ms)` 稍微拖长一点，
Dock 又刚好在第二轮之前回来，就会**先返回，一条都不记**。

修法：阈值改成 `.zero`，让**第一轮就一定采样**，不再受轮询抖动影响。改完连跑 4 次，每次都稳定记 2 条。

> **教训：验收测试里的"肯定"要当心。** 断言只要依赖"某件事发生在某轮轮询之前"，
> 就是竞态，会跟着机器负载变。

#### 修好以后真机长什么样

```
[A8 取证] 探针直读：LS=72409 scan=72409　dockPID()=72409
[A8 取证] 真机重载：SIGHUP 成功：PID 72409 → 72516，Dock 不可用 37 ms；
          慢重启取证：0ms LS=72409 scan=nil｜36ms LS=nil scan=72516
```

**这一行马上给出了新线索**：SIGHUP 发出去以后，`NSRunningApplication` 还在报**旧** Dock，
内核进程表里却已经没有了 —— 见 15.3。

### 15.3 第六个假说（LaunchServices 滞后）也推翻了 —— 定向测量（2026-09-20）

#### 假说哪来的

15.2 修好后，第一次真机取证就显示 `0ms LS=<旧 PID> scan=nil`。这正好对上
`RealDockProcessControl.dockPID()` 的写法：

```swift
func dockPID() -> pid_t? {
    if let pid = launchServicesDockPID() { return pid }   // ⚠️ LS 优先
    return scanForDockPID()                               // 只有 LS 给不出才扫进程表
}
```

`DockReloader.waitForRestart()` 判断重启的依据是 `pid != oldPID`。
**假如重启期间 LS 一直返回那个正在退出的旧 Dock，`dockPID()` 就会一直返回 `oldPID`，
等的那一方根本看不到重启已经发生** —— 它会一直等到 LS 放手。LS 要是能滞后到秒级，这就是 A8。

（实验 13 恰好没测这个角度：实验 13 测的是"两条路径**答案一不一致**"，
这次要测"**LS 什么时候放下旧答案**"。）

#### 测量

新加了脚本 `scripts/measure-launchservices-lag.swift`（**只读 + 发 SIGHUP**，安全闸门和产品代码一样）：

```bash
swiftc -O -o /tmp/md-ls-lag scripts/measure-launchservices-lag.swift && /tmp/md-ls-lag 6
```

每轮：读 old PID → 发 SIGHUP → 每 **1 ms** 同时问两条路径，直到两条都看到新 PID，或者超时 1.5 s。

#### 结果（6 轮，全部一致）

| 量 | 实测 |
| --- | --- |
| 进程表看到新 PID | 26–33 ms |
| **LS 放手（不再报旧 PID）** | **11–29 ms** |
| LS 看到新 PID | 70–93 ms |
| `dockPID()`（先问 LS）发现重启 | 26–33 ms |
| **危险窗口（进程表已经知道新 PID、`dockPID()` 还在报旧的）** | **6/6 = 0 ms** |
| LS 比进程表晚多久"看到新 PID" | min 41 / 中位 57 / max 63 ms |

#### 结论：**假说不成立，机制上就不成立**

关键是 LS 的两件事**是分开的**：

- **放手很早**（~11–29 ms）：SIGHUP 之后它很快就不报旧 Dock 了；
- **认领很晚**（~70–93 ms）：要再晚 ~50 ms 才认出新 Dock。

`dockPID()` 是 **先问 LS，拿到 nil 就退回去扫进程表** —— LS 一放手，回退就接上了，
所以"认领晚"这半段**全被回退盖住**。危险窗口一直是 0：LS 放下旧答案的时间总是**早于**
进程表看到新 Dock 的时间（~25 ms vs ~30 ms）。

> 顺带看到：有几轮在 **400–550 ms** 处又出了一次 `LS=nil`（LS 一时丢了已经认领的 Dock），
> 随后恢复。同样被回退盖住，没有害处。

**意义**：这是第六个被推翻的假说，而且很可能是**最后一个"我们的 bug"候选**。
剩下能解释的只有 launchd / Dock 那边"归位本身慢"。

⚠️ **别改 `dockPID()` 选路径的顺序。** 判定规则表第 1 行说"改成先用 `procScan`"，
**前提是时间线真的显示分叉** —— 15.3 已经证明正常重启不会分叉。
别再"顺手"把 scan 挪到前面（这样 LS 本来更快的时候 `dockPID()` 反而变慢，而且没有任何证据支持）。

⚠️ **这次测量的边界**：测的是**正常重启**（26–33 ms 归位）。A8 时 Dock 要 26 s 才归位 ——
要让危险窗口成立，LS 得**攥着旧 PID 26 秒不放**，比实测的 ~25 ms 差了三个数量级。

### 15.4 补上最后一个洞：**"Dock 真的不在" 也可能是 "我们没在看"**（2026-09-20）

#### 起因：复核 11.6 里那条"已排除"的观察

11.6 和 15 都写过"那 26 秒里主线程活着，所以测量不是假的"。复核真机日志原文后发现，**这话说过头了**：

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

toast 那 4 组开合只覆盖了 **18.675 → 28.388（前 10 秒）**。**后 16.35 秒日志一片空白。**

这段空白**两种解释都说得通**：
- Dock 真的不在 → 没东西可记；
- 主线程卡住了 → 想记也记不了（重载期间 `DockPresenceMonitor` 本来就被 `guard !isReloading()` 静了音，
  连"我还在跑"都不会说）。

#### 这个洞出在结构上，不是这一次碰巧

`DockReloader.waitForRestart` 的 `elapsed` 是**墙钟时间**，轮询循环又跑在 `@MainActor` 上。
主线程一旦被别的东西卡住，循环就跑不动 —— 我们**其实没在看**，
恢复以后却照样把整段时间记成 `Dock 不可用 26046 ms`。
**在旧日志里，"Dock 慢" 和 "我们瞎了" 长得一模一样。**

#### 做法：用数字证明我们一直在看

`waitForRestart` 每轮记两个数，跟慢重启那一句日志一起输出：

```
… Dock 不可用 26046 ms；轮询 1738 次，最长间隔 18 ms；慢重启取证：…
```

| 读数 | 结论 |
| --- | --- |
| 轮询次数 ≈ `elapsed / pollInterval`（默认 15 ms），最长间隔十几毫秒 | **我们一直在看** → Dock 真的不在（launchd 那边） |
| 次数比预期少得多，最长间隔到了**秒级** | **观察断了** → 是我们的 bug，跟 Dock 无关 |

只在 `elapsed > 1` 时记，**快路径的日志行一个字节都不变**（有单测钉着）。
两个计数器都是整数运算，开销小到可以不计。

单测 3 条（`DockReloaderTests` 的「存活性」一节）：快路径不记、慢重启记上、
**替身在第 3 次 `dockPID()` 时阻塞 80 ms → 最长间隔必须反映出来**（并和没阻塞的情况对照）。

> **教训**：凡是"某段时间里 X 没发生"的结论，都要先问一句 ——
> **那段时间里，我看得到 X 吗？** 观察者自己活没活着，也是证据的一部分。


---

## 实验 16：A8 的修法 —— **别干等，去催**（2026-09-20）

用户说「解决 A8 剩余的问题」。前面六个"我们的 bug"候选全被推翻，只剩 launchd 那一边。所以这轮
**不再找新假说，而是回到真机日志里一直没当回事的那条线索**，顺手把一条"已推翻"的结论重新验了一遍。

### 16.1 ⚠️ 先更正一条：假说 ③ 的"已推翻"站不住

实验 13 把「连续快速重启触发退避」判成 ❌，依据是 **"连发 6 次（间隔 2 s）全部正常"**。

**可 `com.apple.Dock.plist` 里的 `ThrottleInterval` 本来就是 1 s** ——
**间隔 2 s 的重启根本没触到节流**。换句话说，这条假说**从来没在真正触发节流的条件下测过**。
真机那两次失败偏偏就是这个没测过的形状：故障前后的重启**挤在一起**（05:32:12 一次，
05:32:18 又要在 6.5 s 内再来一次），不是隔开 2 秒。

### 16.2 补测：让 Dock 活不到 1 秒就重启，连打 10 轮

脚本：新加的 `scripts/measure-launchd-backoff.swift`。轮与轮之间**不等待**，
每轮记下旧 Dock 活了多久、从 SIGHUP 到看到新 PID 花了多久；超过 3 s 还没归位就自动催一发 `kickstart`。

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

1. **Dock 活不到 1 s 时，launchd 一律把归位卡在 ~1016 ms —— 不累积、不增长、不漂移。**
   → 到这时假说 ③ 才算**真的推翻了**（实验条件对了）。
2. **那 ~1 s 是封顶值，不是越来越慢的起点。** 所以 26–31 s **不可能**是节流一点点累积出来的。

> ⚠️ 另外：`launchctl kickstart` **绕不过**这 1 秒节流。真机验收里 `nudgeAfter: 0`
> 那一发在 SIGHUP 之后 0 ms 就催了，Dock 还是到 **1037 ms** 才回来。催办解决的不是节流，
> 而是**"launchd 根本没打算把它拉起来"**（见 16.4）。

### 16.3 真机日志里一直被忽略的那半截：**一催就活**

回头一个字一个字看 `05:33:16` 那次：

```
05:33:16.817 kickstart 成功：PID 39143 → 39164，Dock 不可用 31039 ms（先等了 1032 ms 错开节流）
```

`31039 ms` 里，**30000 ms 是 SIGHUP 那条路等满的超时**，500 ms 是 SIGTERM 的宽限，
**剩下约 540 ms 才是 `kickstart` 发出去以后 Dock 归位用的时间**。

也就是说：**SIGHUP 等了 30 秒没等到的，`kickstart` 0.5 秒就拿到了。**
前几轮一直在争"launchd 为什么慢"，却没人问一句 —— **我们手里本来就有一条马上能把它叫回来的路，
只是排在了 30 秒以后。**

### 16.4 机制（推断，附可以验证的预测）

`/System/Library/LaunchAgents/com.apple.Dock.plist` 的 KeepAlive 是
`{AfterInitialDemand: 1, SuccessfulExit: 0}`。`man launchd.plist` 里写着：

> `SuccessfulExit`：为真时，**程序只要正常退出**就重新拉起；为假时，**程序只要异常退出**
> （被信号杀掉）就重新拉起。

所以：

- Dock **被 SIGHUP 打死**（异常退出）→ launchd 自动拉起，约 1 s（16.2 实测）。
- Dock **干净退出**（exit 0）→ launchd **不会**重新调度它，要等**有东西明确提出要它**。
  这个"要求"可以来自任何去连它服务的 XPC 客户端 —— **什么时候来、来不来，我们说了不算**。
  "偶发"就是这么来的。

`launchctl kickstart`（不带 `-k`）就是那个**明确的"现在就跑"的要求**，所以一催就活。

**可以验证的预测**（真机复现时一步就能定案）：在"一直没归位"的那段时间里执行

```bash
/bin/launchctl print gui/501/com.apple.Dock.agent | grep -E "state|runs|last terminating"
```

- 走干净退出那条路 → `state` 不是 `running`，并且**没有 `last terminating signal`**；
- 正常（被信号打死）那条路 → `last terminating signal = Hangup: 1`（**本机现在就是这个值**）。

这次实验在**正常重启期间**抓到的样子（`launchctl print` 跑一次约 0.5 s，窗口里只能抓一两次）：

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
| Dock 是不是在**反复崩溃**（自己拼 tile 那种做法会让它 SIGABRT） | ❌ `~/Library/Logs/DiagnosticReports/` 和 `/Library/Logs/DiagnosticReports/` 里**都没有 Dock 的崩溃报告** |
| 能不能读**系统日志**，看 launchd 自己怎么说 | ❌ 不行。`/usr/bin/log show` 一律报 `log: Cannot run while sandboxed`；**申请脱离沙箱也一样**（`log` 自己做了 `sandbox_check`）。`launchd` 那句 `Service only ran for … Pushing respawn out by …` 拿不到，只能用 `launchctl print` 从侧面看 |

### 16.6 修法（`DockReloader`）

一句话：**把 `kickstart` 从"30 秒后的兜底"提前成"500 毫秒后的催办"。**

| 改动 | 值 | 为什么 |
| --- | --- | --- |
| 新加 `nudgeAfter` | `500 ms` | 到时间还没看到新 Dock，就催一发 `kickstart`。正常路径 35–126 ms，永远碰不到 |
| 新加 `nudgeInterval` | `1 s` | 重复催。⚠️ **尽力而为**：`LaunchctlParking.hasOutstanding` 闸门会吞掉叠在一起的催办（真机验收实测第二发被吞了） |
| `timeout` | **30 s → 3 s** | 原来定 30 s，理由是"launchd 退避以几十秒计"（实验 8.5）—— 16.2 证明其实是 **1 s**，这个理由不成立了。3 s ≈ 正常值的 24 倍，够宽松了 |
| 新加 `kickstartTimeout` | `30 s` | 真正要耐心等的那段挪到这里：**催完以后**再给 30 s |
| **PID 守卫** | 新加 | 兜底原来是先 `let dyingPID = process.dockPID() ?? oldPID`，再对 `dyingPID` 发 SIGTERM。假如 launchd 刚好在超时前后把 Dock 拉了回来，读到的就是**新** PID，这一发 SIGTERM 会把刚恢复的 Dock **再杀一次**。超时缩短后更容易撞上这个窗口，必须挡住 |
| 失败路径的取证 | 修 | 原来只带最后一段（`kicked`）的时间线，**偏偏丢了最有用的主路径那段**（催办记录就在里面）。现在三段拼起来，每段标上名字 |

安全前提是**实测**出来的，不是推出来的：

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
| 真机验收 | **9/9 绿、43.1 s**（新加 `testPrematureNudgeIsHarmlessAgainstTheRealDock`） |
| 真机实测催办 | `nudgeAfter: 0` → `0ms 催 kickstart #1`，重载照样成功，**Dock 只换了一次 PID**（800 ms 后还是同一个）—— 催早了也不会多弹一次 |
| Dock 域 | 和备份逐字节一致（只差 `mod-count`）；`config.json` 的 SHA1 没变 |

新加或改过的用例：`testSlowRestartIsNudgedWithKickstart`、`testNudgeRepeatsWhileTheDockStaysAway`、
`testFastRestartIsNeverNudged`、`testNudgeDoesNotFireWhenTheDockReturnsFirst`、
`testProductionDefaultsNudgeEarlyEnough`（钉住生产默认值）、
`testFallbackNeverSignalsAFreshlyRestartedDock`（PID 守卫）。

### 16.8 这轮过后 A8 还剩什么

**修好的是"代价"，不是"成因"。**

- ✅ 最坏情况从 **26–31 s** 降到 **~1–3.5 s**：不再干等 30 s，500 ms 就走那条"明确要求"的路。
- ✅ 顺手修掉一个真实存在、一直没发作的 bug（给刚归位的 Dock 补发 SIGTERM）。
- ❌ **launchd 为什么偶尔不去重新拉起，还是没有直接看到**（16.4 是机制推断 + 可以验证的预测）。
  系统日志拿不到（16.5），只能等下次真机复现时用 `launchctl print` 从侧面看。

**下次复现时这样读（顺序很重要）：**

1. 先看 `轮询 N 次，最长间隔 M ms` —— **M 到了秒级，就说明我们没在看**（实验 15.4），后面都不用看了。
2. 再看时间线里有没有 `催 kickstart #n` —— 有，就说明催办真的发出去了。
3. 最后跑一次 `launchctl print … | grep -E "state|last terminating"`：
   **没有 `last terminating signal` = 干净退出 = 16.4 的机制成立**；还是 `Hangup: 1` 的话，说明还有第三个成因。


---

## 实验 17：CoreDock 私有 API 通道 —— 「热重载不存在」**推翻了一半**（2026-10-03）

**问题**：不重启 Dock，能不能直接换掉图标（`persistent-apps` / `persistent-others` + 外观）？
实验 1 的结论是「不存在热重载」——但那次只测了 **notifyd 这条路**（`notifyutil` / `NSDistributedNotificationCenter`）。
这次把另一条路（**MIG → `com.apple.dock.server`**）挖出来实测了一遍。先说结论：

> **通道存在、无权限闸门；外观键实时生效已实锤（一次意外命中）；条目热替换未打通（三种载荷全被 Dock 静默拒绝）。**
> **「post 通知无效」依然成立；「必须重启 Dock 进程」不再成立。**

### 17.1 通道怎么找到的（纯静态分析，一个字节都不写）

| 步骤 | 做法 | 发现 |
| --- | --- | --- |
| 1 | `launchctl print gui/501/com.apple.Dock.agent` | Dock 挂着 **`com.apple.dock.server`** 等 14 个 launchd 端点（注意：用 `sed` 截取会漏，必须完整列出来） |
| 2 | 对 Dock 二进制跑 `strings` | 能看到 `com.apple.dock.server` / `com.apple.dock.prefchanged` / `com.apple.dock.add-item` |
| 3 | 对 **Finder** 二进制跑 `nm -u` | Finder 导入了 **`_CoreDockAddFileToDock`**、**`_CoreDockSendNotification`**、`_CoreDockSetTrashFull`（垃圾桶变满，就是"外部进程让 Dock 实时变化"的现成例子） |
| 4 | `dyld_info -imports Finder` | 这些符号 **(from ApplicationServices)** → 实现在 **HIServices** 里（由 ApplicationServices 重新导出，**不用 dlopen，直接能链接**） |
| 5 | `dyld_info -exports HIServices` | 完整的 API：Add/Remove/Set/Get/CopyPreferences/SendNotification 等约 60 个 `CoreDock*` 函数 |
| 6 | 排除干扰项 | `DockKit.framework` 是 MagSafe 配件框架（`DockAccessoryManager`），跟 Dock 条目无关；System Settings 二进制里没有 `com.apple.dock.server` 字符串（走的是框架内部）；旧的 `Dock.prefPane` 只是个没有二进制的资源壳 |

### 17.2 还原签名（用 lldb 反汇编 HIServices 桩函数，全部核实过）

Dock 二进制的符号被裁掉了（`nm -U` 只剩 9 个 C++ typeinfo），但 HIServices 的桩函数还在，用 `lldb -b -o "target create <探针>" -o "disassemble -n <函数名>"` 直接看。

| 函数 | 真实签名（从反汇编还原） | 要点 |
| --- | --- | --- |
| `CoreDockSendNotification` | `(CFStringRef name, Int32 flags) -> OSStatus` | 把 CFString 序列化 → `_DSSendNotification(port, 0x7D0, data, len, flags)` |
| `CoreDockAddFileToDock` | `(CFTypeRef file, Int32 flags) -> OSStatus` | msgid 也是 0x7D0，载荷换成序列化的 CFType —— **Dock 那边按载荷类型分派** |
| `CoreDockSetPreferences` | `(CFDictionary) -> OSStatus` | msgid **0xBB8(3000)**，只有一个参数 |
| `CoreDockCopyPreferences` | `(CFTypeRef request, CFTypeRef *out) -> OSStatus` | **两个参数**；request 传 nil 会崩（SerializeCFType 不判空）——第一次跑探针的 SIGSEGV 就是它 |
| `CoreDockGetTileSize` | `() -> Float`（从 xmm0 返回） | 没有参数，返回 float；读到 0.17857143，和域里的 36.0 对不上，**数值含义还不清楚** |
| `CoreDockSetTileSize` | `(Int32) -> OSStatus` | `sendSetFloatValue(1, value)` —— **参数按 float 的位模式解读**（见 17.3） |
| `CoreDockRemoveItem` | `(Int32) -> OSStatus` | 底层叫 `_DSRemoveWindow`，参数是 Dock 内部的窗口/tile ID，**不是数组下标** |
| `CoreDockIsDockRunning` | `() -> Bool` | 读的是 HIServices 自己缓存的标志 `sDockRunning`，没注册客户端时永远是 false，**不说明 Dock 没在跑** |
| `getDockPort` | 用 bootstrap 查 `com.apple.dock.server` | **没有权限闸门**：没特权的 CLI 进程实测拿到了 status=0 和真实的 orientation/pinning 值 |

### 17.3 实测结果（每轮：`defaults export` 备份 → 触发 → 轮询 GUID/PID/域 → 强制还原）

| 尝试 | status | Dock 的反应 | 判定 |
| --- | --- | --- | --- |
| `SendNotification("com.apple.dock.prefchanged", 0)`（先写好一个没有 GUID 的测试 tile） | 0 | 5 s 内没补 GUID，PID 没变 | ❌ Dock 不会因为这条消息重读偏好 |
| `SetPreferences(整份域 35 键, tilesize=37)` | 0 | 域里的 tilesize 没变 | ❌ 不接受整个域的字典 |
| `AddFileToDock(CFURL(Calculator), 0)` | 0 | apps 数量没变 | ❌ CFURL 载荷不起作用（也可能要先注册客户端，或者要别的类型） |
| **`SetTileSize(999999)`**（本来想当"无副作用自检"，**结果是真调用了**） | 0 | **域里 `tilesize` 36.0 → 16.0，PID 没变，mod-count 没动** | ✅ **实锤：实时生效，还持久化了**（999999 按 float 位模式 ≈ 1.4e-39 → 被压到最小值 16） |
| `SetTileSize(0x42100000=36.0f 位型)` / `64` / `36` | 0 | 域不再变 | ⚠️ 数值含义还不清楚（36.0 的位模式为什么没用），**别按现在的理解上生产** |

### 17.4 意外和恢复（如实记下）

1. **我误发了 `SetTileSize(999999)`** —— 我以为它是"无副作用自检"，其实就是一次真调用。用户的 Dock 图标当场变小。已经用 `defaults write com.apple.dock tilesize -float 36` + SIGHUP 恢复。教训：**"自检"调用也必须走无副作用模式，不能拿写函数来试编译**。
2. 三轮实验一共重启了 Dock 5 次（都在还原时），PID 链是 `493→47938→48072→48206→48395→48484`，全部正常；结束时和实验前做全量 diff，**没有差别**（mod-count 这类 Dock 自己的键除外）。
3. **新发现的沙箱坑**：这个会话的沙箱里，`CFPreferencesCopyMultiple(nil, …)` **只返回 1 个键**，逐个键调 `CFPreferencesCopyAppValue` 却完全正常 → 探针观察时必须一个键一个键地读，不然会把"观察手段坏了"错当成"实验失败"（第一轮就因为这个白跑了）。
4. 沙箱里 `defaults` CLI 读到的是**真实的域**（18057 字节 / 35 键），和探针用 CFPreferences 看到的不一样 —— 两边口径不同，别混着用。

### 17.5 结论和下一步

1. **更正实验 1 的说法**：`com.apple.dock.prefchanged` 在 Dock 二进制里多半是它**往外广播**用的（自己改了偏好时通知别人），不是用来收的；Dock 不监听任何 notifyd 通知，这一点没变。
2. **外观键的热重载通道确实存在**（`CoreDockSetTileSize` 成功过一次：改了域 + 持久化 + 没重启），但**数值含义还不清楚**，不能上生产。
3. **条目热替换没打通** —— 三种载荷都被悄悄拒了。卡在 Dock 那边 msgid 2000/3000 处理函数的分派逻辑上：可能要先用 `CoreDockRegisterClientWithRunLoop` 注册，可能要特定的 CFType（CFString 路径而不是 CFURL），也可能会校验发送方的 audit token。
4. **下一步（实验 17 续，全部只读）**：
   - 反汇编 Dock 那边的 handler：Dock 二进制就在磁盘上（10 MB），用 `otool -tV` 整个反汇编，找 0x7D0/2000 的消息分派表，以及 `com.apple.dock.prefchanged` / `com.apple.dock.add-item` 的引用；
   - 先用 `CoreDockRegisterClientWithRunLoop` 注册，再把三种载荷重试一遍；
   - 试 `AddFileToDock(CFString 路径, 0)`；
   - 看 Finder「在 Dock 中保留」时是谁发了什么（`dyld_info -fixups Finder`，或者反汇编 Finder 的 `cmdAddToDock:` 附近——用 lldb attach Finder 可能会被 hardened runtime 拒绝）。
5. 如果条目这条路最后打通了：`DockController.apply` 可以升级成「写域 + 实时推送」，SIGHUP 退为兜底；A8 暴露出来的问题（launchd 节流/退避）就会**整个从应用主路径上消失**。如果打不通：也可以先用外观键 setter，让"只改外观"的 apply 从重启变成不用重启（但得先搞清楚 17.3 的数值含义）。

### 17.6 Finder 是怎么调用的（B15 收尾的基准，2026-10-04）

Finder 自己就有 `cmdAddToDock:` / `validateAddToDock:`（ObjC 元数据：IMP 分别是 `0x100677275` / `0x1000b7ad0`，符号裁掉了，从 otool -oV 里拿的）。
用 lldb 反汇编 `cmdAddToDock:`：**对每个选中项调一次 `CoreDockAddFileToDock(<NSURL>, 0)`** ——
第一个参数是从 item 转出来的 NSURL（`NodeCopySFNodeRef` / `SFNodeCopyMountPoint` / `-fileURL` 这一类），
第二个参数实打实是 `xorl %esi, %esi` = **0**；调完**不发任何通知**，失败了才弹错误提示。
⇒ 我们探针的 `(CFURL, 0)` 和 Finder 的调用**每个参数都一样**。

### 17.7 一组判别测试（2026-10-04，带备份/看门狗/还原）

| 尝试 | 结果 |
| --- | --- |
| `CoreDockRegisterClientWithRunLoop` | ❌ 没调：反汇编证明它注册的是**接收端**（建一个 `_DCXDockClientDefs_subsystem` 的 MIG server source，接 Dock→客户端的消息，还要求先设好 client message proc），跟有没有权限发消息无关 ——「先注册再发」这条排除 |
| `CopyPreferences("com.apple.dock", &out)` | **status = -4956**、out=nil —— 读请求被**明确拒绝**（不是悄悄忽略） |
| `SendNotification(prefchanged, flags=1)` | status=0，没效果（和 flags=0 一样） |
| `AddFileToDock(CFString 路径, 0)` | status=0，条目没变（和 CFURL 载荷一样） |

**结论（B15 结案：「不做」）**：

1. **外观的 typed setter**（`SetTileSize` 这一类）对第三方开放；**所有带对象的 MIG 消息**（SendNotification / SetPreferences / AddFileToDock / CopyPreferences）对第三方要么报错，要么悄悄忽略。
2. Finder **一模一样的调用**能成功 ⇒ Dock 是看**发送方**放行的（Apple 平台二进制），或者要求已注册的客户端会话。我们**不伪造发送方身份**（违背零权限这条硬约束的本意）。
3. 系统设置里的实时滑杆**不走 CoreDock**（SystemSettings 主二进制、Settings / PreferencePanesSupport 框架都不导入 CoreDock）；Dock 却导入了 `_SLSCoordinatedLocalNotificationCenter` 这一类 —— 那个实时通道多半是 **SkyLight 协调通知中心**。没深挖：收益低（SIGHUP 也只要 100 ms）。
4. ⇒ 「不重启换图标」在 macOS 15 上的最终答案：**外观键能做，但 `SetTileSize` 的数值含义还不清楚；条目键没有给第三方的通道**。将来 Apple 正式开放的话，B15 可以重开。

---

## 实验 18：真人用手势切桌面会触发 activeSpaceDidChange（B7 结案，2026-10-04）

**问题（B7）**：用户手动切桌面时，`NSWorkspaceActiveSpaceDidChangeNotification` 会不会触发？
它只决定一件事：跟随延迟能不能从 300 ms 降到接近 0。

**工具**：`scripts/spike-space-notify-watch.swift`——一边听公开通知，一边对 SkyLight 活动空间做
**50 ms 一次的高频轮询**（只读）。轮询每发现一次切换，就回头看 ±0.5 s 内有没有通知跟着来。
不要权限、不写东西、不切桌面；后台开 240 s 窗口，用户用 ⌃←/⌃→ 手势切换。

**结果**：轮询看到 **5 次切换**（id64 6↔7），**5/5 都有通知**，而且**通知比轮询早 2–30 ms**
（例：`01:37:49.994 NOTIFY` vs `01:37:49.996 POLL`）。

**结论（B7 结案）**：

1. P0 的说法要更准确：**用程序**切桌面（`CGSManagedDisplaySetCurrentSpace`）不触发通知；
   **真人用手势**切桌面**会触发**（5/5，而且通知比 50 ms 轮询先到）。
2. `SpaceObserver` 的通知快速通道（通知一到就 `refresh()`，看代码确认已经接好）**实测管用**——
   手势切换的跟随延迟本来就 ≈0，**代码一行都不用改**；轮询继续留着，给程序化切换兜底。
3. 顺带把 `docs/facts.md` 里「桌面切换通知」那一行改准确了。

---

## 实验 19：macOS 更新到 15.8.1 —— GUID 回填这个判据失效了（2026-10-04）

**怎么发现的**：真机 Dock 验收（15.7.9 时一直 9/9 绿）第一次跑就红了：`testApplyThenRestoreLeavesDockUntouched`
里「Dock 给无 GUID 的条目回填 GUID」这条断言失败（重跑还是失败）。诊断显示 apply 整条链路完全正常：
SIGHUP 重启（PID 329→755、60 ms）、写了 10 个键、条目进了 Dock、还原后只差 `mod-count`。

**根因**：系统已经从 **15.7.9 (24G830) 更新到了 15.8.1 (24H32)**（Dock 二进制 09-23 重新构建过；
实验 1–17 全是在 15.7.9 上做的）。新系统里 Dock 重启时 **mod-count 照样 +1**（说明确实重启并
重读了），但 **persistent-apps 一个字节都没改写** —— 不再给外部写进去的条目补 GUID。

**处理和影响**：

1. 验收用例按系统版本区分：15.7.x 还用 GUID 判据；15.8+ 退一步，只看「条目跨 Dock 重启仍在」。
   重跑 **9/9 绿、40 s**（15.8.1 上第一次全绿验收）。
2. `docs/facts.md`：「Dock 是否应用了写入」那行和实验 8 那行加了注。实验 8 的 **SIGABRT 结论不靠
   这个判据**，「其他项只搬不造」照旧；"不认领"的取证方法在 15.8+ 上过时了。
3. **对产品没影响**：`DockController` 的 verify / 指纹短路、`DockWatcher`、无痕基线都不靠
   GUID 回写——GUID 一直只是验收时观察的量。
4. 环境事实：`docs/facts.md` 里开发机那行已改成 15.8.1 (24H32)；实验 18（观察通知）是在更新后
   的系统上做的，其他实验（1–17）都是 15.7.9 时的数据。

---

## 实验 20：自动隐藏三明治 —— 把整个重启藏进「滑走 → 隐形 → 滑入」里（2026-10-04，**已实现**）

**用户要的**：「切换桌面不用重启 Dock（会先黑屏再出现 Dock 栏），而是平滑地感觉不到」。
在 GitHub 上搜过（中英文各一轮）：**没有**现成仓库能不重启就换 Dock 内容；社区缓解重启闪烁的
共识办法，恰恰就是"开自动隐藏"。而我们手里正好有实验 20 证实能用的 typed setter 通道。

**能不能做的实测**（`CoreDockSetAutoHideEnabled` / `GetAutoHideEnabled`，lldb 反汇编出的签名：
`sendSetBooleanValue(id=3)`，和实测能用的 `SetTileSize` 是同一类）：

| 判据 | 结果 |
| Set(true) | ✅ 实时生效（PID 不变），**Dock 自己把它存进域里**（autohide=true） |
| 隐藏状态下发 SIGHUP | ✅ 新 Dock 回来时还是隐藏的（PID 30611→30724）——重启看不见 |
| Set(false) | ✅ 实时滑回来，域也还原成 false |
| 用 CGWindowList 观察 | ⚠️ 15.8.1 的窗口列表里**看不到 Dock 的容器窗口**（owner=Dock 一条都没有）——"窗口移到屏外"观察不到，改用 Get/域值当客观信号 |

**实现**（`DockAutoHide.swift` + `DockReloader` 三明治）：

1. `DockAutoHideControlling` 协议 + `HIServicesDockAutoHide`（`dlsym(RTLD_DEFAULT)`；协议要求没有默认实现，所以不会掉进见证位陷阱；符号找不到时构造出 nil，平稳退回老路径）。
2. `DockReloader.reload(strategy:sandwichRevealAutoHideTo:)`：参数不是 nil 时，把 `reloadCore` 包起来——
   **Set(true) 滑走 → 等 300 ms 动画 → SIGHUP（看不见的重启）→ 等归位 → Set(reveal) 滑回**；
   不管从哪条路返回都会恢复可见（失败重试一次，还失败就记 `revealFailed`，下次 apply 自己恢复——
   reveal 的值取自**配置**，不是当时的域，所以能自己恢复）。
3. `DockController.apply` 只在不是退出流程、并且 `config.appearance.autohide == false` 时才传这个参数
   （配置本来就要隐藏的话，重启后的 Dock 自然是隐藏的，不会闪）。
4. 失败时怎么办：Set(true) 失败 → 走老路径，闪一次；整个重载失败 + reveal 也失败 → Dock 保持隐藏，
   等下次 apply 恢复（反正 Dock 本来就没回来，看到的结果一样）。

**验收**：单测 333 全绿（+5 条用例：三明治的时序、降级、失败路径）；真机效果等用户重新构建、重启后
切桌面看日志（`隐藏中重启（无闪烁）`）和实际感受。⚠️ 实验 19 的教训：改了代码必须重新跑
`./scripts/build-app.sh` 才算装上。

---

## 实验 21：次级 Dock 条的几何从哪来 —— Dock 条不是独立的 CG 窗口（2026-10-04，**已实现**）

**背景**：用户拍板做「贴原生 Dock、半露、hover 滑出」的次级条（见 `docs/PLAN.md` §3.12）。
原计划是用 CGWindowList 按 Dock 的 PID 找到「Dock 条窗口」，量它的几何。

**实测（`scripts/spike-probe.swift` + 一次性把所有窗口 dump 出来）**：

| 观察项 | 值 |
| --- | --- |
| Dock 进程的所有窗口（`.optionAll`） | **只有两个全屏的 layer-20 窗口**（1920×1200，一个 onscreen，一个 offscreen） |
| Dock 条自己的窗口 | **没有** —— 条是画在全屏容器窗口里的（15.8.1；实验 20 也碰到过 owner=Dock 一条都没有的容器） |
| 屏幕 | 1920×1200，`visibleFrame = (0, 53, 1920, 1147)`（菜单栏自动隐藏，顶部没内缩） |
| 当前偏好 | `orientation=bottom`、`autohide=0`、`tilesize=36` |
| config.json | 默认和全部 3 条绑定都是 `bottom`（A9 时的"默认 right"已经过时，用户改过了） |

**结论和决定**：

1. **几何改从 `NSScreen.visibleFrame` 的内缩里取** —— 它就是系统给原生 Dock 留出的位置，最权威，
   会跟着 Dock 的方位、大小、自动隐藏自动更新，而且 Dock 重启期间也不受影响（Dock 重启那 45–90 ms
   里 CGWindowList 是空的）。`visibleFrame` 只有 top 那边是菜单栏，left/right/bottom
   三个方向的内缩就是 Dock。
2. **摆法统一成「贴内侧、半露藏身后」**（贴着内侧，露一半，另一半藏在 Dock 后面）：条贴着 Dock 朝屏幕内的那一面（bottom→上方、right→左侧、
   left→右侧，和用户 msg3 说的三个方位一致）；露一半 = 往 Dock 方向挪半个条的厚度。条窗口的层级
   **19 < 20**，挪进去的那半被原生 Dock 的像素挡住；hover 时往屏幕内侧滑出整条。
   这种摆法**不依赖侧边 Dock 的垂直锚定**，三个方位的几何完全一样。
3. **点击和 hover 的事件怎么走**：全屏的 Dock 容器窗口压在条的区域上面（层级 20 > 19），但在
   条区域以外它一定让事件穿透（不然全屏下所有普通窗口都收不到点击）——真机窗口核对见下，点击手感
   归到用户手测（A 组）。

**真机验收（`build/MultiDock.app`，04:45）**：window-dump 读到次级条窗口
`layer=19 x=600 y=1115 w=720 h=56`（CG 坐标）——换算成 AppKit 坐标就是 y 29–85：
下半截 29–53 在 Dock 条后面，上半截 53–85 从 Dock 顶边露出来，水平居中，宽 720 = 16 个条目
（访达 + 15 个配置的图标），和设计逐像素对得上。日志里出现了
`次级 Dock 条：Dock 几何变化 → bottom 内缩 (0.0, 53.0, 1920.0, 1147.0)`。

**测试**：+27 条（三个方位的几何/露一半/clamp、内容构建时 Finder 排第一 + 运行指示、状态机的
hover 防抖/安全网/全屏隐藏、冻结闸门、旧配置解码）——**355 全绿**，快照
`secondary-dock-{light,dark}.png` 人工核对过。

---

## 实验 22：零权限看 Dock 实际是显是隐 —— typed setter 只翻旗标，不改 work area（2026-10-04，**已实现**）

**背景**：用户要次级条跟着原生 Dock 一起显隐（「原生 Dock 隐藏了次级条也 hide，show 则同步 show」）。
得先回答：Dock **实际**在不在屏幕上，有没有不要权限就能读的信号？

**实测（`scripts/spike-secondary-dock-sync.swift`）**：三路同时采样（`visibleFrame` 内缩 /
探针窗口的 `occlusionState` / CGWindowList），用 `CoreDockSetAutoHideEnabled` 翻旗标，
再用 `CGWarpMouseCursorPosition` 把光标甩到底边，让 Dock 临时显出来。

| 观察项 | 结果 |
| --- | --- |
| `SetAutoHideEnabled(true)` 之后的 **inset** | **一点没动（47）** —— 旗标翻了（Get=true，域也存了），但 Dock **并没有真的滑走**，work area 不变。⚠️ 这条更正了实验 20 的理解：「实时生效」只到**旗标这一层**；三明治里的「隐藏」靠的是**重启后的 Dock 读到旗标**，不是当场滑走 |
| `Set(false)` 往**显出**方向 | 实时生效（对照流程日志：重启后处于隐藏态，inset≈0「探测不到」→ Set(false) 后 0.7 s 内回到 47）—— 跟隐藏方向不对称 |
| 探针窗口的 `occlusionState`（level 19、放在 Dock 区域里、alpha 0.05） | **用不了**：Dock 在屏的基线下就在 是/否 之间来回跳，没有稳定的判据 |
| CGWindowList（Dock 在屏时） | owner=Dock 的在屏窗口 0 个 / 全部窗口 0 个 —— 15.8.1 上还是完全看不到 Dock 的窗口（和实验 20 一样） |
| `CGWarpMouseCursorPosition` | err=0（光标确实动了），但这次实验里 Dock 一直没进入隐藏态（旗标不起作用），没法用它判断显出 |

**结论和决定**：

1. **Dock 实际显隐没有零权限能直接读的信号**。能用的事实只有两条：`visibleFrame` 的内缩跟着 Dock
   **实际**占的位置走（真机对照日志：隐藏态「探测不到」，恢复后内缩 47——和实验 21 一致）；
   自动隐藏时让 Dock **显出来的触发条件** = 光标碰到屏幕边（这是 Dock 自己的机制，没有 API）。
2. **显隐同步这样实现**：以 face（inset）为主信号，再用「光标在显出带」这条经验规则补上自动隐藏的情况：
   face != nil → 条显示；face == nil（自动隐藏起作用中，或重启的那一瞬间）→ 光标在 Dock 最近一次占的
   那条区域里（往外多扩 8 pt），就说明 Dock 在屏或马上要显出 → 条跟着显示；光标离开显出带 → 等 400 ms 宽限再收起。
   几何轮询从 1 s 改成 **200 ms**（跟得上 Dock 滑进滑出）。
3. **别再试的路**：探针的 occlusionState、用 CGWindowList 找 Dock 窗口、指望 typed setter 翻的
   旗标能反映看到的状态——三条都实测过，走不通。

**测试**：+6 条（三个方位的 dockArea、显出带里保持/带外宽限后收起/回来再显示、sizingSlots 固定
frame、冻结模式下几何固定 + 图标尺寸用默认 Dock 的）——**364 全绿**。

## 实验 23：次级条为什么跟着桌面滑 —— `.canJoinAllSpaces` 让 `.stationary` 失效（2026-10-04，已实现；**「纯 stationary 钉住」被实验 24 推翻**）

**背景**：用户反馈，用触控板滑动切桌面时，次级 Dock 条**跟着桌面一起滑**，原生 Dock 却钉在原地。
次级条窗口的配置是 `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`。
本来以为有 `.stationary` 就够了（第 35 次会话里也是这么写的），实测打了脸。

**问题**：`.canJoinAllSpaces` 和 `.stationary` 放在一起时，到底是谁在管空间切换的过渡动画？

**实测（`scripts/spike-stationary-spaces.swift`，不要权限、不改系统）**：建两个小窗口，
A 设成 `canJoinAllSpaces + stationary`，B 设成 `仅 stationary`。用 SkyLight 程序化切桌面
（`CGSManagedDisplaySetCurrentSpace`，0–6 ms 硬切），每到一个空间就读 `isOnActiveSpace`，
再用 `CGWindowList(.optionOnScreenOnly)` 看窗口在不在屏上。

| 组合 | rawValue | 跨空间在不在屏 | `isOnActiveSpace` |
| --- | --- | --- | --- |
| A: `.canJoinAllSpaces` + `.stationary` | 337 | 全部 true | 全部 true |
| B: 仅 `.stationary`（没有 canJoinAllSpaces） | 336 | **全部 true** | 结果不一（有些是 false，但**不影响实际显示**） |

关键发现：**B 组去掉 `.canJoinAllSpaces` 后，窗口在所有空间照样在屏**（CGWindowList 才是
权威判据；对纯 stationary 窗口来说，`isOnActiveSpace` 的含义本来就不稳）。跨空间可见
**不靠** `.canJoinAllSpaces`——`.stationary` 本身就表示「不属任何空间、浮在所有
空间之上」。

**结论和决定**：

1. **滑动是 `.canJoinAllSpaces` 惹的**：它把窗口登记成每个空间的成员，空间过渡动画
   自然要带着它一起滑。`.stationary` 管的是 Mission Control/Exposé，**管不到**
   `.canJoinAllSpaces` 参与空间过渡动画这件事。
2. **修法**：次级条窗口去掉 `.canJoinAllSpaces`，只留 `[.stationary, .fullScreenAuxiliary,
   .ignoresCycle]`——跟原生 Dock 的表现一样（浮在所有空间上面，切换时不动）。
3. **和 toast 不一样**：toast 还留着 `.canJoinAllSpaces`（它是切完桌面才弹出来的，过渡
   动画里有没有它都行；而且 toast 的配置是以前踩坑踩出来的结论，不动）。两者从这里开始各走各的。
4. **手势滑动的过渡动画没法用脚本复现**（实验 7），条到底钉没钉住，要用户在真机上确认。

**改动**：`Sources/MultiDock/UI/SecondaryDockWindow.swift` 改了一行（collectionBehavior 去掉
`.canJoinAllSpaces`）+ 加了注释。**364 测试全绿**（没有单测覆盖窗口的 collectionBehavior，
靠 spike 脚本实测证明）。

⚠️ **2026-10-04 晚上被推翻**：用户在真机上用手势滑动实测，**只有 `.stationary` 的条照样跟着桌面滑**。
这个实验的判据有漏洞：用的是**程序化硬切**（0–6 ms，没有过渡动画）+ `CGWindowList` 核对在不在屏——它只能
证明「切换完成后窗口在新空间在屏」，**证明不了「过渡动画期间窗口不参与滑动」**。真正能用的判据
只有真人手势 + 眼睛看（脚本复现不了手势动画，实验 7）。教训：**「在屏」和「不滑动」是两回事**，
跨空间可见的第三方窗口一律会被卷进过渡动画（机制见实验 24）。

---

## 实验 24：零权限下次级条做不到「不滑动」—— 每条路都试过不行，`.moveToActiveSpace` 是唯一的折中（2026-10-04 晚，**结论 = macOS 硬限制**）

**背景**：实验 23 的修法（纯 `.stationary`）在真机上实测**还是会滑**。之后系统地排查了零权限下
所有「窗口跨空间可见 + 过渡不滑动」的可能做法，11 个 spike 一条条靠人眼实测（都不要权限、不改
系统；每条路建一个有颜色的测试窗口，真人用触控板滑动切桌面观察）。

**逐条否定（脚本 → 观察）**：

| # | 做法 | 脚本 | 真机看到的 |
| --- | --- | --- | --- |
| 1 | 窗口层级：用 `CGSSetWindowLevel` 设成 20（Dock 级）/ 24（菜单栏级）/ 25（状态栏级），另加一组「纯 stationary + CGS 20」 | `spike-window-level-sticky.swift` | **全都滑**（红/蓝/绿/橙/紫没有一个钉住） |
| 2 | SkyLight 窗口级私有 API | `spike-window-workspace.swift` | **15.8.1 上没有 `CGSSetWindowWorkspace`**（查了 13 个符号，`SLSSetWindowWorkspace` 也没有）；`CGSSetWindowTags`（bit 16 NeverFlatten）没用，红窗照滑 |
| 3 | 照抄原生 Dock 的窗口 tags | `spike-dock-tags.swift` | 读出 Dock 的 tags 写进测试窗口（分「Dock tags」「NeverFlatten 位」「Dock+NeverFlatten」三组）——**照滑**。特权不是从 tags 来的 |
| 4 | 纯 `.managed`（只属于当前空间）+ 切换后用 `orderFrontRegardless` 拉回来 | `spike-managed-space.swift` | 窗口**留在原来的空间，跟着旧桌面滑走**；切完能拉回来，但过程看得见 |
| 5 | `.moveToActiveSpace` + 收到通知/轮询到之后「临时 canJoinAllSpaces → orderFront → 设回」，拉到新空间 | `spike-move-to-active.swift` | **不滑**——切换那一刻窗口消失，到新空间后再出现（「消失再出现」） |
| 6 | 每个桌面一个单独的窗口（`.managed`，用程序逐个空间创建） | `spike-multi-window.swift` | 8 个彩色窗口各归各的空间——**过渡时旧窗口跟着旧空间滑走，新窗口跟着新空间滑进来**，等于一个滑动变成了两个 |
| 7 | 保留 canJoinAllSpaces，SkyLight 30 ms 轮询一发现变化马上 `alphaValue=0`，通知到了再恢复 | `spike-hide-show.swift` | 品红窗口**闪现后就没了**（alpha 0/1 来回跳，眼睛看得出来），不能用 |
| 8 | `.managed`，发现变化就 `orderOut`，150 ms 后拉回来 | `spike-hide-during-anim.swift` | 黄窗口一样会闪断 |
| 9 | `.managed`，等动画结束（NSWorkspace 通知）再拉 | `spike-pull-after-anim.swift` | 橙窗口不滑，但什么时候出现要看通知，延迟感觉得到 |
| 10 | 拉回提速（30 ms 轮询 + 同步设回） | `spike-pull-fast.swift` | 紫窗口还是能感觉到延迟，30 ms 轮询很费 CPU |
| 11 | 只靠 NSWorkspace 通知 + 10 ms 设回 | `spike-pull-nsworkspace.swift` | 青窗口和 5 一样——「消失再出现」，延迟看通知什么时候来 |

**结论（硬限制，别再往这些方向改代码）**：

1. **只有系统特权进程的窗口（原生 Dock、菜单栏）才能跨空间可见、过渡时又不滑**——特权来自进程
   身份，不是窗口属性。第三方窗口不管 `collectionBehavior`、窗口层级（19/20/24/25）、
   窗口 tags 怎么设，只要跨空间可见，就**一定会被卷进空间过渡动画**。
2. `.stationary` 只管 Mission Control/Exposé（Apple 文档原文这么说），**管不到它参不参与 Spaces 过渡**。
3. 零权限下一共只有两个选项，没有第三个：① **接受滑动**（现状，纯 `.stationary`）；②
   **用 `.moveToActiveSpace` 拉回**——窗口只属于一个空间，切换那一刻消失、到位后再出现（说白了是
   拿「放弃过渡期间可见」换「不滑动」）。隐藏/显示、alpha、多窗口这些花样，最后都是②的劣化版
   （闪断肉眼可见）。
4. `.moveToActiveSpace` 方案已知的毛病（待打磨/待拍板）：什么时候拉回，要靠 NSWorkspace 通知
   （手势切换实测会触发，实验 18）或 SkyLight 轮询；「闪现后消失」说明 alpha/显隐切得太糙，
   真要用，得在 `SecondaryDockWindow` 上专门处理过渡。

**决定（2026-10-05 更新）**：**用户拍板用方案 ②**，已经做进产品（v3.6.3）。要点：
平时用单空间配置（`[.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]`）——
切换那一刻条留在旧空间（不滑）；切换回调 `SecondaryDockWindow.pullToActiveSpace()` =
设成透明 → 临时加 `.canJoinAllSpaces` + `orderFrontRegardless`（在当前空间重新登记）→ 16 ms 后设回
单空间 → 0.18 s easeInEaseOut 淡入（连续切换时，复位任务自己取消）。拉不拉回由
`SecondaryDockController.spaceDidChange` 把关：只有「换了空间 && 切换前后都在显示」才拉（同一空间的
重复事件、进出全屏、从隐藏恢复都不拉）。拉回时机不只靠一个通知：手势走 NSWorkspace 快速通道，
程序化切换走 `SpaceSwitcher.switchTo → observer.refreshNow()` 当场回调，两路都汇到
`SpaceObserver` 去重后的回调里。真机手感（淡入节奏 / 有没有空窗感）等用户手测（A11）。

**没采用的更激进的方向**（记下备查）：辅助功能权限 / 私有的 `CGSSetWindowWorkspace`（已经没有了）
/ 每个空间一个独立窗口（第 6 条路，效果更差）。

---

## 实验 25：「随滑动幅度渐进沉入原生 Dock」——过渡期间改 frame 的动画没用，v3.7 否定后回退（2026-10-05，**结案**）

**背景**：用户的提议（v3.7）：手势切桌面时，次级条随滑动幅度一点点隐藏，滑到最大（1/4 桌面宽）
时整条沉到原生 Dock 后面。分两层：Layer 1 不要权限——收到切换回调后做 frame 下沉动画，利用
层级 19 < Dock 20 被挡住的效果，把条沉到 Dock 后面；Layer 2 预判手势幅度（要事件通道）。先做 spike A
验证最大的风险：**空间过渡进行中改窗口 frame 管不管用**（之前从没测过）。

**脚本**：`scripts/spike-sink-during-transition.swift`——照搬生产配置（层级 19、单空间配置
`[.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]`、半露位置 =
`visibleFrame` 底边往上探一半）。两个事件源（16 ms SkyLight 轮询 + NSWorkspace 通知，谁先到谁
触发，互相兜底）。流程 = 下沉 0.25 s → 拉回（crossSpace + `orderFrontRegardless`，**alpha
保持 1**，frame 已经在沉下去的位置）→ 0.25 s 升回半露位置。

**两轮真机手测**：

- 第一轮暴露了 spike 自己的 bug：`DispatchSourceTimer` 挂在 GCD main queue 上，在 `RunLoop.main.run()`
  下**一次都不触发**（轮询全哑，23 条通知全到了，流程一次没跑）。没人编排时，窗口留在旧空间
  跟着桌面滑走——顺带证明了必须拉回。修法：改用 `Timer.scheduledTimer`（RunLoop Timer）。
- 第二轮流程全通（轮询先到 13–25 ms，每轮都「已拉回当前空间」，总共 ~550 ms），但用户
  看到：**滑动过程中条没有往下沉**——它跟着桌面横着移、慢慢变淡，桌面滑到大约 1/4 屏宽时条就完全没了。这其实就是
  实验 24 的「消失再出现」机制，跟有没有往下沉无关。

**结论（结案，v3.7 回退）**：

1. **空间过渡期间改窗口 frame，看不出任何效果**——过渡合成时窗口怎么显示由 WindowServer 接管
   （跟着旧空间横移 + 渐隐），AppKit 的 frame 动画不参与过渡合成。「渐进沉入」这个效果根本不存在。
2. **`CGSGetActiveSpace` 的空间 ID 变化只比 NSWorkspace 通知早 13–25 ms**，两个都是过渡
   动画结束后才到——零权限下没有「过渡进行中」的事件可抓，16 ms 轮询也抢不到。Layer 2
   （预判手势幅度）一起否掉：就算提前知道幅度，窗口一进过渡就被接管了，改不了。
3. 拉回的配置（alpha=1 + 放在沉下去的位置的版本）功能正常——用户第二轮手测确认**「滑动结束后看到条
   从底部升上来」**：升起的效果确实看得到（滑动过程中没下沉，条只是跟着过渡变淡）。
4. **结局（2026-10-05 用户拍板）**：「随幅度渐进沉入」否定并回退（渐进沉入、幅度预判都不做）；
   **只留下它唯一看得到的那部分**——`SecondaryDockWindow.pullToActiveSpace()` 从「0.18 s 原地
   alpha 淡入」改成「沉没位置位（拉回当拍一次跳变，无视觉）→ 0.12 s easeInEaseOut 升回
   原位 + 同步淡显」（先放到沉下去的位置，拉回那一刻跳一下看不出来，再升回原位、同时淡入），切换结束后总共感觉 ≈ 0.14 s（用户要求 ≤ 0.15 s）。369 测试全绿。

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

# 次级条跨空间可见性 / 滑动根因（实验 23；零权限、不改系统、结束自动切回原桌面）
swift scripts/spike-stationary-spaces.swift

# 次级条「不滑动」全路排查（实验 24；全部零权限、有色测试窗，需真人触控板滑动切桌面观察）
#   每个脚本建 1–8 个有色窗，观察颜色见 docs/spikes.md 实验 24 的表格
swift scripts/spike-window-level-sticky.swift    # 窗口层级 20/24/25
swift scripts/spike-window-workspace.swift       # CGSSetWindowWorkspace 等符号探查（已不存在）
swift scripts/spike-dock-tags.swift              # 复制原生 Dock 的窗口 tags
swift scripts/spike-managed-space.swift          # 纯 .managed + orderFront 拉回
swift scripts/spike-multi-window.swift           # 每桌面独立窗口（会程序化切遍所有桌面再切回）
swift scripts/spike-move-to-active.swift         # .moveToActiveSpace 拉回（唯一不滑的折中）
swift scripts/spike-pull-after-anim.swift       # 动画结束后拉回（NSWorkspace 通知）
swift scripts/spike-pull-fast.swift              # 30 ms 轮询快速拉回
swift scripts/spike-pull-nsworkspace.swift       # 纯 NSWorkspace 通知拉回
swift scripts/spike-hide-show.swift              # 切换时 alpha 隐藏、结束恢复
swift scripts/spike-hide-during-anim.swift       # 切换时 orderOut、150 ms 后拉回
```

---

## 实验 26：设置窗口重构要用的数据从哪来——桌面缩略图和台前调度开关（2026-10-06，**结案**）

**背景**：用户拍板重构设置窗口（v4 内容模型，见 `docs/PLAN.md` §3.7 顶部的记录）：
默认 Dock = 最近添加的应用（1–15 个，可调）；桌面 Tab 改成 Dock 栏列表（默认 5 根），
每根栏绑定一个桌面（**下拉框带缩略图**）+ 一个位置（**避开台前调度占着的那一边**）。这两个 UI 要用的数据
都得零权限拿到，所以动手前先在本机（macOS 15.8.1）摸一遍。

**摸到的情况和结论**：

1. **台前调度开关 = `com.apple.WindowManager` 的 `GloballyEnabled`**（本机 = 1）。
   `defaults read com.apple.WindowManager` 一次就读到，不要权限；用 `CFPreferencesCopyAppValue`
   也能读。Stage Manager 的最近使用窗口条固定占着屏幕**左边**（系统没有换边的设置），
   所以 `DockBarPosition.available(stageManagerActive:)` 在它开着时去掉 `.left`。
   读不到（键不存在/出错）就按**没开**处理（三个位置都给）——宁可多给选项，也不错删功能。
2. **桌面缩略图 = 那个空间的壁纸**，`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`
   能读（不要权限）：`Spaces → <spaceUUID> → Desktop → Content → Choices[].Files[].relative`
   指向壁纸文件的 URL；本机的 `Spaces` 是空的（各空间都用系统壁纸），于是退到
   `AllSpacesAndDisplays/Desktop/.../Files[0].relative` = `Iridescence.heic`，
   用 `NSImage(contentsOf:)` 直接加载成功（UI 快照里显示正常）。连壁纸都拿不到时，退成
   按 UUID 算出来的固定渐变色块。**真正像 Mission Control 那样的窗口缩略图做不到**：别的空间里的
   窗口内容系统压根不渲染（跟实验 24「特权来自进程身份」是一个道理），给了屏幕录制权限也换不来。
3. **SwiftUI menu Picker 的坑（顺手记一下）**：行标签里放自定义视图（HStack + 图片）会被画成
   一整块高亮色，收起状态下没法用 —— 缩略图必须放在 Picker 外面（`docs/rules.md` 新坑 #1）。

**验收**：UI 快照（`MULTIDOCK_UI_SNAPSHOT=1 --filter UISnapshotTests`）——
桌面 Tab 的桌面名称区显示出了真实的壁纸缩略图；回归测试 `DockBarModelTests`（位置可用性 /
迁移 / 扫描器排序）和 `SecondaryDockTests`（独立贴边几何、附着 - 独立切换）全绿。

---

## 实验 27：swipe 预隐藏——用 type 30 认出手势，切桌面前一拍先把次级条藏起来（2026-10-05/06，**已实现**）

> spike 脚本是 `scripts/spike-swipe-prefetch.swift`（开头注释里有全部六轮的结论）；
> 期间内部的轮次编号写成「26c–26f」，跟实验 26（设置窗口数据源）没关系。

**背景**：用方案 ② 时，手势切桌面的过程中次级条留在旧空间，跟着桌面慢慢淡掉（用户 2026-10-05 晚反馈：
视频全屏时条跟着桌面滚，看着难受）。要求：**手势一开始条就消失**。

**六轮的结论**：

1. **NSEvent 全局 swipe 监听一个事件都收不到**——真切桌面的整个过程里 `.swipe` 都不触发，零权限的 NSEvent 这条路判死。
2. **listen-only 的 CGEventTap 不用授权就能挂上**（macOS 15.8.1）：只要 mask 里不含键盘事件（type 10/11/12），
   `tapCreate` 就成功；但切桌面的手势只混在 type 29（gesture，约 200/s 的环境采样流）里，
   常规字段跟普通触摸没区别。
3. **认准 type 30**（26c，用宽 mask 采集）：13 次三指/四指手势切桌面，在翻转前约 620 ms 内
   **每次都**出现 30（一串 30×1–30×5）；8 次 ⌃→ 键盘切换**一个 30 都没有**。第一次出现时的字段是
   `110=23 123=1 132=1 134=1 135=… 136=1 138=3 165=1`（138 可能是手指数）。
   故意**不加字段门槛**（四指时可能是 138=4）。另外确认：字段 55 和事件类型一样；169 是环境时间戳
   （并进 29 的基线 `{39,40,45,50,55,58,85,87,101,169}`）；MC/捏合手势是另一种特征
   （29 带 `110=32`，没有 30，不影响触发规则）。
4. **看到 30 → 预隐藏**（26d）手测通过：横扫切桌面，第一拍就藏起来 ✓；⌃→ 对照不藏 ✓。
   但有三种情况下条会「永久消失」（MC / 横扫到一半停下 / Launchpad）。
5. **`window.animator().alphaValue` 在这个窗口上会随机悄悄失效**（26e 查实）：九次超时渐回里
   七次被安全网抓到 alpha=0.0 —— 26d 的「永久消失」也是这个原因（当时还没有安全网）；
   孤儿窗口（+16 ms 时 `moveToActiveSpace` 被绑进 MC 的临时空间）全程只有 4 次，偶尔才有，不是主因。
   安全网的静默等待 800 ms 太慢（用户反馈「要等好几秒」）→ 26f 收紧。
6. **26f 定稿**（用户拍板上生产）：animator alpha 全部换成**分步直接设值**（`fadeAlpha`，
   6 步 × 20 ms）；安全网静默等待 250 ms，连续没恢复就退避 500 ms；新加一种故障特征
   「hidden=false 但 alpha<1」。横扫到一半停下/MC/Launchpad 之后，大约 0.7 s 条就渐渐回来，用户认可。

**上生产**（2026-10-06）：

- `Spaces/SpaceTransitionGestureMonitor.swift`：listen-only tap（`.cghidEventTap` +
  `.commonModes`），mask 只开 type 30 这一位（是宽 mask 的子集，29 的环境流一条都不要），
  3 s 重试 + 遇到 `tapDisabledByTimeout` 自己恢复；不要权限。
- `SecondaryDockWindow`：`hideForSpaceTransition()`（直接设 α=0）+ `fadeBackFromSpaceTransition()`
  （分步渐回）+ `isOnActiveSpace`/`currentAlpha`（给安全网用的信号）；`pullToActiveSpace` 里的
  animator alpha 换成分步直接设值，升起的目标改用 `intendedFrame`（安全网兜底时，窗口 frame
  可能停在沉下去的位置之类的无效值上）。
- `SecondaryDockController`：`spaceTransitionGestureDetected()`（预隐藏 + 600 ms 超时
  续期 + 顺手把展开的条收回去）；`spaceDidChange` 一确认翻转就取消超时，交给拉回处理；
  安全网挂在 `geometryTick`（200 ms 一拍）上，判断条件**不分模式**——独立贴边时露一半的 frame
  本来就在屏外，不能照搬 spike 里「frame 出屏」的判断，只看 `!isOnActiveSpace` 和
  `!preHidden && alpha<0.99`；预隐藏期间这两个信号都不算（翻转前窗口还在当前空间，α=0
  是预期状态，而且 30 一直在续期）；预隐藏期间压住 hover；`hide()` 清掉预隐藏状态，并把 α 分步
  复位（不然下次 orderFront 会碰上一个看不见的窗口）。

**验收**：406 测试全绿（+11：预隐藏/续期/超时渐回/翻转取消超时/条不在时忽略/hover
压制/安全网三种状态/退避）；release 零警告；`build/MultiDock.app` 已重新打包。
真机手测归到 A11（清单更新：① 手势切桌面第一拍就藏起来 + 切换后从沉下去的位置升起；② 横扫到一半停下，
600 ms 渐回；③ 关掉 MC/Launchpad 后 ≤1 s 回来；④ 两指横扫网页不会误藏；⑤ ⌃→ 对照）。

---

## 实验 28：合成键盘事件，借「切桌面」的过渡动画（2026-10-06，结论：**投递时被拦，做不到**）

**动机**：用户要求「菜单栏点击切换桌面时也要有左右滑动的效果」。

**背景**：实验 7 已经判定程序化切空间是硬切，四条路全不通；实验 7.6 把「合成按键」那条路
归为**权限问题**（那时零权限的约束还在）。2026-10-05 用户取消了「零权限」一票否决，
所以这条值得重测——**如果只是权限问题，授权后就该通了**。

**测法**（探针 `scripts/spike-animated-switch.swift`，另外用编译好的二进制再测一遍）：

| 观察项 | 结果 |
| --- | --- |
| `AXIsProcessTrusted()` | **true**（辅助功能已授权） |
| `CGPreflightPostEventAccess()` | **true** |
| `CGEventSource(stateID: .hidSystemState)` | 创建成功（不是 nil） |
| 系统热键 79（⌃←）/ 81（⌃→） | `enabled = true`（`AppleSymbolicHotKeys` 实测参数 `[65535, 123/124, 8650752]`） |
| 合成 ⌃→ 后轮询 1.5 s（每 2 ms 一次） | **空间 ID 一直没变** |
| **阳性对照：合成 Cmd+Tab** | **前台 App 没变**（Google Chrome → Google Chrome） |
| 换成 `swiftc -O` 编译的独立二进制再测 | **结论一样** → 跟进程身份无关 |
| 另一条路：AppleScript `key code 124 using control down` | `NSAppleScriptErrorNumber = -1743`（没授权 Apple Events） |

**结论**：**不是权限，不是 tap 选错了，也不是参数**。事件在**投递那一层**被系统拦下了 ——
跟实验 7.6 看到的现象一样，但原因要更正：**实验 7.6 说是"权限"不准确**，
授权后还是不通。

**产品上怎么处理**（如实为先，不做假开关）：

1. **默认关掉**：`AppSettings.animatedDesktopSwitch = false`（可以手动改 config.json）。
2. **设置 UI 里故意不放这个开关** —— 打开了也没用的开关就是假开关（项目规矩 D1/C7）。
3. 代码留着（`Spaces/AnimatedSpaceSwitch.swift` + `SpaceSwitcher` 里的合成路径）：
   它是**唯一对的那条路**，哪天换了机器或系统、投递闸门放开了，不用改代码就能启用。
4. 合成路径**带超时兜底 + 防抢跑**：合成没起作用就回到硬切，绝不会卡着不切
   （10 条测试覆盖：相邻桌面走合成、跨着选/循环不走合成、没授权就回退、超时兜底、防抢跑）。

**以后要是再试**（留给下一个 session）：判断依据是**阳性对照 Cmd+Tab** ——
先跑 `scripts/spike-animated-switch.swift`。Cmd+Tab 起作用了，说明投递闸门放开了，
这条路又能用了；连 Cmd+Tab 都没反应，就别在参数上浪费时间（实验 7.6 的教训）。

### 28.1 复盘（2026-10-25，等 Rei 真机确认）

热键 79/81 登记的修饰位是 `8650752 = 0x840000` = Control + **SecondaryFn**；当时合成只带了 `.maskControl`，
跟热键对不上——"空间不动"很可能就是这个原因。Cmd+Tab 本来就不响应合成事件，**算不上合格的阳性对照**。
现在的实现：完全按热键表里的修饰键合成，并补发修饰键的按下/抬起；跨着选/循环用「切换到桌面 N」（118–133，一次滑到位）；
设置 → 菜单栏里能开关，并显示权限/快捷键是否就绪。真机验证：打开开关并授权后点菜单栏图标，看有没有滑动。

---

## 实验 29：读 Launchpad 数据库 —— 文件夹和顺序都能完整还原（2026-10-06，**已实现**）

**问题**（用户的要求）：在 macOS 26 以下，从 Launchpad 拿到「所有文件夹（名称 + 内含 apps）」。

**结论**：Launchpad 的数据就在一个**普通 SQLite 库**里，用 `SQLITE_OPEN_READONLY` 直接就能读，
不要权限、不写东西 —— 用不着任何私有 API。

| 观察项 | 结果（本机 macOS 15.8.1 / build 24H32） |
| --- | --- |
| 库在哪 | `$DARWIN_USER_DIR/com.apple.dock.launchpad/db/db`（`confstr(_CS_DARWIN_USER_DIR)`；`~/Library/Application Support/Dock/` 已经没有了）。WAL 模式（`db` + `-shm` + `-wal`，`rw-r--r--`） |
| 表结构 | `items(rowid, uuid, flags, type, parent_id, ordering)`；`apps(item_id, title, bundleid, storeid, category_id, moddate, bookmark)`；`groups(item_id, category_id, title)`；另外还有 `categories` / `app_sources` / `image_cache` / `downloading_apps` 和 6 个触发器（我们都不碰） |
| type 的含义 | `1` 根（`parent_id = 0`）/ `2` 文件夹 / `3` 页 / `4` App；**App 不直接挂在文件夹下面**，中间隔着一层或几层 `type 3` 页（文件夹可以有好几页） |
| 数据量 | **27 个文件夹、160 个 App**（列出来的都是用户或系统建的真文件夹；「最近添加」「建议」这种系统分区不会当成文件夹出现） |
| 顺序 | 每一层有自己的 `ordering`；rowid 跟屏幕上的顺序**没关系**。用递归 CTE 把路径算出来以后，顺序和启动台里看到的一致 |
| bookmark | blob 以 `book` 魔数开头（标准的 CFURL bookmark）；用 `URL(resolvingBookmarkData:options:[.withoutUI, .withoutMounting], relativeTo: nil)` **解析 160/160 全部成功**，路径上的文件都在（包括 `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app` 这种 cryptex 路径） |
| 只读 | 读之前和读之后文件**逐字节相同**（`LaunchpadAcceptanceTests` 里有断言）；真机验收用 `MULTIDOCK_LAUNCHPAD_ACCEPTANCE=1` |

**实现**：`Launchpad/` 模块（`LaunchpadDatabase` / `LaunchpadResolver` / `LaunchpadImport`）。
查文件夹、查 App 属于哪个文件夹各用一条递归 CTE；解析时先用 bookmark，不行再用 bundle id 索引兜底
（用到时才建，`skipsPackageDescendants`）。搬过来有两种动作（并入 / 替换），都走现有的 `dockBarEdited` 通路。

**以后要是想再确认**（留给下一个 session / 换机器时）：重跑一下
`MULTIDOCK_LAUNCHPAD_ACCEPTANCE=1 swift test --disable-sandbox --filter LaunchpadAcceptanceTests` 就行 ——
它会打印文件夹清单、定位成功率，并检查是不是只读。macOS 26+ 上启动台已经被「应用程序」取代，
这一页由 `LaunchpadSupport` 闸门显示说明，不读库（在 15 的机器上验证不了 26 的行为）。

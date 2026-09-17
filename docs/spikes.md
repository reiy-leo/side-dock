# P0 实验结论

> 执行日期：2026-09-18　机器：macOS 15.7.9 (24G830) / x86_64 / 单显示器 / Swift 6.2.4
> 本文是 `docs/PLAN.md` §4「P0 实验」的产出，结论直接决定 §3.5 的主路径与 §3.1 的事件源设计。
> 原始数据留在 `/tmp/multidock-spike/`（临时目录，不随项目走）；可复现脚本见 `scripts/spike-*.{sh,swift}`。

---

## 摘要：结论

> 实验 1–3 是 P0 阶段的原始三问；实验 4–7 是后续阶段落地时**挖出来的新发现**，其中实验 5、6 各推翻了
> `docs/PLAN.md` 的一处假设，实验 7 是一条**明确的不做项**（别再去试）。

1. **不存在热重载**。写偏好后无论 post 什么通知，Dock 都不会重新读取——必须重启 Dock 进程。
2. **重启很快**：SIGHUP 后 Dock 仅约 **101 ms** 不可用；SIGTERM 约 **395 ms**（Dock 收到 TERM 会先做约 255 ms 清理再退出）。→ **主路径定为 SIGHUP**，SIGTERM + kickstart 作兜底。
3. **程序化切桌面可用且极快（P0 粗测 20 ms，后经实验 7 精测为 0–6 ms），但不触发 `NSWorkspaceActiveSpaceDidChangeNotification`**。→ SpaceObserver 必须以**轮询为主**，通知只能当优化。
4. **切桌面的"左右滑动动画"做不到**（实验 7）：程序化切空间是硬切（0–6 ms），SkyLight 不暴露带过渡的入口；唯一像入口的会话级开关**写后读不回**、碰了就破无痕原则；`SLSWillSwitchSpaces` 签名未知、猜错直接段错误。**零权限 + 无痕下无解，不要再试。**

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
```

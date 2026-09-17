# P0 实验结论

> 执行日期：2026-09-18　机器：macOS 15.7.9 (24G830) / x86_64 / 单显示器 / Swift 6.2.4
> 本文是 `docs/PLAN.md` §4「P0 实验」的产出，结论直接决定 §3.5 的主路径与 §3.1 的事件源设计。
> 原始数据留在 `/tmp/multidock-spike/`（临时目录，不随项目走）；可复现脚本见 `scripts/spike-*.{sh,swift}`。

---

## 摘要：三句话结论

1. **不存在热重载**。写偏好后无论 post 什么通知，Dock 都不会重新读取——必须重启 Dock 进程。
2. **重启很快**：SIGHUP 后 Dock 仅约 **101 ms** 不可用；SIGTERM 约 **395 ms**（Dock 收到 TERM 会先做约 255 ms 清理再退出）。→ **主路径定为 SIGHUP**，SIGTERM + kickstart 作兜底。
3. **程序化切桌面可用且极快（20 ms），但不触发 `NSWorkspaceActiveSpaceDidChangeNotification`**。→ SpaceObserver 必须以**轮询为主**，通知只能当优化。

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
| 生效耗时 | **20 ms**（首次采样即已切换） |
| 切回原桌面 | 正常 |
| 切换动画 | 有系统自带动画；**无动画时长控制符号**（`CGSSetWorkspaceAnimationDuration` 等均不存在，与 AGENTS.md 记录一致） |
| **`NSWorkspaceActiveSpaceDidChangeNotification`** | **未触发，0 次**（观察窗口 2.5 s，程序化切换） |

### 通知为 0 是真实结论，不是环境问题

做了对照实验：同一个 CLI 进程里注册 `NSWorkspace` 的多个通知，然后用 `NSWorkspace.openApplication` 启动 Calculator —— `didActivateApplication` 与 `didLaunchApplication` **都正常收到**。说明通知通道本身工作正常。

> **结论：程序化切换桌面不会触发 `activeSpaceDidChange` 通知。** 该通知大概率只在**用户主动切换**（Ctrl+←/→、Mission Control、点击 Dock 上的窗口）时发出。

### 决定

> **§3.1 的事件源主次必须反转：轮询为主（建议 300 ms），通知为辅（若用户主动切换时确实会触发，则可作为"快速通道"降低延迟）。**

- 计划原文写「`NSWorkspaceActiveSpaceDidChangeNotification`（主）+ 1 秒轮询（兜底）」，**对程序化切换完全不成立**，必须改。
- 轮询间隔从 1 s 收紧到 **300 ms**：因为切桌面本身只要 20 ms，1 s 的检测延迟会让"切桌面 → Dock 更新"明显滞后。300 ms 轮询的开销可忽略（一次 `CGSGetActiveSpace` + `CGSCopyManagedDisplaySpaces` 是纯内存调用）。
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

## 对 `docs/PLAN.md` 的修订清单

| 位置 | 原内容 | 修订为 |
| --- | --- | --- |
| §1 环境事实表 | `ManagedSpaceUUID` | `uuid`（另附 `Current Space` 可直取当前空间） |
| §3.1 | 通知为主 + 1 s 轮询兜底 | **轮询为主（300 ms）+ 通知为辅**；预应用升级为必需 |
| §3.5 | A/B 可能零闪烁；C 闪 0.3–1 s | A 彻底无效；B 实为重启但仅 ~100 ms 不可用；**主路径 = B**，C 兜底（~395 ms） |
| §3.6 | 合成 tile 用 `dock-extra:0` | 用户 App 用 `true`、启动台用 `false`（按真实域）；`_CFURLString` 必须带尾斜杠 |
| §4 P0 行 | 三实验并列 | 已完成，结论见本文 |
| §4 P2 行 | 待做 | ✅ 已完成（见本文实验 4 与 AGENTS.md §8 第 5 次记录） |
| §6 | 桌面"位置"含义待确认 | 仍未确认（与本文件无关，见 AGENTS.md §6） |

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
```

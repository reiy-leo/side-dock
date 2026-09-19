# MultiDock — 项目长期记忆（索引）

> macOS 多桌面工具，为每个 Space 绑定一套**原生 Dock** 配置。个人自用、本地运行、不公证不上架、
> ad-hoc 签名。界面中文，标识符英文。
>
> **技术细节不写在这里。** 权威副本是仓库里的三份文档，改代码前先读：
> - `AGENTS.md` —— 交接（§3 进度 / §4 环境事实 / §5 工程约定 / §6 待确认与未解决 / §8 会话记录）
> - `docs/PLAN.md` —— 设计与进度权威副本
> - `docs/spikes.md` —— **15 个实验**的实测结论，多处推翻 PLAN.md 的原始假设
>
> 本文件只留"读文档时容易漏、且代价高"的东西。

## 硬约束

**六条，原文在 `AGENTS.md` §2（权威副本，别只看这里）**：① 无痕原则（绝不永久改用户的 Dock，
退出还原 + 强杀自愈）；② 只用原生 Dock，不实现替代品；③ 菜单栏左键=下一个桌面、**⇧+左键=上一个**、
右键/⌥+左键=菜单；④ **零系统权限**（辅助功能 / 屏幕录制 / root 都不用，方案要权限先问用户）；
⑤ 桌面命名（≤10 字素簇，仅本地）+ 切换后屏幕中上部 **1 秒 toast**（已完成）；
⑥ **不做静默修改**（会改变使用习惯的系统设置如 `mru-spaces` 必须显式开关）。

## 明确"不做"（两条，有实测依据）

**切桌面的左右滑动动画**（spikes 实验 7）、**在 App 里新建 Dock 文件夹/文件条目**（实验 8，会让 Dock 崩溃循环）。只搬不造。

## 每轮必做（用户明确要求）

1. **更新文档**：`AGENTS.md` §3 / §4 / §6 / **§8（append-only，最新在最上面）**；设计有变 → `PLAN.md`；新实测 → `spikes.md`。
2. **`git commit` 一次**。提交前确认 1Password 在运行，且指对 socket：

```bash
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" git commit ...
```

`git log --show-signature` 的 "No signature" 只是**无法验证**；判据是 `git cat-file -p HEAD | grep '^gpgsig'`。**不要 `--no-gpg-sign`。**

## 环境与验收纪律

- macOS 15.7.9 (24G830) / x86_64 / **单显示器** / Swift 6.2.4。换机器重验 `AGENTS.md` §4。
- **`swift build` / `swift test` 必须 `--disable-sandbox`**（否则报 `sandbox_apply: Operation not permitted`，伪装成 `Invalid manifest`；`build-app.sh` 已内置）。⚠️ 即使加了**退出码也可能非 0**（`/Users/apple/.swiftpm/security (file-write-unlink)` 拦截），**判据只看 `Executed N tests, with 0 failures`**。
- **不能用截图验收**（无屏幕录制权限）。用 `multidock.log`、调试面板、`CGWindowListCopyWindowInfo` 或"Dock 是否给 tile 补 GUID"这类客观信号。
- **动 Dock 的改动跑真机验收**：`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`。**跑前 `defaults export com.apple.dock` 备份，中途别手动改 Dock**。
- `DockReloader` 单测一律传 `minimumSpacing: .zero`。

## 代价最高的几个坑（细节在 AGENTS.md §4）

- ⚠️⚠️ **协议要求返回 `T?` 时，具体实现必须逐字写 `T?`** —— 写成 `T` 会被当成另一个重载，见证位**由扩展里的默认实现（返回 `nil`）满足**：`(Real() as any P).m()` 恒为 nil，**生产路径静默失效而替身单测全绿**（2026-09-20 实测，让 A8 的取证仪表完全没接线）。**每加一条有默认实现的协议要求，就必须补一条"走 `any` 协议"的守卫测试**；已全仓审计，`pidProbe()` / `startTime(of:)` 两条都配了守卫，`readMRUSpaces()` 构造上安全。
- ⚠️ **别把"某段时间里 X 没发生"当结论** —— 先问"那段时间我**有能力**观察到 X 吗"。观测者自身的存活性也是证据：`elapsed` 是**墙钟**、轮询跑在 `@MainActor` 上，主线程被冻住时会**没在看**却记成"Dock 慢"。已补 `轮询 N 次，最长间隔 M ms`（M 秒级 = 观察窗口断了）。见 spikes 15.4。
- **发信号前必须拒绝 `pid <= 0` 并确认进程名是 `Dock`** —— Dock 重启窗口 `NSRunningApplication` 返回 `-1`，`kill(-1, sig)` = 杀掉当前用户全部进程。
- ⚠️ **别信"Dock 重启被罚是因为 uptime 太短"** —— 六个假说已被实验 12–14 / 15.3 / 15.4 逐个证伪。**`minimumSpacing` 保持 1 s、`dockPID()` 的 LS 优先都不要动**；A8 根因未定、**"我们的 bug"一侧已无候选**，已装取证仪表，**等它自己出现**。
- ⚠️ **用脚本核对 `config.json` 前先把真实键名打出来**（是 `pinnedApps` / `otherItems`，**不是** `apps` / `others`）—— 2026-09-20 因凭记忆写键名，把"3 个图标"读成"0 个"，据此写出一个**不存在的**损坏结论。
- ⚠️ **"内容看起来一样"≠"等价"** —— `effectiveConfig(for:) = binding(for:)?.override ?? settings.defaultDock` 是**整体替换**，不是逐字段合并。动手前先读代码。
- **另外四个老坑**（细节在 §4）：重载期间 `DockPresenceMonitor` **刻意静默**（日志空白是预期）；⚠️ **验"新代码有没有进 release 包"只能用字节搜索，不能用 `grep -a`** —— 含中文的模式**一律返回 0**（哪怕字符串明明在），短 ASCII 还会被小字符串优化吃掉，实测 `grep -ac "轮询"` → 0 而字节搜索 → 3；`withTaskGroup` 当"赛跑"用会让上限静默失效（要轮询可观察标志）；**配置损坏会自我固化**（残缺 override → 真实 Dock 残缺 → `DockWatcher` 合法回存 → 钉死）。**同一个文件不要在同一条消息里发两个编辑**（会静默丢一个）。

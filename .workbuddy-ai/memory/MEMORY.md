# MultiDock — 项目长期记忆（索引）

> **技术细节不写在这里。** 权威副本是仓库里的三份文档，改代码前先读，别靠这份记忆：
> - `AGENTS.md` —— 交接说明（§3 进度 / §4 环境事实 / §5 工程约定 / §6 待确认与未解决 / §8 会话记录）
> - `docs/PLAN.md` —— 设计与进度权威副本，实现变了必须同步
> - `docs/spikes.md` —— **11 个实验**的实测结论，多处推翻 PLAN.md 的原始假设
>
> 本文件只留"读文档时容易漏掉、且代价高"的东西。

## 项目性质

macOS 多桌面工具，为每个 Space 绑定一套**原生 Dock** 配置。个人自用、本地运行、不公证不上架、ad-hoc 签名。
界面中文，代码与标识符英文。

## 硬约束（用户明确要求，不可推翻）

1. **无痕原则**：App 绝不永久改变用户的 Dock。首次运行存基准快照，退出还原，强杀后下次启动自愈。
2. 只用原生 Dock，不实现替代品。
3. 菜单栏：左键=切下一个桌面，**⇧+左键=切上一个**，右键/⌥+左键=下拉菜单。左键改成"打开菜单"时 ⇧+左键一并走菜单。
4. 设置窗口两个 Tab：通用（默认 Dock）/ 桌面（逐桌面）。
5. **不需要任何系统权限**（辅助功能、屏幕录制、root 都不用）。方案开始要求权限 → 先问用户。
6. **桌面命名**（≤10 字素簇，仅存本地）+ **切换后在屏幕中上部弹 1 秒 toast**（不抢焦点、不挡点击）。已做完。
7. **不做静默修改**：会改变用户使用习惯的系统设置（如 `mru-spaces`）必须给显式开关，用户主动点击才改。

## 明确"不做"（有实测依据，别再试）

- **切桌面的左右滑动动画** —— 程序化切空间是硬切（0–6 ms）；SkyLight 不暴露带过渡的入口；
  会话级开关 `SLSSetSessionSwitchCubeAnimation` 写后读不回（破无痕）；`SLSWillSwitchSpaces` 猜签名直接段错误；
  合成按键事件被拦（阳性对照 `Cmd+Tab` 也不动）。见 spikes 实验 7。
- **在 App 里新建 Dock 文件夹 / 普通文件条目** —— Dock 不认领自拼的 `directory-tile`（不补 `GUID`），
  字段不全的形状会让 Dock **SIGABRT 进崩溃循环**。只搬不造，要加文件夹让用户去访达自己拖。见 spikes 实验 8。

## 用户要求的固定工作流（每次对话结束前必做）

1. **更新文档**：`AGENTS.md` §3 / §4 / §6 / **§8 会话记录（append-only，最新在最上面）**；
   设计有变 → `docs/PLAN.md`；新实测结论 → `docs/spikes.md`。
2. **`git commit` 一次**，提交信息说清做了什么。

**提交前先确认 1Password 在运行**（签名密钥由它托管），且要指对 socket：

```bash
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" git commit ...
```

`git log --show-signature` 显示 "No signature" 只是**无法验证**；判据是 `git cat-file -p HEAD | grep '^gpgsig'`。
**不要用 `--no-gpg-sign` 绕过。**

## 本机环境与验收纪律

- macOS 15.7.9 (24G830) / x86_64 / **单显示器** / Swift 6.2.4。换机器需重验 `AGENTS.md` §4。
- **`swift build` / `swift test` 必须加 `--disable-sandbox`**（SwiftPM 自带 sandbox 在本机报
  `sandbox_apply: Operation not permitted`，错误信息伪装成 `Invalid manifest`）。
- **不能用截图验收**（无屏幕录制权限，`screencapture` 只返回壁纸）。用 `multidock.log`、调试面板，
  或 `CGWindowListCopyWindowInfo` / "Dock 是否给 tile 补 GUID" 这类客观信号。
- 保持零警告构建；不接受"编译通过就算完成"，每个功能都要实测。
- **动 Dock 的改动跑真实验收**：`MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests`
  （会真的改 `com.apple.dock` 并重启 Dock 几十次，跑完自动还原）。**跑前先 `defaults export com.apple.dock` 备份，
  中途别手动改 Dock**（会报假失败）。
- **`DockReloader` 的单测都要传 `minimumSpacing: .zero`**，否则每个用例白等。
- 当前基线：**308 个测试通过、7 个跳过、零失败**。

## 高危踩坑（改代码前必看，细节在 AGENTS.md §4）

- **发信号前必须拒绝 `pid <= 0` 并确认进程名是 `Dock`** —— Dock 重启窗口里 `NSRunningApplication`
  会返回 `-1`，`kill(-1, sig)` = 杀掉当前用户**全部进程**。
- **`launchctl kickstart` 绝不能 `waitUntilExit()`** —— launchd 退避时它会阻塞几十秒，而这条在 `@MainActor` 上。
- ⚠️ **别信"Dock 重启被罚是因为 uptime 太短"** —— 这个假说（连同另外三个）已被实验 12–14 **实测证伪**：
  uptime 6 s 的重启只要 37–68 ms，`com.apple.Dock.plist` 里本来就是 `ThrottleInterval = 1`。
  **`minimumSpacing` 不要动。** 偶发的 26–31 s 根因未定，见 `docs/spikes.md` 实验 11.6。
- **`withTaskGroup` 当"赛跑"用会让上限静默失效**（返回值对、墙钟错）→ 带上限的等待必须**轮询可观察标志**，
  回归守卫要断言墙钟。
- **配置损坏会自我固化**：残缺 override 被 apply → 真实 Dock 真的变残缺 → `DockWatcher` 合法地把它当
  "用户手动改动"回存 → 钉死。修代码不会自动修数据。
- **同一个文件不要在同一条消息里发两个编辑** —— 会静默丢掉一个（症状是报错指向一个你明明写过的符号）。

# MultiDock

macOS 多桌面（Space）下，为每个桌面使用**不同的原生 Dock** 配置，切换桌面时自动切换 Dock。菜单栏常驻，单击图标切到下一个桌面，⇧+单击切上一个。

不替换 Dock、不画自己的 Dock 栏 —— 只改 `com.apple.dock` 偏好并重启原生 Dock 进程。

- 详细设计与实施计划：[docs/PLAN.md](docs/PLAN.md)
- P0 实测结论（**含对计划的多处修正**）：[docs/spikes.md](docs/spikes.md)
- 项目进度、开发约定与交接信息：[AGENTS.md](AGENTS.md)

---

## 当前状态

**P0（实验）～ P5（收尾）已完成并实测通过**，263 个单元测试全绿。

现在能做的：

- 识别所有桌面、菜单栏单击循环切换（⇧+单击往回切）、切完弹 1 秒的桌面名提示
- 给每个桌面配一套自己的 Dock（图标 + 位置 + 大小 + 外观），或沿用默认 Dock
- 设置页可视化编辑图标条（拖入 / 拖出 / 排序 / 从访达拖 `.app` 进来）
- **无痕**：退出自动还原、强杀后下次启动自愈、每次写 Dock 前自动备份

还没做的：

- **多显示器未真机验证**（本机只有一台屏；代码已就绪，需插一台外接屏实测）
- **切桌面没有过渡动画** —— 程序化切空间是瞬时硬切，且零权限下无解，**已定性为不做**（证据见 [docs/spikes.md](docs/spikes.md) 实验 7）

---

## 构建与运行

```bash
swift build -c release --disable-sandbox   # 编译（--disable-sandbox 在本机是必须的，见下）
swift test --disable-sandbox               # 263 个单元测试
./scripts/build-app.sh                     # 组装 build/MultiDock.app（ad-hoc 签名）
open build/MultiDock.app                   # 运行
```

必须打包成 `.app` 再运行：直接执行 `.build/release/MultiDock` 没有 bundle，菜单栏图标与登录项都会异常。

> **`--disable-sandbox` 不是可选项。** SwiftPM 自带的 `sandbox-exec` 在本机报 `sandbox_apply: Operation not permitted`，
> manifest 编译直接失败，错误信息是 `error: 'multi-dock': Invalid manifest` —— 看着像 `Package.swift` 坏了，其实是环境问题。

需要登录启动时，在 **设置 → 通用 → 启动与自愈** 里打开开关（默认关）。

---

## 怎么用

菜单栏出现一个 Dock 形状的图标，标题是当前桌面序号。

| 操作 | 行为 |
| --- | --- |
| **左键单击** | 切到下一个桌面（循环）。可在设置里改成"打开菜单" |
| **⇧+左键单击** | 切到上一个桌面（循环）。左键若设为"打开菜单"，这个也一并打开菜单 |
| **右键 / ⌥+左键** | 打开下拉菜单 |

下拉菜单：桌面列表（当前项打勾，点选即切）→ 下一个桌面 → 上一个桌面 → 用当前 Dock 重置本桌面配置 → 刷新桌面列表 → 立即还原到原始 Dock → 调试面板 / 设置 → **退出并还原 Dock**。

> 图标看不见？本机若开了「自动隐藏菜单栏」，把鼠标移到屏幕顶端即可。App 是 `LSUIElement`，不会出现在 Dock 里，也没有窗口。

### 设置 → 通用

- **默认 Dock**：图标条编辑区。访达与启动台固定在最前（访达在 plist 里根本没有条目，删不掉也无需处理）。可拖入/拖出/排序，或从访达拖 `.app` 进来
- **外观**：位置（下/左/右）、大小、放大、自动隐藏、最小化特效、最小化到应用图标、运行指示点。本机不支持的键会被禁用并说明原因，不做"能改但没反应"的假开关
- **应用**：立即应用 / 立即还原到原始 Dock / 把当前 Dock 设为新基准
- 另有：菜单栏交互、桌面切换提示、退出行为、启动与自愈、桌面行为（`mru-spaces`）、备份与还原、Dock 应用方式

### 设置 → 桌面

左侧是所有桌面（可就地改名，**最长 10 个字符**，仅存本地 —— macOS 15 没有桌面命名接口），右侧是该桌面的独立 Dock 配置：

- 「沿用默认 Dock」开关；关掉后可编辑该桌面自己的图标条与外观
- 「从当前真实 Dock 抓取」—— 把此刻 Dock 现状存成该桌面的配置，首次配置最省事
- 「复制默认 Dock 到本桌面」/「重置为默认」/「立即应用」

**默认 Dock 为空时不自动抓取、也不允许应用**（显示橙色警告 + 禁用按钮）。必须先点「从当前 Dock 抓取」，否则一点「立即应用」就会把 Dock 清空。

---

## 无痕原则（硬约束）

App 绝不永久改变你的 Dock。

1. **首次运行**把当时的 `com.apple.dock` 全量存为基准快照（`baseline.plist`），此后不覆盖
2. **正常退出**自动还原到基准（可在设置里关掉）
3. **被强杀 / 崩溃 / 断电**，下次启动检测到残留的 `session.state` 就会自动还原，并弹一条提示
4. **每次真正写 Dock 之前**都留一份全量备份（`backups/`，保留最近 20 份），可在设置页挑一份恢复

刚装完什么都不配置时，Dock 与安装前完全一致 —— 这条有实测：App 运行前后 `defaults export com.apple.dock` 逐键相同。

---

## 需要知道的几点

- **切换桌面时 Dock 会重启约 0.1 秒**（SIGHUP 实测 45–90 ms 不可用）。Dock **没有热重载**，改配置必须重启进程，没有零闪烁方案。两个桌面共用同一份 Dock 时会被短路，完全不重启
- 一次切换的**应用总耗时约 1 秒**，其中大部分是主动错开 launchd 重启节流的等待 —— 等待期间 Dock 是**可用**的。直接硬重启会让 Dock 消失一秒多，所以选了"宁等不闪"
- 识别与切换桌面依赖 **SkyLight 私有 API**（`CGSCopyManagedDisplaySpaces` / `CGSManagedDisplaySetCurrentSpace`），运行时 `dlopen` 加载、不链接私有框架。macOS 升级可能失效，失效时 App 会降级并在调试面板明确报警
- **零系统权限**：不需要辅助功能、屏幕录制、root。桌面名提示就是本 App 自己的一个无边框窗口
- **本机 `mru-spaces` 默认是开的**（系统按最近使用重排桌面顺序），会打乱"下一个桌面"的直觉。设置页给了显式开关，**只有你主动点才会改**
- 程序化切桌面不触发系统的空间变化通知，所以 App 用 300 ms 轮询识别桌面变化 —— 你自己用触控板/快捷键切桌面一样能识别、一样会弹提示

---

## 文件位置

全部在 `~/Library/Application Support/MultiDock/`：

| 文件 | 用途 |
| --- | --- |
| `baseline.plist` | 首次运行时对 `com.apple.dock` 全量域的只读备份，**此后不覆盖** |
| `config.json` | 桌面绑定与设置（原子写） |
| `session.state` | 会话标记；正常退出会删除，**残留即代表上次被强杀** |
| `multidock.log` | 运行日志（上限 512 KB），反馈问题时直接附上 |
| `backups/` | 写 Dock 前的全量域备份，保留最近 20 份 |

登录项若走了 LaunchAgent 兜底，还有一份 `~/Library/LaunchAgents/local.multidock.loginitem.plist`。

**调试面板**（菜单栏 → 调试面板…）显示当前 `spaceUUID` / `id64` / `type`、识别到的桌面列表、实时日志，以及上述文件的路径。

---

## 完全卸载与还原 Dock

### 第一步：让 App 把 Dock 还原回去

菜单栏 → **「退出并还原 Dock」**（或设置 → 通用 → 「立即还原到原始 Dock」）。这一步只写 Dock 的图标与外观键，不动热角、启动台网格等设置。

如果 App 已经不在运行、或你想**连同后来改过的其他 Dock 设置一起**回到最初状态，用基准快照整域还原：

```bash
defaults import com.apple.dock ~/Library/Application\ Support/MultiDock/baseline.plist
kill -HUP $(pgrep -x Dock)          # 信号致死才会被 launchd 拉回；不要 killall Dock
```

> `defaults import` 是**整域替换**，会把从装 App 到现在这段时间内你对 Dock 的所有改动（包括热角）一起回退。
> 这正是"完全还原"想要的；如果你只想还原图标和外观，用设置页那个按钮。

### 第二步：关掉登录启动

设置 → 通用 → 启动与自愈 → 关掉「登录时自动启动」。若 App 已经打不开：

```bash
rm -f ~/Library/LaunchAgents/local.multidock.loginitem.plist
```

### 第三步：删干净

```bash
rm -rf ~/Library/Application\ Support/MultiDock
rm -rf /path/to/MultiDock.app        # 默认在仓库的 build/MultiDock.app
```

三步走完，系统里没有任何残留：Dock 回到安装前的状态，登录项与数据目录都不在了。

---

## 故障排查

| 现象 | 先看这里 |
| --- | --- |
| 切了桌面 Dock 没变 | 调试面板看当前 `spaceUUID` 是否在列表里；`type` 非 0（全屏 App 空间）不参与切换 |
| 「立即应用」是灰的 | 默认 Dock 为空，先点「从当前 Dock 抓取」 |
| 菜单栏没有图标 | 本机可能开了自动隐藏菜单栏，把鼠标移到屏幕顶端 |
| 桌面名提示不弹 | 设置 → 通用 → 桌面切换 → 「切换桌面时显示桌面名称」是否开着；启动时首次采样和从全屏 App 退回桌面**故意不弹** |
| 启动后弹「已自动还原上次未还原的 Dock」 | 上次是强杀/崩溃退出的，App 已自动把 Dock 还原为基准。这是预期行为 |
| 桌面功能不可用 | SkyLight 私有 API 失效（通常发生在系统大版本升级后）。App 会降级为"只能手动改 Dock、不能自动跟随与切换"，调试面板会写明原因 |
| 别的都对不上 | 看 `~/Library/Application Support/MultiDock/multidock.log`，里面每条应用/还原都带了耗时与结果 |

---

## 开发

```bash
swift build -c release --disable-sandbox
swift test --disable-sandbox
```

**动 Dock 的改动必须跑真实验收**（会真的改 `com.apple.dock` 并重启 Dock 几十次，跑完自动还原）：

```bash
defaults export com.apple.dock /tmp/dock-backup.plist     # 先手工备份一次
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests
```

跑的时候**别手动改 Dock**，否则会报假失败。

其他约定（`--disable-sandbox`、1Password 签名的 git 提交、零警告构建、文档同步）都写在 [AGENTS.md](AGENTS.md)。

---

## 已知未做 / 待实测

- **切桌面没有过渡动画**（**已定性为不做**）：程序化切空间是瞬时硬切（实测 0–6 ms），
  SkyLight 没有暴露"带过渡地切到某空间"的入口；唯一像入口的会话级开关**写后读不回**（改了就还原不回去，违反无痕原则）；
  `SLSWillSwitchSpaces` 签名未知、猜错会直接段错误。零权限下无解，完整证据见 [docs/spikes.md](docs/spikes.md) 实验 7。
- **多显示器与热插拔**（唯一剩下的实测项）：映射键用了 `(displayUUID, spaceUUID)`，提示窗也按 `displayUUID` 定位到对应屏幕并有回落，
  插拔外接显示器后会自动重读桌面列表，但**只在一台显示器上开发，没有实测过插拔外接屏**。
  插上屏后开调试面板核对两件事就行：「显示器数量」对不对、每个桌面 `displayUUID` 前 8 位有没有串。
- **注销/关机时的还原**：系统不给等待时间，只能尽力（先留债务标记、下次启动自愈），未实测。
- 另外两项低优先级的：Dock 被外部弄死且 `launchctl` 也拉不回时只在日志里报，没有 UI 提示；
  SkyLight 私有 API 失效的报警只在调试面板，设置页没有横幅。

已实测过的（不用担心）：全屏 App 空间的过滤（真机回归通过）、编辑条竖排、孤儿绑定提示、回存撤销。

详见 [AGENTS.md](AGENTS.md) §3「未完成」与 §6.3。

# MultiDock

macOS 多桌面（Space）下，为每个桌面使用不同的原生 Dock 配置，切换桌面时自动切换 Dock。菜单栏常驻，单击图标切到下一个桌面。

- 详细设计与实施计划：[docs/PLAN.md](docs/PLAN.md)
- P0 实测结论（**含对计划的三处修正**）：[docs/spikes.md](docs/spikes.md)
- 项目进度、开发约定与交接信息：[AGENTS.md](AGENTS.md)

## 当前状态

**P0（实验）与 P1（骨架 + 桌面识别 + 菜单栏）已完成。** 现在可以：识别所有桌面、菜单栏单击循环切换、调试面板查看实时状态与日志。

**还不能**改 Dock —— 编辑条与配置应用属于 P2/P3。本阶段 App 全程不写任何 Dock 设置（已实测确认：运行前后 `com.apple.dock` 逐键相同）。

## 构建与运行

```bash
swift build -c release      # 编译
swift test                  # 运行单元测试
./scripts/build-app.sh      # 组装 build/MultiDock.app（ad-hoc 签名）
open build/MultiDock.app    # 运行
```

必须打包成 `.app` 后再运行：直接执行 `.build/release/MultiDock` 没有 bundle，菜单栏图标行为会异常。

也可以直接用 Xcode 打开 `Package.swift` 开发调试。

## 怎么用

菜单栏出现一个 Dock 形状的图标，标题是当前桌面序号。

- **左键单击** → 切到下一个桌面（循环）
- **右键** 或 **⌥ + 左键** → 下拉菜单：桌面列表（点选即切换）、下一个桌面、刷新桌面列表、调试面板、设置、退出

> 如果菜单栏图标看不见：本机若开了「自动隐藏菜单栏」，把鼠标移到屏幕顶端即可。另外 App 是 `LSUIElement`，不会出现在 Dock 里。

**调试面板**（菜单 → 调试面板…）显示当前 `spaceUUID` / `id64` / `type`、识别到的桌面列表、实时日志，以及基准快照、配置文件、日志文件的路径。

## 需要知道的几点

- 识别当前桌面、主动切换桌面依赖 SkyLight 私有 API（`CGSCopyManagedDisplaySpaces`、`CGSManagedDisplaySetCurrentSpace`），运行时 `dlopen` 加载，不链接私有框架。macOS 版本升级可能导致失效，失效时 App 会降级并在界面明确报警。
- 不需要辅助功能、屏幕录制或 root 权限。
- **切换桌面时 Dock 不会刷新** —— 本阶段根本不改 Dock。等 P2 之后才会，届时的代价是 Dock 刷新约 0.1 秒（见 `docs/spikes.md`：Dock 没有热重载，改配置必须重启 Dock 进程）。
- **无痕原则**：首次运行会把当前 Dock 完整存为基准快照，退出时自动还原；被强杀或崩溃后，下次启动也会检测并还原。安装后不做任何配置时，Dock 与安装前完全一致。（还原动作在 P4 接上；本阶段因为完全不写 Dock，所以无需还原。）

## 文件位置

全部在 `~/Library/Application Support/MultiDock/`：

| 文件 | 用途 |
| --- | --- |
| `baseline.plist` | 首次运行时对 `com.apple.dock` 全量域的只读备份，**此后不覆盖** |
| `config.json` | 桌面绑定与设置（原子写） |
| `session.state` | 会话标记；正常退出会删除，残留即代表上次被强杀 |
| `multidock.log` | 运行日志（上限 512 KB），反馈问题时直接附上 |
| `backups/` | 写 Dock 前的全量域备份，保留最近 20 份 |

## 卸载与还原 Dock

本阶段 App 不写 Dock，所以卸载不影响 Dock。等 P2 之后如果 Dock 状态不对，可以：

```bash
# 用基准快照还原
defaults import com.apple.dock ~/Library/Application\ Support/MultiDock/baseline.plist
# 让 Dock 重新读取（信号致死才会被 launchd 拉回）
kill -HUP $(pgrep -x Dock)
```

彻底删除本 App 的数据：

```bash
rm -rf ~/Library/Application\ Support/MultiDock
```

（P5 会把这一节补成完整的卸载流程。）

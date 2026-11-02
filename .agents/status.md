# 项目现状（交接用）

新 session 先读这份，再按需翻 `AGENTS.md`（入口、硬约束、致命陷阱）和 `docs/`（设计、实验、事实、约定、会话史）。这份只讲「现在到哪了、还欠什么、代码大致怎么组织」，细节以那几份为准。

更新于 2026-11-02，对应 `main` 的 `3d43a2b`。

## 一、项目是什么

- **Side Dock（中文名：侧边坞，原名 MultiDock）**，仓库 `reiy-leo/side-dock`（公开）。macOS 菜单栏 App，给每个桌面（Space）一套自己的 Dock。
- 做法：原生 Dock 在所有桌面保持一样（「冻结」默认开），每个桌面多出来的 App 放在自己画的「次级 Dock 条」里。条可以绑桌面、放底 / 左 / 右，默认半露，鼠标碰到才滑出。
- 无痕原则：App 绝不永久改用户的 Dock。首次运行存基准快照，退出时还原；崩溃了下次启动自愈。
- 其他功能：菜单栏单击切桌面、桌面命名和切换后大字显示、启动台文件夹导入、配置导出导入、云盘文件夹同步。
- 技术栈：Swift Package（swift-tools 6.0），macOS 14+，SwiftUI + AppKit，私有 SkyLight API 用 `dlopen` 调。不签名不公证（ad-hoc），个人自用。
- 界面中英双语，调用点写 `L("中文", "English")`。
- **对外名字改了，内部没改**：模块名 / target / 可执行文件 `MultiDock`、bundle ID `local.multidock`、配置目录 `~/Library/Application Support/MultiDock/` 都刻意保留，改了会丢用户配置和登录项。

## 二、版本和分支

- 最新版本：预发布 `v0.2.1-alpha.2`（`Support/Info.plist` 0.2.1，build 10，2026-10-26）。最新正式版 `v0.2.0`（build 8，2026-10-24）。下一版 build 11。
- **发版前必须先问 Rei**，不要自己打 tag。
- 发版做法：改 `Support/Info.plist` 版本（保持纯数字）→ 打 tag `vX.Y.Z` → 推 `main` 和 tag。CI 在 arm64 / x86_64 两种 runner 上测试、打包，自动建 Release，附 `SideDock-v<版本>-<架构>.dmg` 和 `.zip` 共 4 个文件。tag 带 `-`（如 `-alpha.2`）自动标成预发布，App 里的更新检查不推。
- 分支：只有 `main`，直接在上面开发（Rei 2026-10-26 定）。`feat/multi-row-dock` 已合并并删除，不要再建。
- `v0.2.1-alpha.2` 之后 `main` 上没有新代码。

## 三、已经做完的功能

| 模块 | 现状 | 细节 |
|---|---|---|
| 冻结原生 Dock | 默认开：切桌面不写 Dock、不重启 Dock；原生 Dock 归用户自己 | `docs/PLAN.md` §3.12，`AGENTS.md` §1 |
| 无痕与自愈 | 基准快照、退出还原、崩溃后下次启动还原、备份轮转 20 份 | `docs/PLAN.md` §3.3、§3.9 |
| 次级 Dock 条 | 默认 5 根栏，可增删改名；绑桌面（一桌面一栏，同桌面同边最多 3 根）、位置底 / 左 / 右；半露 + 悬停滑出；独立贴边时离屏幕边 6 pt | `docs/PLAN.md` §3.12 |
| 多行条 | 条只显示一行，滚动一次切一行（0.35 s 冷却），末端圆点表示行数；收起后记住上次那一行 | `docs/PLAN.md` §3.12.x |
| 条的细节 | 悬停放大（跟随系统设置）、悬停出名字、点未运行的 App 会弹跳、拖出一定距离松手移除、右键改位置、避开台前调度那条边（那一项灰掉标「台前调度」） | `docs/sessions.md` 2026-10-23、10-24 两条 |
| 切桌面时条的表现 | 手势一开始就隐藏条，切完从底部 0.12 s 升起；没切成就渐回 | `docs/spikes.md` 实验 25、27 |
| 菜单栏 | 单击下一个桌面、⇧ 单击上一个、右键 / ⌥ 单击出菜单；图标 Lucide 五选一 | `AGENTS.md` §2 第 3 条 |
| 切桌面动画 | 可选，默认关；要辅助功能权限，合成系统快捷键（相邻 ⌃←/⌃→，跨桌面用「切换到桌面 N」），快捷键没开就硬切 | `docs/sessions.md` 2026-10-25 条 |
| 桌面命名 | 名字最多 10 个字，只存本机；切换后锁屏式大字显示 1 秒，位置顶 / 中 / 底，背景效果三档 | `docs/PLAN.md` §3.10 |
| 启动台页 | 只读启动台数据库，列出文件夹，可「添加到」或「替换」某根栏；macOS 26 起页面禁用 | `docs/PLAN.md` §3.13 |
| 原生固定 App 排除 | 原生 Dock 里已有的 App 不进自定义栏（冻结模式才生效） | `AGENTS.md` §3「原生固定 App 排除」 |
| 配置导出导入 | 数据页导出 / 导入，导入和启动加载走同一套归一化 | `docs/PLAN.md` §3.7 |
| 配置同步 | 同步到用户选的文件夹（Google Drive 桌面版或挂载的 WebDAV）；每台 Mac 只写 `SideDock/<硬件 UUID>.json`；别的 Mac 手动导入，按「第几块屏 · 第几个桌面」映射 | `docs/PLAN.md` §3.14，`docs/rules.md`「2026-10-26 配置同步」 |
| 缺 App 过滤 | 原路径没了先按 bundle ID 找；找不到就不画、不写进原生 Dock，配置保留，编辑器标灰 | 同上 |
| 文档 | Wiki 双语（英文默认，中文在 `wiki/zh/`），由 Actions 同步；README 只留简介 | `AGENTS.md` 顶部说明 |

## 四、代码怎么组织（快速地图）

源码都在 `Sources/MultiDock/`，详细的模块表在 `AGENTS.md` §3「模块地图」。

| 目录 | 放什么 |
|---|---|
| `App/` | 入口委托、全局状态 `AppState`（含 `AppState+Sync.swift`）、生命周期与自愈、落盘日志、登录启动、`L10n` |
| `Dock/` | 写原生 Dock 的流水线、Dock 重载（SIGHUP → kickstart）、手动改动回存、Dock 存活监视、栏模型、次级条布局、多行翻页 `SecondaryDockRowPager`、`AppLocator` |
| `Spaces/` | 私有 API 桥、桌面列表与轮询、切换（含合成快捷键动画）、手势预隐藏监视、桌面命名 |
| `Store/` | `config.json`、基准快照与备份、`ConfigSync`、`DeviceIdentity`（硬件 UUID） |
| `Launchpad/` | 只读启动台 SQLite 库、解析、导入规则 |
| `UI/` | 菜单栏、设置窗口七页（通用 / 菜单栏 / 应用栏 / 桌面 / 启动台 / 数据 / 关于）、次级条窗口和视图、桌面名大字、HUD |

其他：

- `Tests/MultiDockTests/`：测试函数约 577 个（按源码数的，以 CI 为准）。真机 Dock 验收、离屏 UI 快照、启动台只读验收默认跳过，要设环境变量才跑。
- `scripts/`：`build-app.sh` 打包、`make-app-icon.swift` 出图标，其余是实验脚本。
- `.github/workflows/ci.yml`：推 `main`（和 `feat/**`）、PR、`v*` tag 时跑；`wiki.yml`：推 `wiki/**` 时渲染设置截图并同步到 Wiki。
- `wiki/`：Wiki 的唯一来源，别在网页上改。

## 五、开发和验证的规矩

- 沙箱是 Linux，**编译不了也跑不了测试**。验证全靠 CI，或者通过 tailcat 远程到 Rei 的 Mac（2018 Intel MBP，macOS 15.8.1，Xcode 26.3）跑。
- 本地命令：`swift build -c release --disable-sandbox`、`swift test --disable-sandbox`、`./scripts/build-app.sh`。`--disable-sandbox` 必须加。
- 动 Dock 相关代码前，先读 `AGENTS.md` §5 的 17 条致命陷阱（`-1` PID、kickstart 阻塞、animator alpha 失效等，每条都真踩过）。
- 每次结束按 `AGENTS.md` §0：更新文档，`docs/sessions.md` 追加一条（最新在上），再提交。
- 提交身份：仓库里配好了 Ryan Lincs。Rei 本机用 1Password 签名；沙箱推的提交和 tag 不带签名。
- 推送：先 `sudo -n apt-get update && sudo -n apt-get install -y openssh-client`（沙箱重置后会丢），再用部署密钥 `/workspace/.keys/side-dock_deploy`。GitHub connector 开 PR、手动触发 workflow 都返回 403 禁止访问。
- 中文文档按 zh-writing 写；提交前跑 `pnpm lint:zh`（沙箱用 `/workspace/.tools/autocorrect --lint`）。界面文案 `L()` 里的中文要改先问 Rei。
- 新文案必须走 `L()`，有源码扫描测试拦。图标用 Lucide。`AppSettings` 加字段要同时补 `decodeIfPresent`。
- 未经 Rei 要求不改代码、不推送、不发版。

## 六、没做完 / 等 Rei 的事

### 等 Rei 动手

- **真机手测**：A11（次级条手感、手势预隐藏）、A12（栏位置和绑定）、A13（设置各页）、A14（启动台页）、A15（多行条）、A16（悬停名称、台前调度避让、放大点击穿透）、A17（配置同步六项）。步骤都在 `AGENTS.md` §3。
- 切桌面动画：确认真机上真有滑动动画（`812cccb`）。
- 底板材质和描边：和原生 Dock 对比，可用 `defaults write local.multidock SecondaryDockMaterial -int <值>` 换材质。
- 等条件的：B5 多显示器热插拔、B8 Finder 移除、B9 / B10 注销和重登录、A8 偶发慢重启（只等复现，别主动折腾）。
- 侧边坞的桌面实景截图，给 Wiki 和 README 用。
- 想做 Google 登录同步时：在 Google Cloud 建「桌面应用」类型的 OAuth 客户端，开 Google Drive API，把 `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` 放进仓库 Actions secrets。

### 等 Rei 拍板

- **Google Drive appDataFolder 同步**（2026-10-26 提出，没开工）：Rei 想要的是隐藏的应用数据夹，不是自己选文件夹。待定：只留 appDataFolder，还是和文件夹同步并存。
- 同步的四个默认做法（`AGENTS.md` §6.1 #6）：选了文件夹默认开自动同步；只各写各的、不自动拉取；本机「从云端恢复」也弹确认；未冻结模式回存时缺的 App 会从栏里掉。
- `AGENTS.md` §6.1 #1、#2、#3、#5：自愈后要不要弹提示、登录启动默认开不开、文件夹类条目只能排序不能新建、显示次级条和冻结两个开关没有界面入口。
- `pnpm lint:zh` 要不要接进 CI 当失败门槛。
- 界面里最难懂的 5 条中文文案要不要改（2026-10-25 列过建议，见会话记录）。

### 我们这边还能做的

- Rei 定了以后实现 appDataFolder 同步：OAuth 桌面客户端 + PKCE + `127.0.0.1` 回调，scope 只要 `drive.appdata`，refresh token 存钥匙串；Client ID / Secret 由 CI 从 secrets 写进 App，设置里留输入框给本地构建用；文件仍按 `<硬件 UUID>.json` 分设备。
## 七、写了但从没在真机上跑过的

沙箱编译不了，下面这些只过了 CI 测试，没人在真机上点过：

- 配置同步全套和缺 App 过滤（A17）。
- 切桌面动画（合成快捷键）。
- 底板材质 `.fullScreenUI` + 双描边、拖出移除。
- 悬停名称的修法、放大时透明区点击穿透（A16）。
- 2026-10-24 那批修复：条长度按当前行、屏幕边缝隙弹跳、台前调度那条边灰掉、悬停放大时圆点被盖住。Rei 当天在 alpha 上看过一部分问题，修好后没再确认。
- 更早的 A1–A3、A5、A11–A15 逻辑都有单测，差真人点。

## 八、项目外的东西（不在仓库里）

- Hark 项目「side-dock」：仓库副本在 `repo/`；`zhwork/` 是 2026-10-25 中文改写的临时文件和守门脚本 `check.py`（比对代码、链接、数字是否被改），可以删。
- 沙箱工具：`/workspace/.tools/autocorrect`（AutoCorrect Rust CLI，npm 包没有 linux-arm64 版本）。
- 推送用的部署密钥：`/workspace/.keys/side-dock_deploy`；连 Rei 的 Mac 用的 tailcat 地址也在 `/workspace/.keys/`。
- Wiki 推不了：沙箱代理会把 github.com 的认证换成 connector 令牌，所以 Wiki 只能由 `wiki.yml` 用 `GITHUB_TOKEN` 同步。
- Rei 本机：用户日志 `~/Library/Application Support/MultiDock/multidock.log` 是核对真机行为的唯一凭据，测试别写进去；包管理用 MacPorts，别随便 `brew install`（Intel Mac 会从源码编译卡死）。
- 部署：没有服务器，只有 GitHub Releases 和 Wiki。

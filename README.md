# Side Dock（侧边坞）

macOS 多桌面（Space）菜单栏工具：**原生 Dock 全桌面保持一致，每个桌面的差异由贴在屏幕边的「侧边坞」呈现**。
不替换原生 Dock、不改它的偏好，切桌面零写入零重启；退出即还原，无痕。

- **每个桌面一套自己的 App 栏**：贴在 Dock 内侧或独立贴在屏幕左 / 右 / 下边，半露、悬停滑出
- **一个桌面多根栏**：同一条边最多 3 根，双指滚动切行，末端圆点指示当前行
- **像原生 Dock 的手感**：悬停放大、显示名称、点击未运行的 App 弹跳、拖出条外即移除
- **菜单栏一键切桌面**：单击下一个、⇧+单击上一个，切完大字提示桌面名；可选系统滑动动画
- **启动台导入**（macOS 26 以下）：把启动台文件夹一键加到某根栏
- **零系统权限、无痕**：退出自动还原，强杀后下次启动自愈

<p>
  <img src="https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-app-bars-light.png" width="49%" alt="设置 · 应用栏">
  <img src="https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-desktop-light.png" width="49%" alt="设置 · 桌面">
</p>

## 下载

[GitHub Releases](https://github.com/reiy-leo/side-dock/releases/latest) 里按机器选：Apple Silicon 用 `arm64`，Intel 用 `x86_64`（DMG 或 zip 都行）。
App 只做 ad-hoc 签名，首次打开请右键 →「打开」。详见 [下载与安装](https://github.com/reiy-leo/side-dock/wiki/下载与安装)。

## 文档

完整说明在 **[Wiki](https://github.com/reiy-leo/side-dock/wiki)**：[使用指南](https://github.com/reiy-leo/side-dock/wiki/使用指南) · [切换动画](https://github.com/reiy-leo/side-dock/wiki/切换动画) · [无痕原则](https://github.com/reiy-leo/side-dock/wiki/无痕原则) ·
[卸载与还原](https://github.com/reiy-leo/side-dock/wiki/卸载与还原) · [故障排查](https://github.com/reiy-leo/side-dock/wiki/故障排查) · [构建与开发](https://github.com/reiy-leo/side-dock/wiki/构建与开发) · [已知限制](https://github.com/reiy-leo/side-dock/wiki/已知限制)。

设计与实验记录：[docs/PLAN.md](docs/PLAN.md)、[docs/spikes.md](docs/spikes.md)；开发交接：[AGENTS.md](AGENTS.md)。
Wiki 源文件在仓库 [`wiki/`](wiki/) 目录，推送后由 Actions 自动同步。

# Side Dock（侧边坞）

[English](README.md) | **中文**

macOS 多桌面（Space）菜单栏工具。**原生 Dock 在所有桌面都一样，每个桌面各自的 App 放在屏幕边上的「侧边坞」里。**
它不替换原生 Dock，也不改 Dock 的偏好；切桌面时什么都不写，什么都不重启。退出就还原，不留痕迹。

- **每个桌面有自己的 App 栏**：贴在 Dock 内侧，或单独贴在屏幕左、右、下边；平时露一半，鼠标移上去就滑出来
- **一个桌面可以有多根栏**：同一条边最多 3 根，双指滚动切行，末端圆点告诉你在第几行
- **手感像原生 Dock**：悬停放大、显示名称，点没开的 App 会弹跳，把图标拖出条外就删掉
- **点菜单栏切桌面**：单击去下一个，⇧+单击回上一个，切完用大字显示桌面名；也可以打开系统的滑动动画
- **导入启动台**（macOS 26 以下）：一键把启动台里的文件夹加到某根栏
- **不要系统权限，不留痕迹**：退出自动还原，被强杀后下次启动自己修好

<p>
  <img src="https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-app-bars-light.png" width="49%" alt="设置 · 应用栏">
  <img src="https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-desktop-light.png" width="49%" alt="设置 · 桌面">
</p>

## 下载

到 [GitHub Releases](https://github.com/reiy-leo/side-dock/releases/latest) 按机器选：Apple Silicon 选 `arm64`，Intel 选 `x86_64`，DMG 和 zip 都行。
App 只做了 ad-hoc 签名，第一次打开要右键 →「打开」。详见 [下载与安装](https://github.com/reiy-leo/side-dock/wiki/下载与安装)。

## 文档

完整说明在 **[Wiki](https://github.com/reiy-leo/side-dock/wiki/首页)**：[使用指南](https://github.com/reiy-leo/side-dock/wiki/使用指南) · [切换动画](https://github.com/reiy-leo/side-dock/wiki/切换动画) · [无痕原则](https://github.com/reiy-leo/side-dock/wiki/无痕原则) ·
[卸载与还原](https://github.com/reiy-leo/side-dock/wiki/卸载与还原) · [故障排查](https://github.com/reiy-leo/side-dock/wiki/故障排查) · [构建与开发](https://github.com/reiy-leo/side-dock/wiki/构建与开发) · [已知限制](https://github.com/reiy-leo/side-dock/wiki/已知限制)。

设计和实验记录看 [docs/PLAN.md](docs/PLAN.md)、[docs/spikes.md](docs/spikes.md)；开发交接看 [AGENTS.md](AGENTS.md)。
Wiki 的源文件在仓库的 [`wiki/`](wiki/) 目录，推送后 Actions 会自动同步。

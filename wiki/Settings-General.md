**English** | [[中文|设置-通用]]

![Settings · General](https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-en-general.png)

- **Default Dock**: the icon bar editor. Finder and Launchpad are pinned first (Finder has no entry in the plist at all, so it can't be removed and needs no handling). Drag in / out / reorder, or drop `.app` files from Finder
- **Other items (folders / stacks)**: folders on the real Dock (e.g. Downloads) are listed in a row below; reorder by dragging, remove via right-click or by dragging to the trash. **They can't be created here** — testing showed the Dock won't adopt folder entries the app builds itself (see [[Known Limitations|Known-Limitations]]). To add a folder, drag it onto the Dock in Finder and the app records it in the current desktop's configuration
- **Appearance**: position (bottom / left / right), size, magnification, auto-hide, minimize effect, minimize into app icon, running indicators. Keys this Mac doesn't support are disabled with the reason — no switches that "change but do nothing"
- **Side dock** (the "Side Dock Bars" section; each bar's position is changed on the App Bars page or from the bar's right-click menu):
  - **Show side dock** (on by default): a self-drawn icon bar just inside the native Dock, half-visible until you hover and it slides out;
    its contents follow the current desktop and swap instantly; it shows and hides with the native Dock
  - **Freeze per-desktop native Dock switching** (on by default): the native Dock keeps one fixed configuration and never restarts on switch;
    per-desktop differences are shown by the side dock. Turn it off to go back to "one native Dock per desktop"
- **Apply**: Apply Now / Restore Original Dock Now / Make Current Dock the New Baseline
- Also: menu bar interaction, desktop switch banner, quit behaviour, launch and self-heal, desktop behaviour (`mru-spaces`), backup and restore, how the Dock is applied

# Side Dock

**English** | [中文](README.zh-CN.md)

A macOS menu bar tool for multiple desktops (Spaces): **the native Dock stays the same on every desktop, and what differs per desktop lives in a "side dock" pinned to the screen edge.**
It doesn't replace the native Dock or change its preferences; switching desktops writes nothing and restarts nothing. Quit and everything is restored — no trace left.

- **Each desktop gets its own app bars**: inside the native Dock or free-standing on the left / right / bottom edge, half-visible, sliding out on hover
- **Multiple bars per desktop**: up to 3 per edge; two-finger scroll switches rows, with dots showing the current one
- **Feels like the native Dock**: hover magnification, app names, launch bounce, drag an icon off to remove it
- **Switch desktops from the menu bar**: click for next, ⇧-click for previous, with a big desktop name banner; optional system slide animation
- **Launchpad import** (below macOS 26): add a Launchpad folder to a bar in one click
- **No permissions, no trace**: restores on quit, self-heals after a force quit

<p>
  <img src="https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-en-app-bars.png" width="49%" alt="Settings · App Bars">
  <img src="https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-en-desktop.png" width="49%" alt="Settings · Desktops">
</p>

## Download

Get it from [GitHub Releases](https://github.com/reiy-leo/side-dock/releases/latest): `arm64` for Apple Silicon, `x86_64` for Intel (DMG or zip).
The app is only ad-hoc signed — right-click → Open the first time. See [Download and Install](https://github.com/reiy-leo/side-dock/wiki/Download-and-Install).

## Docs

Everything else is in the **[Wiki](https://github.com/reiy-leo/side-dock/wiki)**: [User Guide](https://github.com/reiy-leo/side-dock/wiki/User-Guide) · [Switch Animation](https://github.com/reiy-leo/side-dock/wiki/Switch-Animation) · [No-Trace Principle](https://github.com/reiy-leo/side-dock/wiki/No-Trace-Principle) ·
[Uninstall and Restore](https://github.com/reiy-leo/side-dock/wiki/Uninstall-and-Restore) · [Troubleshooting](https://github.com/reiy-leo/side-dock/wiki/Troubleshooting) · [Building and Development](https://github.com/reiy-leo/side-dock/wiki/Building-and-Development) · [Known Limitations](https://github.com/reiy-leo/side-dock/wiki/Known-Limitations).

Design and experiment notes: [docs/PLAN.md](docs/PLAN.md), [docs/spikes.md](docs/spikes.md) (Chinese); developer handoff: [AGENTS.md](AGENTS.md).
Wiki sources live in [`wiki/`](wiki/) (English at the root, Chinese in `wiki/zh/`) and sync via Actions on push.

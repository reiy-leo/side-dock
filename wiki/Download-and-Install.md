**English** | [[中文|下载与安装]]

The latest release is on [GitHub Releases](https://github.com/reiy-leo/side-dock/releases/latest).
Pick the package for your Mac (each release ships two native architectures, as DMG or zip): open the DMG and drag `Side Dock.app` into Applications, or unzip and drag it in.

- **Apple Silicon (M series)**: `SideDock-vX.Y.Z-arm64.dmg` (or `.zip`)
- **Intel**: `SideDock-vX.Y.Z-x86_64.dmg` (or `.zip`)

> Upgrading from MultiDock: delete the old `MultiDock.app`, then install `Side Dock.app`. If you had "Launch at login" on, turn it off and on again in Settings.

> Both packages are built and architecture-checked by GitHub Actions on two native runners (see [.github/workflows/ci.yml](https://github.com/reiy-leo/side-dock/blob/main/.github/workflows/ci.yml)).

> The app is **ad-hoc signed and not notarized**, so Gatekeeper blocks the first launch:
> right-click the app → Open → Open again in the dialog; or run
> `xattr -dr com.apple.quarantine "/Applications/Side Dock.app"`.

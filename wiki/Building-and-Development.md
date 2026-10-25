**English** | [[中文|构建与开发]]

```bash
swift build -c release --disable-sandbox   # build (--disable-sandbox is required on this machine, see below)
swift test --disable-sandbox               # all unit tests
./scripts/build-app.sh                     # assemble build/Side Dock.app (ad-hoc signed)
open "build/Side Dock.app"                 # run
```

Run it as a packaged `.app`: executing `.build/release/MultiDock` directly has no bundle, so the menu bar icon and login item misbehave.

> **`--disable-sandbox` is not optional.** SwiftPM's built-in `sandbox-exec` fails here with `sandbox_apply: Operation not permitted`,
> and the manifest fails to compile with `error: 'multi-dock': Invalid manifest` — it looks like a broken `Package.swift` but is an environment problem.

For launch at login, turn on the switch under **Settings → General → Launch and Self-heal** (off by default).

## Development and acceptance

```bash
swift build -c release --disable-sandbox
swift test --disable-sandbox
```

**Changes that touch the Dock must run the real acceptance tests** (they really modify `com.apple.dock` and restart the Dock dozens of times, restoring afterwards):

```bash
defaults export com.apple.dock /tmp/dock-backup.plist     # make a manual backup first
MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --disable-sandbox --filter DockAcceptanceTests
```

**Don't touch the Dock while it runs**, or you'll get false failures.

Other conventions (`--disable-sandbox`, 1Password-signed git commits, zero-warning builds, keeping docs in sync) are in [AGENTS.md](https://github.com/reiy-leo/side-dock/blob/main/AGENTS.md).

The wiki itself is generated from the repo's [`wiki/`](https://github.com/reiy-leo/side-dock/tree/main/wiki) folder by `.github/workflows/wiki.yml`; don't edit pages on the web.

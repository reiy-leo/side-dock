**English** | [[中文|文件位置]]

Everything lives in `~/Library/Application Support/MultiDock/`:

| File | Purpose |
| --- | --- |
| `baseline.plist` | Read-only backup of the whole `com.apple.dock` domain from the first run, **never overwritten** |
| `config.json` | Desktop bindings and settings (written atomically) |
| `session.state` | Session marker; deleted on a normal quit, **left behind means the last run was force-quit** |
| `multidock.log` | Runtime log (capped at 512 KB) — attach it when reporting a problem |
| `backups/` | Full-domain backups taken before Dock writes, latest 20 kept |
| `sync-settings.json` | Sync settings (chosen sync folder, auto-sync switch); stays on this Mac, never synced |
| `device-id` | Only if the hardware UUID can't be read: this Mac's sync ID |

With sync on, the cloud folder also has `SideDock/<hardware UUID>.json`; see [[Settings: Data & Sync|Settings-Data]].

If launch at login fell back to a LaunchAgent, there's also `~/Library/LaunchAgents/local.multidock.loginitem.plist`.

The **Debug Panel** (menu bar → Debug Panel…) shows the current `spaceUUID` / `id64` / `type`, the detected desktops, a live log, and the paths of the files above.

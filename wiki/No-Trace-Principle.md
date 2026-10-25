**English** | [[中文|无痕原则]]

The app never permanently changes your Dock.

1. **On first run** it saves the whole `com.apple.dock` domain as a baseline snapshot (`baseline.plist`) and never overwrites it
2. **On a normal quit** it restores the baseline automatically (can be turned off in Settings)
3. **After a force quit / crash / power loss**, the next launch finds the leftover `session.state`, restores automatically and shows a notice
4. **Before every real Dock write** it keeps a full backup (`backups/`, the latest 20), which you can restore from Settings

Installed with nothing configured, the Dock is exactly as before — verified: `defaults export com.apple.dock` is key-for-key identical before and after running the app.

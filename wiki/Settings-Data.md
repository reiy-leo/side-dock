**English** | [[中文|设置-数据]]

The Data page holds three things: export / import a config file, sync to a cloud folder, and Dock backups.

## Config file

- **Export Config…** saves every setting (Dock bars, bindings, desktop names, switches) as one JSON file, same format as `config.json`
- **Import Config…** replaces the whole configuration with the file's content. Side dock bars update right away; the native Dock follows via "Apply", a desktop switch or the next launch

## Sync

Each Mac keeps **its own copy** in a folder you choose. Macs never overwrite each other.

Google Drive has no official WebDAV, so Side Dock doesn't talk to any cloud service directly. It only reads and writes files in a folder; your cloud client does the uploading. Any of these works:

- Google Drive for desktop: `~/Library/CloudStorage/GoogleDrive-…/My Drive`
- iCloud Drive, Dropbox
- A WebDAV volume mounted in Finder (Go → Connect to Server)

How to use it:

1. Click **Choose…** next to "Sync Folder" and pick a folder in your cloud drive
2. Leave **Sync Automatically** on: about 2 seconds after any settings change, this Mac writes its own file. If nothing changed, the file isn't rewritten
3. Or click **Sync Now** at any time

Each Mac writes only `<folder>/SideDock/<hardware UUID>.json`, and never writes or deletes another Mac's file. The file holds the computer name, app version, time written, and the same content as `config.json`.

What doesn't sync: the baseline snapshot, backups, session marker, `mru-spaces`, the login item, the sync settings themselves, and which row each side dock bar was last scrolled to.

The list under the buttons shows every Mac's copy in the folder:

- **Restore from Cloud** (this Mac's copy): replaces this Mac's settings with the cloud copy
- **Import to This Mac** (another Mac's copy): replaces all settings on this Mac, after a confirmation

Desktop IDs never match across Macs, so imported bindings are matched **by order**: the Nth desktop on the Nth display (main display first). Bars that don't match keep their old binding and show up as orphans; unbind them on the App Bars page.

Apps that aren't installed on this Mac stay in the config. The side dock doesn't draw them, and they're skipped when writing the native Dock (no question-mark icons). If the app moved, it's found again by bundle ID. The bar editor still shows missing apps greyed out.

If the folder can't be found (cloud client not running, volume not mounted), the page says so and nothing is written.

## Backups & Restore

A full Dock backup is kept before every real Dock write, up to 20. Restoring only overwrites Dock contents (icons and so on), not hot corners or the Launchpad layout.

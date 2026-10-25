**English** | [[中文|卸载与还原]]

## Step 1: let the app restore your Dock

Menu bar → **Quit and Restore Dock** (or Settings → General → Restore Original Dock Now). This only writes the Dock's icon and appearance keys; hot corners, Launchpad grid and the like are untouched.

If the app is no longer running, or you want to go back to the original state **including other Dock settings changed since**, restore the whole domain from the baseline:

```bash
defaults import com.apple.dock ~/Library/Application\ Support/MultiDock/baseline.plist
kill -HUP $(pgrep -x Dock)          # only a fatal signal makes launchd relaunch it; don't use killall Dock
```

> `defaults import` **replaces the whole domain**, rolling back every Dock change since the app was installed (hot corners included).
> That's what a full restore means; to restore only icons and appearance, use the button in Settings.

## Step 2: turn off launch at login

Settings → General → Launch and Self-heal → turn off "Launch at login". If the app won't open:

```bash
rm -f ~/Library/LaunchAgents/local.multidock.loginitem.plist
```

## Step 3: remove everything

```bash
rm -rf ~/Library/Application\ Support/MultiDock
rm -rf "/path/to/Side Dock.app"      # build/Side Dock.app in the repo by default
```

After these three steps nothing is left behind: the Dock is as it was before installing, and the login item and data folder are gone.

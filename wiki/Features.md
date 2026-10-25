**English** | [[中文|功能一览]]

![Settings · App Bars](https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-en-app-bars.png)

**v0.2.0 (2026-10-24)**: everything in the plan is done, **540+ unit tests pass**, and on-device Dock acceptance is **9/9 green**.

What it does today:

- Detects all desktops; click the menu bar icon to cycle desktops (⇧-click goes back); a 1-second desktop name banner after each switch (background styles: **Default / Flowing Neon / Cyber Violet**)
- **Frozen mode (default)**: the native Dock stays fixed as your "Default Dock" — switching desktops writes no preferences and never restarts the Dock. Per-desktop differences are shown by the side dock (icons swap instantly with the desktop, fixed size next to the native Dock, shows and hides in sync with it)
- Prefer the old way? Turn off "Freeze per-desktop native Dock switching": each desktop gets its own native Dock, applied on switch
  (via SIGHUP inside an auto-hide sandwich — **the restart is invisible, no black flash**)
- **Multiple bars per desktop**: up to 3 per screen edge, stacked as rows of one side dock. It **always shows one row**;
  one two-finger scroll moves one row (dots at the end show how many rows and which one), and its length follows the current row
- **Feels like the native Dock**: hover magnification (follows the system Magnification setting; the backing grows with the icons), app names on hover,
  bouncing until a not-yet-running app finishes launching, **drag an icon off the bar to remove it** (not far enough and it snaps back).
  A free-standing bar floats 6 pt off the screen edge on a frosted material close to the native Dock
- **Stays clear of Stage Manager**: the edge Stage Manager uses is greyed out in the position options and marked "(Stage Manager)"; bars already on that edge temporarily move to the bottom
- Visual icon bar editor in Settings (drag in / out / reorder, or drop `.app` files from Finder)
- **Launchpad page (below macOS 26)**: reads every Launchpad folder, then "Add to" or "Replace" a Dock bar in one click
- **Leaves no trace**: restores on quit, self-heals on next launch after a force quit, and backs up before every Dock write

Not done yet:

- **Multiple displays are untested on real hardware** (the code is ready; it needs an external display to verify)
- **Switch animation (optional, awaiting on-device testing)**: Settings → Menu Bar → "Use the system slide animation to switch desktops". Needs Accessibility; it borrows the Mission Control shortcuts (⌃← / ⌃→ for neighbours, "Switch to Desktop N" for jumps — enable them under Keyboard Shortcuts → Mission Control). See [[Switch Animation|Switch-Animation]]
- Whether the **side dock material** fully matches the native Dock still needs an on-device comparison (try `defaults write local.multidock SecondaryDockMaterial -int <n>`, takes effect after relaunch; `defaults delete` to reset)

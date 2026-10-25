**English** | [[中文|切换动画]]

![Settings · Menu Bar](https://raw.githubusercontent.com/wiki/reiy-leo/side-dock/images/settings-en-menu-bar.png)

When you switch desktops from the menu bar, Side Dock can borrow the system Mission Control shortcuts to get the same left/right slide as a trackpad swipe (**off by default, needs Accessibility, awaiting on-device testing**).

## Turning it on

Settings → Menu Bar → "Switch Animation" → turn on "Use the system slide animation to switch desktops". The first time, a prompt walks you through granting Accessibility: tick Side Dock in System Settings → Privacy & Security → Accessibility.

> The app is only ad-hoc signed, so the permission may stop working after an update: remove Side Dock from the list and add it again.

## System shortcuts it uses

| Case | Shortcut | Default |
| --- | --- | --- |
| Neighbouring desktop (next / previous) | Move left / right a space (⌃← / ⌃→) | On |
| Jumping, wrapping around | Switch to Desktop N | 1–9 default to ⌃1–⌃9 but are **off**; 10–16 need a key you assign |

Enable them in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. "Switch to Desktop N" slides straight to the target, so going from desktop 10 back to 1 plays a single animation.

If the needed shortcut is off, that switch simply happens instantly — it never gets stuck. With multiple displays, jumps don't animate yet (desktop numbering is unverified); neighbouring switches are unaffected.

macOS allows up to 16 desktops per display.

**English** | [[中文|工作原理与注意事项]]

- **In the default (frozen) mode, switching desktops never touches the native Dock**: no preference writes, no restart, no flicker. The native Dock stays fixed at the "Default Dock" configuration;
  if it differs from the baseline at launch (normal after a restore), it's aligned once (about 0.4 s, inside the auto-hide sandwich so you don't see it) and skipped when already identical
- **In the unfrozen (old) mode the Dock restarts for about 0.1 s on each switch** (SIGHUP, measured 45–90 ms), but the restart is wrapped in an **auto-hide sandwich** by default (slide away → invisible restart → slide back), so there's **no visible black flash**.
  Two desktops sharing the same Dock are short-circuited with no restart at all
- One apply takes about 1 second in total, mostly a deliberate wait to stay clear of launchd's restart throttling — the Dock is **usable** during the wait
- Detecting and switching desktops relies on **private SkyLight APIs** (`CGSCopyManagedDisplaySpaces` / `CGSManagedDisplaySetCurrentSpace`), loaded at runtime via `dlopen` with no private framework linked. A macOS update could break them; the app then degrades and says so clearly in the Debug Panel
- **No system permissions by default**: no Accessibility, Screen Recording or root (only the optional [[Switch Animation|Switch-Animation]] needs Accessibility). The name banner and side dock are just the app's own borderless windows
- **`mru-spaces` is on by default** (the system reorders desktops by recent use), which scrambles what "next desktop" means. Settings has an explicit switch, and **it only changes if you click it**
- Programmatic switches don't fire the system's space-change notification, so the app polls every 300 ms — switching with the trackpad or keyboard is detected the same way and shows the banner too (the gesture notification path works, ≈0 delay)

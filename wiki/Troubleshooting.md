**English** | [[中文|故障排查]]

| Symptom | Check this first |
| --- | --- |
| The Dock didn't change when I switched desktops | **Expected in the default frozen mode**: the native Dock stays fixed and differences show in the side dock. If the side dock doesn't appear, make sure "Show side dock" is on and the desktop's configuration isn't empty |
| The side dock doesn't show / doesn't move as before | Check the switch is on; in full-screen app spaces it hides like the native Dock; with auto-hide it shows and hides with the native Dock |
| Hovering doesn't slide it out | Move onto the half-bar peeking above the Dock; if neither click nor hover works, note it and report it |
| A position option is greyed out | That edge is taken by Stage Manager (marked "Stage Manager"), or that edge already has 3 bars on this desktop |
| "Apply Now" is greyed out | The Default Dock is empty — click "Capture from Current Dock" first |
| No menu bar icon | The menu bar may be set to auto-hide; move the pointer to the top of the screen |
| The desktop name banner doesn't appear | Check Settings → General → Desktop Switching → "Show desktop name when switching"; the first sample at launch and returning from a full-screen app **intentionally don't show it** |
| "Restored the Dock left over from last time" at launch | The last run was force-quit or crashed and the app restored the baseline. This is expected |
| Desktop features unavailable | The private SkyLight APIs stopped working (usually after a major macOS update). The app degrades to "manual Dock edits only, no following or switching", with the reason in the Debug Panel |
| Anything else | Read `~/Library/Application Support/MultiDock/multidock.log`; every apply/restore is logged with timing and result |

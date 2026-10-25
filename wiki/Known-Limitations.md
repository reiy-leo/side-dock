**English** | [[中文|已知限制]]

- **Switch animation can only borrow system shortcuts**: a programmatic SkyLight switch is instant (measured 0–6 ms) and there's no safe "switch to a space with a transition" entry point (guessing `SLSWillSwitchSpaces`'s signature segfaults).
  So the optional [[Switch Animation|Switch-Animation]] uses the system Mission Control shortcuts and needs Accessibility; without the shortcut it falls back to an instant switch. Evidence: [docs/spikes.md](https://github.com/reiy-leo/side-dock/blob/main/docs/spikes.md) experiment 7.
- **Multiple displays and hot-plugging** (the one remaining on-device check): bindings are keyed by `(displayUUID, spaceUUID)`, the banner is placed on the matching screen by `displayUUID` with a fallback,
  and the desktop list is re-read when displays change — but it was **developed on a single display and never tested with an external one**.
  After plugging one in, check two things in the Debug Panel: the display count, and that the first 8 characters of each desktop's `displayUUID` don't get mixed up;
  **also glance at Settings → Desktops to see the list is grouped by display with the right names**.
- **Restoring at logout/shutdown**: the system gives no time to wait, so it's best-effort (a debt marker is left and the next launch self-heals); untested.
- **Folders / stacks (other items) can't be created in the app**: testing showed the Dock **won't adopt** folder entries the app builds
  (no `GUID` / `book`, not even with a self-made bookmark), and **an incomplete entry crashes the Dock outright**
  (launchd relaunches it over and over — a crash loop that leaves you without a Dock). So the editor can **only reorder / remove** existing items;
  to add a folder, **drag it onto the Dock in Finder** and the app records it for the current desktop. Evidence: `docs/spikes.md` experiment 8.
- **The root cause of occasional slow Dock restarts (26–31 s) is unknown**: instrumentation is in place and the "don't wait, nudge" fix cuts the cost to ~1–3.5 s;
  seven hypotheses have been ruled out. In the default frozen mode switching no longer restarts the Dock, so exposure is small. When it reproduces, read the log as described in `docs/spikes.md` experiments 15/16.4.
- **Killing the Dock repeatedly puts launchd into increasing back-off**: after dozens of restarts the Dock may not come back for tens of seconds (waiting is faster than repeated `kickstart`).
  This affects acceptance-test pacing; **normal use used to hit it too** (the "black screen for minutes" in experiment 9 on 2026-09-19 snowballed this way);
  the fix — "non-blocking kickstart + no stacking + slower monitor" — has shipped and is covered by on-device logs.

Already verified (nothing to worry about): filtering of full-screen app spaces (on-device regression passed), vertical editor bar, orphaned binding notice, undoing a save-back,
reordering / removing other items (on-device: none of the Dock's own `GUID` / `book` lost), the warning banner at the top of Settings,
flicker-free restart (auto-hide sandwich), zero restarts when switching in frozen mode, fixed side dock geometry and synced show/hide.

See [AGENTS.md](https://github.com/reiy-leo/side-dock/blob/main/AGENTS.md) §3 "Not done" and §6.3.

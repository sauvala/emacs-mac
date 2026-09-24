---
id: s3-windows-redisplay
title: "S3: Move window lifecycle and redisplay to the new loop"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: claude-app-loop-session-3
---

## Scope

Implement decisions W1-W14: single-owner window fields and coalesced
records, one live-resize session with Lisp drawing in tracking mode, safe
stale presentation, fullscreen and scale records, close/Quit dedupe with the
"Waiting for Emacs…" indicator, and the four event-loop preferences not
registered (each re-enableable by override).

## Acceptance gate

W15 passes on macOS 27 with evidence recorded, including a run with each
preference re-enabled individually and all disabled.

## Decisions

- [Window decisions](../comments/window-redisplay/2026-09-23-discussion.md)
- [Migration plan M8](../comments/migration-plan/2026-09-23-discussion.md)

## Blocked by

- [S2: Build the persistent event-loop core](10-s2-event-loop-core.md)

## Progress (2026-09-24)

On branch `app-loop`:
- The four preferences are not registered (`EMACS_MAC_LOOP_PREFS` re-enables
  them).
- The synthetic resize events are skipped.
- Live resize, zoom, minimize and fullscreen converge while Lisp is busy.
- Stale fullscreen parameter events are ignored by serial.
- Close and Quit are deduplicated, with the "Waiting for Emacs…" subtitle
  after 100 ms (W7/W8).

Later on 2026-09-24 (see the implementation notes in the window
discussion):
- W3: the Metal layer's background is the published frame background
  (the exposed area was undefined before). The live-resize snapshot
  layer is not used, and the fullscreen snapshot is built only with Lisp
  access.
- W2: live-resize steps reach Lisp while it is idle, so it redraws during
  the drag. Steps are skipped while Lisp is busy.
- W6/W10: deferred state callbacks coalesce per object and kind. The
  unlocked Metal context resize on backing changes is gone.
- Per-preference scripted runs: see
  `test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-prefs.md`.

Not done:
- Interactive W3 check on real drags, including rapid reversals and a
  busy fullscreen toggle (screenshots are not possible in the agent
  session).
- Mixed-scale display move (W10).
- Real window-server drags with accessibility discovery (W13).
- Publishing size hints instead of reading `FRAME_SIZE_HINTS` on the GUI
  thread (a benign race; see the notes).

A pending close or Quit is considered resolved at Lisp's next input wait,
which can come slightly before the queued event is read; a rare repeated
click in that window is still possible.

### Interactive checklist for the user (W3, W10, W13, timings)

Launch with `test/manual/mac-app-loop/run.sh new`. The fixture starts
both heartbeats, and `M-x mac-app-loop-report` shows the Lisp and GUI
maximum gaps. Use a dark theme (`M-x load-theme RET modus-vivendi`) so
that white or black flashes stand out.

1. Idle: drag the bottom-right corner slowly, then quickly. Expected: the
   text reflows during the drag, not only on release.
2. Busy: `M-: (mac-app-loop-busy 10)`, then drag larger and smaller,
   with rapid reversals. Expected: the old content stays top-left and is
   not stretched, and the new area is the theme background. No garbage,
   black or white areas, and no stale fragments at the edges. The layout
   is correct within about 0.25 s after the busy loop ends.
3. Busy: click the green button (fullscreen) and back. Expected: AppKit's
   default animation, and the final state is correct after Lisp is idle.
4. If a second display with a different scale is available: move the
   frame between the displays, idle and busy. Expected: blurry or
   mis-sized content only while busy, never corrupt; sharp once idle.
5. Idle and during `(mac-app-loop-busy 10)`: run
   `test/manual/mac-app-loop/windows.py` in a terminal that has
   Accessibility permission. Expected: the frames are listed with title,
   position, size and minimized state both times.
6. `M-x mac-app-loop-report`. Report the GUI max gap and any gaps over
   100 ms, and send the log paths that `run.sh` printed.

---
id: s3-windows-redisplay
title: "S3: Move window lifecycle and redisplay to the new loop"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
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

Not done:
- W3 stale presentation during a busy resize (nothing was visible without
  screenshots).
- W6/W10 coalesced records beyond the current deferrals.
- Per-preference acceptance runs.
- Real window-server drags.

A pending close or Quit is considered resolved at Lisp's next input wait,
which can come slightly before the queued event is read; a rare repeated
click in that window is still possible.

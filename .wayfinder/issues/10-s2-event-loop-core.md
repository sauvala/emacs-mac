---
id: s2-event-loop-core
title: "S2: Build the persistent event-loop core"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Implement 04's decisive prototype under the new loop: persistent
`NSApplication.run`, the locked GUI-to-Lisp input queue with GUI-side quit
recognition, per-request Lisp-to-GUI delivery in both mode classes, the
input wait through `thread_select` (the current single-thread `mac_select`
path holds the global lock), and safe-point try-lock with the existing
`thread.c` pair. Menus stay on the old path; IME and accessibility snapshots
are stubbed. The GUI never writes `kbd_buffer` directly.

## Acceptance gate

04's prototype criteria pass on macOS 27 in fresh processes with evidence
recorded, including lock-release instrumentation during the input wait.

## Decisions

- [Event-loop decisions](../comments/event-loop-ownership/2026-09-23-discussion.md)
- [Migration plan facts and M1-M2](../comments/migration-plan/2026-09-23-discussion.md)

## Blocked by

- [S1: Add the launch-selected event-loop option](09-s1-launch-selector.md)

## Progress (2026-09-24)

Implemented on local branch `app-loop` (not merged, not pushed), selected
with `EMACS_MAC_PERSISTENT_LOOP=1` or `--enable-mac-persistent-loop`. The
input wait goes through `thread_select`, and the GUI takes the global lock
by try-lock only while Lisp waits for input. A design difference from the
ticket: GUI-bound events and callbacks without Lisp access go into a
deferred FIFO replayed on the next access, instead of a separate locked
record queue. Scripted evidence is in
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-both-scripted.md`,
including try-lock grants during the input wait. Interactive acceptance is
still unverified, so the ticket stays open.

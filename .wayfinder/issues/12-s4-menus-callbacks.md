---
id: s4-menus-callbacks
title: "S4: Move menus and callbacks to the new loop"
status: closed
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Implement decisions D1-D20: no GUI-thread Lisp, per-frame menu snapshots
with bounded open-time refresh, the Lisp-rooted generation table,
revalidated at-most-once actions with `user-error` feedback, the F10 popup
and Control-F2 navigation, published Services and Help data, and C-g
cancellation. Carbon interception and the retry/redirect machinery are not
used by the new loop.

## Acceptance gate

D21 passes on macOS 27 with evidence recorded; the extended
`test/manual/mac-menu/check.py` covers the table's lifetime rules.

## Decisions

- [Menu decisions](../comments/menu-callbacks/2026-09-23-discussion.md)
- [Migration plan M8](../comments/migration-plan/2026-09-23-discussion.md)

## Blocked by

- [S3: Move window lifecycle and redisplay to the new loop](11-s3-windows-redisplay.md)

## Progress (2026-09-24)

On branch `app-loop`, scripted menu-bar actions pass: menu-idle, menu-busy,
and menu-stale (rejected with `user-error`). What is implemented:
- Redisplay publishes a deep snapshot per update (D6).
- The installed root carries the snapshot's generation. When only the
  window or buffer changes, a new generation is published and the root
  restamped.
- A selection becomes one `mac-menu-bar-selection` special event,
  revalidated when read (D5, D17).
- F10 opens a popup (D9).
- Menu-bar help-echo is fire-and-forget and coalesced (D13), dereferenced
  only while its snapshot lives.
- Apple events, Services, Help search and toolbar callbacks defer without
  Lisp access.

Added later on 2026-09-24:
- `:enable` is rechecked when the action executes, in the snapshot's
  window and buffer (D5); scenarios `menu-disabled` and `menu-nested`.
- A deleted frame's snapshots are retracted (D16); scenario
  `menu-frame-deleted`.
- C-g cancels menu-bar tracking on the GUI thread (D15). This is not
  verified with real tracking.
- D6's busy placeholder is not needed, because the deep fill expands
  every `:filter`.
- `test/manual/mac-menu/check.py` covers the snapshot table.
- The deep fill is postponed to an idle timer while commands run. Rebuilds
  that only change the evaluated values of `:enable`/`:selected` forms
  or recons equal strings no longer refill AppKit (see the implementation
  notes in the menu-callbacks discussion).

Real mouse and keyboard menu tracking, and C-g during it, passed
interactive checks on 2026-09-24. D3 moved to
[S4 follow-up: open-time submenu refresh](17-s4-open-time-refresh.md).

Snapshots are kept for the eight newest generations rather than by
reference count.

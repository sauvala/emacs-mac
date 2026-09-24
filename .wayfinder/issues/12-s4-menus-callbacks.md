---
id: s4-menus-callbacks
title: "S4: Move menus and callbacks to the new loop"
status: open
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

Not done:
- Rechecking `:enable` at execution (D5).
- Retracting a deleted frame's snapshot (D16).
- The disabled "Unavailable while Emacs is busy" entry for never-expanded
  `:filter` submenus.
- D15 C-g during tracking.
- Extending `test/manual/mac-menu/check.py`.
- Real mouse and keyboard menu tracking.

Snapshots are kept for the eight newest generations rather than by
reference count.

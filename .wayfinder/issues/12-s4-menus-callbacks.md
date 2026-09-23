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

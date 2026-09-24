---
id: s8-old-loop-removal
title: "S8: Remove the old loop and its workarounds"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: claude-old-loop-removal
---

## Scope

Delete the old loop and each workaround in the M8 table, together with
`EMACS_MAC_NATIVE_MENUS`, `EMACS_MAC_WORKER_MENUS` and
`--enable-mac-native-menus`.

## Acceptance gate

Every OS still on the old loop has flipped with evidence or been explicitly
dropped by the user; `AGENTS.md` guidance on the removed settings is updated
in the same change.

## Decisions

- [Migration plan M8](../comments/migration-plan/2026-09-23-discussion.md)

## Blocked by

- [S7: Converge older macOS versions](15-s7-older-os-convergence.md)

## Progress (2026-09-24)

Implemented on branch `old-loop-removal` at the user's request, after
the user dropped older macOS versions (S7) and asked to make the new loop
the default and remove the old one (S6):
- `c31bd2ca898` removes the launch selector and the configure options.
- `0988ae3be8a` deletes the old loop and every M8 workaround: semaphore
  bridge, select emulation and temporary runs, NSEvent handling in
  `read_socket`, Carbon menu interception and fake click, native and
  worker menus with their flags, event-loop preferences, synthetic
  resize and font-panel slider events, and the accessibility
  heuristics. About 2,300 lines are gone.
- Found on the way: the font panel's size slider drag stopped after its
  first step under the new loop, because it suspended tracking and only
  the old loop resumed it. Removing the suspension fixes that.
- `mac-select-latency-stats` stays for the benchmark tooling and now
  reports zeros (it measured only the old select emulation).
- AGENTS.md, README.md and the mac-app-loop and mac-menu fixtures are
  updated in the same change.

Checks: all 29 scripted scenarios, 25 Metal source tests, the menu
snapshot check and the fixture ERT tests pass. Awaiting the user's check
of the installed build before merging and closing.

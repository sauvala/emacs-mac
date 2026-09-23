---
id: s8-old-loop-removal
title: "S8: Remove the old loop and its workarounds"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
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

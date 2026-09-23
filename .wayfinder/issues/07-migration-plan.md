---
id: migration-plan
title: Decide migration stages and workaround retirement gates
status: closed
labels: ["wayfinder:grilling"]
parent: macos-app-integration
assignee: null
---

## Question

What implementation sequence makes the agreed architecture reviewable and
recoverable? Specify whether an initial macOS 27+ opt-in is needed, older-OS
convergence, shared-code and upstream-sync boundaries, test/prototype gates,
rollback conditions, and per-workaround removal criteria. Close only when the
result is implementation-ready and remaining fog has been resolved or explicitly
excluded with the user; implementation itself is outside this map.

## Blocked by

- [Choose menu preparation and GUI-to-Lisp callback contracts](05-menu-callbacks.md)
- [Choose window lifecycle and redisplay coordination](06-window-redisplay.md)

## Discussion

- [Recorded decisions](../comments/migration-plan/2026-09-23-discussion.md)
- [Resolution](../comments/migration-plan/2026-09-23-resolution.md)

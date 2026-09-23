---
id: s5-content-snapshots
title: "S5: Replace IME and accessibility stubs with safe content access"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Publish the IME cursor rectangle and marked/selected range at the end of
redisplay, and serve accessibility content queries under the safe-point lock
or as unavailable, replacing the `poll_suppress_count`/`inhibit-quit`
heuristics under the new loop.

## Acceptance gate

The IME and accessibility scenarios of the acceptance contract pass on
macOS 27 with Lisp idle and busy, with evidence recorded.

## Decisions

- [Event-loop decisions](../comments/event-loop-ownership/2026-09-23-discussion.md)
- [Window decisions W11, W13](../comments/window-redisplay/2026-09-23-discussion.md)
- [Acceptance contract](../comments/native-behavior/2026-09-23-discussion.md)

## Blocked by

- [S2: Build the persistent event-loop core](10-s2-event-loop-core.md)

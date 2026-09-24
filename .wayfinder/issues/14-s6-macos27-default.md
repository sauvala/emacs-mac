---
id: s6-macos27-default
title: "S6: Make the new loop the macOS 27 default"
status: closed
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Flip the compiled default to the new loop on macOS 27+ only, keeping the
environment variable to select the old loop.

## Acceptance gate

Before flipping: the full acceptance scenario table under idle, busy,
minibuffer, multi-thread and delayed-quit Lisp states, plus one week of daily
use on macOS 27 with no open regression. After: the M7 rollback triggers
apply.

## Decisions

- [Migration plan M2, M7](../comments/migration-plan/2026-09-23-discussion.md)
- [Acceptance contract](../comments/native-behavior/2026-09-23-discussion.md)

## Blocked by

- [S3: Move window lifecycle and redisplay to the new loop](11-s3-windows-redisplay.md)
- [S4: Move menus and callbacks to the new loop](12-s4-menus-callbacks.md)
- [S5: Replace IME and accessibility stubs with safe content access](13-s5-content-snapshots.md)

## Resolution (2026-09-24)

Closed by the user's live decision: [resolution](../comments/s6-macos27-default/2026-09-24-resolution.md).

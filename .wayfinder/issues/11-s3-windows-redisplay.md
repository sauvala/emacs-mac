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

---
id: native-behavior
title: Define native responsiveness and acceptance scenarios
status: open
labels: ["wayfinder:grilling"]
parent: macos-app-integration
assignee: null
---

## Question

What observable behavior and response limits define success while Lisp is idle,
busy, waiting for input, or running multiple threads? Agree on immediate native
feedback versus deferred Lisp-dependent work, stale menu policy, quit behavior,
close/save prompts, resize redisplay, fullscreen and display transitions,
window discovery and automation, and startup/reopen/quit. Define the supported
OS/build matrix and fresh-process interactive evidence needed for acceptance.

## Blocked by

- [Establish documented AppKit lifecycle and tracking contracts](01-appkit-contracts.md)
- [Establish upstream direction and supported macOS baseline](02-upstream-baseline.md)

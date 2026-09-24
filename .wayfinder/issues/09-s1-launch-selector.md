---
id: s1-launch-selector
title: "S1: Add the launch-selected event-loop option"
status: closed
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Add the configure option beside `--enable-mac-native-menus`
(`configure.ac:696-701`, `:5670-5676`) and the launch environment variable
that select the loop (04). Both loops compile into one binary; the old loop
stays the default everywhere and behaves unchanged.

## Acceptance gate

Default builds show no behaviour change against the S0 baseline; the
selector chooses each loop in fresh processes; the variable overrides the
compiled default in both directions.

## Decisions

- [Event-loop decisions](../comments/event-loop-ownership/2026-09-23-discussion.md)
- [Migration plan M1, M7](../comments/migration-plan/2026-09-23-discussion.md)

## Blocked by

- [S0: Add loop instrumentation and busy-Lisp fixtures](08-s0-instrumentation.md)

## Resolution (2026-09-24)

Closed at the user's request: [resolution](../comments/s1-launch-selector/2026-09-24-resolution.md).

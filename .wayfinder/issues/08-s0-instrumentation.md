---
id: s0-instrumentation
title: "S0: Add loop instrumentation and busy-Lisp fixtures"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Scope

Add measurement and tracing with no behaviour change: native response and
acknowledgment timing, a busy-Lisp fixture that never waits for input, and
traces for GUI-thread Lisp evaluation, Carbon queue access, synthetic events
and preference registration. Create `test/manual/mac-app-loop/` with the
evidence-record template (migration M9) and extend the standalone checks
(M10).

## Acceptance gate

Both current configurations build; the fixture and traces run on macOS 27;
an evidence record from the unchanged old loop exists as the baseline.

## Decisions

- [Migration plan M1, M9, M10](../comments/migration-plan/2026-09-23-discussion.md)
- [Acceptance contract](../comments/native-behavior/2026-09-23-discussion.md)

## Blocked by

None.

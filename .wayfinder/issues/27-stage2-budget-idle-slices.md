---
id: stage2-budget-idle-slices
title: "Stage 2: budgeted parse continued in idle slices"
status: open
labels: ["wayfinder:task"]
parent: treesit-budgeted-parse
assignee: null
---

## Scope

Halt reparses that run past the budget. Apply the display policy while a parse is pending, and continue the parse in idle slices on the Lisp thread. No threads.

## Acceptance gate

- A batch ERT test: with a budget of 0 and interleaved edits, the finished tree equals a synchronous parse.
- The latency scenarios show typing `"` in the 800 KB file within one frame, and the string face appears afterwards.
- A `MallocScribble=1` scenario run passes.
- The user edits large Python and TypeScript files live and confirms.
- Stats cover slice durations (with the maximum), pending age at completion (restarted and not restarted), restarts per parse and staleness-deadline firings, and a day of the user's editing is recorded for the [worker-stage gate](25-worker-stage-gate.md).

## Blocked by

- [Stage 1: time every tree-sitter parse](26-stage1-parse-instrumentation.md)
- [What redisplay shows while a parse is pending](22-pending-parse-display-policy.md)
- [How a halted parse continues on the Lisp thread](23-idle-slice-continuation.md)

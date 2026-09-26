---
id: stage2b-idle-slices
title: "Stage 2b: budgeted parse continued in idle slices"
status: open
labels: ["wayfinder:task"]
parent: treesit-budgeted-parse
assignee: null
---

## Scope

Halt reparses that run past the budget. Apply the display policy while a
parse is pending, and continue the parse in idle slices on the Lisp
thread. No threads.

## Trigger

Start only if the stage 1 stats of a day of the user's editing show more
than 10 reparses above 8 ms, or the user notices typing hitches in large
files. The same threshold as the [worker-stage gate](25-worker-stage-gate.md).
Stage 1 measured none above 3 ms in live editing, so until then the map
ends with stage 2 ([split decision](../comments/treesit-budgeted-parse/2026-09-26-stage2-split.md)).

## Acceptance gate

- A batch ERT test: with a budget of 0 and interleaved edits, the finished tree equals a synchronous parse.
- The latency scenarios show typing `"` in the 800 KB file within one frame, and the string face appears afterwards.
- A `MallocScribble=1` scenario run passes.
- The user edits large Python and TypeScript files live and confirms.
- Stats cover slice durations (with the maximum), pending age at completion (restarted and not restarted), restarts per parse and staleness-deadline firings, and a day of the user's editing is recorded for the [worker-stage gate](25-worker-stage-gate.md).

## Blocked by

- [Stage 2: cap runaway parses](27-stage2-budget-idle-slices.md)
- [What redisplay shows while a parse is pending](22-pending-parse-display-policy.md)
- [How a halted parse continues on the Lisp thread](23-idle-slice-continuation.md)

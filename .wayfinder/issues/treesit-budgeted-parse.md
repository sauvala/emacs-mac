---
id: treesit-budgeted-parse
title: Plan taking tree-sitter parsing off the keystroke path
status: open
labels: ["wayfinder:map"]
parent: null
assignee: null
---

## Destination

An implementation-ready, staged plan for roadmap item 13
(`docs/nemesis-performance-roadmap.md`) that keeps a tree-sitter reparse
from blocking a keystroke or a redisplay. The stages are:

1. Instrument and time parses, with no behaviour change.
2. Cap runaway parses: halt a parse past a hard limit and give up on
   that parser until the user retries.
2b. Only if stats or the user call for it, budget the parse and continue
   a halted parse in idle slices on the Lisp thread.
3. Only if a measured gate says so, resume a halted parse on a worker
   thread.

Each stage has its tests, its live check and a go/no-go gate.

## Notes

- Fork-local work on `nemesis`; nothing goes to GNU Emacs (AGENTS.md).
- The measurements and first design are in the roadmap's item 13 section
  (commit `ffb9c42bdee`):
  - An ordinary reparse takes under 1 ms.
  - Typing `"` in a 240-800 KB file costs 3-7 ms.
  - A first parse costs 17-44 ms.
  - Query and faces take about 1 ms per screen.
- Standing user preference (memory, 2026-09-23): when a session has a
  recommended answer, it adopts it and records it as self-adopted rather
  than asking. Close HITL decision tickets only after the user confirms.
- Minimise the sync surface: GNU master changed `src/treesit.c` and
  `lisp/treesit.el` in 74 commits in six months. Prefer new code in
  separate functions or files with narrow hooks into `treesit.c`.
- Skills: grilling and domain-modeling for decisions; research (Context7
  for the tree-sitter API, per the user's rules) for library facts; tdd for
  stage tests.
- Benchmarks bind `jit-lock-defer-on-input` to nil; otherwise scripted GUI
  loops time unfontified redisplay. Only one GUI test at a time. Run GUI
  scenarios under `MallocScribble=1`.
- Implementation stages are `wayfinder:task` children, as for the
  macOS app-integration map. Each stage's work happens on its own branch
  off `nemesis`.

## Decisions so far

- [Tree-sitter halt and resume contract](19-ts-halt-resume-contract.md): a halted parse resumes from any input with identical bytes (so another thread works), but every edit needs `ts_parser_reset`; the callback fires about every 15 us, so a 1-3 ms budget holds except for giant tokens and end-of-file balancing; the API exists from 0.25, with a fallback for older versions ([resolution](../comments/ts-halt-resume-contract/2026-09-25-resolution.md))
- [Inventory every reader of a parser tree](20-treesit-tree-access-inventory.md): only `treesit--pre-redisplay` and jit-lock fontification can skip waiting; deferral must cover the whole jit-lock chunk (indent-bars and `syntax-propertize` read the tree inside it); `syntax-ppss` after an edit forces the parse; install finished trees only at a safe point ([resolution](../comments/treesit-tree-access-inventory/2026-09-25-resolution.md))
- [Tree-sitter latency scenarios for the benchmark harness](21-ts-latency-scenarios.md): `ts-perf.el` added; typing `"` at a line start reparses in 4-5 ms at 50-100 KB, 9 ms at 240 KB and 63 ms in an 800 KB docstring-heavy Python file, while keystrokes and scrolls stay 1-3 ms ([resolution](../comments/ts-latency-scenarios/2026-09-25-resolution.md))
- [What redisplay shows while a parse is pending](22-pending-parse-display-policy.md): stale faces stay; jit-lock defers the whole chunk while the primary parser has a pending parse; only `treesit--pre-redisplay` and idle slices make budgeted attempts, every other reader finishes the parse; completion runs the existing notifiers and re-arms deferred chunks; stage 2 covers buffers with only a primary parser without included ranges, and the first parse stays synchronous ([decision](../comments/pending-parse-display-policy/2026-09-26-decision.md))
- [How a halted parse continues on the Lisp thread](23-idle-slice-continuation.md): a re-arming Lisp idle timer runs 2 ms slices back to back until input arrives; an edit resets and restarts the parse; redisplay starts parses but never continues one; a 0.5 s staleness deadline, counted across restarts, makes the next attempt unbudgeted; completion reuses the notifiers and the post-timer redisplay ([decision](../comments/idle-slice-continuation/2026-09-26-decision.md))
- [Keep the change small in upstream files](24-sync-surface-containment.md): logic lives in `src/treesit_budget.c` and `lisp/treesit-budget.el`; upstream files get one call in `treesit_ensure_parsed`, a small halted-return block, one line each in parser deletion, `syms_of_treesit`, the parser struct and `Makefile.in`, and about three lines in `treesit--pre-redisplay`; edits are detected at resume by comparing `CHARS_MODIFF`, narrowing and ranges; no configure option; generic defer hooks in fork-owned `jit-lock.el` ([decision](../comments/sync-surface-containment/2026-09-26-decision.md))
- [Gate for building the worker-thread stage](25-worker-stage-gate.md): build it only if a day of stage-2 stats shows more than 10 overruns above 8 ms, or a p95 pending age above 250 ms for parses that were not restarted, or the user notices either; restarts and waiters do not count because a worker cannot fix them; otherwise stage 2 is the end state ([decision](../comments/worker-stage-gate/2026-09-26-decision.md))
- [Stage 1: time every tree-sitter parse](26-stage1-parse-instrumentation.md): `treesit-budget-stats` times every parse with no measurable cost; a typing replay stood in for the editing day: the user's files reparse past 3 ms in 0.05% of edits, large repositories past 8 ms in 0.65% (max 48 ms); a 600 s hang came from an old TypeScript grammar, now replaced, and its reduced input is kept for stage 2's halt test ([resolution](../comments/stage1-parse-instrumentation/2026-09-26-resolution.md))
- [Split stage 2](27-stage2-budget-idle-slices.md): stage 2 is now only a hard cap on parse time (a freeze guard; every other editor bounds parses, upstream Emacs does not); budgeting and idle slices become [stage 2b](28-stage2b-idle-slices.md), started only if a day of stats shows more than 10 reparses above 8 ms or the user notices hitches ([decision](../comments/treesit-budgeted-parse/2026-09-26-stage2-split.md))

## Not yet specified

- **Worker-thread stage.** Its details wait for the gate on the stage-2b
  results:
  - the text snapshot format;
  - parser ownership handoff and how waiters join the worker;
  - how edits typed during a worker parse are queued and applied;
  - the completion wakeup through the persistent loop;
  - interaction with GC and parser deletion;
  - replacing the `xmalloc` allocator passed to `ts_set_allocator`,
    which is unsafe off the Lisp thread (halt/resume research).
- **First parse on file open (17-44 ms).** Whether it is budgeted like a
  reparse. That means showing unfontified text briefly; the alternative
  is to keep it synchronous below some size. The display-policy decision
  (ticket 22) recommends keeping it synchronous in
  stage 2 and revisiting with the stage-2 numbers.
- **User-facing knobs.** Names, defaults and whether they are
  `defcustom`s, once stage 2b has numbers. Ticket 23 proposes a budget
  and slice of 2 ms and a staleness deadline of 0.5 s as starting values.

## Out of scope

- Moving cc-mode or other Lisp font-lock off the Lisp thread: a C worker
  cannot run Lisp; see the helper-process prior art on
  `codex/responsive-coding-bb3c`.
- Parsers with included ranges or embedded language parsers; they keep
  parsing synchronously.
- Moving tree-sitter queries or face application off the Lisp thread.

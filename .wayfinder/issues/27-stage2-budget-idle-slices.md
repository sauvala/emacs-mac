---
id: stage2-budget-idle-slices
title: "Stage 2: cap runaway parses"
status: open
labels: ["wayfinder:task"]
parent: treesit-budgeted-parse
assignee: claude
---

## Scope

Stop any parse, first parse or reparse, that runs past a hard time limit,
so that a pathological grammar or input cannot freeze Emacs. Parses under
the limit behave as today; nothing is deferred or resumed. Budgeting and
idle slices move to [stage 2b](28-stage2b-idle-slices.md), which waits for
its own trigger ([split decision](../comments/treesit-budgeted-parse/2026-09-26-stage2-split.md)).

- The progress callback in `src/treesit_budget.c` halts the parse once it
  has run past `treesit-budget-parse-limit` seconds (default 2.0; nil
  disables). The worst legitimate parse measured in stage 1 is 48 ms.
- After a halt the parser gives up: until the user retries (a command)
  or the parser is recreated, it parses an empty input instead of the
  buffer. One message names the buffer and the limit.
- The give-up must not raise errors in redisplay, jit-lock,
  `syntax-ppss` or mode setup: readers find an empty tree.
- Fix the `treesit-parse-error` path in `treesit_ensure_parsed`, which
  returns without clearing `within_reparse` and would leave the parser
  silently stale.
- Stats count halts at the limit.

## Acceptance gate

- The tree-sitter ERT suite passes.
- A batch test with a tiny limit shows the halt: the parser gives up
  and yields an empty tree, and a retry after raising the limit gives
  the same tree as a synchronous parse.
- The hang input `test/manual/redisplay-bench/ts-grammar-hang.ts` with
  the old grammar (`~/.emacs.d/tree-sitter/old-2023/`) stops within the
  limit in a GUI session, with the message, and Emacs stays usable.
  The user opens it live and confirms.
- The latency scenarios show no regression.
- Hooks stay within [Keep the change small in upstream files](24-sync-surface-containment.md).

## Blocked by

- [Stage 1: time every tree-sitter parse](26-stage1-parse-instrumentation.md)

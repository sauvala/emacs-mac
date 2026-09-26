# Resolution: stage 2 gate passed

2026-09-26, branch `treesit-stage2`. The ERT, batch, latency and
upstream-hook gates passed as recorded in the
[progress note](2026-09-26-progress.md). This note records the last
gate, the user's live check.

## Live check

The user opened `test/manual/redisplay-bench/ts-grammar-hang.ts` with
the old TypeScript grammar (`~/.emacs.d/tree-sitter/old-2023/`) in a
fresh GUI process of the development bundle, `-Q`. Emacs froze for
about the 2 s limit, showed the "parser disabled" message, and then
edited normally without tree-sitter highlighting, as described.

## What it means for the map

- Stage 2 is the end state unless [stage 2b](../../issues/28-stage2b-idle-slices.md)'s
  trigger fires: a day of stats with more than 10 reparses above 8 ms,
  or hitches the user notices.
- Stats keep being logged at every exit and now count halts.

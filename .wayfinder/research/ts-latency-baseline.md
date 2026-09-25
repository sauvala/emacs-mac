# Tree-sitter latency baseline

Date: 2026-09-25. Question: [Tree-sitter latency scenarios for the benchmark harness](../issues/21-ts-latency-scenarios.md).

Harness: `test/manual/redisplay-bench/ts-perf.el`, with its usage in the
header. Build: the installed `/Applications/Emacs.app`, a PGO + ThinLTO
build of `ba7e776ed83`, on an M2 with tree-sitter 0.27 (ABI 15). The
frame is 200x60, `gc-cons-threshold` is 16 MB and
`jit-lock-defer-on-input` is nil. Every row passed the fontification check.

All times are in ms. Each time includes `(redisplay t)`. "open" is from
visiting the file to a fontified first screen, median of 10 visits; its
p90 is dominated by the first visit, which loads the mode and the grammar.
"quote" types `"` at the indentation of a code line near the middle of
the buffer; "parse" is the part up to the finished reparse.

## Generated fixtures (the default run)

| Mode | Size | open | scroll-page median / p90 | keystroke median / p90 | quote median / p90 | quote parse median |
|---|---|---|---|---|---|---|
| python-ts | 800 KB | 135 | 3.0 / 3.8 | 1.2 / 1.2 | 64.7 / 65.7 | 63.2 |
| python-ts | 50 KB | 14 | 2.0 / 3.0 | 0.9 / 0.9 | 5.4 / 5.6 | 4.1 |
| typescript-ts | 800 KB | 196 | 2.6 / 2.9 | 1.6 / 1.7 | 26.4 / 27.4 | 25.7 |
| typescript-ts | 50 KB | 17 | 1.7 / 2.5 | 0.6 / 0.7 | 2.3 / 2.3 | 1.7 |

## Real files (`TS_PERF_FILES`)

| Mode | File | open | scroll-page | keystroke | quote | quote parse |
|---|---|---|---|---|---|---|
| python-ts | glib `codegen.py`, 240 KB | 45 | 2.5 / 3.4 | 0.7 / 0.7 | 10.1 / 10.4 | 9.0 |
| python-ts | pip's `rich/console.py`, 99 KB | 34 | 1.7 / 2.6 | 0.8 / 0.9 | 6.0 / 6.2 | 4.9 |
| typescript-ts | `lib.dom.d.ts`, 800 KB | 135 | 2.4 / 3.5 | 1.5 / 1.6 | 2.0 / 2.1 | 1.1 |

## Observations

- Keystrokes and scrolls are 1-3 ms everywhere, and the quote reparse
  accounts for nearly all of the quote time.
- A quote at the start of a line costs more than one at the end of a line
  (the roadmap's 6.7 ms for `codegen.py`). In Python it can re-pair every
  later `"""` docstring, so the tree changes to the end of the buffer.
  The generated Python fixture is docstring-heavy and shows the worst
  case: 63 ms at 800 KB.
- The cost scales with the size of the file after the edit. It is 4-5 ms
  at 50-100 KB and 9 ms at 240 KB. On `lib.dom.d.ts`, whose TypeScript
  declarations recover locally, it is only 1.1 ms.
- Opening a file costs more than the parse alone: 45 ms against a 17 ms
  parse for `codegen.py`, and 135-196 ms at 800 KB.

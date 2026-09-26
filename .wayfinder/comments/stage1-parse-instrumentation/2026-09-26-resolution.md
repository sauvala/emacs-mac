# Resolution: stage 1 gate passed

2026-09-26, branch `treesit-stage1`. The code, ERT and latency gates
passed as recorded in the [progress note](2026-09-26-progress.md). This
note records the last gate, parse stats from a day of editing.

## A replay stands in for the day of editing

The user had little code to edit, so the user agreed to close the gate on
a replay of typing edits plus the stats of the live editing that did
happen. `test/manual/redisplay-bench/ts-replay.el` visits real files
with their tree-sitter parser and, at seeded random lines, types a
word, deletes it, adds and removes a newline, and types and deletes
each of `" ' ( { [` at the indentation, reparsing after every edit.
Runs used the stage 1 build and the user's grammars of that morning
(the old TypeScript grammar included). Times are reparses only, in ms.

| Set | Files | Size | Edits | p99 | Max | Over 1 / 3 / 8 ms |
|---|---|---|---|---|---|---|
| The user's own files | 177 | 662 KB | 105,600 | 0.35 | 988 (\*) | 169 / 51 / 5 |
| cpython, django, fastapi, vscode | 224 | 6.2 MB | 43,200 | 6.3 | 29 | 2,693 / 1,159 / 281 |
| TypeScript compiler sources | 59 | 7.1 MB | 11,800 | 1.9 | 48 | 345 / 73 / 18 |

(\*) Leaving out the 596 s hang caused by the old TypeScript grammar,
which is replaced now; see the progress note and
`test/manual/redisplay-bench/ts-grammar-hang.ts`. The 988 ms reparse is
the backspace that undid that edit.

Repository revisions: cpython `8122ff4`, django `4fab678`, fastapi
`192b121`, vscode `90da900`, TypeScript `7e133be`; 30 sites per file
for the user's files, 10 for the others.

Live editing in the installed build (three sessions, summed from
`~/.emacs.d/treesit-budget-stats.eld`): 257 reparses, 54 ms in all,
at most 1.6 ms; 7 over 1 ms, none over 3 ms. Six first parses, at
most 7.4 ms.

## What it means for stage 2

- The user's own files almost never reparse past 3 ms, so stage 2
  changes little there beyond protecting against outliers like the
  grammar hang.
- Large real-world files do: in the repositories, 0.65% of edits
  reparse past 8 ms, most of them openers and backspaces. Stage 2's
  latency scenario (a `"` in an 800 KB file) is representative of these.
- The worst replayed reparse after the grammar fix is 48 ms, so a 2 ms
  slice budget would spread it over about 24 slices.
- Stats keep being logged at every exit; stage 2's own gate needs a
  day of its stats in any case.

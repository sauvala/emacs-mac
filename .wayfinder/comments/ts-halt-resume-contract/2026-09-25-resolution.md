# Resolution: Tree-sitter halt and resume contract

Resolved 2026-09-25 by an AFK research subagent. Full findings with
source citations: [research/ts-halt-resume-contract.md](../../research/ts-halt-resume-contract.md)
(tree-sitter v0.27.0 `6070dbfefd32`; nemesis `81d8a9da939`).

- **What resumes a parse:** the parser's internal state alone. `old_tree`
  is ignored on a resume; the input read function and payload may change,
  but the bytes must be identical. A language change resets the parse.
  Pass the options (the callback) on every call.
- **An edit during a halt needs `ts_parser_reset`.** A halted parse keeps
  the pre-edit tree, so every buffer edit, visible-region change or
  included-range change must reset it and throw away the halted work.
  Idle slices therefore cannot carry a parse across an edit; they restart.
- **Callback frequency:** every 100 parser operations, about 10-20 us
  apart; its cost is within noise. A 1-3 ms budget holds for ordinary code
  and incremental reparses. It does not hold for a single giant token
  (an 8 MB string took 78 ms without a callback) or for the end-of-file
  balancing step (8.3 ms on a 12 MB JSON array).
- **Threads:** the library has no thread-local state, so a halted parser
  can be resumed on another thread after a synchronized handoff. The
  blockers are in Emacs: `ts_set_allocator (xmalloc, ...)` can signal a
  Lisp error and touch profiler state, and `treesit_read_buffer` reads
  buffer internals directly. The callback must never quit or longjmp.
- **Versions:** `ts_parser_parse_with_options` has existed since 0.25.0
  (language ABI 15). Emacs accepts 0.20.2 and later. Declare the function
  under `#if TREE_SITTER_LANGUAGE_VERSION >= 15`; on Windows, load it
  with `LOAD_DLL_FN_OPT`. Fall back to `ts_parser_parse` with no
  budgeting.
- **Possible upstream bug, not reproduced:** changed included ranges are
  not rebuilt on a resume (`parser.c:2138`, `2153`). This matters only
  for ranged parsers, which are out of scope.

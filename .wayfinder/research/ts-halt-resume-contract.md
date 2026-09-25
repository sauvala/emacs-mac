# Tree-sitter halt and resume contract

Research date: 2026-09-25.
Question: [Tree-sitter halt and resume contract](../issues/19-ts-halt-resume-contract.md).

Source revision: tree-sitter **v0.27.0**, commit
`6070dbfefd326bd735e5683eb128cc1b57dad0c0` (same release as the installed
Homebrew `/opt/homebrew/Cellar/tree-sitter/0.27.0`); `api.h` for v0.20.2,
v0.24.0, v0.25.0 and v0.26.0 and `parser.c` for v0.25.0 and v0.26.0 were
compared. Emacs side: `src/treesit.c` at nemesis `81d8a9da939` (last change to
the file: `c130f1db476`).

Citations: `api.h:N` is `/opt/homebrew/opt/tree-sitter/include/tree_sitter/api.h`;
`parser.c:N`, `lexer.c:N`, `tree.c:N`, `subtree.c:N`, `alloc.c:N` are
`lib/src/` at the commit above
(<https://github.com/tree-sitter/tree-sitter/blob/v0.27.0/lib/src/parser.c>).
Context7 (`/tree-sitter/tree-sitter`) was queried for halt/resume and
concurrency; it returned only the parsing guide and the concurrency note
(trees are not thread safe, copy with `ts_tree_copy`), nothing beyond `api.h`
on resume, so the answers below come from source.

## Summary

- The documented contract is one sentence: after a callback halt the parser
  "will resume where it left off on the next call to `ts_parser_parse` or other
  parsing functions" unless `ts_parser_reset` is called first (`api.h:372-381`).
  No other condition is documented.
- In source, resume depends only on internal parser state, not on the
  arguments. The **text** must be byte-identical to the text of the first
  call; the `old_tree` argument is ignored on resume; the `TSInput` payload and
  read function may change. Included ranges must not change, and a
  language change resets the parse.
- The callback is invoked every 100 parser operations, roughly every 10-20 us
  on an M2. A 1-3 ms budget holds for ordinary parsing but **not** for a
  single huge token or for the end-of-input tree-balancing step (measured 78
  ms and 8 ms without any callback).
- There is no thread-local state in the library. A halted `TSParser` can be
  resumed on another thread if the handoff is serialized. The Emacs side is
  what blocks a worker: `ts_set_allocator (xmalloc, ...)` and
  `treesit_read_buffer`.
- `ts_tree_edit` on the old tree does **not** reach the halted parse. The
  halted parse keeps using the pre-edit tree, so after any buffer edit the
  caller must `ts_parser_reset`. `ts_parser_reset` discards the halted parse
  completely.
- `ts_parser_parse_with_options` / `TSParseOptions` first appear in
  **v0.25.0**. The older timeout and cancellation-flag API exists from before
  0.20.2 through 0.25.x and was removed in v0.26.0.

## Resume conditions

Evidence, `ts_parser_parse` (`parser.c:2121-2249`):

- Whether a call resumes is decided by `ts_parser_has_outstanding_parse`
  (`parser.c:1969-1976`): `canceled_balancing`, a live external-scanner
  payload, a stack not in state 1, or nodes since the last error. The
  arguments do not affect it. A successful parse ends with
  `ts_parser_reset` (`parser.c:2246-2247`), so the next call starts fresh.
- **`old_tree`:** consulted only on a fresh start. The parser then retains the
  root subtree (`ts_subtree_retain`, `self->old_tree`) and seeds
  `reusable_node` from it (`parser.c:2150-2158`). On resume the argument is
  used only in the language check at `parser.c:2127-2130`: NULL passes, and a
  tree of another language makes the call return NULL. Otherwise it is
  ignored. Because the parser holds its own reference, the caller may even
  `ts_tree_delete` its `TSTree` while the parse is halted.
- **Input (`TSInput`):** every call does `ts_lexer_set_input`
  (`parser.c:2137`). That stores the new struct, clears the cached chunk and
  re-reads at `current_position` (`lexer.c:416-420`). A different payload,
  read function or chunking is therefore accepted. Stack and token-cache
  subtrees hold only lengths and symbols, so the **bytes** at every offset,
  both before and after the halt point, must equal the bytes seen by the
  first call. The library cannot detect a mismatch and would silently build a
  tree for mixed text. This was verified by alternating two read functions
  with different payloads (identical content) on every slice; the resulting
  tree matched the one-shot parse (see Measurements).
- **Language:** `ts_parser_set_language` calls `ts_parser_reset` first
  (`parser.c:2033-2034`), so a language change discards the halted parse.
- **Included ranges:** `ts_parser_set_included_ranges` only replaces the
  lexer's ranges and re-seeks (`parser.c:2082-2088`, `lexer.c:478-503`).
  It does **not** reset. A range change during a halt would silently
  continue with mixed ranges. There is a further trap in the library:
  `included_range_differences`, which stops node reuse inside regions whose
  inclusion changed (`parser.c:740-750`, used at `parser.c:798`), is cleared on
  every call (`parser.c:2138-2139`) but recomputed only on a fresh start
  (`parser.c:2153-2157`). After the first resume, old-tree nodes inside a
  changed included range can be reused. If the included ranges differ from
  `old_tree`'s, the parse should run to completion or not be budgeted
  (inference from source; not observed).
- **Encoding / decode:** part of `TSInput`, taken on each call. Keep them
  constant.
- `TSParseOptions` is per call: `parse_with_options` installs the options and
  clears them afterwards (`parser.c:2251-2263`). A resume through plain
  `ts_parser_parse` therefore runs **without** a callback until the parse
  completes. Each slice must pass the options again.

## Callback frequency, cost, and whether 1-3 ms is enforceable

- `ts_parser__check_progress` (`parser.c:1574-1592`) adds `operations` to a
  counter and calls the callback only when the counter reaches
  `OP_COUNT_PER_PARSER_CALLBACK_CHECK = 100` (`parser.c:81`). The counter is
  zeroed at the start of each call (`parser.c:2141`).
- An operation is one iteration of the lookahead loop in
  `ts_parser__advance` (`parser.c:1645-1649`). That covers the token lex, or
  the reuse of a whole old-tree subtree, plus the parse actions for that
  lookahead. During final balancing it is one tree-stack pop, or one
  `ts_subtree_compress` step weighted by `i >> 4` truncated to `uint8_t`
  (`parser.c:1926`, `1940-1951`).
- **Uninterruptible units:**
  1. Lexing one token (`ts_parser__lex`, `parser.c:505` onward, including
     grammar external scanners), whatever its length.
  2. A single `ts_subtree_compress` call on a long repetition.
  3. `ts_parser__condense_stack`, error recovery, and `ts_tree_new` between
     checks.
  4. Emacs's own post-parse work (`ts_tree_get_changed_ranges` in
     `treesit_get_affected_ranges`, after-change functions,
     `treesit.c:1996-1997`), which is outside the parse.
- `TSParseState` (`api.h:96-100`) gives the payload, `current_byte_offset`
  and `has_error`. The offset is not updated during balancing
  (`position == NULL`).
- **Cost:** one indirect call every 100 operations. With a callback that reads
  `CLOCK_UPTIME_RAW` and compares, overhead was within noise (−5 % to +2.4 %
  total, including per-slice resume costs of roughly 10 us).

### Measurements

Bench: `bench.c` in the session scratchpad (not committed). It uses installed
libtree-sitter 0.27.0 with grammars from `~/.emacs.d/tree-sitter` on an Apple
M2 at -O2, with 1-byte reads (like `treesit_read_buffer`) unless noted.

| Input | Plain parse | Callback gap p50 / p99 / max | 1 ms budget: slices, max slice | Tree equal |
|---|---|---|---|---|
| Python, 6.0 MB (stdlib x10) | 500 ms | 21 / 46 / 1290 us | 467, 1.57 ms | yes |
| Python, 6.0 MB, 4 KB reads | 420 ms | 20 / 37 / 1279 us | 414, 2.11 ms | yes |
| JSON, 12.2 MB | 705 ms | 11 / 15 / **8255 us** | 710, **8.58 ms** | yes |
| Python, one 8 MB string literal | 78 ms | **no callback at all** | 1 slice, **78 ms** | yes |
| Python 0.6 MB, 2 ms budget | 48 ms | 22 / 46 / 441 us | 24, 2.19 ms | yes |
| 1-char edit in 6 MB Python (incremental) | 7.1 ms | — | 7 slices, 1.09 ms | yes |
| 1-char edit in 12 MB JSON (incremental) | 13.6 ms | — | 10 slices, 1.45 ms | yes |

The maximum gaps occur at `current_byte_offset == length` (instrumented
run), which is the accept and balancing phase. **Conclusion:** a 1-3 ms slice
budget is met for ordinary code and for incremental reparses. However, the
library cannot bound one giant token (a 78 ms stall with zero callbacks, since
fewer than 100 operations ran) or the end-of-file balancing of a huge flat
repetition (8 ms for a 40 000-element JSON array). Budgeted parsing reduces
latency; it does not provide a hard deadline.

## Threads

- There are no `thread_local`, `_Thread_local` or `__thread` declarations in
  `lib/src`. The only mutable globals are the allocator hooks
  `ts_current_malloc` and related (`alloc.c:33-47`), which are set once. All
  parse state (stack, lexer, token cache, `old_tree`, `reusable_node`,
  external-scanner payload, subtree pool) lives in `struct TSParser`
  (`parser.c:89-115`). Subtree reference counts are atomic (`subtree.c:572-594`,
  `atomic.h`). A `TSParser` is not safe for concurrent use, but a halted
  parser can be resumed on another thread provided the handoff has a
  happens-before edge (a mutex or queue) and no other thread touches the
  parser meanwhile. The docs require a separate `ts_tree_copy` for any tree
  used on two threads at once (Context7: "Concurrency", `docs/src/using-parsers/3-advanced-parsing.md`;
  `api.h:412-413`).
- Grammar external scanners are outside the library contract. Their state
  should be per-parser (the `external_scanner_payload`), but a grammar with
  static state would break this. Audit the grammars Emacs actually loads.
- The Emacs side blocks worker resumption:
  - `ts_set_allocator (xmalloc, xcalloc, xrealloc, xfree)` (`treesit.c:571`).
    `xmalloc` calls `memory_full` (a Lisp signal/longjmp) on failure and
    `MALLOC_PROBE` (profiler state) (`alloc.c:658-665`). Neither is safe off
    the Lisp thread.
  - `treesit_read_buffer` (`treesit.c:2008` onward) reads `struct buffer`
    text, gap and rope directly.

  A worker needs either a snapshot of the text and a plain allocator, or
  exclusive buffer access. A longjmp out of the callback or allocator would
  leave the `TSParser` mid-mutation. The callback must only return a bool,
  and `maybe_quit` must never run inside it.

## Effect of `ts_tree_edit` and `ts_parser_reset` on a halted parse

- `ts_tree_edit` (`tree.c:97-105`) rewrites `tree->root` through
  `ts_subtree_edit`, which clones any subtree with `ref_count > 1`
  (`subtree.c:284-290`). The halted parser holds a reference on the old root
  (`parser.c:2151`), so the edit produces a new root for the caller's
  `TSTree`. The parser's snapshot keeps the **pre-edit** tree and pre-edit
  offsets, and its stack already covers pre-edit text. Resuming after an edit
  would mix old structure with new text. **Every Emacs buffer change that
  reaches `treesit_record_change` / `ts_tree_edit` (`treesit.c:1300-1314`)
  must discard the halted parse with `ts_parser_reset`.** A changed visible
  region or new included ranges set by `treesit_sync_visible_region`
  (`treesit.c:1874`) or `treesit-parser-set-included-ranges`
  (`treesit.c:2827`, `2834`) must do the same. Then restart from the edited
  `old_tree`.
- `ts_parser_reset` (`parser.c:2094-2119`) destroys the external-scanner
  state and releases the retained `old_tree`, the reusable-node cursor, the
  stack, the token cache and any `finished_tree`. It clears
  `canceled_balancing`, the options and the parse state. The next call is a
  fresh parse. Nothing of the halted work survives, so an edit during a long
  halted parse throws away all slices done so far (the incremental edit rows
  above show a restart from an edited tree is cheap).

## Version availability and loading in `treesit.c`

- `TSParseOptions` / `ts_parser_parse_with_options` are absent from the
  v0.24.0 `api.h` and present from **v0.25.0**, the first release with
  `TREE_SITTER_LANGUAGE_VERSION 15`. v0.25.0's `parser.c` already has
  `canceled_balancing` resumable balancing (lines 118, 1862-1945).
  `ts_parser_set_timeout_micros` and `ts_parser_set_cancellation_flag` exist
  in v0.20.2-v0.25.x, with the same "resume by calling again with the same
  arguments, or `ts_parser_reset`" text (v0.24.0 `api.h:248-258`), and were
  removed in v0.26.0. The v0.26.0 and v0.27.0 `ts_parser_parse` bodies differ
  only in the added `old_tree->language` check.
- Emacs accepts **tree-sitter ≥ 0.20.2** (`configure.ac:4112`; a ≥ 0.6.3
  fallback probe follows at `configure.ac:4118`).
- `DEF_DLL_FN` / `LOAD_DLL_FN` exist only under `#ifdef WINDOWSNT`
  (`treesit.c:37` onward; macros in `w32common.h:77-97`). `LOAD_DLL_FN`
  fails the whole library load when a symbol is missing. `LOAD_DLL_FN_OPT`
  leaves the pointer NULL. On macOS the library is linked directly: `src/emacs`
  links `/opt/homebrew/opt/tree-sitter/lib/libtree-sitter.0.27.dylib`, a
  versioned install name, so the header version at build time matches run
  time.
- Recommended pattern (following the existing
  `#if TREE_SITTER_LANGUAGE_VERSION >= 15` switch for `ts_language_abi_version`,
  `treesit.c:41-45`, `104-107`, `189-193`, `254-258`):
  - under `>= 15`, declare `DEF_DLL_FN (TSTree *, ts_parser_parse_with_options, (TSParser *, const TSTree *, TSInput, TSParseOptions))`;
  - load it with `LOAD_DLL_FN_OPT` on Windows, since a DLL older than the
    header would otherwise fail the whole load;
  - add the `#undef`/`#define fn_` pair;
  - at run time, use it when the function pointer is non-NULL (always on
    non-Windows builds), and otherwise fall back to plain `ts_parser_parse`,
    that is, no budgeting.
  - Optionally, `< 15` headers could budget with `ts_parser_set_timeout_micros`
    (also checked every 100 operations in those versions, with the same
    resume semantics). It is probably not worth a code path.

## Open points for the design ticket

- A 78 ms single-token stall shows budgeting cannot bound worst-case latency.
  Any deadline claim needs a separate mitigation (e.g. skipping budgeting for
  files with known pathological tokens, or accepting the stall).
- The included-range-differences reset on resume looks like an upstream
  defect. It has not been reproduced here. Treat parsers whose included
  ranges changed since `old_tree` as non-budgetable until tested.

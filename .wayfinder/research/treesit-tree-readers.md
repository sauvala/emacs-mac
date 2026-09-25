# Readers of a tree-sitter parser tree

Date: 2026-09-25. Question: [Inventory every reader of a parser tree](../issues/20-treesit-tree-access-inventory.md).

Source revision: nemesis `22e39f421ab` (`src/treesit.c`, `lisp/treesit.el`,
`lisp/progmodes/python.el`, `lisp/progmodes/typescript-ts-mode.el`), and the
user's `~/.emacs.d/elpa/indent-bars/indent-bars-ts.el`.

## C: parsing happens at two entry points

`treesit_ensure_parsed` (`treesit.c:1954`) is the only function that
parses. It is reached from:

| Entry | Line | Reached by |
|---|---|---|
| `treesit-parser-root-node` | `treesit.c:2682` | `treesit-buffer-root-node`, `treesit-node-at`, `treesit-node-on`, and `treesit_resolve_node` (`:3985`), which `treesit-query-capture` and the other query and search functions call when given a parser or a language instead of a node |
| `treesit-parser-changed-regions` | `treesit.c:2978` | `treesit--pre-redisplay` only |

Everything else reads `XTS_PARSER (p)->tree` without parsing:

- `treesit_record_change_1` (`:1447`) applies `ts_tree_edit` to the tree
  in place and sets `need_reparse`. Under budgeting, it must also
  `ts_parser_reset` a halted parse; see
  [Tree-sitter halt and resume contract](../comments/ts-halt-resume-contract/2026-09-25-resolution.md).
- `treesit_sync_visible_region` (`:1683`) edits the tree for narrowing
  changes. It runs at the start of `treesit_ensure_parsed`, and the same
  reset rule applies.
- `treesit_cursor_helper` (`:4391`) and node functions work on a node's
  tree. They never parse; `treesit_check_node` (`:2984`) signals
  `treesit-node-outdated` when the node's timestamp differs from the
  parser's.
- Parser creation, deletion and GC (`:2110`, `:2182`) own the tree.

## Node objects and cursors

- A Lisp node stores its parser and the parser's timestamp at creation
  (`:2155`). A reparse increments the timestamp (`:1994`), which makes
  every older node outdated. While a parse is pending, nodes made from the
  edited old tree stay valid until the new tree is installed. That is
  today's behaviour between an edit and the next reparse.
- No query cursor or tree cursor lives across calls; each is created per
  call.
- Query predicates and `treesit_pred_with_guard` (`:2320`, `:3891`) signal
  `treesit-buffer-changed` if Lisp called from a predicate triggers a
  reparse. A pending parse must not complete inside a predicate. If
  completion happens only at a safe point (installed by the Lisp thread
  outside queries), this holds.

## Lisp: who forces a parse, and when

| Caller | Runs from | Forces a parse via | Under a pending parse it should |
|---|---|---|---|
| `treesit--pre-redisplay` (`treesit.el:2324`) | `pre-redisplay-functions` | `treesit-parser-changed-regions` | skip; completion marks the changed ranges instead |
| `treesit-font-lock-fontify-region` (`:2161`) | jit-lock during redisplay; `font-lock-ensure` | `treesit-parser-root-node` for every parser | defer the region under jit-lock; wait under `font-lock-ensure` |
| `treesit--pre-syntax-ppss` (`:2328`) | `syntax-propertize-extend-region-functions`, so any `syntax-ppss`, including `font-lock-default-fontify-region` (`font-lock.el:1582`) | calls `treesit--pre-redisplay` | wait. Syntax properties must match the tree. |
| Mode `syntax-propertize-function`s: `python--treesit-syntax-propertize`, `typescript-ts--syntax-propertize` (`typescript-ts-mode.el:831`) | `syntax-propertize` | `treesit-node-at`, `treesit-query-capture` with a language | wait (as above) |
| `treesit-indent`, `treesit-indent-region` | commands, and `electric-indent-mode` on RET and electric characters | root node | wait |
| Navigation (`treesit-beginning-of-defun`, sexp and thing commands, `treesit-simple-imenu`, outline, `which-function`) | commands and timers | root node, `treesit-node-at` | wait |
| `treesit-update-ranges` in the notifier (`:2290`) | notifiers after a reparse | queries the host parser | out of scope (ranged parsers stay synchronous) |
| `indent-bars-ts` (user's config, `python-base-mode`) | font-lock keywords during jit-lock (`indent-bars-ts.el:247`, `:271`); scope update on an idle timer (`:380`) | `treesit-node-on`, `treesit-query-capture` on its parser | defer as part of the jit-lock chunk; the idle-timer update waits |

## Consequences for the design

1. Only two call sites run inside redisplay and can avoid waiting:
   `treesit--pre-redisplay` and jit-lock's call of the font-lock
   function. Every other reader waits for the parse to finish, which is
   no longer than today's synchronous parse.
2. Deferral must cover the **whole jit-lock chunk**, not only
   `treesit-font-lock-fontify-region`. Third-party font-lock keywords
   (`indent-bars`), and `syntax-propertize` called by
   `font-lock-default-fontify-region`, read the tree from inside the same
   fontification. The natural hook is a jit-lock check, like
   `jit-lock--defer-fontification-p`, that asks whether the buffer's
   primary parser has a parse pending.
3. `syntax-ppss` is the risky reader. It runs from commands directly
   after a keystroke: `electric-pair-mode` on `"`, `show-paren` on its
   timer, and many motion commands. None of these are enabled in the
   user's configuration apart from the default `show-paren-mode`
   (timer, 0.125 s) and `electric-indent-mode` (RET). If a command runs
   `syntax-ppss` right after the edit, the parse completes synchronously
   inside that command, and budgeting saves nothing for that keystroke.
4. A completed parse must be installed only at a safe point outside
   queries and predicates, so that `treesit-buffer-changed` cannot fire.

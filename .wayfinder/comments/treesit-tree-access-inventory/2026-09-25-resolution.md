# Resolution: Inventory every reader of a parser tree

Resolved 2026-09-25 (AFK task). The table is
[research/treesit-tree-readers.md](../../research/treesit-tree-readers.md).

- Only `treesit_ensure_parsed` parses. It is reached from
  `treesit-parser-root-node` (and everything that resolves a parser or a
  language to its root) and from `treesit-parser-changed-regions` (only
  `treesit--pre-redisplay`).
- Only two readers run inside redisplay and can avoid waiting:
  `treesit--pre-redisplay` and jit-lock fontification. Every other reader
  (indentation, navigation, imenu, `syntax-ppss`, mode
  `syntax-propertize` functions, idle timers) must wait.
- Deferral has to cover the whole jit-lock chunk. `indent-bars` font-lock
  keywords and `font-lock-default-fontify-region`'s `syntax-propertize`
  read the tree from inside the same fontification.
- `syntax-ppss` right after an edit (from `electric-pair-mode` or motion
  commands) completes the parse synchronously. The user's configuration
  runs it only from `show-paren`'s timer.
- A completed parse must be installed at a safe point outside queries and
  predicates, or `treesit-buffer-changed` can fire.

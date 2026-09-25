---
id: ts-halt-resume-contract
title: "Tree-sitter halt and resume contract"
status: open
labels: ["wayfinder:research"]
parent: treesit-budgeted-parse
assignee: null
---

## Question

What exactly does tree-sitter 0.27 (and the oldest tree-sitter `src/treesit.c` still loads) promise for a parse halted by the `progress_callback` of `ts_parser_parse_with_options`?

- What must be identical when the parse resumes: the input text, the `old_tree` pointer, the included ranges, the language?
- How often is the callback called? Can a budget of 1-3 ms be kept on large files?
- What does the callback cost?
- Can a halted parser be resumed on a different thread (no thread-local state)?
- What happens to a halted parse after `ts_tree_edit` on the old tree, or after `ts_parser_reset`?
- How should `treesit.c` load `ts_parser_parse_with_options` optionally, falling back to `ts_parser_parse` on older libraries?

Cite the `api.h` and `lib/src/parser.c` sources.

## Blocked by

None.

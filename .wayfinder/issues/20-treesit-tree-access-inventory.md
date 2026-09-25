---
id: treesit-tree-access-inventory
title: "Inventory every reader of a parser tree"
status: open
labels: ["wayfinder:task"]
parent: treesit-budgeted-parse
assignee: null
---

## Question

Which code paths read `XTS_PARSER (p)->tree` or call `treesit_ensure_parsed`? Cover `src/treesit.c` and the Lisp entry points in `lisp/treesit.el` and the tree-sitter modes. For each, record:

- whether it runs during redisplay (`pre-redisplay-functions`, jit-lock, `syntax-propertize` from redisplay) or from commands and timers;
- what it would do with a tree that is out of date while a parse is pending: wait, defer, or use the stale tree;
- node objects and query cursors that hold a tree across calls;
- the timestamp checks for outdated nodes.

This is an AFK fact-finding task. Record the result as a table under `research/`.

## Blocked by

None.

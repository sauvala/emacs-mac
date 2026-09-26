---
id: pending-parse-display-policy
title: "What redisplay shows while a parse is pending"
status: closed
labels: ["wayfinder:grilling"]
parent: treesit-budgeted-parse
assignee: null
---

## Question

When a reparse has been halted and not yet finished, decide:

- what redisplay shows for regions whose faces are stale or unfontified;
- which callers (from the inventory) defer, which wait for the parse, and which may read the edited old tree;
- whether `treesit--pre-redisplay` and `syntax-propertize` defer;
- what `(font-lock-ensure)` and `font-lock-flush` do while a parse is pending.

## Blocked by

- [Inventory every reader of a parser tree](20-treesit-tree-access-inventory.md)

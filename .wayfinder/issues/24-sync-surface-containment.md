---
id: sync-surface-containment
title: "Keep the change small in upstream files"
status: open
labels: ["wayfinder:grilling"]
parent: treesit-budgeted-parse
assignee: null
---

## Question

Decide where the new code lives so the weekly GNU master sync stays cheap:

- a new file (such as `src/treesit-budget.c`) behind a small hook in `treesit_ensure_parsed`, or inline changes;
- guards, if any (a configure option, `HAVE_MACGUI`, or none, since it is plain C);
- which `lisp/treesit.el` changes go into a separate file;
- a note in AGENTS.md for resolving future sync conflicts in this area.

## Blocked by

None.

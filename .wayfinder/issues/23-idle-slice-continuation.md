---
id: idle-slice-continuation
title: "How a halted parse continues on the Lisp thread"
status: open
labels: ["wayfinder:grilling"]
parent: treesit-budgeted-parse
assignee: null
---

## Question

Decide how the no-thread stage continues a halted parse:

- slice length, and how slices are scheduled (idle timer, `timer-idle-list`, or between `read_socket` polls);
- what happens when an edit arrives while a parse is halted: reset and restart from the edited old tree, or finish synchronously first;
- how starvation is bounded when the user types continuously in a huge file;
- what triggers the redisplay after the parse completes.

## Blocked by

- [Tree-sitter halt and resume contract](19-ts-halt-resume-contract.md)

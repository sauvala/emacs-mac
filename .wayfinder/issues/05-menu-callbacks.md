---
id: menu-callbacks
title: Choose menu preparation and GUI-to-Lisp callback contracts
status: open
labels: ["wayfinder:grilling"]
parent: macos-app-integration
assignee: claude-session-05
---

## Question

How will menu preparation, validation, action delivery, Help/Services, quit,
and other callbacks cross the GUI/Lisp boundary without deadlock or unsafe Lisp
reentry? Decide snapshot freshness and ownership, GC roots, queued action
lifetime, frame changes or destruction, and busy-Lisp behavior. Identify how
cancel/rebuild/reopen menus and Carbon queue interception can be retired.

## Blocked by

- [Choose application event-loop ownership and Lisp scheduling](04-event-loop-ownership.md)

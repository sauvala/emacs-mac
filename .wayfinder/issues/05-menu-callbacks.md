---
id: menu-callbacks
title: Choose menu preparation and GUI-to-Lisp callback contracts
status: closed
labels: ["wayfinder:grilling"]
parent: macos-app-integration
assignee: null
---

## Question

How will menu preparation, validation, action delivery, Help/Services, quit,
and other callbacks cross the GUI/Lisp boundary without deadlock or unsafe Lisp
reentry? Decide snapshot freshness and ownership, GC roots, queued action
lifetime, frame changes or destruction, and busy-Lisp behavior. Identify how
cancel/rebuild/reopen menus and Carbon queue interception can be retired.

## Blocked by

- [Choose application event-loop ownership and Lisp scheduling](04-event-loop-ownership.md)

## Discussion

- [Recorded decisions](../comments/menu-callbacks/2026-09-23-discussion.md)
- [Resolution](../comments/menu-callbacks/2026-09-23-resolution.md)

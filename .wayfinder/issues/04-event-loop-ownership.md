---
id: event-loop-ownership
title: Choose application event-loop ownership and Lisp scheduling
status: open
labels: ["wayfinder:grilling"]
parent: macos-app-integration
assignee: null
---

## Question

Which documented event-loop architecture can satisfy the agreed behavior across
supported macOS versions? Compare continuous AppKit ownership with viable
alternatives and published upstream work. Specify thread ownership, wakeups,
input delivery, startup/shutdown, nested tracking/modal loops, and the limits on
synchronous GUI/Lisp calls. Identify a decisive prototype if evidence is insufficient.

## Blocked by

- [Define native responsiveness and acceptance scenarios](03-native-behavior.md)

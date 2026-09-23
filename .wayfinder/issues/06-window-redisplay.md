---
id: window-redisplay
title: Choose window lifecycle and redisplay coordination
status: open
labels: ["wayfinder:grilling"]
parent: macos-app-integration
assignee: claude-session-05
---

## Question

How will native geometry and lifecycle changes reach Lisp and redisplay under
the chosen event loop? Decide ownership and ordering during live resize,
minimize/restore, zoom/fullscreen, close/save, multiple frames, display changes,
and application termination. Define behavior while Lisp cannot redraw, how
automation observes windows, and how synthetic tracking events and undocumented
window/control preferences can be retired.

## Blocked by

- [Choose application event-loop ownership and Lisp scheduling](04-event-loop-ownership.md)

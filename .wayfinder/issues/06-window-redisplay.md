---
id: window-redisplay
title: Choose window lifecycle and redisplay coordination
status: closed
labels: ["wayfinder:grilling"]
parent: macos-app-integration
assignee: null
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

## Discussion

- [Recorded decisions](../comments/window-redisplay/2026-09-23-discussion.md)
- [Resolution](../comments/window-redisplay/2026-09-23-resolution.md)

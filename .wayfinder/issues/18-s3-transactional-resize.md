---
id: s3-transactional-resize
title: "S3 follow-up: present live-resize frames with the window change"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
---

## Problem

Under the persistent loop, a live-resize step while Lisp is idle applies
the new size with Lisp access, but redisplay runs later on the Lisp
thread, and the Metal presenter copies the backbuffer to a drawable
asynchronously on its own queue. The screen can therefore show a
backbuffer from a different moment than the window's current size.

Real drags on macOS 27 (reported by the user 2026-09-24) showed this as:
- blank frames between steps, from `redraw_frame`'s clear of the
  garbaged frame being presented, directly or by a pending presentation
  that ran after the clear was committed;
- a white band on a fast grow, from the resized backbuffer's new area
  (hard-coded white) and from drawables larger than the backbuffer a
  presentation took.

Commits `ad88be181a9`, `fb6cb18a20f` and `a5972084b64` on `nemesis`
removed the visible symptoms: the clear's presentation is held, a held
clear waits (at most 100 ms) until a pending presentation has committed
its copy, and undrawn areas are filled with the frame background. The
first of those fills is ordinary initialization. The hold, the wait and
the presenter's fill work around the unsynchronized presentation
instead of removing it.

## Scope

While Lisp is idle during a live resize, draw and present each step in
the same Core Animation transaction as the window size change, as
native Metal apps do:
- in the live-resize step, with Lisp access, apply the size, run
  redisplay for that frame, and present with
  `CAMetalLayer.presentsWithTransaction` (commit, wait until scheduled,
  then present the drawable), outside the async presenter;
- return to asynchronous presentation when live resize ends;
- keep the W3 fallback while Lisp is busy: the last presentation
  anchored top-left over the layer's background colour.

Running redisplay from a GUI-thread callback must follow the access
rules in AGENTS.md ("Persistent event loop"): only with Lisp access, and
never from a context where access is borrowed from a Lisp request.
Verify primary Apple documentation for `presentsWithTransaction` before
relying on its ordering.

Once this holds, reconsider whether the presentation wait from
`fb6cb18a20f` and the presenter's larger-drawable fill are still needed
and remove them if not.

## Acceptance gate

With a person at the Mac on macOS 27, idle and busy:
- fast hand-driven grow and shrink from edges and corners show no blank
  frames, no white or stale bands, and no text shown at an old size
  outside the window edge, in a screen recording checked frame by frame
  (`ffmpeg -f avfoundation`; `screencapture -v` loses the file if it is
  interrupted);
- busy-Lisp drags keep the W3 presentation and stay within the 100 ms
  responsiveness target;
- the scripted resize scenarios (`idle-resize`, `live-resize`,
  `resize-burst`, `busy-resize-layer`, `idle-resize-layer`,
  `stalled-resize-layer`) and `fullscreen-*` match the recorded evidence
  on both loops;
- a scripted 8 ms-step corner drag (real drags run at about 120 Hz;
  40 ms steps missed the presenter race) shows no blank frames;
- per-step redraw cost is recorded, since a slow redisplay now delays
  the window edge.

## Decisions

- [Window decisions](../comments/window-redisplay/2026-09-23-discussion.md)

## Blocked by

- [S3: Move window lifecycle and redisplay to the new loop](11-s3-windows-redisplay.md)

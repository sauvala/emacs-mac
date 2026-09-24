---
id: s3-transactional-resize
title: "S3 follow-up: present live-resize frames with the window change"
status: closed
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

Not fixed by them (reported 2026-09-24): during a resize the mode line
jiggles. It is drawn at its old position for a moment, then jumps to
the window's new bottom edge. The same lag moves the rest of the
content, but it is most visible at the bottom edge.

## Scope

While Lisp is idle during a live resize, draw and present each step in
the same Core Animation transaction as the window size change, as
native Metal apps do:
- in the live-resize step, apply the size, then have the Lisp thread
  redisplay the frame while the GUI thread waits for a bounded time
  (about one display frame), running Lisp requests meanwhile, as the D3
  open-time menu refresh does (`mac-menu-bar-open-refresh`);
- present that frame from the GUI thread with
  `CAMetalLayer.presentsWithTransaction` (commit, wait until scheduled,
  then present the drawable) inside the resize step's transaction,
  outside the async presenter;
- return to asynchronous presentation when live resize ends;
- keep the W3 fallback while Lisp is busy: the last presentation
  anchored top-left over the layer's background colour.

Redisplay must stay on the Lisp thread even though the GUI has Lisp
access during idle steps: it runs Lisp (fontification, mode-line
`:eval`, `window-size-change-functions` such as `perfect-margin`), and
the S4 decisions forbid Lisp on the GUI thread. Agent-adopted
correction (2026-09-24): an earlier draft of this approach, given to
the user in chat, proposed running redisplay in the GUI callback.
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
- the mode line follows the bottom edge without jumping back;
- a step whose redraw misses the wait shows the W3 presentation, never
  a late frame at a size the window no longer has;
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

## Progress (2026-09-24, agent-adopted)

Implemented on branch `transactional-resize`; scripted checks pass
(evidence
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-sync-resize.md`).
- `-viewWillStartLiveResize` switches the frame's Metal context to
  synchronous presentation (`presentsWithTransaction`); the end of live
  resize switches back and presents any ready frame asynchronously.
  In synchronous mode `emacs_metal_schedule_presentation` marks the
  frame ready with its size instead of using the presenter queue.
- An idle step applies the size, wakes Lisp, and waits for a ready
  frame of the new size with `mac_loop_wait_for_lisp`, then presents it
  (commit, `waitUntilScheduled`, `present`). A late frame is presented
  from the main queue only if the layer still has its size.
- Decisions adopted on the way:
  - Most steps arrived while Lisp finished the previous step's
    redisplay and were deferred (175 of 208). If Lisp was idle at the
    previous step, a step now waits (same bound) for Lisp's input wait,
    which signals the GUI semaphore while `mac_loop_gui_awaits_idle` is
    set. One failed wait marks Lisp busy until a step finds it idle, so
    busy-Lisp drags wait at most once.
  - Default wait 30 ms (`EMACS_MAC_RESIZE_WAIT_MS`, 0 disables): the
    user's configuration needed 15 ms median, 18 ms p90.
  - Fullscreen transitions send live-resize notifications but are
    animated by AppKit; synchronous presentation is skipped while
    `fullScreenTransitionCompletionHandlers` is set (it raised the
    `fullscreen-idle` GUI gap over 100 ms).
  - The workarounds from `fb6cb18a20f` and `a5972084b64` stay: the
    asynchronous path still serves busy-Lisp steps' final frames,
    programmatic resizes, zoom and fullscreen.
- `resize-band.sh`: 62 of 175 frames with an undrawn band (up to
  70 px) with the wait disabled, none with it.

Still open: the acceptance gate's hand-driven checks with a person at
the Mac (mode line following the edge, fast grow/shrink, busy drags).

## Resolution (2026-09-24)

Closed with the user's live confirmation after hand-driven resizes with
their configuration: [resolution](../comments/s3-transactional-resize/2026-09-24-resolution.md).

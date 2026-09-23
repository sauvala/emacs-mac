# Window lifecycle and redisplay discussion

Status: open, awaiting user confirmation. Per the user's 2026-09-23
instruction, the agent adopted its own recommended answers and documented
them for later review. Every decision below is **agent-adopted, not yet
user-confirmed**. The ticket must not close until the user confirms live.
Menu-side counterparts are in
[the menu callback discussion](../menu-callbacks/2026-09-23-discussion.md).

## Source facts used (verified by the parent agent)

A cheaper agent inventoried window and redisplay code; the parent checked the
cited sites at `254f965d9c0`:

- Today `[NSApp run]` is entered only until `applicationDidFinishLaunching:`
  stops it (`src/macappkit.m:2087`); the persistent loop of ticket 04 is new.
- Four event-loop preferences are registered before the application exists:
  on macOS 26+ `NSEventConcurrentProcessingEnabled=NO` and
  `NSApplicationUpdateCycleEnabled=NO` (Carbon queue access, C-g reroute hang,
  deferred menu clicks); on macOS 27+ `NSWindowResizeNeedsTrackingLoop=YES`
  and `NSControlPrefersGestureRecognizerTracking=NO`
  (`src/macappkit.m:2062-2081`). Other registered defaults (press-and-hold,
  autofill heuristics, period substitution, the 11.0 inline-title fix) are
  input or titlebar preferences, not event-loop workarounds.
- Before macOS 27, `windowWillResize:toSize:` restarts resize tracking with
  synthetic release/press events (`suspendResizeTracking:`) so Lisp can
  redraw between sessions; macOS 27 and Shift/Option drags use a bitmap
  snapshot transition layer instead (`src/macappkit.m:3549-3574`). It reads
  `FRAME_SIZE_HINTS` on the GUI thread (`:3561`).
- During a drag, geometry is not sent to Lisp: `viewFrameDidChange:` skips
  live resize and `viewDidEndLiveResize` delivers only the final size via
  `mac_handle_size_change`, which delays `change_frame_size`
  (`src/macappkit.m:7861-7893`, `src/macterm.c:4469`).
- Fullscreen transitions write the `fullscreen` frame parameter through
  synchronous `mac_within_lisp` (`src/macappkit.m:3212`) and completion
  handlers (`storeFullScreenFrameParameter`, `:4069`). Minimize/restore only
  store input events. `updateBackingScaleFactor` writes
  `FRAME_BACKING_SCALE_FACTOR` from the GUI thread without a lock (`:3243`).
- `windowShouldClose:` stores `DELETE_WINDOW_EVENT` and returns NO
  (`:3474`). `terminate:` dispatches `kAEQuitApplication`, handled by
  `mac-ae-quit-application`, which can cancel through the suspended Apple
  event reply (`lisp/term/mac-win.el:927`). Reopen and open-documents are
  Apple events routed to Lisp handlers (`mac-win.el:877`, `:897`); there is no
  `applicationShouldHandleReopen:` delegate.
- Frame creation, deletion, raise/lower, flush and focus locking are
  synchronous `mac_within_gui` calls from the Lisp thread; redisplay draws
  through them (CG drawing queue, or Metal implicit frames).
- Accessibility content getters read buffer state on the GUI thread, guarded
  by `poll_suppress_count`/`inhibit-quit` heuristics and a try-lock
  (`src/macappkit.m:16043`).

## Decisions (agent-adopted)

- **W1. Geometry ownership.** Under the new loop, fields are owned by one
  side. The GUI owns window frame, screen, backing scale, visibility,
  minimized, zoomed and fullscreen state; it applies user changes immediately
  and posts coalesced state-change records (latest per frame and field wins)
  to the input queue. Lisp owns title, size hints, background colour, menu
  and IME data and publishes them (see W11). Lisp changes GUI-owned fields
  only through structural requests. A stale Lisp snapshot never overwrites a
  GUI-owned field.
- **W2. Live resize.** The GUI resizes natively in one tracking session and
  applies size-hint increments from the published hints (no GUI-thread read
  of `FRAME_SIZE_HINTS`). Geometry is posted as coalesced records during the
  drag, not only at its end. Lisp redraws at the new size whenever it runs;
  its presentation requests run in tracking mode (04), so an idle Lisp keeps
  up live. The GUI never waits for Lisp to draw.
- **W3. Presentation while Lisp cannot draw.** Keep the last completed Lisp
  presentation, anchored to the top-left, clipped when shrinking and padded
  with the published frame background colour when growing. Never stretch,
  and never show uninitialized pixels. A Lisp presentation made for an older
  size follows the same rule until a matching one arrives. The prototype
  chooses between layer contents placement and the existing snapshot
  transition layer; the snapshot layer stays for the fullscreen animation.
- **W4. Synthetic tracking events retire.** `suspendResizeTracking:` is not
  used by the new loop on any OS, because W2 lets Lisp draw during the drag.
  The old loop keeps it for pre-27 systems.
- **W5. Undocumented preferences.** The new loop registers none of the four
  event-loop preferences by default. Each can be re-enabled individually by an
  environment override so validation can bypass them one at a time, as 04
  requires. The input, autofill, period substitution and 11.0 inline-title
  defaults are outside this effort and stay unchanged.
- **W6. Minimize, zoom and fullscreen.** User-initiated operations complete
  natively and post state records; Lisp updates `fullscreen`, visibility and
  geometry parameters when it dequeues them. The synchronous
  `store_frame_param` calls from fullscreen transitions retire. A
  Lisp-initiated change is a structural request that returns once AppKit has
  accepted the transition, not when the animation ends; the final state
  arrives as a record, which corrects the parameter if the transition failed.
  The fullboth/fullscreen route through maximized stays a GUI-side sequence
  within one request.
- **W7. Close.** `windowShouldClose:` keeps storing `DELETE_WINDOW_EVENT`
  and returning NO. The GUI marks the frame close-pending; further clicks
  while pending are dropped. If Lisp has not resolved the close within
  100 ms (frame deleted, prompt shown, or delete cancelled), the window shows
  "Waiting for Emacs…" as its subtitle on macOS 11+ or a titlebar accessory
  label on older systems. Lisp publishes the resolution, which clears the
  flag and indicator. Save prompts and hooks run as today.
- **W8. Quit.** Keep `terminate:` sending `kAEQuitApplication` with Lisp
  deciding and cancellation through the suspended reply; do not adopt
  `NSTerminateLater`. One Quit may be pending; repeats are dropped. The same
  100 ms indicator appears on the key frame (or all frames if none is key)
  until Lisp shows a prompt, cancels, or exits. Logout and shutdown quit
  events take the same path.
- **W9. Lisp-initiated window requests.** Create, delete, raise, lower,
  set size/position and parameter changes are structural requests: default
  mode, synchronous, waiting out resize or menu tracking (04). A
  Lisp-requested size change for a frame that the user is resizing is applied
  after the drag ends; the user's final geometry is posted first so Lisp sees
  the order in which things happened.
- **W10. Display and scale changes.** The GUI updates drawable size and layer
  scale immediately and posts a record; Lisp updates
  `FRAME_BACKING_SCALE_FACTOR` and redraws. Until then the old presentation
  is scaled by the layer (blurry, not corrupt). This removes the unlocked
  GUI-thread write.
- **W11. Snapshot publication timing.** Lisp publishes the per-frame window
  snapshot (frame id, title, size hints, background colour, close-pending
  resolution) at the end of each redisplay cycle when changed and on frame
  create/delete. The IME cursor rectangle and marked/selected range are
  published at the end of redisplay with the cursor position. Menu snapshots
  follow ticket 05 (D2).
- **W12. Drawing scheduling.** Redisplay output stays synchronous
  presentation-class requests (04) that run in default, modal and tracking
  modes and end with an explicit `displayIfNeeded`, since `updateWindows` is
  not automatic in tracking mode. The CG drawing queue and Metal implicit
  frames are unchanged. `kill-emacs` flushes pending presentation before
  exit (04).
- **W13. Accessibility and automation.** Window discovery, title, geometry
  and minimized state come from AppKit's own `NSWindow` state, which W1
  keeps current without Lisp. Content queries follow 04 (safe-point lock or
  unavailable); under the new loop they replace the
  `poll_suppress_count`/`inhibit-quit` heuristics.
- **W14. Lifecycle events.** Reopen and open-documents stay Apple events
  routed to Lisp handlers; there is no GUI-only reopen action, to avoid
  duplicate frames. Events arriving before Lisp requests the application stay
  queued (04). Last-frame close and daemon behaviour stay Lisp-decided.
- **W15. Window prototype.** Extend 04's prototype, which already covers
  busy-Lisp resize, minimize, zoom, fullscreen and close acknowledgment, with:
  live redraw during a drag while Lisp is idle; W3 presentation with no
  corrupt pixels while busy, including rapid reversals; a scale change by
  moving between mixed-scale displays; close and Quit repeated clicks with
  unsaved buffers, cancel and save, and the 100 ms indicator; Dock reopen and
  open-file while busy; accessibility discovery of frames while busy; and a
  run with each of the four preferences individually re-enabled and all
  disabled. Fails on any GUI-thread Lisp evaluation, synthetic tracking event,
  or result that needs an undocumented preference.

## Open items for user review

- W7/W8 add a visible "Waiting for Emacs…" indicator; the wording and
  subtitle placement are new UI.
- W9 defers Lisp resizes of a frame being dragged until the drag ends.
- W6 returns from Lisp fullscreen requests before the animation finishes, so
  `frame-parameter` briefly reports the requested state.

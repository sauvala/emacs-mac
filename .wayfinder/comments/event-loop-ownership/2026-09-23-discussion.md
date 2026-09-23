# Event-loop ownership discussion

Status: confirmed by the user and resolved. This records user answers,
not a ticket resolution.

## Agreed so far

- **Loop owner:** a persistent `NSApplication.run` on the main thread for the
  process lifetime. Lisp stays on its existing thread; requests cross through
  run-loop sources. A persistent custom `nextEventMatchingMask:`/`sendEvent:`
  loop is a fallback only if a prototype shows `run` blocks a specific need.
  Extra event pumping in the current loop and Lisp-on-main-thread are rejected:
  neither keeps native operations responsive while Lisp is busy.
- **GUI waits on Lisp:** never unbounded. A bounded wait (about 50 ms, within
  the 100 ms response target) is allowed only when Lisp is at a known safe
  point such as waiting for input. Otherwise the GUI answers from a
  Lisp-published snapshot or a documented unavailable result.
- **Run-loop modes:** presentation and geometry-safe Lisp requests run in
  default, modal and tracking modes; requests that mutate window or menu
  structure run only in default mode. Tickets 05 and 06 classify requests.
- **Lisp-initiated modal loops:** the Lisp thread blocks until the popup
  menu, panel or alert returns, as today. Servicing timers and process output
  during that wait is a possible later refinement, not required.
- **Coexistence:** old and new loops ship in one binary, selected at launch,
  for fresh-process comparison and rollback without rebuilding. Staging belongs
  to the migration ticket.
- **Input and quit:** the GUI thread converts NSEvents into event records on a
  locked GUI-to-Lisp queue and wakes Lisp through the existing self-pipe; the
  Lisp thread moves them into its keyboard buffer. The GUI recognizes the quit
  key from a published copy of the quit configuration and sets an atomic quit
  request plus pending signal; Lisp turns it into `quit-flag` at its next quit
  check. The GUI thread never calls `handle_interrupt` or longjmps.
- **Safe point and GUI reads:** a safe point is when the Lisp thread has
  released the global Lisp lock (for example, waiting for input); the GUI may
  take it by try-lock or within the bounded wait. Lisp publishes immutable
  snapshots for responsiveness data: window list, titles, geometry, minimized
  state, and the IME cursor rectangle and marked/selected range. Content
  queries (accessibility text, substrings) take the lock at a safe point or
  return unavailable. The prototype must confirm the input wait releases the
  lock on this path.
- **Lisp-to-GUI requests:** remain synchronous; Lisp blocks until done. Each is
  delivered by a run-loop source in its mode class and carries its own
  completion signal instead of the shared semaphore pair. Structural requests
  wait out menu or resize tracking. Asynchronous conversion is a later
  optimization.
- **Lisp-initiated modal loops:** popup menus, panels, dialogs, drags and
  printing are safe points because Lisp is parked on them. Their GUI-to-Lisp
  callbacks stay synchronous and unbounded as a documented exception to the
  bounded-wait rule. A timeout-and-skip budget is recorded as later hardening.
  User-initiated menu-bar tracking is not in this class.
- **Multiple Lisp threads:** any thread holding the global lock may issue GUI
  requests with per-request completion; at most one blocking request is
  outstanding. A debug assertion checks the issuer holds the lock. The GUI
  safe-point rule is independent of which thread released it.
- **Startup and termination:** the main thread waits until Lisp requests the
  application (preserving daemon, `-nw` and dump behavior), then enters
  `NSApplication.run` permanently. Early Apple events stay queued. Quit keeps
  the Apple-event route with Lisp deciding, plus the contract's immediate
  acknowledgment (detail for the window ticket). `kill-emacs` asks the GUI to
  finish pending presentation, then the process exits.
- **Decisive prototype:** a launch-selected persistent-loop prototype on
  macOS 27 containing only the persistent `run`, the locked input queue with
  GUI-side quit recognition, per-request Lisp-to-GUI delivery in both mode
  classes, and safe-point lock acquisition. Menus stay on the old path;
  IME/accessibility snapshots are stubbed. With Lisp in a busy loop that never
  waits for input, in fresh processes: edge/corner resize, minimize/restore,
  zoom, fullscreen and close acknowledgment meet the contract limits; C-g sets
  `quit-flag` and interrupts; typed input arrives in order afterwards; idle
  editing and `M-x` work; a stress run interleaving Lisp-to-GUI requests with
  tracking shows no deadlock; instrumentation confirms the input wait releases
  the global lock. It fails if any of these needs an undocumented preference or
  a callback runs on the wrong thread. Menu and redisplay prototypes belong to
  tickets 05 and 06.
- **Launch selection:** an environment variable plus a configure option for
  the compiled default, like the native-menu flags. Opt-in on any OS; the old
  loop stays the default everywhere until migration gates pass. Undocumented
  preferences are bypassed only under the new loop, one at a time.
- **Upstream work:** PRs #153, #135 and #144 are comparison only; the persistent
  loop, safe-point/snapshot rule and per-request delivery address their
  concerns. No maintainer contact now; revisit in the migration ticket, and
  only with explicit user approval.

## Handoff boundaries

Ticket 05 classifies menu and callback requests, native menu-bar tracking under
the cached-menu policy, and Services/Help delivery. Ticket 06 classifies window
requests, live-resize presentation, close/Quit acknowledgment, snapshot
publication timing, and drawing-queue scheduling. Ticket 07 stages the
prototype, OS evidence, and preference retirement.

## Source facts used (verified by the parent agent)

A cheaper agent inventoried the GUI/Lisp boundary; the parent checked the cited
sites. At this revision: IME and accessibility read buffer and glyph state on
the GUI thread, try-locking only with multiple Lisp threads
(`src/macappkit.m` `mac_try_buffer_and_glyph_matrix_access`); `storeEvent:`
reaches `kbd_buffer_store_event`, whose quit path calls `handle_interrupt`
(`src/keyboard.c`); `windowShouldClose:` stores `DELETE_WINDOW_EVENT` and
returns NO; `terminate:` dispatches a Quit Apple event instead of
`NSTerminateLater`; synchronous GUI-to-Lisp calls are limited to help-echo,
drag motion, fullscreen/titlebar parameter changes and native menu
preparation, each gated by a parked-Lisp phase flag; about ten Lisp-to-GUI
calls allow inner Lisp for nested loops.

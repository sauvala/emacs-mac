# Scripted comparison, old and persistent loops (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | `b6fc30668bc` (first table); `5c38600668b` (menu and close/Quit rows, full rerun) (branch `app-loop`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2 |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Deployment target | configure default |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | `--with-metal-rendering --with-native-compilation --with-tree-sitter --enable-mac-app=yes --enable-mac-self-contained --with-rope --with-mailutils` |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP=0` (old) or `=1` (new), `EMACS_MAC_TRACE_LOOP=1`; no menu flags; `-Q` |
| Lisp state | per scenario: idle (input wait), busy (Lisp loop that never waits for input, C-g allowed), second Lisp thread busy |
| Scenario | `run-scenarios.sh both` (scenarios below) |
| Pass/fail/unverified | see table; interactive acceptance is **unverified** |

## Environment limitations

The session had no Accessibility or Screen Recording permission, and the
computer-use daemon was not set up, so no OS-level input or screenshots were
possible. A system dialog stayed frontmost, so Emacs could not become the
active application. Input came from `mac-loop-test-schedule`: real NSEvents
posted with `-[NSApplication postEvent:atStart:]` and native window
operations (`miniaturize:`, `zoom:`, `toggleFullScreen:`, `performClose:`,
`setFrame:display:`) called from GUI-thread timers. The posted events skip the
window server. Plain typing needs a key window's input context, so the
scenarios type control-key commands, which become Emacs events directly.
Posted key events go to the target window's first responder only while test
recording is on. None of this replaces interactive acceptance.

"Max gap" is the longest interval between 5 ms GUI-thread heartbeats on the
main dispatch queue. The heartbeat does not run inside AppKit's own animation
run-loop mode, so the `zoom:` frame animation (about 360 ms) and
`performClose:`'s button highlight (about 100 ms) show up as gaps in both
loops; they are OS animation time, not stalls.

## Results

| Scenario | Old loop | Persistent loop | Assessment |
| --- | --- | --- | --- |
| idle-typing | 50 ms gap; commands in order | 43 ms; in order | pass (scripted) |
| busy-typing (3 s busy) | 2014 ms gaps; commands run afterwards in order | 12 ms; same order | pass (scripted) |
| quit (C-g at 1.5 s during 6 s busy) | quit at 2.87 s | quit at 1.504 s | pass (scripted) |
| live-resize (corner drag during 3 s busy) | 1481 ms gap | 53 ms; geometry converged | pass (scripted); presentation not seen |
| idle-resize | 64 ms | 54 ms; 20 try-lock accesses | pass (scripted) |
| busy-native (set size, minimize, restore, zoom twice, commands during 6 s busy) | 2024 ms | 356 ms = zoom animation; state converged | pass (scripted) |
| fullscreen-busy (enter and leave during 5 s busy) | 2051 ms; ends still fullscreen | 55 ms; leaves on time; ends 833x600, not fullscreen | pass (scripted) |
| fullscreen-idle | 2013 ms | 77 ms | same final state in both (collector runs inside a timer) |
| close-busy (3 closes of a second frame during busy) | 1241 ms | 107 ms = close highlight; frame deleted once | pass (scripted) |
| stress-requests (580 title changes + redisplay during drag, zoom, minimize) | 360 ms | 372 ms = zoom animation; no deadlock | pass (scripted) |
| thread-busy (second Lisp thread busy 3 s) | 23 ms | 62 ms | pass (scripted) |
| menu-idle (perform a custom menu-bar item) | item never runs (old loop needs tracking interception) | runs once | pass (scripted) |
| menu-busy (same during 2 s busy) | 1187 ms; never runs | 22 ms; runs once after busy | pass (scripted) |
| menu-stale (select, then switch buffer before Lisp reads it) | never runs | rejected: `user-error: Menu item no longer available (buffer changed)` | pass (scripted) |
| win-close-dedupe (3 closes of a second frame during busy) | 1256 ms; `handle-delete-frame` 3 times | 102 ms; once | pass (scripted) |
| win-close-indicator (subtitle 150 ms and 1.3 s after a busy close) | empty | "Waiting for Emacs…" both times; frame deleted after busy | pass (scripted); clearing after Lisp resumes is covered only by the frame's deletion |
| win-quit-idle (terminate while idle) | Quit handler once | once | pass (scripted) |
| win-quit-dedupe (3 terminates during busy) | 1163 ms; Quit handler 3 times | 39 ms; once | pass (scripted) |

The full rerun at `5c38600668b` reproduced the first table within a few
milliseconds. `fullscreen-idle` ends with the `fullscreen` parameter set
but the normal size under both loops: its collector runs in a timer and the
exit transition's parameter event is read after the result is written, so
this row does not show a regression. `performItemAtIndex:` stands in for a
click; it skips menu tracking, so the old loop, which fills and dispatches
menus by intercepting tracking, cannot run these menu rows.

Batch suites `src/process-tests`, `src/thread-tests`, `src/timefns-tests`,
`src/keyboard-tests` and `lisp/subr-tests` give the same results under both
`EMACS_MAC_PERSISTENT_LOOP` values.

The access counters (try-lock grants, grants while Lisp was parked, denials,
deferred events, deferred callbacks, queued items) confirm that the GUI took
the global lock during Lisp's input wait (20-23 grants in resize and stress
runs), which ticket 04 required the prototype to show.

## Not covered (unverified)

- Actual mouse drags on window edges through the window server, and what
  is drawn during a busy live resize (W3); no screenshots.
- Real menu-bar tracking with the mouse or keyboard, Services, Help search.
- The cost of the deep menu-bar fill that redisplay now does under the
  persistent loop, in a large configuration.
- Accessibility and window-manager discovery (`windows.py` needs permission).
- Dock reopen, open-file Apple events, Quit with unsaved buffers.
- Mixed-scale displays and Spaces.

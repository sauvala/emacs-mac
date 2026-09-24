# Interactive window, menu and accessibility checks, new loop (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | `7003b5e5e13` plus the `windows.py` fix committed with this file (branch `app-loop`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2, built-in Retina display only |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Deployment target | configure default |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | as in `2026-09-24-macos27-new-interactive.md` |
| Runtime env flags | `run.sh new` (`EMACS_MAC_PERSISTENT_LOOP=1`, `EMACS_MAC_TRACE_LOOP=1`), `-Q`, fixture loaded, background `#102030` |
| Lisp state | idle, and `mac-app-loop-busy` for 10-15 s, started from `emacsclient` |
| Scenario | ticket 11 checklist steps 1, 2 (outward only), 3, 5 and 6; a menu opened during a menu-bar update |
| Pass/fail/unverified | pass for the steps run; rapid reversals, mixed-scale displays and a real input method: **unverified** |

The agent drove real input through the window server with Claude's
computer-use tool, with the user present. Emacs was granted only the
"click" tier, so the agent could click and press, move and release the
mouse button over the desktop, but not type or move the held pointer
back over Emacs. Drags therefore grew the window from its top-left
corner, and busy periods and window placement came from `emacsclient`.
Screenshots fail while a button is held, so mid-drag frames came from
`screencapture` every 0.6 s.

## Results

| Check | Result |
| --- | --- |
| 1. Idle corner drag | 4 of 4 live steps applied; content reflowed during the drag |
| 2. Busy corner drag (15 s busy, grown in steps) | 2 steps applied before the busy loop, 5 deferred during it. Mid-drag and after release, the old content stayed anchored top-left, unstretched, and the grown area was the frame background `#102030`. No garbage, black or white areas. Correct layout right after `BUSY-END` |
| 3. Green button while busy | fullscreen entered at once; old content top-left over the background; full-screen layout after the busy loop; left fullscreen normally |
| Menu during update | the Buffers menu, opened by a click, stayed unchanged while Lisp created `loop-new-buffer`; after closing, reopening showed it; selecting it switched the window's buffer |
| 5. `windows.py` idle and busy | title, position 99,130, size 1034x786 and minimized state reported both idle and busy. A click on the yellow button while busy gave `minimized: true` (query took 0.23 s); after restore, `false` |
| 6. `mac-app-loop-report` | Lisp heartbeat max gap 15.0 s (the busy loops). GUI max gap 593 ms, and 2 gaps over 100 ms: 593 ms at the yellow-button click (busy) and 555 ms at the restore (idle), both AppKit's minimize animations on the main thread. No GUI gap over 100 ms during the drags, fullscreen or menu use |

Logs: `$TMPDIR/mac-app-loop/20260924T164512Z-new.{log,stderr}`.

`windows.py` failed to parse its output on macOS 27, where `osascript`'s
default output flattens nested lists. It now asks for source-form output
(`osascript -s s`).

## Not covered

- Rapid drag reversals and shrinking drags: the tool refuses to move a
  held pointer over an app with the click tier.
- Moving between displays of different scales: only the built-in
  display was attached.
- A real input method (ticket 13): typing was not possible.

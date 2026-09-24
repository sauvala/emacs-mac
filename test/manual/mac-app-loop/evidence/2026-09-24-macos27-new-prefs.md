# Per-preference scripted runs, persistent loop (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | the commit that adds this file (branch `app-loop`); the new-loop runs used a binary built before a `mac-loop-test-results` docstring edit, which is the only difference |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2 |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Deployment target | configure default |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | as in `2026-09-24-macos27-new-interactive.md` |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP=1`, `EMACS_MAC_TRACE_LOOP=1`, and `EMACS_MAC_LOOP_PREFS` unset, each of the four keys alone, or `all`; `-Q` |
| Lisp state | per scenario (idle, busy, second thread busy) |
| Scenario | `run-scenarios.sh new` default list, 22 scenarios including the new `resize-burst` |
| Pass/fail/unverified | scripted: pass in all six configurations; interactive: **unverified** |

The environment limits in `2026-09-24-macos27-both-scripted.md` still
apply: input is posted by `mac-loop-test-schedule`, with no window-server
drags and no screenshots.

Each run's stderr confirmed that the override took effect: the
configurations with a key logged `registering preference <key>`, and
`all` logged all four keys.

## Results

All 132 runs (22 scenarios x 6 configurations) exited 0 with a result.
The observable outcomes were the same in every configuration: final
geometry, commands executed, buffer contents, menu rejections with their
reasons, close and Quit counts, and the "Waiting for Emacs…" subtitles.
GUI heartbeat maxima differed by run-to-run noise only:

| Scenario | GUI max gap across the six configurations | Outcome (identical in all) |
| --- | --- | --- |
| idle-typing, busy-typing | 25-56 ms | 5 commands, same buffer |
| quit | 6 ms | busy interrupted at 1.50 s |
| busy-native | 357-359 ms (zoom animation, as in the old table) | 700x500 outer, 3 commands |
| idle-resize, live-resize | 7-23 ms | converged to 950x754 or 953x756 outer (drag step granularity) |
| resize-burst | 10-48 ms | 790x495 outer |
| close-busy, win-close-dedupe, win-close-indicator | 102-108 ms (close button highlight) | one frame deleted, subtitle shown |
| stress-requests | 357-361 ms (zoom animation) | 3 commands, 576-582 ticks |
| thread-busy | 62 ms | 3 commands |
| fullscreen-idle, fullscreen-busy | 35-91 ms | fullscreen entered and left |
| menu-idle, -busy, -nested | 19-42 ms | one command |
| menu-stale, -disabled, -frame-deleted | 18-50 ms | rejected: buffer changed, item disabled, frame closed |
| win-quit-idle, win-quit-dedupe | 6-47 ms | one Quit |

So on this system none of the four undocumented preferences is needed
by the persistent loop in the scripted matrix, and re-enabling any of
them, or all of them, breaks nothing that it checks.

The old loop, rerun on the final binary with the same list, reproduced
the earlier table: stalls of 1.2-2.0 s while Lisp is busy, the known
inability to run the scripted menu rows, and repeated close/Quit
handling (`delete-frame-count` 3, `quit-count` 3). It was not changed.

## W6/W10 coalescing counter

The seventh `:access` value counts deferred state callbacks replaced by
later ones. `busy-native` replaced 40-42 and `stress-requests` 40-41.
`resize-burst` replaced none, because busy Lisp drains the deferred FIFO
from `read_socket` between its 50 ms steps.

## Not covered

- Pixels: what a busy drag actually shows (W3) needs the interactive
  checklist in `.wayfinder/issues/11-s3-windows-redisplay.md`.
- Real window-server drags, mixed-scale displays, and accessibility
  discovery.

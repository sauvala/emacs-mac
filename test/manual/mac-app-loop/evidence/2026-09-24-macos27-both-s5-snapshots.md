# S5 text snapshots and idle wakeups, both loops (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | the commit that adds this file (branch `app-loop`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2 |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Deployment target | configure default |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | as in `2026-09-24-macos27-new-interactive.md` |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP=0` or `1`, `EMACS_MAC_TRACE_LOOP=1` (`2` for the wakeup count), `-Q` |
| Lisp state | idle; busy for 1.5 s after an edit without redisplay |
| Scenario | `run-scenarios.sh both` default list, 29 scenarios including the new `stalled-resize-layer`, `text-idle` and `text-busy` |
| Pass/fail/unverified | scripted: pass; IME and VoiceOver with real input: **unverified** |

The environment limits in `2026-09-24-macos27-both-scripted.md` still
apply. The `text` test action calls the frame view's NSTextInputClient
and accessibility methods from a GUI-thread timer, as an input method
or assistive application would. It does not go through the
accessibility server or a real input method.

## Idle wakeups (fixed before these runs)

A plain `emacs -Q` under the new loop, idle for 3 s with
`EMACS_MAC_TRACE_LOOP=2`, logged 1317 input waits ended by the keyboard
descriptor, about 470 a second. The read_socket throttle timer woke
Lisp unconditionally, and Lisp then called read_socket again within the
interval and rearmed the timer. After the fix (wake only when items or
deferred events are pending), the same run logged 5 waits.

The spin was present in all earlier new-loop scripted runs. Idle Lisp
spent most of its time outside its input wait, so GUI try-lock access
succeeded only by chance. Scenarios that rely on it, such as idle
resize steps and menu access, passed then and still pass. In
`text-idle` all 15 queries were denied before the fix and granted after.

## Text queries

Setup: a 24-character buffer, region from 2 to 5 with point at 5,
redisplayed. `text-busy` then appends 4 characters without redisplay
and computes for 1.5 s. Each probe records the selected range, the
character count, the marked-text rectangle (for location `NSNotFound`),
the role, the value length and the insertion-point line.

| Probe | Old loop | New loop |
| --- | --- | --- |
| idle | sel 0+1, 24 chars, 7x16, AXTextArea, value 24, line 0 | same (15 try-lock grants) |
| busy, 0.5 s | sel 1+3, 28 chars, value 28, line 0 (answered after Lisp yields) | sel 1+3, 24 chars, 7x16, AXTextArea, value and line unavailable (3 snapshot answers) |
| after busy, 2.5 s | sel 0+1, 28 chars, value 28 | same |

While Lisp is busy, the new loop answers the selection, character count
and cursor rectangle from the snapshot published at the end of the last
redisplay, so they describe the displayed state (24 characters), not
the unredisplayed edit. The role comes from AppKit without Lisp. The
buffer text is unavailable rather than read without the lock. In the
idle probes the region had been deactivated by then, so both loops
report 0+1.

## Full suite

All 58 runs (29 scenarios, both loops) exited 0 with the same outcomes
as before: final geometry, commands, buffer contents, menu rejections,
close and Quit counts, and subtitles. `stalled-resize-layer` is in
`2026-09-24-macos27-new-prefs.md`.

## Not covered

- A real input method: candidate window placement while Lisp is busy,
  and marked text in the echo area (isearch).
- VoiceOver or `windows.py` against a busy Emacs.
- Queries arriving while the GUI thread runs a Lisp request (for
  example, deferred key events drained from read_socket). They now get
  the snapshot or "unavailable"; the scenarios do not reach this case.

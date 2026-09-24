# S3 resolution

Closed on 2026-09-24 with the user's live confirmation.

With the user present, the agent drove the ticket's interactive
checklist through the window server on macOS 27: idle and busy corner
drags, the green button while busy, the yellow button and accessibility
discovery with `windows.py` idle and busy, a menu open during a
menu-bar update, and the fixture's timing report. See
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-interactive-agent.md`.
The user then checked rapid drag reversals while Lisp was busy by hand
and confirmed that they work well. The scripted scenarios pass in both
loops. Implementation choices are in the implementation notes of
`../window-redisplay/2026-09-23-discussion.md`.

Deviations from the acceptance gate, accepted by the user:
- Step 4 (moving between displays of different scales, W10) was not
  run, because only the built-in display is attached. The code path is
  covered by the deferred backing-change callback only.
- The only GUI-thread gaps over 100 ms were AppKit's minimize and
  restore animations (593 ms and 555 ms), which the loop does not
  control.

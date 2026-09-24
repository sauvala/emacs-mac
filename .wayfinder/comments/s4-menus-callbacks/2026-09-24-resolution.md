# S4 resolution

Closed on 2026-09-24 with the user's live confirmation.

The user tested the persistent loop interactively on macOS 27. Mouse menus
(idle and busy, nested), Control-F2 navigation, F10 (the popup opens once
Lisp is idle), C-g and Escape during tracking, the stale-selection
rejection, Services and Help search all passed. See
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-interactive.md`.
The scripted menu scenarios pass, and `test/manual/mac-menu/check.py` covers
the snapshot table. Implementation choices are in the implementation
notes of `../menu-callbacks/2026-09-23-discussion.md`.

Deviations from the D21 gate, accepted by the user:
- D3's bounded open-time refresh is not implemented. An idle-time deep
  fill stands in for it. It moved to
  `../../issues/17-s4-open-time-refresh.md`.
- D6's busy placeholder is unnecessary with the deep fill.
- The ticket was closed while its S3 prerequisite (ticket 11) is still
  open. S3's remaining gaps concern windows and redisplay, not menus.
- Timings were reported, not measured, and forced GC was covered only by
  the scripted table checks.

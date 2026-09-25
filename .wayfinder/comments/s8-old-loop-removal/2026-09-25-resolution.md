# Old-loop removal resolution

Closed on 2026-09-25 with the user's live confirmation.

The user dropped macOS versions before 27 (S7) and made the persistent
loop the only loop (S6), which satisfies the acceptance gate: no OS is
left on the old loop. `c31bd2ca898` and `0988ae3be8a` removed the
selector, the old loop and the M8 workarounds; `0a2cfc8f8a3` updated
`AGENTS.md` and `README.md` in the same series.

The user's first test of the installed build found two problems:
- The app froze on its first launch. macOS hang reports showed a
  GUI-thread abort in `draw_glyphs` under `note_tab_bar_highlight`:
  with `ns-transparent-titlebar`, mouse events over the tab bar
  hit-test as titlebar chrome, so `mac_loop_send_event` dispatched them
  without Lisp access, yet AppKit delivered them to `EmacsMainView`.
  The race predates S8. `7c25c89c4b0` makes the view's mouse handlers
  defer without access. A scripted drag over the tab bar while Lisp
  computes now defers its callbacks; all 29 loop scenarios pass.
- The mode line jiggled during resizes again. It happened only in the
  session that rebuilt the native-compilation cache for the new build,
  and not after a second restart, which suggests redisplay slower than
  the 30 ms live-resize wait while code ran as byte code. The idle
  scripted resizes presented 18 of 18 steps synchronously. No code
  change was made for it; it was not traced.

The user then reported no freeze on launch and a still mode line after
the restart.

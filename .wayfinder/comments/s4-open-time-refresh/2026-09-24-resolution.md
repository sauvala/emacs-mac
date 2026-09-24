# D3 open-time refresh resolution

Closed on 2026-09-24 with the user's live confirmation.

The user opened the menu bar in the development build under the
persistent loop. A test menu's label, `(format "Count %d" ...)`,
changed every second without a menu-bar update.
- Opened twice while idle, it showed a higher count each time. The
  trace shows both refreshes applied (result 3), answered in 0.4 ms,
  with 0.2 ms spent in Lisp.
- Opened during a 10 s `mac-app-loop-busy`, it came from the cache
  without waiting.
- Before the first retest, 13 opens of the other top-level menus were
  answered in 0.3-24 ms, with no timeouts or cancellations. The user
  saw no problems.

The scripted evidence is
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-open-refresh.md`.

Found in real use: an unwind handler made a redundant GUI round trip
after each answer, which held Lisp 12-49 ms while the menu was
displayed. Fixed in `1d89f899bc1`, and the retest above used the fix.

Deviations from the acceptance gate:
- The Buffers menu and a `:filter` menu were not opened separately.
  They take the same path as the test menu's computed label.
- `menu-fill-cost` numbers are recorded, but the idle deep fill was
  kept rather than dropped (agent-adopted; see ticket 17 Progress).

# Menu-bar updates during tracking, both loops (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | the commit that adds this file (branch `app-loop`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2 |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Deployment target | configure default |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | as in `2026-09-24-macos27-new-interactive.md` |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP=0` or `1`, `EMACS_MAC_TRACE_LOOP=1`, `-Q` |
| Lisp state | idle |
| Scenario | `menu-tracking-update`, and the full default list (28 scenarios) |
| Pass/fail/unverified | scripted: pass; real menu-bar tracking: **unverified** |

The `menu-tracking` test action sends the root `EmacsMenu` the begin and
end tracking notifications that AppKit sends when the user opens the menu
bar. No menu is displayed, and AppKit does not call `menuNeedsUpdate:`.

## menu-tracking-update

A LoopTest menu is installed, tracking begins at 0.3 s, a timer at 0.6 s
defines a second top-level menu and redisplays, tracking ends at 1.5 s,
and the root is probed at 1.2 s and 2.2 s.

| Probe | Old loop | New loop |
| --- | --- | --- |
| 0.3 s, begin | 9 menus | 9 menus, generation 3 |
| 0.6 s, update | applied | "menu fill deferred while tracking" |
| 1.2 s, tracking | 10 menus (root replaced) | 9 menus, generation 3 (root kept) |
| 1.5 s, end | 10 menus | 9 menus; refresh event queued |
| 2.2 s | 10 menus | 10 menus, generation 5 |

In the old loop, Lisp is parked while the real menu bar is tracked, so
the replacement shown here cannot happen there; the row only shows that
the old loop is unchanged. In the new loop, before this change, the
0.6 s update replaced the tracked root.

## Full suite

All 56 runs (28 scenarios, both loops) exited 0 with the same outcomes
as the run recorded in `2026-09-24-macos27-both-s5-snapshots.md`.

## Not covered

- Real menu-bar tracking with a submenu open while an idle update
  changes it, such as a new buffer appearing in the Buffers menu.

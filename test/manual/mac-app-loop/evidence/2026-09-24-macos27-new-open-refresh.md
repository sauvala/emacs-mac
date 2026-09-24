# Open-time menu refresh (D3), scripted (macOS 27)

| Field | Value |
| --- | --- |
| Source revision | the commit that adds this file (branch `app-loop`) |
| OS version/build | macOS 27.0 (26A428) |
| Hardware/CPU | Apple M2 |
| SDK | macOS 27.0 SDK (Xcode clang) |
| Renderer | Metal (`--with-metal-rendering`) |
| Configure flags | as in `2026-09-24-macos27-new-interactive.md` |
| Runtime env flags | `EMACS_MAC_PERSISTENT_LOOP=1` (and `=0` for the full list), `EMACS_MAC_TRACE_LOOP=1`, `-Q` |
| Lisp state | idle, busy (1 s loop), slow `menu-bar-update-hook` (0.2 s) |
| Scenario | `menu-open-refresh`, `menu-open-cost`, `menu-fill-cost`, and the full default list (29 scenarios, both loops) |
| Pass/fail/unverified | scripted: pass; real menu-bar tracking: **unverified** |

The new `menu-open` test action sends a top-level menu's delegate
`menuNeedsUpdate:` and `menuWillOpen:`, as AppKit does when the user
opens it, after the `menu-tracking` action has begun tracking.
AppKit does not display the menu, so this does not show whether a real
tracking session behaves the same (window-server timing, Help search,
visual flicker).

## menu-open-refresh

The LoopTest menu has an item labelled `(format "Dyn %d" ...)`. The
variable changes without a menu-bar update, so the installed menu is
stale when opened.

| Time | Lisp | Result |
| --- | --- | --- |
| 0.4 s | idle, label variable 1, menu shows "Dyn 0" | answered in 7 ms, menu shows "Dyn 1" (result 3, applied) |
| 1.0 s | busy loop, variable 2 | "Lisp busy, cached" without waiting; shows "Dyn 1" |
| 2.2 s | idle | answered in under 1 ms, shows "Dyn 2"; Dyn performed from it during tracking ran once (`:count 1`) through the menu's own generation |
| 2.6 s | tracking ends | root rebuilt: generation 6 before, 13 at 3.2 s |
| 3.8 s | `menu-bar-update-hook` takes 0.2 s | timed out after 51 ms, cached "Dyn 2" shown; the answer came 200 ms later while the menu was displayed and was dropped (result 1); root rebuilt after tracking |

While Lisp was busy, the GUI heartbeat's longest gap was 57 ms, with no
gaps over 100 ms. The old loop does not refresh on open (the result is
unchanged from before this change).

## Cost

`menu-fill-cost` (deep fill of the whole menu bar, the idle-time update
kept by this change): 9.1 ms plain, 22.0 ms with 200 buffers and six
major-mode buffers (org, c, python, sh, outline, emacs-lisp).

`menu-open-cost` (same loaded setup, each top-level menu opened once
while idle):

| Menu | Items | GUI wait | Lisp time |
| --- | --- | --- | --- |
| File | 30 | 1 ms | 1.3 ms |
| Edit | 26 | 2 ms | 1.8 ms |
| Options | 24 | 4 ms | 4.0 ms |
| Buffers | 22 | 1 ms | 0.6 ms |
| Tools | 32 | 4 ms | 3.6 ms |
| Table | 25 | 1 ms | 1.3 ms |
| Org | 28 | 4 ms | 3.7 ms |
| Text | 6 | 0 ms | 0.4 ms |
| Window | 8 | 0 ms | 0.4 ms |
| Help | 22 | 3 ms | 2.5 ms |

All were unchanged (result 2), so none published a generation or
caused a root rebuild. AppKit's own items are in the menus' item arrays:
Edit ends with "Emoji & Symbols" and Window with the frame's window
entry. The refresh compares and replaces only the items Emacs put there,
so they survive.

## Full list

All 29 default scenarios exited 0 on both loops, and the new-loop
results match `2026-09-24-macos27-both-scripted.md`. That run used a
build without two later fixes (keeping AppKit's items, and answering the
request on a nonlocal exit). On the final build the menu scenarios were
rerun on the new loop (`menu-open-refresh`, `menu-open-cost`,
`menu-fill-cost`, `menu-idle`, `menu-busy`, `menu-stale`,
`menu-disabled`, `menu-nested`, `menu-frame-deleted`,
`menu-tracking-update`), with unchanged results.

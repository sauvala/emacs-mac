---
id: s4-open-time-refresh
title: "S4 follow-up: open-time submenu refresh (D3)"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: claude-app-loop-session-3
---

## Scope

Implement D3 under the persistent loop. At `menuNeedsUpdate:`, if Lisp
is at a safe point, request a bounded (about 50 ms) refresh of only the
submenu being opened, which runs `menu-bar-update-hook` and expands its
keymap or `:filter`. On timeout, or with no safe point, show the cached
snapshot, and keep a late result for the next opening. Never edit a menu
while it is displayed.

Today an idle-time deep fill (`mac-update-pending-menu-bars`) stands in
for this. Menus can be up to 0.2 s of idle time stale after a command,
and each idle update costs about 9-23 ms of Lisp time. D3 would allow
dropping the deep fill for lazy submenus.

## Acceptance gate

Dynamic submenus (Buffers, `:filter`) are fresh when opened while Lisp is
idle. Menus still open within 100 ms from cache while Lisp is busy. No
Lisp runs on the GUI thread, and no cancel/reopen cycle occurs. Record the
`menu-fill-cost` numbers before and after.

## Decisions

- [Menu decisions D3, D6](../comments/menu-callbacks/2026-09-23-discussion.md)

## Blocked by

- [S4: Move menus and callbacks to the new loop](12-s4-menus-callbacks.md)

## Progress (2026-09-24, agent-adopted)

Prerequisite fixed: "never edit a menu while it is displayed" did not
hold. Under the persistent loop Lisp keeps running while the user
tracks the menu bar, and `mac_fill_menubar` refused to replace the root
only during native-menu-experiment tracking. An idle update that
changed something visible (a new buffer in the Buffers menu, a timer
changing an `:enable`) could replace the root menu while one of its
submenus was open. Now:
- `mac_fill_menubar` also refuses while the root has
  `persistentTracking`, and `set_frame_menubar` marks the frame
  pending.
- `mac-update-pending-menu-bars` does not rebuild while the menu bar is
  tracked.
- When tracking ends after an update was held back, the GUI queues a
  `mac-menu-bar-refresh` special event and Lisp applies the update at
  its next read. The idle timer alone would not retry, because a
  repeating idle timer fires once per idle period.

Scripted check `menu-tracking-update` (evidence
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-both-menu-tracking.md`):
the tracked root kept 9 menus and generation 3 while a new top-level menu
was defined, and had 10 menus and generation 5 0.7 s after tracking
ended (the first probe after the end).

D3 itself is not implemented. Open questions found on the way:
- Generations are per root menu. Refreshing only the submenu being
  opened would give its items the tags of a newer snapshot than the rest
  of the root, so selections need a per-submenu generation (for
  example, a map from top-level submenu to generation on the root). A
  full root replacement is not allowed during tracking.
- The refresh must run on the Lisp thread (the gate says no Lisp on the
  GUI thread), so `menuNeedsUpdate:` would wait for Lisp while servicing
  the fill request that Lisp sends back, as `mac_loop_within_lisp` does
  in the other direction, with a 50 ms bound. After a timeout the result
  must not be applied until tracking ends, which the refresh event above
  now provides.
- Validation needs real menu-bar tracking. The `menu-tracking` test
  action only sends the begin and end notifications, and AppKit does not
  call `menuNeedsUpdate:` for them.

## Progress (2026-09-24, later; agent-adopted)

D3 is implemented under the persistent loop, and the scripted checks
pass (evidence
`test/manual/mac-app-loop/evidence/2026-09-24-macos27-new-open-refresh.md`).
- `menuNeedsUpdate:` of a top-level menu, during menu-bar tracking and
  with Lisp in its input wait, queues a `mac-menu-bar-open-refresh`
  special event. It then waits at most 50 ms, running Lisp requests
  meanwhile. Busy Lisp: the cached menu is shown at once.
- The Lisp thread (`mac-menu-bar-refresh-submenu`) runs
  `activate-menubar-hook` and `menu-bar-update-hook`, expands only that
  menu, and publishes it as a snapshot generation of its own. The GUI
  fills the menu from the widget values while Lisp is parked, as
  `mac_fill_menubar` does, so no Lisp runs on the GUI thread.
- Decisions adopted on the way:
  - The per-submenu generation is an associated object on the top-level
    `NSMenu`. Selections and help-echo look it up before the root's.
  - A refresh that changed a menu makes the root rebuild once tracking
    ends, which retires the per-menu generation. An unchanged refresh
    keeps the old items and releases its generation.
  - A late answer is applied only while the menu is not displayed
    (`menuWillOpen:` and `menuDidClose:` track that). Otherwise it is
    dropped, and the root rebuilds after tracking.
  - AppKit adds items of its own to Edit, Window and Help. The refresh
    compares and replaces only the items Emacs put there.
  - `NATIVE_MENU_SNAPSHOT_KEEP` is 16, up from 8.
  - The idle deep fill stays. The gate does not require dropping it,
    and it covers menus opened while Lisp is busy.
- Numbers: open-time refresh 0.4-4 ms of Lisp per menu (loaded setup),
  GUI wait 0-4 ms. Deep fill unchanged at 9.1 ms plain, 22.0 ms loaded.

Still open before closing: real menu-bar tracking with a person at the
Mac. Check that dynamic menus (Buffers after `C-x b`, a `:filter` menu)
are fresh when opened while idle, that nothing flickers, that Help's
search field and Edit's AppKit items remain, and that menus open
promptly while Lisp is busy. Computer control was not available to this
session for that check.

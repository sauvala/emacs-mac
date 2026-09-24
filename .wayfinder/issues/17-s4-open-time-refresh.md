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

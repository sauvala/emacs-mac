---
id: s4-open-time-refresh
title: "S4 follow-up: open-time submenu refresh (D3)"
status: open
labels: ["wayfinder:task"]
parent: macos-app-integration
assignee: null
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

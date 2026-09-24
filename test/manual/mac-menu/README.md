# macOS menu-bar snapshot check

`check.py` compiles the menu-bar snapshot table functions from
`src/macmenu.c` (publication, trimming to the newest
`MENU_BAR_SNAPSHOT_KEEP` generations, restamping on a window or buffer
change, retraction when a frame is deleted, and generation wraparound)
with a small Lisp-object fixture, and runs them:

```sh
python3 test/manual/mac-menu/check.py
```

It does not exercise AppKit or real Lisp garbage collection.  Real
menu-bar tracking is checked with the scripted scenarios in
`test/manual/mac-app-loop/` and by hand.

The interactive fixture for the native-menu experiment that ran under
the old event loop (`lifecycle.el`, `EMACS_MAC_NATIVE_MENUS`,
`EMACS_MAC_WORKER_MENUS`) was removed with that loop in 2026; see git
history.

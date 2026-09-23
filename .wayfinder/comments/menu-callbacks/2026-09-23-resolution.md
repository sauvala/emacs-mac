# Resolution

[Choose menu preparation and GUI-to-Lisp callback contracts](../../issues/05-menu-callbacks.md)
resolved on 2026-09-23 with the user's live confirmation of the
[recorded decisions](2026-09-23-discussion.md).

The GUI thread never evaluates Lisp. Callbacks are requests that wake a Lisp
thread; the GUI waits within the ~50 ms safe-point budget, except inside
Lisp-initiated popups and dialogs, and help-echo is fire-and-forget. Lisp
publishes immutable per-frame menu-bar snapshots without waiting; the GUI
fills a submenu from the snapshot or a bounded refresh when it opens and never
edits a displayed menu. The GUI side holds no Lisp objects. A Lisp-rooted
generation table maps item ids to bindings and is released only when
superseded and unreferenced. A selected action carries its generation, frame,
window and buffer, and is revalidated (including `:enable`) before running
at most once. Otherwise it raises a `user-error`. Busy menus show the cached
state and a disabled placeholder for never-expanded submenus.

Under the new loop, Carbon menu-bar interception, event replay, the
cancel/rebuild/reopen cycle, Help menu redirection and the GUI-thread Lisp
flags retire; the old loop keeps them. F10 shows a popup, as in GNU's NS
port, and real keyboard menu-bar navigation uses the system Control-F2
shortcut. Nothing fakes events. Services and Help search read published
data; Services providers stay asynchronous. A menu prototype on top of 04's
decides the design under idle, minibuffer and busy Lisp.

A cheaper agent inventoried the menu machinery; the parent verified the cited
sites. No application code changed and no GUI tests were run.

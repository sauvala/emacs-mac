# macOS native-menu lifecycle fixture

This is an opt-in manual regression fixture for the experimental native-menu
path on macOS 27+. It does not enable the path itself. Start a fresh
development GUI process from the checkout root:

```sh
EMACS_MAC_NATIVE_MENUS=1 \
EMACSLOADPATH=/Users/janne/repos/emacs-mac-janne/lisp \
/Users/janne/repos/emacs-mac-janne/mac/Emacs.app/Contents/MacOS/Emacs \
  -Q -l /Users/janne/repos/emacs-mac-janne/test/manual/mac-menu/lifecycle.el \
  --eval '(progn (require (quote info)) (run-at-time 0 nil (function mac-menu-lifecycle-start)))'
```

Use the two uniquely named generated buffers to check that their different
buffer-local `Lifecycle A` and `Lifecycle B` menus remain distinct. Invoke an action and
verify an `ACTION ...` line in the visible log; a menu being drawn is not
evidence that its command was delivered. In one buffer use “Change menu for
next opening”, close/reopen the menu, and verify that it now logs the
`CHANGED` command. Use `C-c m f` once or twice to create uniquely named,
fixture-owned frames and switch frames while opening both menus. `C-c m q`
stops the optional worker, deletes only buffers and frames made by this
fixture, and removes its log. The worker is optional and is never started
automatically; there are no timers running by default.

Manual matrix (record pass/fail and the observed log line):

* Mouse: open each buffer's menu, select its action, and confirm actual command
  delivery in the log. Escape/cancel and reopening must still deliver later
  actions.
* Keyboard: run `M-x mac-menu-bar-open-internal`, then select an item using
  arrow keys and Return. Separately use the platform keyboard gesture, select
  an item with the keyboard, and confirm the command/action, not just display.
* Dynamic lifecycle: change a buffer's menu between openings; repeat after
  switching buffers and frames. Test cancellation and rapid frame switching.
* Resize: while menus are closed, drag a frame edge and corner continuously;
  repeat after menu use. Confirm the drag remains continuous.
* Titlebar: click the yellow minimize button, restore the window from the
  Dock, and repeat after menu use. Check zoom/full-screen and close on a
  disposable fixture frame. Programmatic `iconify-frame` alone does not test
  titlebar control tracking.
* Worker: start the optional worker, open/select/cancel the menu repeatedly,
  then change buffers and repeat before stopping the worker. Also test
  starting the worker before the first menu opening in a fresh process via
  `M-x mac-menu-lifecycle-start-worker`. A menu cached before the worker
  starts does not establish fresh-menu preparation with multiple threads.
* Recovery: start/stop the optional worker, exercise `C-g` during menu opening
  and resizing, then run `C-c m q` and verify no fixture objects remain.

This fixture cannot automate AppKit tracking, native command delivery, frame
dragging, keyboard activation, or `C-g`; it provides observable setup and log
evidence only. The source-level checker does not exercise real Lisp garbage
collection or AppKit object lifetime. Run it separately:

```sh
python3 test/manual/mac-menu/check.py
```

That checker and a successful batch load do not replace the GUI matrix above.

On the tested macOS 27 system, cancelling the old menu before root replacement
passed mouse command delivery, changed commands, second-frame selection, and
Escape dismissal. This behaviour is part of the native-menu opt-in; no separate
cancellation flag is needed. The direct native keyboard press also passed
opening, arrow navigation to Deliver A, Return command delivery, and dismissal.
Keyboard Escape cancellation followed by reopening and command delivery also
passed.

The separate `EMACS_MAC_WORKER_MENUS=1` candidate passed an initial worker
mouse-opening/action-dispatch/dismissal check, with visible cancel/reopen
blinking. It cancels the actual submenu in tracking run-loop mode before
deferring preparation to Lisp. With the worker running, changed-menu delivery
(A v3 -> CHANGED), Escape cancellation that stays closed, and keyboard
activation/arrow navigation/Return delivery also passed. Switching from A v3 to
B delivered B, and a new fixture frame delivered B and dismissed its menu.
Worker stop/start also passed: B delivered after both transitions; stopping
removed the visible blink. After restart the user noticed no blink, but the
trace still showed cancellation and reopening. The broader regression matrix
remains pending.

The subsequent candidate clears stale submenu contents in `menuNeedsUpdate:`
before the same safe cancellation/rebuild. The user confirmed first and repeated
opening/delivery without visible blinking; traces confirmed action dispatch
both times, including clearing nine old items on the second opening. The
internal retry remains. The user also confirmed changed-command delivery
(`CHANGED`) and Escape dismissal that stays closed; the trace records action
dispatch and a later dismissal without an action, with the Lisp heartbeat
continuing. Keyboard activation via `mac-menu-bar-open-internal`, arrow/Return
delivery of `CHANGED`, and keyboard Escape dismissal also passed without
blinking. Buffer/frame switching also passed without blinking: B delivered
after a buffer switch and in a new fixture frame, then `CHANGED` delivered
after returning to A in the original frame. Worker stop/start also passed:
`CHANGED` delivered and dismissed without blinking after both transitions.
Broader regressions remain pending;
do not treat it as default-ready.

Help required two additional fixes: capture the main Emacs window for retry
ownership (Help search can make its popup key), and temporarily redirect
`NSApp.helpMenu` to an off-bar menu during unprepared tracking. Restore Help
before safe preparation and on tracking end. The user confirmed initial and
repeated Help openings without blinking, search accepting `describe`, and
Escape dismissal with search available after reopening. Window-menu frame
selection and Services submenu opening/Escape dismissal also passed without
blinking or freezing. Services command execution was not tested. Edit -> Undo
in `*scratch*`, yellow-button minimize/Dock restore, and continuous edge/corner
resizing after menu use also passed. Rapid Escape cancellation and subsequent
responsiveness passed; C-g initially failed to dismiss menus.

The later C-g candidate intercepts dequeued key-down events during native
tracking using the existing quit-key recognizer, cancels native tracking and
pending retry, and consumes the event without calling Lisp. The user confirmed
Edit dismissal, Help dismissal with search text entered, normal C-x then C-g
prefix cancellation outside menus, and subsequent Lifecycle A command delivery
without blinking. Runtime traces confirm the native quit handler and tracking
end, with the Lisp heartbeat continuing. Nested menus, remapped quit keys, and
cancellation during retry have not been exhaustively tested.

;;; scenarios.el --- scripted persistent-loop scenarios  -*- lexical-binding: t -*-

;; Run inside a GUI Emacs of this checkout, for example:
;;   mac/Emacs.app/Contents/MacOS/Emacs -Q \
;;     -l test/manual/mac-app-loop/scenarios.el \
;;     --eval '(mac-loop-scenario-run (quote busy-native))'
;; The result is written as a Lisp plist to $MAC_LOOP_RESULT (default
;; /tmp/mac-loop-result.eld) and Emacs exits.
;;
;; Native operations and input are scheduled with
;; `mac-loop-test-schedule', which posts real NSEvents and invokes
;; native window operations on the GUI thread, so they happen while
;; Lisp is busy.  These runs exercise the event path without the
;; accessibility or screen-recording permissions a synthetic-input tool
;; would need.  They do not replace interactive acceptance: posted
;; events skip the window server, and there are no screenshots.

;;; Code:

(defvar mac-loop-scenario-log nil)

(defun mac-loop-scenario--note (fmt &rest args)
  (push (cons (mac-loop-uptime) (apply #'format fmt args))
        mac-loop-scenario-log))

(defun mac-loop-scenario--busy (seconds)
  "Compute for SECONDS without waiting for input.
Return the elapsed time, or (quit . ELAPSED) if interrupted."
  ;; Timers run with `inhibit-quit' bound to t; allow C-g here.
  (let ((start (float-time)) (n 0) (inhibit-quit nil))
    (condition-case nil
        (progn
          (while (< (- (float-time) start) seconds)
            (setq n (1+ n))
            (when (zerop (% n 1000))
              ;; Allocate so that GC and ordinary maybe_quit run.
              (ignore (make-string 10 ?x))))
          (- (float-time) start))
      (quit (cons 'quit (- (float-time) start))))))

(defun mac-loop-scenario--frame-state (&optional frame)
  (setq frame (or frame (selected-frame)))
  (list :size (list (frame-pixel-width frame) (frame-pixel-height frame))
        :outer (list (frame-outer-width frame) (frame-outer-height frame))
        :visible (frame-visible-p frame)
        :fullscreen (frame-parameter frame 'fullscreen)))

(defun mac-loop-scenario--key (code char &optional mods)
  (list code char mods))

(defconst mac-loop-scenario--keys
  '((?a . 0) (?b . 11) (?c . 8) (?d . 2) (?e . 14) (?f . 3) (?g . 5)
    (?n . 45) (?o . 31) (?p . 35)))

(defvar mac-loop-scenario-commands nil
  "Commands run since the scenario started, most recent first.")

(defun mac-loop-scenario--record-command ()
  (push this-command mac-loop-scenario-commands))

(defun mac-loop-scenario--type (start string &optional step)
  "Return actions typing control characters of STRING from time START.
Plain characters need an active input context, which requires a key
window; posted control keys become Emacs events directly."
  (let ((time start) actions)
    (dolist (ch (string-to-list string))
      (push (list time 'key (cdr (assq ch mac-loop-scenario--keys))
                  ch '(control))
            actions)
      (setq time (+ time (or step 0.05))))
    (nreverse actions)))

(defun mac-loop-scenario--commands ()
  (reverse mac-loop-scenario-commands))

(defun mac-loop-scenario--finish (name result)
  (let* ((test (mac-loop-test-results t))
         (file (or (getenv "MAC_LOOP_RESULT") "/tmp/mac-loop-result.eld"))
         (plist (append (list :scenario name
                              :gui-max-gap (nth 0 test)
                              :gui-long-gaps (nth 1 test)
                              :access (nth 3 test))
                        result
                        (list :lisp-log (reverse mac-loop-scenario-log)
                              :gui-log (nth 2 test)))))
    (with-temp-file file
      (let ((print-length nil) (print-level nil))
        (pp plist (current-buffer))))
    (kill-emacs 0)))

(defun mac-loop-scenario--prepare ()
  (switch-to-buffer (get-buffer-create "*loop-test*"))
  (erase-buffer)
  (set-frame-size nil 800 600 t)
  (sit-for 0.5)
  (mac-loop-test-results t)
  (mac-loop-test-schedule '((0 activate)))
  (sit-for 0.5)
  (setq mac-loop-scenario-commands nil)
  (add-hook 'post-command-hook #'mac-loop-scenario--record-command))

(defmacro mac-loop-scenario--then (wait &rest body)
  "Return a continuation: collect BODY's plist after WAIT seconds.
The wait lets the command loop execute queued input first."
  (declare (indent 1))
  `(list :wait ,wait :collect (lambda () ,@body)))

(defun mac-loop-scenario-busy-native ()
  "Native operations and commands while Lisp computes for 6 s."
  (let ((before (mac-loop-scenario--frame-state)))
    (mac-loop-test-schedule
     (append '((0.5 probe 1)
               (1.0 set-size 700 500)
               (1.5 miniaturize)
               (2.5 deminiaturize)
               (3.2 zoom)
               (3.8 zoom))
             (mac-loop-scenario--type 4.3 "ofo")
             '((5.0 probe 2))))
    (mac-loop-scenario--note "busy start")
    (let ((busy (mac-loop-scenario--busy 6)))
      (mac-loop-scenario--note "busy end %S" busy)
      (mac-loop-scenario--then 1.5
        (list :busy busy
              :before before
              :after (mac-loop-scenario--frame-state)
              :buffer (buffer-string)
              :commands (mac-loop-scenario--commands))))))

(defun mac-loop-scenario-quit ()
  "C-g while Lisp computes; expect interruption at about 1.5 s."
  (mac-loop-test-schedule '((1.5 key 5 ?g (control))))
  (mac-loop-scenario--note "busy start")
  (let ((busy (mac-loop-scenario--busy 6)))
    (mac-loop-scenario--note "busy end %S" busy)
    (mac-loop-scenario--then 0.5 (list :busy busy))))

(defun mac-loop-scenario-idle-typing ()
  "Commands typed while Lisp waits for input."
  (mac-loop-test-schedule (mac-loop-scenario--type 0.2 "ofobo"))
  (mac-loop-scenario--then 1.5
    (list :buffer (buffer-string) :point (point)
          :commands (mac-loop-scenario--commands))))

(defun mac-loop-scenario-busy-typing ()
  "Commands typed during computation run in order afterwards."
  (mac-loop-test-schedule (append (mac-loop-scenario--type 0.5 "ofo")
                                  (mac-loop-scenario--type 2.0 "bo")))
  (let ((busy (mac-loop-scenario--busy 3)))
    (mac-loop-scenario--then 1.0
      (list :busy busy :buffer (buffer-string) :point (point)
            :commands (mac-loop-scenario--commands)))))

(defun mac-loop-scenario--corner-drag (start)
  (let* ((x (- (frame-outer-width) 3))
         (y (- (frame-outer-height) 3))
         (actions (list (list start 'down x y)))
         (time start))
    (dotimes (i 30)
      (setq time (+ time 0.03))
      (push (list time 'drag (+ x (* 4 (1+ i))) (+ y (* 3 (1+ i)))) actions))
    (push (list (+ time 0.1) 'up (+ x 120) (+ y 90)) actions)
    (nreverse actions)))

(defun mac-loop-scenario-live-resize ()
  "Drag the bottom-right corner while Lisp computes."
  (let ((before (mac-loop-scenario--frame-state)))
    (mac-loop-test-schedule (mac-loop-scenario--corner-drag 0.5))
    (let ((busy (mac-loop-scenario--busy 3)))
      (mac-loop-scenario--then 1.5
        (list :busy busy :before before
              :after (mac-loop-scenario--frame-state))))))

;; A fast vertical shrink, the drag in which the mode line vanished.

(defun mac-loop-scenario--shrink-drag (start)
  "Return actions dragging the bottom-right corner up from time START.
Steps are 8 ms apart and 4 px each, as a fast trackpad drag."
  (let* ((x (- (frame-outer-width) 3))
         (y (- (frame-outer-height) 3))
         (actions (list (list start 'down x y)))
         (time start))
    (dotimes (i 50)
      (setq time (+ time 0.008))
      (push (list time 'drag x (- y (* 4 (1+ i)))) actions))
    (push (list (+ time 0.1) 'up x (- y 200)) actions)
    (nreverse actions)))

(defun mac-loop-scenario-shrink-jump ()
  "Shrink the frame by a corner drag whose pointer jumps into the text area.
On macOS 27 the window resizes while the drag events are dispatched.
A fast shrink leaves the pointer over the text area, but the drag
belongs to the window edge where the button went down, so Lisp must
redraw every step: each applied step should also be presented."
  (let* ((x (- (frame-outer-width) 3))
         (y (- (frame-outer-height) 3))
         (actions (list (list 0.3 'down x y)))
         (time 0.3))
    (dotimes (i 6)
      (setq time (+ time 0.05))
      ;; 120 px above the corner that the previous step left.
      (push (list time 'drag x (- y (* 40 (1+ i)) 120)) actions))
    (push (list (+ time 0.1) 'up x (- y 360)) actions)
    (mac-loop-test-schedule (nreverse actions))
    (mac-loop-scenario--then 2.0
      (let ((applied 0) (presented 0))
        (dolist (r (nth 2 (mac-loop-test-results)))
          (cond ((string-match-p "\\`live resize step .* applied" (cdr r))
                 (setq applied (1+ applied)))
                ((string-prefix-p "live resize presented" (cdr r))
                 (setq presented (1+ presented)))))
        (list :pass (and (> applied 0) (= applied presented))
              :applied applied :presented presented
              :after (mac-loop-scenario--frame-state))))))

(defun mac-loop-scenario-shrink-drag ()
  "Shrink the frame vertically by a fast corner drag while Lisp is idle.
Every live-resize step should present the frame Lisp drew at the new
size (\"live resize presented\"); a missed step shows the previous,
taller frame cut off at the bottom."
  (let ((before (mac-loop-scenario--frame-state)))
    (mac-loop-test-schedule (mac-loop-scenario--shrink-drag 0.3))
    (mac-loop-scenario--then 2.0
      (let ((presented 0) (missed 0))
        (dolist (r (nth 2 (mac-loop-test-results)))
          (cond ((string-prefix-p "live resize presented" (cdr r))
                 (setq presented (1+ presented)))
                ((string-prefix-p "live resize missed" (cdr r))
                 (setq missed (1+ missed)))))
        (list :presented presented :missed missed :before before
              :after (mac-loop-scenario--frame-state))))))

(defun mac-loop-scenario-resize-burst ()
  "Resize the window 20 times while Lisp computes.
Expect a final outer size of 790x495.  The seventh :access count is
the number of deferred state callbacks replaced by later ones (W6/W10);
it stays 0 when busy Lisp drains them between steps from `read_socket'."
  (let ((time 0.5) actions)
    (dotimes (i 20)
      (push (list time 'set-size (+ 600 (* 10 i)) (+ 400 (* 5 i))) actions)
      (setq time (+ time 0.05)))
    (mac-loop-test-schedule (nreverse actions))
    (let ((busy (mac-loop-scenario--busy 3)))
      (mac-loop-scenario--then 1.0
        (list :busy busy :after (mac-loop-scenario--frame-state))))))

(defun mac-loop-scenario--layer-probes (start drag)
  "Return actions dragging from time START with layer probes.
With DRAG nil, return only probes before, during and after."
  (let ((actions (if drag (mac-loop-scenario--corner-drag start) nil)))
    (append (list (list (- start 0.1) 'layer)
                  (list (+ start 0.6) 'layer)
                  (list (+ start 1.2) 'layer))
            actions)))

(defun mac-loop-scenario-busy-resize-layer ()
  "Record the view layer while a corner drag grows the frame of busy Lisp.
W3 expects a background colour, top-left gravity (bottomLeft in the
flipped layer) and no snapshot overlay.  Busy Lisp applies the deferred
steps from `read_socket', so the drawable follows the layer, but
nothing is presented until the busy loop ends."
  (let ((before (mac-loop-scenario--frame-state)))
    (mac-loop-test-schedule
     (append (mac-loop-scenario--layer-probes 0.5 t)
             '((4.0 layer))))
    (let ((busy (mac-loop-scenario--busy 3)))
      (mac-loop-scenario--then 1.5
        (list :busy busy :before before
              :after (mac-loop-scenario--frame-state))))))

(defun mac-loop-scenario-stalled-resize-layer ()
  "Drag a corner while Lisp computes, then hold the pointer still.
The busy loop ends at 1.5 s, before the mouse-up at 3.5 s.  W3 expects
the deferred step to be applied once Lisp can take it, so the probe at
3.0 s shows a drawable matching the grown layer although no drag event
arrived after the busy loop."
  (let* ((drag (mac-loop-scenario--corner-drag 0.3))
         (up (car (last drag))))
    (setcar up 3.5)
    (mac-loop-test-schedule
     (append (list '(0.2 layer) '(1.2 layer) '(3.0 layer)) drag
             '((4.0 layer))))
    (let ((busy (mac-loop-scenario--busy 1.5)))
      (mac-loop-scenario--then 3.0
        (list :busy busy :after (mac-loop-scenario--frame-state))))))

(defun mac-loop-scenario-idle-resize-layer ()
  "Record the view layer during a corner drag while Lisp is idle."
  (let ((before (mac-loop-scenario--frame-state)))
    (mac-loop-test-schedule
     (append (mac-loop-scenario--layer-probes 0.3 t) '((2.5 layer))))
    (mac-loop-scenario--then 3.0
      (list :before before :after (mac-loop-scenario--frame-state)))))

(defun mac-loop-scenario-idle-resize ()
  "Drag the bottom-right corner while Lisp is idle."
  (let ((before (mac-loop-scenario--frame-state)))
    (mac-loop-test-schedule (mac-loop-scenario--corner-drag 0.3))
    (mac-loop-scenario--then 2.5
      (list :before before :after (mac-loop-scenario--frame-state)))))

;;; S5 text snapshot scenarios: the `text' action queries the frame
;;; view from a GUI-thread timer, as an input method or assistive
;;; application would.

(defun mac-loop-scenario--text-setup ()
  "Fill the buffer, activate a region and redisplay.
The region is 2..5, point 5, so the selected range is 1+3."
  (transient-mark-mode 1)
  ;; Timers run in whatever buffer is current, not the window's.
  (set-buffer (window-buffer))
  (erase-buffer)
  (insert "one two three\nfour five\n")
  (goto-char 2)
  (push-mark (point) t t)
  (goto-char 5)
  (redisplay t))

(defun mac-loop-scenario-text-idle ()
  "Text input and accessibility queries while Lisp is idle.
Expect the live answers: selection 1+3, 24 characters, a cursor
rectangle, role AXTextArea, value length 24 and line 0."
  (mac-loop-scenario--text-setup)
  (mac-loop-test-schedule '((0.3 text) (0.6 text) (0.9 text)))
  (mac-loop-scenario--then 1.0
    (list :buffer-size (buffer-size (window-buffer)))))

(defun mac-loop-scenario-text-busy ()
  "Text input and accessibility queries while Lisp computes.
Lisp inserts text without redisplay and then computes for 1.5 s.  The
new loop answers the selection, character count and cursor rectangle
from the snapshot of the last redisplay (24 characters), and nothing
that needs buffer text (value and line unavailable).  After the busy
loop the answers are live again."
  (mac-loop-scenario--text-setup)
  (mac-loop-test-schedule '((0.5 text) (2.5 text)))
  (save-excursion (goto-char (point-max)) (insert "six\n"))
  (let ((busy (mac-loop-scenario--busy 1.5)))
    (mac-loop-scenario--then 1.5
      (list :busy busy :buffer-size (buffer-size (window-buffer))))))

;;; S4 menu scenarios (D4/D5/D13/D17): a custom top-level "LoopTest"
;;; menu with one item is installed at the front of `global-map's
;;; menu-bar keymap with plain `define-key' (which prepends), so it is
;;; reliably the first Emacs top-level menu, i.e. NSApp.mainMenu item
;;; index 1 (index 0 is always the Apple menu).  Its one submenu item
;;; is therefore index 0.  `mac-loop-test-schedule's `menu' action
;;; performs it on the GUI thread like a real click, exercising
;;; -[EmacsMenu setMenuItemSelectionToTag:] and, under the persistent
;;; loop, the snapshot-bound dispatch in mac_persistent_menubar_selection
;;; (src/macmenu.c) instead of faking an NSEvent.

(defvar mac-loop-scenario--looptest-count 0)
(defvar mac-loop-scenario--looptest-top-index 1)
(defvar mac-loop-scenario--looptest-item-index 0)

(defun mac-loop-scenario--looptest-command ()
  (interactive)
  (setq mac-loop-scenario--looptest-count
        (1+ mac-loop-scenario--looptest-count)))

(defvar mac-loop-scenario--looptest-enabled t
  "The :enable form of the LoopTest menu's Run item.")

(defun mac-loop-scenario--install-looptest-menu ()
  (setq mac-loop-scenario--looptest-count 0
        mac-loop-scenario--looptest-enabled t)
  (define-key global-map [menu-bar looptest]
    (cons "LoopTest" (make-sparse-keymap "LoopTest")))
  (define-key global-map [menu-bar looptest run]
    '(menu-item "Run" mac-loop-scenario--looptest-command
                :enable mac-loop-scenario--looptest-enabled))
  ;; Force a menu-bar rebuild (and, under the persistent loop, a fresh
  ;; snapshot generation stamped on the root menu; see mac_fill_menubar
  ;; and mac_publish_menu_bar_snapshot) before any click is scheduled.
  (force-mode-line-update t)
  (redisplay t))

(defun mac-loop-scenario--looptest-messages-tail ()
  (let ((buf (get-buffer "*Messages*")))
    (if (not buf)
        ""
      (with-current-buffer buf
        (buffer-substring (max (point-min) (- (point-max) 300))
                          (point-max))))))

(defun mac-loop-scenario-menu-tracking-update ()
  "Change the menu bar while the menu bar is tracked, with Lisp idle.
The begin and end notifications are sent by the `menu-tracking' action.
Expect the new loop to keep the tracked root menu (same count and
generation, a \"menu fill deferred while tracking\" record) and to
install the new top-level menu within the idle timer's 0.2 s after
tracking ends."
  (mac-loop-scenario--install-looptest-menu)
  (mac-loop-test-schedule
   '((0.3 menu-tracking 1) (1.2 menu-tracking 2) (1.5 menu-tracking 0)
     (2.2 menu-tracking 2)))
  (run-at-time 0.6 nil
               (lambda ()
                 (define-key global-map [menu-bar looptest2]
                   (cons "LoopTest2" (make-sparse-keymap "LoopTest2")))
                 (define-key global-map [menu-bar looptest2 run]
                   '(menu-item "Run2" ignore))
                 (force-mode-line-update t)
                 (redisplay t)))
  (mac-loop-scenario--then 2.5
    (list :menus (length (lookup-key global-map [menu-bar])))))

(defvar mac-loop-scenario--looptest-dyn 0
  "Counter shown in the label of the LoopTest menu's Dyn item.")

(defun mac-loop-scenario--slow-hook ()
  (mac-loop-scenario--busy 0.2))

(defun mac-loop-scenario-menu-open-refresh ()
  "Open the LoopTest menu after its contents changed (D3).
The Dyn item's label is computed from a variable that changes without
a menu-bar update, so the installed menu is stale when opened.  The
`menu-open' action sends menuNeedsUpdate: as AppKit does.  Expect the
new loop to show \"Dyn 1\" when opened while Lisp is idle, the cached
label without waiting while Lisp computes, a selection from the
refreshed menu to run once, a timeout of about 50 ms when
`menu-bar-update-hook' is slow (the late answer is not applied to the
displayed menu), and a new root generation after tracking ends."
  (mac-loop-scenario--install-looptest-menu)
  (setq mac-loop-scenario--looptest-dyn 0)
  (define-key global-map [menu-bar looptest dyn]
    '(menu-item (format "Dyn %d" mac-loop-scenario--looptest-dyn)
                mac-loop-scenario--looptest-command))
  (force-mode-line-update t)
  (redisplay t)
  (setq mac-loop-scenario--looptest-dyn 1)
  (let ((top mac-loop-scenario--looptest-top-index))
    (mac-loop-test-schedule
     `((0.3 menu-tracking 1) (0.4 menu-open ,top) (0.6 menu-close ,top)
       ;; Lisp computes from 0.8 to 1.8 s.
       (1.0 menu-open ,top) (1.1 menu-close ,top)
       (2.2 menu-open ,top) (2.3 menu ,top 0) (2.4 menu-close ,top)
       (2.6 menu-tracking 0) (3.2 menu-tracking 2)
       ;; From 3.6 s `menu-bar-update-hook' takes 0.2 s.
       (3.7 menu-tracking 1) (3.8 menu-open ,top) (4.4 menu-close ,top)
       (4.5 menu-tracking 0) (5.2 menu-tracking 2))))
  (run-at-time 0.8 nil
               (lambda ()
                 (setq mac-loop-scenario--looptest-dyn 2)
                 (mac-loop-scenario--busy 1.0)))
  (run-at-time 3.6 nil (lambda ()
                         (setq mac-loop-scenario--looptest-dyn 3)
                         (add-hook 'menu-bar-update-hook
                                   #'mac-loop-scenario--slow-hook)))
  (run-at-time 4.4 nil (lambda ()
                         (remove-hook 'menu-bar-update-hook
                                      #'mac-loop-scenario--slow-hook)))
  (mac-loop-scenario--then 5.6
    (list :count mac-loop-scenario--looptest-count
          :commands (mac-loop-scenario--commands))))

(defun mac-loop-scenario-menu-idle ()
  "Select the custom menu-bar item while Lisp is idle; runs exactly once."
  (mac-loop-scenario--install-looptest-menu)
  (mac-loop-test-schedule
   (list (list 0.3 'menu mac-loop-scenario--looptest-top-index
              mac-loop-scenario--looptest-item-index)))
  (mac-loop-scenario--then 1.5
    (list :count mac-loop-scenario--looptest-count
          :commands (mac-loop-scenario--commands))))

(defun mac-loop-scenario-menu-busy ()
  "Select the custom menu-bar item while Lisp computes; runs once after."
  (mac-loop-scenario--install-looptest-menu)
  (mac-loop-test-schedule
   (list (list 0.5 'menu mac-loop-scenario--looptest-top-index
              mac-loop-scenario--looptest-item-index)))
  (let ((busy (mac-loop-scenario--busy 2)))
    (mac-loop-scenario--then 1.0
      (list :busy busy :count mac-loop-scenario--looptest-count
            :commands (mac-loop-scenario--commands)))))

(defun mac-loop-scenario-menu-stale ()
  "Select, then switch buffers/rebuild the menu bar before Lisp drains
the selection: it must be rejected (a message naming the reason) and
must not run the command."
  (mac-loop-scenario--install-looptest-menu)
  (let ((other (get-buffer-create "*loop-test-other*")))
    (mac-loop-test-schedule
     (list (list 0.3 'menu mac-loop-scenario--looptest-top-index
                mac-loop-scenario--looptest-item-index)))
    ;; Stay busy (without draining GUI-queued Lisp blocks) past the
    ;; scheduled click, then switch buffers and force a menu-bar
    ;; rebuild -- still without yielding to the command loop -- so a
    ;; new generation is published before the queued (generation, tag)
    ;; record for the old one is ever drained.
    (let ((busy (mac-loop-scenario--busy 0.6)))
      (switch-to-buffer other)
      (force-mode-line-update t)
      (redisplay t)
      (mac-loop-scenario--then 1.5
        (list :busy busy
              :count mac-loop-scenario--looptest-count
              :buffer (buffer-name)
              :messages (mac-loop-scenario--looptest-messages-tail))))))

(defun mac-loop-scenario-menu-disabled ()
  "Select, then disable the item before Lisp drains the selection: it
must be rejected as disabled (D5) and must not run the command."
  (mac-loop-scenario--install-looptest-menu)
  (mac-loop-test-schedule
   (list (list 0.3 'menu mac-loop-scenario--looptest-top-index
              mac-loop-scenario--looptest-item-index)))
  (let ((busy (mac-loop-scenario--busy 0.6)))
    (setq mac-loop-scenario--looptest-enabled nil)
    (mac-loop-scenario--then 1.5
      (list :busy busy
            :count mac-loop-scenario--looptest-count
            :messages (mac-loop-scenario--looptest-messages-tail)))))

(defun mac-loop-scenario-menu-nested ()
  "Select an item of a nested submenu; its :enable is rechecked through
the nested key path (D5) and it runs exactly once."
  (mac-loop-scenario--install-looptest-menu)
  (define-key global-map [menu-bar looptest nested]
    (cons "Nested" (make-sparse-keymap "Nested")))
  (define-key global-map [menu-bar looptest nested inner]
    '(menu-item "Inner" mac-loop-scenario--looptest-command
                :enable mac-loop-scenario--looptest-enabled))
  (force-mode-line-update t)
  (redisplay t)
  ;; `define-key' prepends, so Nested is item 0 and Run is item 1.
  (mac-loop-test-schedule
   (list (list 0.3 'menu mac-loop-scenario--looptest-top-index 0 0)))
  (mac-loop-scenario--then 1.5
    (list :count mac-loop-scenario--looptest-count
          :commands (mac-loop-scenario--commands)
          :messages (mac-loop-scenario--looptest-messages-tail))))

(defun mac-loop-scenario-menu-frame-deleted ()
  "Select from a second frame's menu bar, then delete that frame before
Lisp drains the selection: it must be rejected as \"frame closed\"
(D16) and must not run the command."
  (mac-loop-scenario--install-looptest-menu)
  (let ((second (make-frame '((width . 40) (height . 10)))))
    (select-frame-set-input-focus second)
    (force-mode-line-update t)
    (redisplay t)
    (mac-loop-test-schedule
     (list (list 0.3 'menu mac-loop-scenario--looptest-top-index
                mac-loop-scenario--looptest-item-index))
     second)
    (let ((busy (mac-loop-scenario--busy 0.6)))
      (delete-frame second)
      (mac-loop-scenario--then 1.5
        (list :busy busy
              :count mac-loop-scenario--looptest-count
              :messages (mac-loop-scenario--looptest-messages-tail))))))

(defun mac-loop-scenario--menu-update-time (n)
  "Return seconds per forced menu-bar update, averaged over N redisplays."
  (let ((start (float-time)))
    (dotimes (_ n)
      (force-mode-line-update t)
      (redisplay t))
    (/ (- (float-time) start) n)))

(defun mac-loop-scenario--load-menus ()
  "Create many buffers and buffers in several modes that add menus."
  (dotimes (i 200)
    (with-current-buffer (get-buffer-create (format "fill-%03d" i))
      (insert "x")))
  (dolist (mode '(org-mode c-mode python-mode sh-mode outline-mode
                  emacs-lisp-mode))
    (with-current-buffer (get-buffer-create (format "*fill-%s*" mode))
      (funcall mode)))
  (switch-to-buffer "*fill-org-mode*"))

(defun mac-loop-scenario-menu-fill-cost ()
  "Time forced menu-bar updates with a plain setup, then with many
buffers and several major modes that add menus.  Each update fills the
whole menu tree, so the difference is the deep-fill cost."
  (let ((plain (mac-loop-scenario--menu-update-time 50))
        (gcs gcs-done))
    (mac-loop-scenario--load-menus)
    (let ((loaded (mac-loop-scenario--menu-update-time 50)))
      (mac-loop-scenario--then 0.5
        (list :plain-ms (* 1000 plain) :loaded-ms (* 1000 loaded)
              :gcs (- gcs-done gcs))))))

(defun mac-loop-scenario-menu-open-cost ()
  "Open each top-level menu once with the setup of `menu-fill-cost'.
Under the new loop each opening while Lisp is idle refreshes that menu
(D3); the \"menu open\" records give the time the GUI waited.  Indices
past the last menu record \"menu-open missing\"."
  (mac-loop-scenario--load-menus)
  (force-mode-line-update t)
  (redisplay t)
  (let ((actions '((0.3 menu-tracking 1))) (time 0.4))
    (dotimes (i 12)
      (push (list time 'menu-open (1+ i)) actions)
      (push (list (+ time 0.1) 'menu-close (1+ i)) actions)
      (setq time (+ time 0.2)))
    (push (list time 'menu-tracking 0) actions)
    (mac-loop-test-schedule (nreverse actions))
    (mac-loop-scenario--then (+ time 0.5)
      (list :buffers (length (buffer-list))))))

(defun mac-loop-scenario-close-busy ()
  "Close a second frame while Lisp computes; it goes away afterwards."
  (let* ((first (selected-frame))
         (second (make-frame '((width . 40) (height . 10)))))
    (sit-for 0.5)
    (mac-loop-test-schedule '((0.5 close) (0.7 close) (0.9 close)) second)
    (select-frame first)
    (let ((busy (mac-loop-scenario--busy 2)))
      (mac-loop-scenario--then 1.0
        (list :busy busy :second-live (frame-live-p second)
              :frames (length (frame-list)))))))

;; 04's stress check: Lisp-to-GUI requests interleaved with native
;; tracking and window operations must not deadlock.
(defun mac-loop-scenario-stress-requests ()
  "Frequent title changes and redisplay during drags and window ops."
  (let* ((n 0)
         (timer (run-at-time 0 0.01
                             (lambda ()
                               (setq n (1+ n))
                               (set-frame-parameter nil 'name
                                                    (format "stress %d" n))
                               (redisplay t)))))
    (mac-loop-test-schedule
     (append (mac-loop-scenario--corner-drag 0.3)
             '((2.0 zoom) (2.8 zoom) (3.5 miniaturize) (4.5 deminiaturize))
             (mac-loop-scenario--type 5.0 "ofo")))
    (mac-loop-scenario--then 6.5
      (cancel-timer timer)
      (list :ticks n :after (mac-loop-scenario--frame-state)
            :commands (mac-loop-scenario--commands)))))

(defun mac-loop-scenario-thread-busy ()
  "A second Lisp thread computes while the main thread waits for input."
  (let ((thread (make-thread (lambda () (mac-loop-scenario--busy 3))
                             "loop-test-busy")))
    (mac-loop-test-schedule
     (append '((0.5 set-size 700 500))
             (mac-loop-scenario--type 1.0 "ofo")))
    (mac-loop-scenario--then 4.5
      (list :thread-alive (thread-live-p thread)
            :after (mac-loop-scenario--frame-state)
            :commands (mac-loop-scenario--commands)))))

;;; Precise scroll gestures.  The GUI thread defers scroll events
;;; while Lisp is busy and merges consecutive `changed' events of one
;;; gesture phase into one event carrying the summed deltas.

(defvar mac-loop-scenario--wheel-events nil
  "Wheel events received, most recent first.
Each element is (PHASE MOMENTUM-PHASE SCROLLING-DELTA-Y TIMESTAMP).")

(defun mac-loop-scenario--record-wheel (event)
  (interactive "e")
  (let ((plist (nth 3 event)))
    (push (list (plist-get plist :phase) (plist-get plist :momentum-phase)
                (or (plist-get plist :scrolling-delta-y) 0.0)
                (/ (posn-timestamp (event-start event)) 1000.0))
          mac-loop-scenario--wheel-events)))

(defun mac-loop-scenario--wheel-setup ()
  "Record every wheel event instead of scrolling."
  (setq mac-loop-scenario--wheel-events nil)
  (let ((map (make-sparse-keymap)))
    (dolist (prefix '("" "double-" "triple-"))
      (dolist (base '(wheel-up wheel-down wheel-left wheel-right))
        (define-key map (vector (intern (concat prefix (symbol-name base))))
                    #'mac-loop-scenario--record-wheel)))
    (setq overriding-local-map map)))

(defun mac-loop-scenario--scroll-gesture (start step)
  "Return actions posting a precise scroll gesture from time START.
Events are STEP seconds apart: a scroll phase `began' (-1 pixel),
20 `changed' (-3 each) and `ended' (0), then a momentum phase `began'
(-2), 15 `changed' (-2 each) and `ended' (0), 93 pixels in all."
  (let* ((time start) actions
         (post (lambda (dy phase momentum)
                 (push (list time 'scroll 0 dy phase momentum) actions)
                 (setq time (+ time step)))))
    (funcall post -1 'began 'none)
    (dotimes (_ 20) (funcall post -3 'changed 'none))
    (funcall post 0 'ended 'none)
    (funcall post -2 'none 'began)
    (dotimes (_ 15) (funcall post -2 'none 'changed))
    (funcall post 0 'none 'ended)
    (nreverse actions)))

(defun mac-loop-scenario--wheel-summary ()
  "Summarize the received wheel events as a plist.
:phases lists the (PHASE MOMENTUM-PHASE) pairs with runs of equal
pairs collapsed, :changed and :momentum-changed count the `changed'
events of either phase, and :total sums the pixel deltas."
  (let ((events (reverse mac-loop-scenario--wheel-events))
        phases (changed 0) (momentum 0) (total 0.0) (prev-time 0) (ordered t))
    (dolist (e events)
      (let ((pair (list (nth 0 e) (nth 1 e))))
        (unless (equal pair (car phases))
          (push pair phases))
        (when (eq (nth 0 e) 'changed) (setq changed (1+ changed)))
        (when (eq (nth 1 e) 'changed) (setq momentum (1+ momentum)))
        (setq total (+ total (nth 2 e)))
        (when (< (nth 3 e) prev-time) (setq ordered nil))
        (setq prev-time (nth 3 e))))
    (list :phases (nreverse phases) :changed changed
          :momentum-changed momentum :total total
          :timestamps-ordered ordered :events events)))

(defconst mac-loop-scenario--scroll-phases
  '((began none) (changed none) (ended none)
    (none began) (none changed) (none ended))
  "The gesture structure every scroll scenario must preserve.")

(defun mac-loop-scenario--c-busy-length (seconds)
  "Return the string length for which `mac-loop-scenario--c-busy' takes SECONDS.
The calibration itself computes for about 0.1 s, and the Lisp around
it lets `read_socket' take deferred events, so call this before
posting the events a scenario expects to be deferred."
  (let* ((n 8000)
         (a (make-string n ?a)) (b (make-string n ?b))
         (start (float-time)))
    (string-distance a b t)
    (let ((unit (max 1e-4 (- (float-time) start))))
      ;; The work grows with the square of the length.
      (min 60000 (round (* n (sqrt (/ seconds unit))))))))

(defun mac-loop-scenario--c-busy (length)
  "Compute in C code that never checks for quits; return the seconds taken.
LENGTH comes from `mac-loop-scenario--c-busy-length'.  Unlike
`mac-loop-scenario--busy', no `maybe_quit' lets `read_socket' take the
deferred events in between, as in a long redisplay."
  (let ((a (make-string length ?a)) (b (make-string length ?b))
        (start (float-time)))
    (string-distance a b t)
    (- (float-time) start)))

(defun mac-loop-scenario-busy-scroll ()
  "A precise scroll gesture while Lisp computes in C.
All events are deferred.  Expect the `changed' events of each phase to
arrive merged (fewer than posted), the pixel total (-93) preserved,
and the began/ended events unmerged and in order.  The merged event
carries the timestamp of the newest event it stands for, so it is at
least 50 ms later than its phase's `began'."
  (mac-loop-scenario--wheel-setup)
  (let ((length (mac-loop-scenario--c-busy-length 0.8))
        busy)
    (mac-loop-test-schedule (mac-loop-scenario--scroll-gesture 0.1 0.004))
    (setq busy (mac-loop-scenario--c-busy length))
    (mac-loop-scenario--then 1.5
      (let* ((s (mac-loop-scenario--wheel-summary))
             (events (plist-get s :events))
             (began (nth 3 (assoc 'began events)))
             (first-changed (nth 3 (assoc 'changed events)))
             (checks
              (list
               ;; The last event is posted at 0.252 s.
               (cons 'busy-covers-burst (> busy 0.3))
               (cons 'phases (equal (plist-get s :phases)
                                    mac-loop-scenario--scroll-phases))
               (cons 'changed-merged (< (plist-get s :changed) 20))
               (cons 'momentum-merged
                     (< (plist-get s :momentum-changed) 15))
               (cons 'total (= (plist-get s :total) -93.0))
               (cons 'ordered (plist-get s :timestamps-ordered))
               (cons 'newest-timestamp
                     (and began first-changed
                          (>= (- first-changed began) 0.05))))))
        (append (list :pass (not (rassq nil checks)) :checks checks
                      :busy busy)
                s)))))

(defun mac-loop-scenario-idle-scroll ()
  "The same scroll gesture while Lisp waits for input.
Expect every event to arrive unmerged, in order, with the pixel total
(-93) preserved.  Events are 30 ms apart so that Lisp is back in its
input wait for each; closer events can arrive while it still handles
the previous one, and are then merged."
  (mac-loop-scenario--wheel-setup)
  (mac-loop-test-schedule (mac-loop-scenario--scroll-gesture 0.1 0.03))
  (mac-loop-scenario--then 2.0
    (let* ((s (mac-loop-scenario--wheel-summary))
           (checks
            (list
             (cons 'phases (equal (plist-get s :phases)
                                  mac-loop-scenario--scroll-phases))
             (cons 'changed (= (plist-get s :changed) 20))
             (cons 'momentum-changed
                   (= (plist-get s :momentum-changed) 15))
             (cons 'total (= (plist-get s :total) -93.0))
             (cons 'ordered (plist-get s :timestamps-ordered)))))
      (append (list :pass (not (rassq nil checks)) :checks checks) s))))

;; Mouse events over the text area.

(defvar mac-loop-scenario--help nil
  "Help strings shown since the scenario started, most recent first.")

(defun mac-loop-scenario--mouse-setup ()
  "Insert text with a `help-echo' property; record the help shown.
Return the positions (TARGET PLAIN) of the text with help and of
plain text below it."
  (setq mac-loop-scenario--help nil
        show-help-function
        (lambda (help) (push help mac-loop-scenario--help)))
  ;; Timers run in whatever buffer was current.
  (set-buffer (window-buffer))
  (insert "\n" (propertize "HELPTARGET" 'help-echo "scenario-help")
          "\n\nplain text here\n")
  (goto-char (point-min))
  (redisplay t)
  (list (+ (point-min) 3) (+ (point-min) 17)))

(defun mac-loop-scenario--window-point (pos)
  "Return the window point (X Y), top-left origin, of the character at POS."
  (let* ((outer (frame-edges nil 'outer-edges))
         (native (frame-edges nil 'native-edges))
         (inside (window-inside-pixel-edges))
         (xy (posn-x-y (posn-at-point pos))))
    (list (+ (- (nth 0 native) (nth 0 outer)) (nth 0 inside) (car xy)
             (/ (frame-char-width) 2))
          (+ (- (nth 1 native) (nth 1 outer)) (nth 1 inside) (cdr xy)
             (/ (frame-char-height) 2)))))

(defun mac-loop-scenario--mouse-actions (start target plain)
  "Return actions from time START: move over TARGET, then PLAIN, then click.
TARGET and PLAIN are buffer positions."
  (let ((a (mac-loop-scenario--window-point target))
        (b (mac-loop-scenario--window-point plain)))
    `((,start move ,@a) (,(+ start 0.3) move ,@b)
      (,(+ start 0.5) down ,@b) (,(+ start 0.55) up ,@b))))

(defun mac-loop-scenario--mouse-checks (plain)
  "Return the checks of a mouse scenario whose click was at PLAIN."
  (list (cons 'help-shown
              (and (member "scenario-help" mac-loop-scenario--help) t))
        (cons 'clicked (= (window-point) plain))
        (cons 'mouse-command
              (and (memq 'mouse-set-point (mac-loop-scenario--commands)) t))))

(defun mac-loop-scenario-idle-mouse ()
  "Move over text with `help-echo' and click while Lisp waits for input.
Expect the help to be shown and point to move to the click."
  (pcase-let ((`(,target ,plain) (mac-loop-scenario--mouse-setup)))
    (mac-loop-test-schedule
     (mac-loop-scenario--mouse-actions 0.2 target plain))
    (mac-loop-scenario--then 1.5
      (let ((checks (mac-loop-scenario--mouse-checks plain)))
        (list :pass (not (rassq nil checks)) :checks checks
              :help mac-loop-scenario--help :point (window-point)
              :commands (mac-loop-scenario--commands))))))

(defun mac-loop-scenario-busy-mouse ()
  "The moves and click of `idle-mouse' while Lisp computes."
  (pcase-let ((`(,target ,plain) (mac-loop-scenario--mouse-setup)))
    (mac-loop-test-schedule
     (mac-loop-scenario--mouse-actions 0.2 target plain))
    (let ((busy (mac-loop-scenario--busy 1.5)))
      (mac-loop-scenario--then 1.5
        (let ((checks (mac-loop-scenario--mouse-checks plain)))
          (list :pass (not (rassq nil checks)) :checks checks :busy busy
                :help mac-loop-scenario--help :point (window-point)
                :commands (mac-loop-scenario--commands)))))))

(defun mac-loop-scenario-fullscreen-busy ()
  "Enter and leave fullscreen while Lisp computes."
  (mac-loop-test-schedule '((0.5 fullscreen) (2.5 probe 1) (3.0 fullscreen)
                            (4.5 probe 2) (7.5 probe 3)))
  (let ((busy (mac-loop-scenario--busy 5)))
    (mac-loop-scenario--then 3.0
      (list :busy busy :after (mac-loop-scenario--frame-state)))))

(defun mac-loop-scenario-fullscreen-idle ()
  "Enter fullscreen while idle and check the frame parameter."
  (mac-loop-test-schedule '((0.3 fullscreen)))
  (mac-loop-scenario--then 2.5
    (let ((during (mac-loop-scenario--frame-state)))
      (mac-loop-test-schedule '((0 fullscreen)))
      ;; `sit-for' returns early on the transition's input events.
      (sleep-for 2.5)
      (list :during during :after (mac-loop-scenario--frame-state)))))

;; W7/W8 window-close and Quit dedupe/indicator scenarios (S3).

(defun mac-loop-scenario-win-close-dedupe ()
  "Three close clicks on a busy second frame delete it exactly once.
`handle-delete-frame' is counted via advice so a regression that lets
duplicate DELETE_WINDOW_EVENTs through is visible even though the
frame itself can only be deleted once."
  (let* ((first (selected-frame))
         (second (make-frame '((width . 40) (height . 10))))
         (count 0))
    (sit-for 0.5)
    (advice-add 'handle-delete-frame :before
                (lambda (&rest _) (setq count (1+ count))))
    (mac-loop-test-schedule '((0.5 close) (0.7 close) (0.9 close)) second)
    (select-frame first)
    (let ((busy (mac-loop-scenario--busy 2)))
      (mac-loop-scenario--then 1.0
        (list :busy busy
              :second-live (frame-live-p second)
              :delete-frame-count count
              :frames (length (frame-list)))))))

(defun mac-loop-scenario-win-close-indicator ()
  "The \"Waiting for Emacs…\" subtitle appears within ~150 ms of a
busy close, and is cleared once Lisp resolves it."
  (let* ((first (selected-frame))
         (second (make-frame '((width . 40) (height . 10)))))
    (sit-for 0.5)
    (mac-loop-test-schedule '((0.5 close) (0.65 subtitle) (1.8 subtitle))
                             second)
    (select-frame first)
    (let ((busy (mac-loop-scenario--busy 2)))
      (mac-loop-scenario--then 1.0
        (let* ((test (mac-loop-test-results nil))
               (log (nth 2 test))
               (subtitles
                (mapcar #'cdr
                        (seq-filter
                         (lambda (e) (string-prefix-p "subtitle " (cdr e)))
                         log))))
          (list :busy busy
                :second-live (frame-live-p second)
                :subtitles subtitles))))))

(defun mac-loop-scenario-win-quit-idle ()
  "Quit while Lisp is idle reaches `save-buffers-kill-emacs' once.
It is overridden so the scenario neither prompts nor exits."
  (let ((count 0))
    (advice-add 'save-buffers-kill-emacs :override
                (lambda (&rest _) (setq count (1+ count))))
    (mac-loop-test-schedule '((0.3 terminate)))
    (mac-loop-scenario--then 2.0
      (list :quit-count count))))

(defun mac-loop-scenario-win-quit-dedupe ()
  "Three Quit (terminate:) calls on a busy Lisp thread quit at most
once.  `save-buffers-kill-emacs' is overridden so the scenario neither
prompts nor actually exits; the override's own return also resumes the
suspended kAEQuitApplication reply as \"cancelled\", exercising the
same code path a real cancel would."
  (let ((count 0))
    (advice-add 'save-buffers-kill-emacs :override
                (lambda (&rest _) (setq count (1+ count))))
    (mac-loop-test-schedule '((0.5 terminate) (0.7 terminate)
                               (0.9 terminate)))
    (let ((busy (mac-loop-scenario--busy 2)))
      (sit-for 0.3)
      (sit-for 0.3)
      (sit-for 0.3)
      (mac-loop-scenario--then 1.0
        (list :busy busy :quit-count count
              :commands (mac-loop-scenario--commands))))))

(defun mac-loop-scenario-run (name)
  "Run scenario NAME, write its result and exit.
Setup and the scenario body run in timers; the result is collected
after the command loop has executed input queued meanwhile."
  (let ((fn (intern (format "mac-loop-scenario-%s" name))))
    (run-at-time
     1 nil
     (lambda ()
       (mac-loop-scenario--prepare)
       (run-at-time
        0.1 nil
        (lambda ()
          (let ((k (condition-case err (funcall fn)
                     (error (list :wait 0 :collect
                                  (lambda ()
                                    (list :error (format "%S" err))))))))
            (run-at-time (plist-get k :wait) nil
                         (lambda ()
                           (mac-loop-scenario--finish
                            name
                            (condition-case err
                                (funcall (plist-get k :collect))
                              (error
                               (list :error (format "%S" err))))))))))))))

;;; scenarios.el ends here

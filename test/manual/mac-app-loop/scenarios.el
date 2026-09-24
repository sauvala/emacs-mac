;;; scenarios.el --- scripted persistent-loop scenarios  -*- lexical-binding: t -*-

;; Run inside a GUI Emacs of this checkout, for example:
;;   EMACS_MAC_PERSISTENT_LOOP=1 mac/Emacs.app/Contents/MacOS/Emacs -Q \
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
                              :loop (or (getenv "EMACS_MAC_PERSISTENT_LOOP")
                                        "0")
                              :gui-max-gap (nth 0 test)
                              :gui-long-gaps (nth 1 test))
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

(defun mac-loop-scenario-idle-resize ()
  "Drag the bottom-right corner while Lisp is idle."
  (let ((before (mac-loop-scenario--frame-state)))
    (mac-loop-test-schedule (mac-loop-scenario--corner-drag 0.3))
    (mac-loop-scenario--then 2.5
      (list :before before :after (mac-loop-scenario--frame-state)))))

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

(defun mac-loop-scenario--install-looptest-menu ()
  (setq mac-loop-scenario--looptest-count 0)
  (define-key global-map [menu-bar looptest]
    (cons "LoopTest" (make-sparse-keymap "LoopTest")))
  (define-key global-map [menu-bar looptest run]
    '(menu-item "Run" mac-loop-scenario--looptest-command))
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
                            name (funcall (plist-get k :collect))))))))))))

;;; scenarios.el ends here

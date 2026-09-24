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

(defun mac-loop-scenario-idle-quit-debug ()
  (let ((count 0))
    (advice-add 'save-buffers-kill-emacs :override
                (lambda (&rest _) (setq count (1+ count))))
    (mac-loop-test-schedule '((0.3 terminate)))
    (mac-loop-scenario--then 2.0
      (list :quit-count count :commands (mac-loop-scenario--commands)))))

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
                            name (funcall (plist-get k :collect))))))))))))

;;; scenarios.el ends here

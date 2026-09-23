;;; fixture.el --- S0 instrumentation fixture for the mac-app-loop project  -*- lexical-binding: t; -*-

;; Copyright notice: fork-local test tooling, not destined for upstream
;; GNU Emacs (see AGENTS.md).

;;; Commentary:

;; Manual/scripted fixture for stage S0 of the persistent event loop work
;; (.wayfinder/issues/08-s0-instrumentation.md).  It makes NO behavior
;; change to the mac port itself: it only logs observable facts (commands
;; run, frame size changes, focus changes, frame deletion, kill-emacs) and
;; provides a busy-Lisp workload that never waits for input, so native
;; responsiveness can be checked while Lisp genuinely cannot service GUI
;; requests.
;;
;; Uses only Emacs built-ins; no external packages.
;;
;; Entry points:
;;   `mac-app-loop-start'                 - call once after loading, sets
;;                                           up logging, hooks and the
;;                                           heartbeat timer.
;;   `mac-app-loop-busy'                  - SECONDS of pure-Lisp CPU work,
;;                                           interruptible with C-g.
;;   `mac-app-loop-busy-no-quit'          - same, wrapped in inhibit-quit.
;;   `mac-app-loop-heartbeat-start/-stop' - 0.1s repeating timer, logs the
;;                                           actual gap between ticks.
;;   `mac-app-loop-key-latency-mode'      - global minor mode logging
;;                                           per-event arrival/latency.
;;   `mac-app-loop-setup-test-buffers'    - a plain buffer and a modified,
;;                                           unsaved file-visiting buffer,
;;                                           for close/quit prompt checks.
;;   `mac-app-loop-report'                - summarizes the log into
;;                                           *mac-app-loop-report*.
;;
;; Log format: one line per event, three tab-separated fields:
;;   TIMESTAMP<TAB>TAG<TAB>DATA
;; TIMESTAMP is `format-time-string' with millisecond precision (sorts as
;; plain text).  DATA is free-form "key=value ..." text produced with
;; `format'.  See `mac-app-loop--parse-log-line'.

;;; Code:

(require 'cl-lib)

(defgroup mac-app-loop nil
  "S0 instrumentation fixture for the mac-app-loop project."
  :group 'tools)

(defvar mac-app-loop-log-file nil
  "Absolute path of the log file used by this session.
Set by `mac-app-loop-start' (or lazily by the first call to
`mac-app-loop-log') from the MAC_APP_LOOP_LOG environment variable, falling
back to /tmp/mac-app-loop.log.")

(defvar mac-app-loop--heartbeat-timer nil
  "Timer object for the running heartbeat, or nil.")

(defvar mac-app-loop--heartbeat-last nil
  "`float-time' of the previous heartbeat tick.")

(defvar mac-app-loop--test-dir nil
  "Temp directory created by `mac-app-loop-setup-test-buffers'.")

(defvar mac-app-loop--focus-advice-installed nil
  "Non-nil once focus tracking has been wired up, so it is only done once.")


;;; Logging

(defun mac-app-loop--log-file ()
  "Return the log file path for this session, computing it once."
  (or mac-app-loop-log-file
      (setq mac-app-loop-log-file
            (let ((env (getenv "MAC_APP_LOOP_LOG")))
              (if (and env (not (string-empty-p env)))
                  env
                "/tmp/mac-app-loop.log")))))

(defun mac-app-loop--timestamp (&optional time)
  "Format TIME (or the current time) with millisecond precision.
Pure given TIME, so it is unit-testable without depending on wall-clock
time; see fixture-tests.el."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%3N" time))

(defun mac-app-loop--format-log-line (timestamp tag data)
  "Format one tab-separated log line from TIMESTAMP, TAG and DATA.
Pure function; the inverse of `mac-app-loop--parse-log-line'."
  (format "%s\t%s\t%s" timestamp tag (or data "")))

(defun mac-app-loop--parse-log-line (line)
  "Parse a tab-separated log LINE into a list (TIMESTAMP TAG DATA).
Return nil if LINE is not well-formed.  Pure function."
  (when (and (stringp line)
             (string-match "\\`\\([^\t\n]+\\)\t\\([^\t\n]+\\)\t\\(.*\\)\\'" line))
    (list (match-string 1 line) (match-string 2 line) (match-string 3 line))))

(defun mac-app-loop-log (tag &rest args)
  "Append a log line tagged TAG to the mac-app-loop log file.
If ARGS is non-nil, its car is a `format' control string applied to the
rest of ARGS to produce the DATA field; otherwise DATA is empty.
Never signals: I/O failures are swallowed so instrumentation cannot itself
break the thing it is observing."
  (let* ((data (if args (apply #'format args) ""))
         (line (mac-app-loop--format-log-line (mac-app-loop--timestamp) tag data)))
    (ignore-errors
      (write-region (concat line "\n") nil (mac-app-loop--log-file) t 'silent))
    line))

(defun mac-app-loop--read-log-lines (&optional file)
  "Read FILE (or the session log file) and return its lines as a list."
  (let ((file (or file (mac-app-loop--log-file))))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (split-string (buffer-string) "\n" t)))))


;;; Busy-Lisp fixture

(defun mac-app-loop--busy-loop (seconds)
  "Spin the CPU for SECONDS of wall-clock time.
Never calls `sit-for', `sleep-for', `accept-process-output', or anything
else that waits on input, timers, or subprocesses; it is ordinary Lisp
arithmetic in a `while' loop, so `maybe_quit' still runs at the normal
per-form check points and C-g can interrupt it (unless `inhibit-quit' is
set by the caller).  Returns the iteration count."
  (let ((end (+ (float-time) (max 0 seconds)))
        (iterations 0)
        (acc 1))
    (while (< (float-time) end)
      ;; Deliberately non-trivial arithmetic so the compiler/interpreter
      ;; cannot fold the loop away; the exact function does not matter.
      (setq acc (mod (+ (* acc 1103515245) 12345) 2147483648))
      (setq iterations (1+ iterations)))
    iterations))

;;;###autoload
(defun mac-app-loop-busy (seconds)
  "Busy-loop in pure Lisp for SECONDS, never waiting for input.
Logs BUSY-START, then BUSY-END or (if interrupted with C-g) BUSY-INTERRUPTED."
  (interactive "nSeconds: ")
  (mac-app-loop-log "BUSY-START" "seconds=%s" seconds)
  (condition-case nil
      (let ((n (mac-app-loop--busy-loop seconds)))
        (mac-app-loop-log "BUSY-END" "seconds=%s iterations=%d" seconds n))
    (quit
     (mac-app-loop-log "BUSY-INTERRUPTED" "seconds=%s" seconds)
     (signal 'quit nil))))

;;;###autoload
(defun mac-app-loop-busy-no-quit (seconds)
  "Like `mac-app-loop-busy', but run inside `inhibit-quit'.
Any C-g received during the loop is recorded as a deferred quit (it fires,
per normal Emacs semantics, only after `inhibit-quit' reverts to nil) and
logged as BUSY-NOQUIT-INTERRUPTED instead of BUSY-NOQUIT-END."
  (interactive "nSeconds: ")
  (mac-app-loop-log "BUSY-NOQUIT-START" "seconds=%s" seconds)
  (let (n deferred-quit)
    (let ((inhibit-quit t))
      (setq n (mac-app-loop--busy-loop seconds))
      (setq deferred-quit quit-flag))
    (if deferred-quit
        (mac-app-loop-log "BUSY-NOQUIT-INTERRUPTED" "seconds=%s iterations=%d" seconds n)
      (mac-app-loop-log "BUSY-NOQUIT-END" "seconds=%s iterations=%d" seconds n))))


;;; Heartbeat

;;;###autoload
(defun mac-app-loop-heartbeat-start ()
  "Start a 0.1s repeating timer that logs the actual gap between ticks.
A gap much larger than 0.1s shows a span during which Lisp could not
service timers (e.g. it was inside `mac-app-loop-busy-no-quit')."
  (interactive)
  (mac-app-loop-heartbeat-stop)
  (setq mac-app-loop--heartbeat-last (float-time))
  (setq mac-app-loop--heartbeat-timer
        (run-at-time 0.1 0.1 #'mac-app-loop--heartbeat-tick))
  (mac-app-loop-log "HEARTBEAT-STARTED" "interval=0.1"))

(defun mac-app-loop--heartbeat-tick ()
  "Log the elapsed time since the previous heartbeat tick."
  (let* ((now (float-time))
         (gap (- now (or mac-app-loop--heartbeat-last now))))
    (setq mac-app-loop--heartbeat-last now)
    (mac-app-loop-log "HEARTBEAT" "gap=%.4f" gap)))

;;;###autoload
(defun mac-app-loop-heartbeat-stop ()
  "Stop the heartbeat timer started by `mac-app-loop-heartbeat-start'."
  (interactive)
  (when mac-app-loop--heartbeat-timer
    (cancel-timer mac-app-loop--heartbeat-timer)
    (setq mac-app-loop--heartbeat-timer nil)
    (mac-app-loop-log "HEARTBEAT-STOPPED" "")))


;;; Command, frame, focus and lifecycle logging

(defun mac-app-loop--post-command ()
  "Log the command just executed and the input event that triggered it."
  (mac-app-loop-log "COMMAND" "this-command=%S last-input-event=%S"
                     this-command last-input-event))

(defun mac-app-loop--window-size-change (frame)
  "Log FRAME's new pixel size."
  (mac-app-loop-log "FRAME-SIZE" "frame=%S pixel-width=%d pixel-height=%d"
                     frame (frame-pixel-width frame) (frame-pixel-height frame)))

(defun mac-app-loop--delete-frame (frame)
  "Log deletion of FRAME."
  (mac-app-loop-log "DELETE-FRAME" "frame=%S" frame))

(defun mac-app-loop--focus-change (&rest _)
  "Log a focus change, naming the currently selected frame."
  (mac-app-loop-log "FOCUS-CHANGE" "selected-frame=%S has-focus=%S"
                     (selected-frame)
                     (ignore-errors (frame-focus-state (selected-frame)))))

(defun mac-app-loop--kill-emacs ()
  "Log Emacs shutting down."
  (mac-app-loop-log "KILL-EMACS" ""))

(defun mac-app-loop--install-hooks ()
  "Wire up the logging hooks.  Idempotent."
  (add-hook 'post-command-hook #'mac-app-loop--post-command)
  (add-hook 'window-size-change-functions #'mac-app-loop--window-size-change)
  (add-hook 'delete-frame-functions #'mac-app-loop--delete-frame)
  (add-hook 'kill-emacs-hook #'mac-app-loop--kill-emacs)
  (unless mac-app-loop--focus-advice-installed
    (setq mac-app-loop--focus-advice-installed t)
    (if (boundp 'after-focus-change-function)
        (add-function :after after-focus-change-function
                       #'mac-app-loop--focus-change)
      ;; Fallback for Emacs < 27; obsolete on the versions this fixture is
      ;; otherwise built against, so silence the byte-compiler about it.
      (with-suppressed-warnings ((obsolete focus-in-hook focus-out-hook))
        (add-hook 'focus-in-hook #'mac-app-loop--focus-change)
        (add-hook 'focus-out-hook #'mac-app-loop--focus-change)))))


;;; Key/mouse latency

(defun mac-app-loop--log-event-latency ()
  "Log arrival/latency information for the event that triggered this command.
For a mouse click event, logs the difference between now and the event's
`posn-timestamp' when that timestamp looks meaningful (mouse timestamps are
milliseconds on a platform-specific clock, not wall-clock epoch time, so the
difference is only a relative diagnostic within one session, not an
absolute latency).  Key events carry no timestamp, so only arrival time is
logged."
  (let ((event last-input-event))
    (if (and (consp event) (consp (event-start event))
             (numberp (posn-timestamp (event-start event))))
        (let* ((posn (event-start event))
               (posn-ts (posn-timestamp posn))
               (now (float-time)))
          (mac-app-loop-log "MOUSE-LATENCY"
                             "event=%S posn-timestamp-ms=%s now=%.4f delta=%.4f"
                             (car-safe event) posn-ts now
                             (- now (/ posn-ts 1000.0))))
      (mac-app-loop-log "KEY-ARRIVAL" "event=%S now=%.4f" event (float-time)))))

;;;###autoload
(define-minor-mode mac-app-loop-key-latency-mode
  "Global minor mode logging per-event arrival time / latency.
See `mac-app-loop--log-event-latency'."
  :global t
  :group 'mac-app-loop
  (if mac-app-loop-key-latency-mode
      (add-hook 'pre-command-hook #'mac-app-loop--log-event-latency)
    (remove-hook 'pre-command-hook #'mac-app-loop--log-event-latency)))


;;; Test buffers

;;;###autoload
(defun mac-app-loop-setup-test-buffers ()
  "Create a plain buffer and a modified, unsaved file-visiting buffer.
The file-visiting buffer lives under a fresh temp directory so close/quit
save-prompt scenarios have something real to prompt about.  Returns
(DIR FILE)."
  (interactive)
  (let* ((dir (make-temp-file "mac-app-loop-" t))
         (file (expand-file-name "scratch-file.txt" dir)))
    (setq mac-app-loop--test-dir dir)
    (with-current-buffer (get-buffer-create "*mac-app-loop-test*")
      (erase-buffer)
      (insert "mac-app-loop plain test buffer.\n"))
    (write-region "initial contents\n" nil file nil 'silent)
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "unsaved edit made by mac-app-loop-setup-test-buffers\n")
      (set-buffer-modified-p t))
    (mac-app-loop-log "SETUP-BUFFERS" "dir=%s file=%s" dir file)
    (list dir file)))


;;; Report

(defun mac-app-loop--summarize-lines (lines)
  "Summarize parsed log LINES.  Return a plist; pure given LINES."
  (let ((command-count 0)
        (frame-size-count 0)
        (max-heartbeat-gap 0.0)
        (heartbeat-count 0)
        (line-count 0)
        (malformed-count 0))
    (dolist (line lines)
      (let ((parsed (mac-app-loop--parse-log-line line)))
        (if (null parsed)
            (setq malformed-count (1+ malformed-count))
          (setq line-count (1+ line-count))
          (cl-destructuring-bind (_ts tag data) parsed
            (cond
             ((equal tag "COMMAND")
              (setq command-count (1+ command-count)))
             ((equal tag "FRAME-SIZE")
              (setq frame-size-count (1+ frame-size-count)))
             ((equal tag "HEARTBEAT")
              (setq heartbeat-count (1+ heartbeat-count))
              (when (string-match "gap=\\([0-9.]+\\)" data)
                (let ((gap (string-to-number (match-string 1 data))))
                  (when (> gap max-heartbeat-gap)
                    (setq max-heartbeat-gap gap))))))))))
    (list :lines line-count
          :malformed malformed-count
          :commands command-count
          :frame-size-events frame-size-count
          :heartbeat-ticks heartbeat-count
          :max-heartbeat-gap max-heartbeat-gap)))

;;;###autoload
(defun mac-app-loop-report ()
  "Summarize the session log into the *mac-app-loop-report* buffer."
  (interactive)
  (let* ((file (mac-app-loop--log-file))
         (lines (mac-app-loop--read-log-lines file))
         (summary (mac-app-loop--summarize-lines lines)))
    (with-current-buffer (get-buffer-create "*mac-app-loop-report*")
      (erase-buffer)
      (insert (format "mac-app-loop report for %s\n\n" file))
      (insert (format "Log lines parsed:      %d\n" (plist-get summary :lines)))
      (insert (format "Malformed lines:       %d\n" (plist-get summary :malformed)))
      (insert (format "Commands executed:     %d\n" (plist-get summary :commands)))
      (insert (format "Frame-size events:     %d\n" (plist-get summary :frame-size-events)))
      (insert (format "Heartbeat ticks:       %d\n" (plist-get summary :heartbeat-ticks)))
      (insert (format "Max heartbeat gap (s): %.4f\n" (plist-get summary :max-heartbeat-gap)))
      (goto-char (point-min))
      (when (called-interactively-p 'any)
        (display-buffer (current-buffer))))
    summary))


;;; Entry point

;;;###autoload
(defun mac-app-loop-start ()
  "Set up the mac-app-loop fixture: logging, hooks and the heartbeat.
Call once per session, e.g. via -l fixture.el -f mac-app-loop-start.  Writes
a SESSION-START header line recording the environment this run is
exercising."
  (interactive)
  ;; Force (re)computation of the log file from the environment, in case
  ;; this is a second call in the same session.
  (setq mac-app-loop-log-file nil)
  (mac-app-loop--log-file)
  (mac-app-loop-log
   "SESSION-START"
   "emacs-version=%S system-configuration=%S EMACS_MAC_PERSISTENT_LOOP=%S window-system=%S display-pixel-size=%S"
   emacs-version
   system-configuration
   (getenv "EMACS_MAC_PERSISTENT_LOOP")
   window-system
   (ignore-errors (list (display-pixel-width) (display-pixel-height))))
  (mac-app-loop--install-hooks)
  (mac-app-loop-heartbeat-start)
  (message "mac-app-loop: logging to %s" (mac-app-loop--log-file)))

(provide 'mac-app-loop-fixture)

;;; fixture.el ends here

;;; multi-cursor-tests.el --- Manual native multi-cursor stress test  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Start a Mac GUI build from the repository root with:
;;
;;   src/emacs -Q -l test/manual/multi-cursor-tests.el \
;;     --eval '(multi-cursor-manual-test-setup)'
;;
;; The fixture creates 300 secondary cursors in a long buffer by default.
;; Pass 1, 3, 30, or 300 to reproduce the painter with a fixed cursor count.
;; Its banner describes the visual checks and keys for changing cursor shape,
;; scrolling, resizing split windows, and switching the selected window.  The
;; `multi-cursor-manual-test-step' command advances a deterministic sequence
;; one redisplay at a time, making it suitable for Computer Use screenshots.
;; `multi-cursor-manual-test-state' returns a machine-readable plist including
;; buffer hashes, cursor positions, visible cursor-cell rectangles, and any
;; Mac renderer counters provided by the build.  No secondary cursor should
;; leave stale pixels; the ordinary primary cursor should remain the only
;; blinking caret.  The first secondary box sits on text whose background
;; equals the configured cursor color; its glyph must remain legible inside
;; the filled box.

;;; Code:

(require 'cl-lib)
(require 'multi-cursor)

(defconst multi-cursor-manual-test--buffer-name
  "*Native Multiple Cursor Manual Test*"
  "Buffer used by the native multiple-cursor manual fixture.")

(defconst multi-cursor-manual-test--cursor-types
  '(box hollow bar (bar . 3) hbar (hbar . 3))
  "Cursor shapes cycled by `multi-cursor-manual-test-toggle-cursor-type'.")

(defvar-local multi-cursor-manual-test--cursor-type-index 0
  "Index of the cursor shape currently shown by the manual fixture.")

(defvar-local multi-cursor-manual-test--initial-positions nil
  "Initial secondary-cursor positions in the current fixture.")

(defvar-local multi-cursor-manual-test--data-start nil
  "Marker at the first numbered data row in the current fixture.")

(defvar-local multi-cursor-manual-test--step-index 0
  "Index of the next deterministic painter scenario step.")

(defvar-local multi-cursor-manual-test--state-sequence 0
  "Monotonic sequence number assigned to captured fixture states.")

(defvar-local multi-cursor-manual-test--state-log nil
  "Newest-first list of states captured by fixture actions.")

(defvar multi-cursor-manual-test-after-step-hook nil
  "Hook run after a deterministic fixture step.

Each hook function receives two arguments: the step name and the state plist.
Screenshot harnesses can use this hook to capture the frame after redisplay.")

(defconst multi-cursor-manual-test--scenario
  '(force-redisplay move-forward insert scroll remove resize force-redisplay)
  "Actions run in order by `multi-cursor-manual-test-step'.")

(defconst multi-cursor-manual-test--mac-counter-functions
  '(mac-gc-clip-stats
    mac-metal-render-stats
    mac-metal-clip-overdraw-stats
    mac-select-latency-stats)
  "Optional Mac renderer counters recorded in fixture states.")

(defvar-keymap multi-cursor-manual-test-mode-map
  :doc "Keymap for the native multiple-cursor manual fixture."
  "b" #'multi-cursor-manual-test-toggle-cursor-type
  "SPC" #'scroll-up-command
  "DEL" #'scroll-down-command
  ">" #'multi-cursor-manual-test-enlarge-window
  "<" #'multi-cursor-manual-test-shrink-window
  "o" #'multi-cursor-manual-test-other-window
  "g" #'multi-cursor-manual-test-refresh
  "s" #'multi-cursor-manual-test-step
  "a" #'multi-cursor-manual-test-run-scenario
  "d" #'multi-cursor-manual-test-display-state
  "1" #'multi-cursor-manual-test-setup-one
  "3" #'multi-cursor-manual-test-setup-three
  "0" #'multi-cursor-manual-test-setup-thirty
  "9" #'multi-cursor-manual-test-setup-three-hundred
  "q" #'multi-cursor-manual-test-quit)

(define-minor-mode multi-cursor-manual-test-mode
  "Provide keys for the native multiple-cursor manual fixture."
  :lighter " MC-Test"
  :keymap multi-cursor-manual-test-mode-map)

(defun multi-cursor-manual-test--redisplay ()
  "Force redisplay of the manual fixture's visible windows."
  (force-window-update (current-buffer))
  (redisplay 'force))

(defun multi-cursor-manual-test--mac-counters (&optional reset)
  "Return available Mac renderer counters, resetting first when RESET."
  (delq nil
        (mapcar
         (lambda (function)
           (when (fboundp function)
             (cons function
                   (condition-case error-data
                       (funcall function reset)
                     (error (list :error
                                  (error-message-string error-data)))))))
         multi-cursor-manual-test--mac-counter-functions)))

(defun multi-cursor-manual-test--cursor-cell (position window)
  "Return screenshot-mask geometry for POSITION in WINDOW, or nil.

The returned rectangle is in frame-relative pixels and covers the complete
glyph cell.  This deliberately over-approximates bar and hbar cursors so a
pixel comparator can ignore only cells in which cursor painting is expected."
  (when-let* ((posn (posn-at-point position window))
              (xy (posn-x-y posn)))
    (let* ((edges (window-inside-pixel-edges window))
           (width
            (condition-case nil
                (max 1 (car (window-text-pixel-size
                             window position
                             (min (1+ position) (point-max)))))
              (error (frame-char-width (window-frame window)))))
           (height (frame-char-height (window-frame window))))
      (list :position position
            :rect (list (+ (nth 0 edges) (car xy))
                        (+ (nth 1 edges) (cdr xy))
                        width height)))))

(defun multi-cursor-manual-test--fixture-window ()
  "Return the selected fixture window, or another window showing it."
  (if (eq (window-buffer (selected-window)) (current-buffer))
      (selected-window)
    (get-buffer-window (current-buffer) t)))

(defun multi-cursor-manual-test-state (&optional label)
  "Capture and return a machine-readable fixture state named LABEL.

Visible cursor rectangles are complete glyph-cell masks in frame-relative
pixels.  A screenshot comparator should permit changes inside those masks and
flag changes elsewhere.  The state is appended to the buffer-local log."
  (interactive)
  (unless (derived-mode-p 'text-mode)
    (user-error "This is not a native multiple-cursor manual fixture"))
  (multi-cursor-manual-test--redisplay)
  (let* ((window (multi-cursor-manual-test--fixture-window))
         (positions (mapcar (lambda (selection)
                              (plist-get selection :point))
                            (multi-cursor-selections)))
         (cells (and window
                     (delq nil
                           (mapcar (lambda (position)
                                     (multi-cursor-manual-test--cursor-cell
                                      position window))
                                   positions))))
         (state
          (list
           :sequence (cl-incf multi-cursor-manual-test--state-sequence)
           :label label
           :buffer (buffer-name)
           :buffer-sha256 (secure-hash 'sha256 (current-buffer))
           :modified-tick (buffer-chars-modified-tick)
           :primary-point (point)
           :primary-cursor-cell
           (and window
                (multi-cursor-manual-test--cursor-cell (point) window))
           :secondary-count (length positions)
           :secondary-positions positions
           :cursor-type cursor-type
           :native-p (and window
                          (multi-cursor--native-cursor-decorations-p window))
           :window-start (and window (window-start window))
           :window-pixel-edges
           (and window (window-inside-pixel-edges window))
           :frame-size (and window
                            (list (frame-pixel-width (window-frame window))
                                  (frame-pixel-height (window-frame window))))
           :visible-cursor-cells cells
           :mac-counters (multi-cursor-manual-test--mac-counters))))
    (push state multi-cursor-manual-test--state-log)
    (when (called-interactively-p 'interactive)
      (message "%S" state))
    state))

(defun multi-cursor-manual-test-display-state ()
  "Display the current machine-readable fixture state in a separate buffer."
  (interactive)
  (let ((state (multi-cursor-manual-test-state 'manual-capture)))
    (with-current-buffer (get-buffer-create
                          "*Native Multiple Cursor Painter State*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pp state (current-buffer))
        (special-mode)))
    (display-buffer "*Native Multiple Cursor Painter State*")))

(defun multi-cursor-manual-test--run-command (command &optional event)
  "Run multiple-cursor COMMAND with optional last input EVENT."
  (let ((last-command-event (or event last-command-event)))
    (command-execute command)))

(defun multi-cursor-manual-test--perform-step (step)
  "Perform deterministic painter scenario STEP."
  (pcase step
    ('force-redisplay
     (multi-cursor-manual-test--redisplay))
    ('move-forward
     (multi-cursor-manual-test--run-command #'forward-char))
    ('insert
     (multi-cursor-manual-test--run-command #'self-insert-command ?x))
    ('scroll
     (let ((window (multi-cursor-manual-test--fixture-window)))
       (when (and window (marker-position multi-cursor-manual-test--data-start))
         (set-window-start
          window
          (save-excursion
            (goto-char multi-cursor-manual-test--data-start)
            (forward-line 20)
            (point))))))
    ('remove
     (when-let* ((selection (car (last (multi-cursor-selections)))))
       (multi-cursor-remove-at-point (plist-get selection :point))))
    ('resize
     (let* ((frame (selected-frame))
            (width (frame-width frame))
            (height (frame-height frame)))
       (set-frame-size frame (if (> width 90) (1- width) (1+ width)) height)))
    (_ (error "Unknown painter scenario step: %S" step)))
  (multi-cursor-manual-test--redisplay))

(defun multi-cursor-manual-test-step ()
  "Advance one deterministic painter regression step and capture its state.

Steps cover forced redisplay, broadcast movement, broadcast insertion,
scrolling, cursor removal, frame resizing, and a final forced redisplay.  Use
one invocation per screenshot so corruption can be attributed to one action."
  (interactive)
  (let ((step (nth multi-cursor-manual-test--step-index
                   multi-cursor-manual-test--scenario)))
    (unless step
      (user-error "Painter scenario finished; run setup to restart"))
    (multi-cursor-manual-test--perform-step step)
    (cl-incf multi-cursor-manual-test--step-index)
    (let ((state (multi-cursor-manual-test-state step)))
      (run-hook-with-args 'multi-cursor-manual-test-after-step-hook step state)
      (message "Painter step %d/%d: %s; %d secondary cursors"
               multi-cursor-manual-test--step-index
               (length multi-cursor-manual-test--scenario)
               step (plist-get state :secondary-count))
      state)))

(defun multi-cursor-manual-test-run-scenario ()
  "Run all remaining painter steps and return their states in action order.

`multi-cursor-manual-test-after-step-hook' runs synchronously after every
forced redisplay, so an automated screenshot harness can capture each frame.
For manual inspection, prefer `multi-cursor-manual-test-step' so each action
is separated by a key press."
  (interactive)
  (let (states)
    (while (< multi-cursor-manual-test--step-index
              (length multi-cursor-manual-test--scenario))
      (push (multi-cursor-manual-test-step) states))
    (nreverse states)))

(defun multi-cursor-manual-test-toggle-cursor-type ()
  "Cycle the fixture through box, hollow, bar, and horizontal cursors."
  (interactive)
  (setq multi-cursor-manual-test--cursor-type-index
        (mod (1+ multi-cursor-manual-test--cursor-type-index)
             (length multi-cursor-manual-test--cursor-types)))
  (setq-local cursor-type
              (nth multi-cursor-manual-test--cursor-type-index
                   multi-cursor-manual-test--cursor-types))
  (multi-cursor-manual-test--redisplay)
  (message "cursor-type: %S" cursor-type))

(defun multi-cursor-manual-test--ensure-split ()
  "Return another live window, creating a right-hand split if needed."
  (if (one-window-p)
      (split-window-right)
    (next-window)))

(defun multi-cursor-manual-test-enlarge-window ()
  "Enlarge the selected fixture window horizontally."
  (interactive)
  (multi-cursor-manual-test--ensure-split)
  (condition-case error-data
      (window-resize nil 5 t)
    (user-error (message "%s" (error-message-string error-data))))
  (multi-cursor-manual-test--redisplay))

(defun multi-cursor-manual-test-shrink-window ()
  "Shrink the selected fixture window horizontally."
  (interactive)
  (multi-cursor-manual-test--ensure-split)
  (condition-case error-data
      (window-resize nil -5 t)
    (user-error (message "%s" (error-message-string error-data))))
  (multi-cursor-manual-test--redisplay))

(defun multi-cursor-manual-test-other-window ()
  "Select another fixture window, creating a split first if necessary."
  (interactive)
  (multi-cursor-manual-test--ensure-split)
  (other-window 1)
  (multi-cursor-manual-test--redisplay))

(defun multi-cursor-manual-test-refresh ()
  "Force a complete redisplay of the fixture."
  (interactive)
  (multi-cursor-manual-test--redisplay))

(defun multi-cursor-manual-test-quit ()
  "Remove the fixture's secondary cursors and kill its buffer."
  (interactive)
  (multi-cursor-remove-all)
  (kill-buffer (current-buffer)))

(defun multi-cursor-manual-test-setup-one ()
  "Reset the painter fixture with one secondary cursor."
  (interactive)
  (multi-cursor-manual-test-setup 1))

(defun multi-cursor-manual-test-setup-three ()
  "Reset the painter fixture with three secondary cursors."
  (interactive)
  (multi-cursor-manual-test-setup 3))

(defun multi-cursor-manual-test-setup-thirty ()
  "Reset the painter fixture with thirty secondary cursors."
  (interactive)
  (multi-cursor-manual-test-setup 30))

(defun multi-cursor-manual-test-setup-three-hundred ()
  "Reset the painter fixture with three hundred secondary cursors."
  (interactive)
  (multi-cursor-manual-test-setup 300))

(defun multi-cursor-manual-test-setup (&optional count)
  "Create and display a manual fixture with COUNT secondary cursors.

Interactively, a prefix argument supplies COUNT; the default is 300."
  (interactive "P")
  (setq count (if count (prefix-numeric-value count) 300))
  (unless (and (integerp count) (> count 0)
               (or (null multi-cursor-max-cursors)
                   (< count multi-cursor-max-cursors)))
    (user-error "COUNT exceeds the configured multiple-cursor limit"))
  (let ((buffer (get-buffer-create multi-cursor-manual-test--buffer-name))
        positions)
    (with-current-buffer buffer
      (when multi-cursor-mode
        (multi-cursor-remove-all))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (text-mode)
        (insert
         "Native multiple-cursor Mac painter stress fixture\n"
         "=================================================\n\n"
         "Expected: secondary cursors paint in one native batch, never blink,\n"
         "and leave no trails.  The primary cursor remains the sole blinking\n"
         "caret.  Check box, hollow, bar, and hbar shapes and inactive colors.\n\n"
         "Keys:\n"
         "  b       cycle cursor shape\n"
         "  SPC/DEL scroll forward/backward\n"
         "  >/<     enlarge/shrink the selected split horizontally\n"
         "  o       split if needed, then switch selected window\n"
         "  g       force a complete redisplay\n"
         "  s       run the next deterministic screenshot step\n"
         "  a       run all remaining steps (hooks can capture each)\n"
         "  d       display machine-readable state and pixel masks\n"
         "  1/3/0/9 reset with 1, 3, 30, or 300 secondary cursors\n"
         "  q       remove cursors and kill this fixture\n\n"
         "Also drag the frame edges repeatedly, switch focus to another app,\n"
         "return to Emacs, and alternate `o' between split windows.  Cursor\n"
         "pixels must remain clipped to the text area with no stale remnants.\n\n")
        (let* ((contrast-start (point))
               (cursor-color (or (frame-parameter nil 'cursor-color) "red")))
          (insert "CONTRAST  glyph text must remain visible inside this box.\n")
          (add-text-properties
           contrast-start (line-end-position)
           `(face (:background ,cursor-color :foreground "yellow")))
          (push (+ contrast-start 10) positions))
        (dotimes (line (+ count 200))
          (let ((start (point)))
            (when (= line 0)
              (setq multi-cursor-manual-test--data-start
                    (copy-marker start)))
            (insert (format "%04d  The quick brown fox jumps over row %04d.\n"
                            line line))
            (when (< line (1- count))
              (push (+ start 7) positions)))))
      (goto-char (point-min))
      (setq-local cursor-type 'box)
      (setq multi-cursor-manual-test--cursor-type-index 0)
      (setq multi-cursor-manual-test--initial-positions
            (copy-sequence (nreverse positions))
            multi-cursor-manual-test--step-index 0
            multi-cursor-manual-test--state-sequence 0
            multi-cursor-manual-test--state-log nil)
      (multi-cursor-manual-test-mode 1)
      (dolist (position multi-cursor-manual-test--initial-positions)
        (multi-cursor-add-selection position)))
    (pop-to-buffer buffer)
    (multi-cursor-manual-test--redisplay)
    (multi-cursor-manual-test--mac-counters t)
    (let ((state (multi-cursor-manual-test-state 'setup)))
      (run-hook-with-args
       'multi-cursor-manual-test-after-step-hook 'setup state))
    (message "Created %d secondary cursors; press s for deterministic steps"
             count)
    buffer))

(dolist (command '(multi-cursor-manual-test-toggle-cursor-type
                   multi-cursor-manual-test-enlarge-window
                   multi-cursor-manual-test-shrink-window
                   multi-cursor-manual-test-other-window
                   multi-cursor-manual-test-refresh
                   multi-cursor-manual-test-step
                   multi-cursor-manual-test-run-scenario
                   multi-cursor-manual-test-display-state
                   multi-cursor-manual-test-setup-one
                   multi-cursor-manual-test-setup-three
                   multi-cursor-manual-test-setup-thirty
                   multi-cursor-manual-test-setup-three-hundred
                   multi-cursor-manual-test-quit))
  (multi-cursor-register-command command 'run-once))

(provide 'multi-cursor-manual-tests)

;;; multi-cursor-tests.el ends here

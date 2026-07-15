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
;; The fixture creates 300 secondary cursors in a long buffer.  Its banner
;; describes the visual checks and keys for changing cursor shape, scrolling,
;; resizing split windows, and switching the selected window.  Also resize the
;; frame and move focus to another application to check scale, clipping, and
;; inactive-frame cursor colors.  No secondary cursor should leave stale
;; pixels; the ordinary primary cursor should remain the only blinking caret.
;; The first secondary box sits on text whose background equals the configured
;; cursor color; its glyph must remain legible inside the filled box.

;;; Code:

(require 'multi-cursor)

(defconst multi-cursor-manual-test--buffer-name
  "*Native Multiple Cursor Manual Test*"
  "Buffer used by the native multiple-cursor manual fixture.")

(defconst multi-cursor-manual-test--cursor-types
  '(box hollow bar (bar . 3) hbar (hbar . 3))
  "Cursor shapes cycled by `multi-cursor-manual-test-toggle-cursor-type'.")

(defvar-local multi-cursor-manual-test--cursor-type-index 0
  "Index of the cursor shape currently shown by the manual fixture.")

(defvar-keymap multi-cursor-manual-test-mode-map
  :doc "Keymap for the native multiple-cursor manual fixture."
  "b" #'multi-cursor-manual-test-toggle-cursor-type
  "SPC" #'scroll-up-command
  "DEL" #'scroll-down-command
  ">" #'multi-cursor-manual-test-enlarge-window
  "<" #'multi-cursor-manual-test-shrink-window
  "o" #'multi-cursor-manual-test-other-window
  "g" #'multi-cursor-manual-test-refresh
  "q" #'multi-cursor-manual-test-quit)

(define-minor-mode multi-cursor-manual-test-mode
  "Provide keys for the native multiple-cursor manual fixture."
  :lighter " MC-Test"
  :keymap multi-cursor-manual-test-mode-map)

(defun multi-cursor-manual-test--redisplay ()
  "Force redisplay of the manual fixture's visible windows."
  (force-window-update (current-buffer))
  (redisplay 'force))

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
            (insert (format "%04d  The quick brown fox jumps over row %04d.\n"
                            line line))
            (when (< line (1- count))
              (push (+ start 7) positions)))))
      (goto-char (point-min))
      (setq-local cursor-type 'box)
      (setq multi-cursor-manual-test--cursor-type-index 0)
      (multi-cursor-manual-test-mode 1)
      (dolist (position (nreverse positions))
        (multi-cursor-add-selection position)))
    (pop-to-buffer buffer)
    (multi-cursor-manual-test--redisplay)
    (message "Created %d secondary cursors; press b, SPC, DEL, >, <, o, or g"
             count)))

(dolist (command '(multi-cursor-manual-test-toggle-cursor-type
                   multi-cursor-manual-test-enlarge-window
                   multi-cursor-manual-test-shrink-window
                   multi-cursor-manual-test-other-window
                   multi-cursor-manual-test-refresh
                   multi-cursor-manual-test-quit))
  (multi-cursor-register-command command 'run-once))

(provide 'multi-cursor-manual-tests)

;;; multi-cursor-tests.el ends here

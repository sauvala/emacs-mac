;;; multi-cursor-tests.el --- Tests for multi-cursor.el  -*- lexical-binding: t; -*-

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

;;; Code:

(require 'ert)
(require 'ert-x)
(require 'cl-lib)
(require 'multi-cursor)

(defun multi-cursor-tests--cursor (id)
  "Return the internal test cursor whose stable identifier is ID."
  (cl-find id multi-cursor--cursors
           :key #'multi-cursor--cursor-id))

(defvar multi-cursor-tests--command-log nil)

(defun multi-cursor-tests--run-once ()
  "Record one ordinary interactive invocation for policy tests."
  (interactive)
  (push (list (point) current-prefix-arg this-command real-this-command
              last-command-event last-command)
        multi-cursor-tests--command-log))

(defun multi-cursor-tests--edit ()
  "Perform an edit which must be blocked when it has no safe policy."
  (interactive)
  (insert "changed"))

(defun multi-cursor-tests--error ()
  "Signal an error for command-loop policy tests."
  (interactive)
  (error "policy test error"))

(defun multi-cursor-tests--quit ()
  "Signal quit for command-loop policy tests."
  (interactive)
  (signal 'quit nil))

(defun multi-cursor-tests--movement-maybe-error (&optional arg)
  "Move by ARG unless point is 5, where a test error is signaled."
  (interactive "p")
  (when (= (point) 5)
    (error "movement test error"))
  (goto-char (+ (point) (or arg 1))))

(defun multi-cursor-tests--movement-maybe-quit (&optional arg)
  "Move by ARG unless point is 5, where quit is signaled."
  (interactive "p")
  (when (= (point) 5)
    (signal 'quit nil))
  (goto-char (+ (point) (or arg 1))))

(defun multi-cursor-tests--ordinary-movement-destination (command position)
  "Return where ordinary COMMAND moves from POSITION in the current buffer."
  (save-excursion
    (goto-char position)
    (funcall command 1)
    (point)))

(defun multi-cursor-tests--handler
    (command prefix keys record-flag special)
  "Record dispatcher arguments for COMMAND."
  (push (list command prefix keys record-flag special
              this-command real-this-command last-command-event)
        multi-cursor-tests--command-log))

(defmacro multi-cursor-tests--with-policy (command policy handler &rest body)
  "Register COMMAND with POLICY and HANDLER while running BODY."
  (declare (indent 3) (debug t))
  (let ((saved (make-symbol "saved"))
        (missing (make-symbol "missing"))
        (cmd (make-symbol "command")))
    `(let* ((,cmd ,command)
            (,missing (make-symbol "missing-policy"))
            (,saved (gethash ,cmd multi-cursor--command-policies ,missing)))
       (unwind-protect
           (progn
             (multi-cursor-register-command ,cmd ,policy ,handler)
             ,@body)
         (if (eq ,saved ,missing)
             (remhash ,cmd multi-cursor--command-policies)
           (puthash ,cmd ,saved multi-cursor--command-policies))))))

(ert-deftest multi-cursor-lifecycle-enable-creates-local-session ()
  (with-temp-buffer
    (multi-cursor-mode 1)
    (should multi-cursor-mode)
    (should (local-variable-p 'multi-cursor--cursors))
    (should (local-variable-p 'multi-cursor--next-id))
    (should-not multi-cursor--cursors)
    (should (= multi-cursor--next-id 0))))

(ert-deftest multi-cursor-lifecycle-repeated-enable-preserves-session ()
  (with-temp-buffer
    (insert "alpha beta")
    (multi-cursor-mode 1)
    (let ((cursor (multi-cursor--add-cursor 7 nil nil)))
      (multi-cursor-mode 1)
      (should multi-cursor-mode)
      (should (eq (car multi-cursor--cursors) cursor))
      (should (= multi-cursor--next-id 1)))))

(ert-deftest multi-cursor-lifecycle-markers-track-edits ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (multi-cursor-mode 1)
    (multi-cursor--add-cursor 7 nil nil)
    (goto-char 1)
    (insert "X")
    (should (= (marker-position
                (multi-cursor--cursor-point
                 (car multi-cursor--cursors)))
               8))))

(ert-deftest multi-cursor-lifecycle-markers-have-before-insertion-gravity ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (multi-cursor-mode 1)
    (let ((cursor (multi-cursor--add-cursor 7 3 t)))
      (save-excursion
        (goto-char 7)
        (insert "X"))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 7))
      (save-excursion
        (goto-char 3)
        (insert "Y"))
      (should (= (marker-position (multi-cursor--cursor-mark cursor)) 3)))))

(ert-deftest multi-cursor-lifecycle-disable-releases-state ()
  (with-temp-buffer
    (insert "alpha beta")
    (multi-cursor-mode 1)
    (let* ((cursor (multi-cursor--add-cursor 7 2 t))
           (point-marker (multi-cursor--cursor-point cursor))
           (mark-marker (multi-cursor--cursor-mark cursor)))
      (multi-cursor-mode -1)
      (should-not multi-cursor-mode)
      (should-not multi-cursor--cursors)
      (should (= multi-cursor--next-id 0))
      (should-not (marker-buffer point-marker))
      (should-not (marker-buffer mark-marker))
      (should-not (memq #'multi-cursor--end-session kill-buffer-hook))
      (should-not (memq #'multi-cursor--end-session before-revert-hook))
      (should-not (memq #'multi-cursor--end-session
                        change-major-mode-hook)))))

(ert-deftest multi-cursor-lifecycle-cleanup-is-idempotent ()
  (with-temp-buffer
    (insert "alpha beta")
    (multi-cursor-mode 1)
    (multi-cursor--add-cursor 7 2 t)
    (multi-cursor-mode -1)
    (multi-cursor-mode -1)
    (multi-cursor--clear)
    (should-not multi-cursor-mode)
    (should-not multi-cursor--cursors)
    (should (= multi-cursor--next-id 0))))

(ert-deftest multi-cursor-lifecycle-normalizes-duplicates ()
  (with-temp-buffer
    (insert "alpha beta")
    (multi-cursor-mode 1)
    (let* ((first (multi-cursor--add-cursor 7 2 t))
           (point-marker (multi-cursor--cursor-point first))
           (mark-marker (multi-cursor--cursor-mark first))
           (second (multi-cursor--add-cursor 7 2 t)))
      (should (= (length multi-cursor--cursors) 1))
      (should (eq first second))
      (should (= (multi-cursor--cursor-id (car multi-cursor--cursors)) 1))
      (should (= multi-cursor--next-id 1))
      (should (eq (marker-buffer point-marker) (current-buffer)))
      (should (eq (marker-buffer mark-marker) (current-buffer))))))

(ert-deftest multi-cursor-lifecycle-normalization-releases-moved-duplicate ()
  (with-temp-buffer
    (insert "alpha beta")
    (multi-cursor-mode 1)
    (let* ((oldest (multi-cursor--add-cursor 7 2 t))
           (newer (multi-cursor--add-cursor 8 3 t))
           (newer-point (multi-cursor--cursor-point newer))
           (newer-mark (multi-cursor--cursor-mark newer)))
      (set-marker newer-point 7)
      (set-marker newer-mark 2)
      (multi-cursor--normalize)
      (should (equal multi-cursor--cursors (list oldest)))
      (should-not (marker-buffer newer-point))
      (should-not (marker-buffer newer-mark)))))

(ert-deftest multi-cursor-lifecycle-retains-distinct-selection-state ()
  (with-temp-buffer
    (insert "alpha beta")
    (multi-cursor-mode 1)
    (multi-cursor--add-cursor 7 2 nil)
    (multi-cursor--add-cursor 7 2 t)
    (should (= (length multi-cursor--cursors) 2))))

(ert-deftest multi-cursor-lifecycle-state-is-buffer-local ()
  (let ((other (generate-new-buffer " *multi-cursor-other*")))
    (unwind-protect
        (with-temp-buffer
          (insert "one")
          (multi-cursor-mode 1)
          (multi-cursor--add-cursor 2 nil nil)
          (with-current-buffer other
            (should-not multi-cursor-mode)
            (should-not multi-cursor--cursors)
            (should-not (local-variable-p 'multi-cursor--cursors))))
      (kill-buffer other))))

(ert-deftest multi-cursor-lifecycle-buffer-events-end-session ()
  (dolist (event '(major-mode-change revert))
    (with-temp-buffer
      (insert "alpha beta")
      (multi-cursor-mode 1)
      (let* ((cursor (multi-cursor--add-cursor 7 2 t))
             (point-marker (multi-cursor--cursor-point cursor))
             (mark-marker (multi-cursor--cursor-mark cursor)))
        (pcase event
          ('major-mode-change (fundamental-mode))
          ('revert (run-hooks 'before-revert-hook)))
        (should-not multi-cursor-mode)
        (should-not multi-cursor--cursors)
        (should-not (marker-buffer point-marker))
        (should-not (marker-buffer mark-marker))))))

(ert-deftest multi-cursor-lifecycle-kill-buffer-releases-markers ()
  (let ((buffer (generate-new-buffer " *multi-cursor-kill*"))
        point-marker mark-marker)
    (with-current-buffer buffer
      (insert "alpha beta")
      (multi-cursor-mode 1)
      (let ((cursor (multi-cursor--add-cursor 7 2 t)))
        (setq point-marker (multi-cursor--cursor-point cursor)
              mark-marker (multi-cursor--cursor-mark cursor))))
    (kill-buffer buffer)
    (should-not (marker-buffer point-marker))
    (should-not (marker-buffer mark-marker))))

(ert-deftest multi-cursor-lifecycle-external-mode-conflict-is-nondestructive ()
  (with-temp-buffer
    (setq-local multiple-cursors-mode t)
    (should-error (multi-cursor-mode 1) :type 'user-error)
    (should multiple-cursors-mode)
    (should-not multi-cursor-mode)
    (should-not multi-cursor--cursors)
    (should-not (memq #'multi-cursor--end-session kill-buffer-hook))
    (should-not (memq #'multi-cursor--end-session before-revert-hook))
    (should-not (memq #'multi-cursor--end-session
                      change-major-mode-hook))))

(ert-deftest multi-cursor-lifecycle-inactive-external-mode-is-allowed ()
  (with-temp-buffer
    (setq-local multiple-cursors-mode nil)
    (multi-cursor-mode 1)
    (should multi-cursor-mode)
    (should (memq #'multi-cursor--end-session kill-buffer-hook))))

(ert-deftest multi-cursor-api-add-selection-preserves-orientation-and-state ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (let* ((forward-id (multi-cursor-add-selection 8 3 t))
           (backward-id (multi-cursor-add-selection 2 6 nil))
           (forward (multi-cursor-tests--cursor forward-id))
           (backward (multi-cursor-tests--cursor backward-id)))
      (should multi-cursor-mode)
      (should (eq (multi-cursor--cursor-direction forward) 'forward))
      (should (multi-cursor--cursor-mark-active forward))
      (should (eq (multi-cursor--cursor-direction backward) 'backward))
      (should-not (multi-cursor--cursor-mark-active backward))
      (should (= (marker-position (multi-cursor--cursor-point forward)) 8))
      (should (= (marker-position (multi-cursor--cursor-mark forward)) 3)))))

(ert-deftest multi-cursor-api-add-selection-returns-stable-id ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (let ((id (multi-cursor-add-selection 7 2 t)))
      (should (integerp id))
      (should (= id (multi-cursor-add-selection 7 2 t)))
      (should (= multi-cursor--next-id 1)))))

(ert-deftest multi-cursor-api-point-local-add-and-remove ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (let* ((first (multi-cursor-tests--cursor
                   (multi-cursor-add-at-point 7)))
           (second (multi-cursor-tests--cursor
                    (multi-cursor-add-selection 7 3 t)))
           (first-marker (multi-cursor--cursor-point first))
           (second-marker (multi-cursor--cursor-point second)))
      (should-error (multi-cursor-add-at-point) :type 'user-error)
      (should (= (multi-cursor-remove-at-point 7) 2))
      (should-not multi-cursor-mode)
      (should-not (marker-buffer first-marker))
      (should-not (marker-buffer second-marker))
      (should (= (multi-cursor-remove-at-point 7) 0)))))

(ert-deftest multi-cursor-api-remove-all-releases-session ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (let* ((cursor (multi-cursor-tests--cursor
                    (multi-cursor-add-selection 8 3 t)))
           (point-marker (multi-cursor--cursor-point cursor))
           (mark-marker (multi-cursor--cursor-mark cursor)))
      (should (= (multi-cursor-remove-all) 1))
      (should-not multi-cursor-mode)
      (should-not multi-cursor--cursors)
      (should-not (marker-buffer point-marker))
      (should-not (marker-buffer mark-marker)))))

(ert-deftest multi-cursor-api-selections-are-detached-integer-snapshots ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (multi-cursor-add-selection 8 3 t)
    (let* ((snapshot (car (multi-cursor-selections)))
           (id (plist-get snapshot :id)))
      (should (equal snapshot
                     `(:id ,id :point 8 :mark 3
                       :mark-active t :direction forward)))
      (should-not (cl-find-if #'markerp snapshot))
      (setf (plist-get snapshot :point) 15)
      (should (= (plist-get (car (multi-cursor-selections)) :point) 8)))))

(ert-deftest multi-cursor-api-selections-query-does-not-normalize-state ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (let* ((first (multi-cursor-tests--cursor
                   (multi-cursor-add-at-point 7)))
           (second (multi-cursor-tests--cursor
                    (multi-cursor-add-at-point 8)))
           (second-marker (multi-cursor--cursor-point second)))
      (set-marker second-marker 7)
      (should (= (length (multi-cursor-selections)) 2))
      (should (= (multi-cursor-count) 3))
      (should (marker-buffer (multi-cursor--cursor-point first)))
      (should (marker-buffer second-marker)))))

(ert-deftest multi-cursor-api-count-includes-primary ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (should (= (multi-cursor-count) 1))
    (multi-cursor-add-at-point 4)
    (multi-cursor-add-at-point 8)
    (should (= (multi-cursor-count) 3))))

(ert-deftest multi-cursor-api-default-ceiling-is-bounded ()
  (should (= multi-cursor-max-cursors 1000)))

(ert-deftest multi-cursor-api-invalid-input-does-not-mutate-session ()
  (let ((other (generate-new-buffer " *multi-cursor-validation*")))
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta")
          (goto-char 1)
          (let ((foreign (with-current-buffer other
                           (insert "other")
                           (copy-marker 2)))
                (detached (make-marker)))
            (dolist (arguments `((0 nil nil)
                                 (,(1+ (point-max)) nil nil)
                                 (1.5 nil nil)
                                 (,foreign nil nil)
                                 (7 ,foreign t)
                                 (,detached nil nil)))
              (should-error (apply #'multi-cursor-add-selection arguments)
                            :type 'user-error)
              (should-not multi-cursor-mode)
              (should-not multi-cursor--cursors)
              (should (= multi-cursor--next-id 0)))
            (should-error (multi-cursor-add-at-point 0) :type 'user-error)
            (should-error (multi-cursor-remove-at-point 0) :type 'user-error)))
      (kill-buffer other))))

(ert-deftest multi-cursor-api-active-selection-requires-mark ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (should-error (multi-cursor-add-selection 7 nil t) :type 'user-error)
    (should-not multi-cursor-mode)
    (should-not multi-cursor--cursors)))

(ert-deftest multi-cursor-api-invalid-ceiling-does-not-mutate-session ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (dolist (limit '(0 -1 invalid))
      (let ((multi-cursor-max-cursors limit))
        (should-error (multi-cursor-add-at-point 7) :type 'user-error)
        (should-not multi-cursor-mode)
        (should-not multi-cursor--cursors)))))

(ert-deftest multi-cursor-api-ceiling-is-validated-before-mutation ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (let ((multi-cursor-max-cursors 2))
      (let ((id (multi-cursor-add-selection 8 3 t)))
        (should (= (multi-cursor-add-selection 8 3 t) id))
        (should-error (multi-cursor-add-at-point 12) :type 'user-error)
        (should (= (multi-cursor-count) 2))
        (should (= multi-cursor--next-id 1))))))

(ert-deftest multi-cursor-api-primary-cursor-is-never-stored ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 7)
    (should-error (multi-cursor-add-selection 7 2 t) :type 'user-error)
    (should-error (multi-cursor-add-at-point) :type 'user-error)
    (should-not multi-cursor-mode)
    (should-not multi-cursor--cursors)
    (should (= multi-cursor--next-id 0))))

(ert-deftest multi-cursor-api-normalization-removes-primary-collision ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (let* ((cursor (multi-cursor-tests--cursor
                    (multi-cursor-add-selection 7 2 t)))
           (point-marker (multi-cursor--cursor-point cursor))
           (mark-marker (multi-cursor--cursor-mark cursor)))
      (goto-char 7)
      (should-not (multi-cursor--normalized-cursors))
      (should-not (marker-buffer point-marker))
      (should-not (marker-buffer mark-marker)))))

(ert-deftest multi-cursor-api-normalization-sorts-and-retains-overlaps ()
  (with-temp-buffer
    (insert "abcdefghijklmnop")
    (goto-char 1)
    (let* ((later-id (multi-cursor-add-selection 10 5 t))
           (overlap-id (multi-cursor-add-selection 8 3 t))
           (earlier-id (multi-cursor-add-selection 4 2 t)))
      (should (equal (mapcar (lambda (cursor)
                               (marker-position
                                (multi-cursor--cursor-point cursor)))
                             (multi-cursor--normalized-cursors))
                     '(4 8 10)))
      (should (multi-cursor-tests--cursor later-id))
      (should (multi-cursor-tests--cursor overlap-id))
      (should (multi-cursor-tests--cursor earlier-id))
      (should (= (length multi-cursor--cursors) 3)))))

(ert-deftest multi-cursor-creation-add-above-and-below-preserve-column ()
  (with-temp-buffer
    (insert "abcde\nxy\n12345\n")
    (goto-char (point-min))
    (forward-line 1)
    (move-to-column 1)
    (let* ((primary (point))
           (above (save-excursion
                    (forward-line -1)
                    (move-to-column 1)
                    (point)))
           (below (save-excursion
                    (forward-line 1)
                    (move-to-column 1)
                    (point))))
      (multi-cursor-add-above)
      (multi-cursor-add-below)
      (should (= (point) primary))
      (should (equal (mapcar (lambda (selection)
                               (plist-get selection :point))
                             (multi-cursor-selections))
                     (list above below))))))

(ert-deftest multi-cursor-creation-add-line-boundary-signals-first ()
  (with-temp-buffer
    (insert "one\ntwo")
    (goto-char (point-min))
    (should-error (multi-cursor-add-above) :type 'user-error)
    (should-not multi-cursor-mode)
    (goto-char (point-max))
    (should-error (multi-cursor-add-below) :type 'user-error)
    (should-not multi-cursor-mode)))

(ert-deftest multi-cursor-creation-line-target-inside-tab-does-not-edit ()
  (with-temp-buffer
    (insert "abcdef\n\tz\n")
    (goto-char (point-min))
    (move-to-column 3)
    (let ((before (buffer-string)))
      (multi-cursor-add-below)
      (should (equal (buffer-string) before))
      (let* ((id (plist-get (car (multi-cursor-selections)) :id))
             (cursor (multi-cursor-tests--cursor id)))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 8))
        (should (= (multi-cursor--cursor-goal-column cursor) 3))))))

(ert-deftest multi-cursor-creation-edit-lines-short-line-policies ()
  (dolist (policy '(eol skip pad))
    (with-temp-buffer
      (insert "abcd\nx\nwxyz\n")
      (goto-char (point-min))
      (move-to-column 3)
      (let ((primary (point))
            (last-line (save-excursion
                         (forward-line 2)
                         (move-to-column 3)
                         (point))))
        (set-mark (save-excursion (forward-line 2) (point)))
        (activate-mark)
        (let ((multi-cursor-edit-lines-short-lines policy))
          (multi-cursor-edit-lines))
        (should (= (point) primary))
        (should-not mark-active)
        (pcase policy
          ('eol
           (should (equal
                    (mapcar (lambda (selection)
                              (plist-get selection :point))
                            (multi-cursor-selections))
                    (list (save-excursion
                            (goto-char (point-min))
                            (forward-line 1)
                            (line-end-position))
                          last-line))))
          ('skip
           (should (equal
                    (mapcar (lambda (selection)
                              (plist-get selection :point))
                            (multi-cursor-selections))
                    (list last-line))))
          ('pad
           (should (equal (buffer-string) "abcd\nx  \nwxyz\n"))
           (should (= (length (multi-cursor-selections)) 2))
           (dolist (selection (multi-cursor-selections))
             (save-excursion
               (goto-char (plist-get selection :point))
               (should (= (current-column) 3))))))))))

(ert-deftest multi-cursor-creation-edit-lines-error-is-atomic ()
  (with-temp-buffer
    (insert "abcd\nx\nwxyz\n")
    (goto-char (point-min))
    (move-to-column 3)
    (set-mark (save-excursion (forward-line 2) (point)))
    (activate-mark)
    (let ((before (buffer-string))
          (multi-cursor-edit-lines-short-lines 'error))
      (should-error (multi-cursor-edit-lines) :type 'user-error)
      (should (equal (buffer-string) before))
      (should mark-active)
      (should-not multi-cursor-mode))))

(ert-deftest multi-cursor-creation-edit-lines-ceiling-is-atomic ()
  (with-temp-buffer
    (insert "abcd\nx\nwxyz\n")
    (goto-char (point-min))
    (move-to-column 3)
    (set-mark (save-excursion (forward-line 2) (point)))
    (activate-mark)
    (let ((before (buffer-string))
          (multi-cursor-edit-lines-short-lines 'pad)
          (multi-cursor-max-cursors 2))
      (should-error (multi-cursor-edit-lines) :type 'user-error)
      (should (equal (buffer-string) before))
      (should mark-active)
      (should-not multi-cursor-mode))))

(ert-deftest multi-cursor-creation-edit-lines-read-only-pad-is-atomic ()
  (with-temp-buffer
    (insert "abcd\nx\ny\n")
    (goto-char (point-min))
    (move-to-column 3)
    (set-mark (save-excursion (forward-line 2) (point)))
    (activate-mark)
    (put-text-property 8 9 'read-only t)
    (let ((before (buffer-string))
          (multi-cursor-edit-lines-short-lines 'pad))
      (should-error (multi-cursor-edit-lines))
      (should (equal (buffer-string) before))
      (should mark-active)
      (should-not multi-cursor-mode))))

(ert-deftest multi-cursor-creation-edit-lines-reuses-at-ceiling ()
  (with-temp-buffer
    (insert "abcd\nx\nwxyz\n")
    (goto-char (point-min))
    (move-to-column 3)
    (set-mark (save-excursion (forward-line 2) (point)))
    (activate-mark)
    (let ((multi-cursor-max-cursors 3))
      (multi-cursor-edit-lines)
      (activate-mark)
      (should (= (length (multi-cursor-edit-lines)) 2))
      (should (= (multi-cursor-count) 3)))))

(ert-deftest multi-cursor-creation-occurrence-next-skips-and-does-not-wrap ()
  (with-temp-buffer
    (insert "foo x foo y foo")
    (goto-char 4)
    (set-mark 1)
    (activate-mark)
    (multi-cursor-select-next-occurrence)
    (multi-cursor-select-next-occurrence)
    (let ((before (multi-cursor-selections)))
      (should-error (multi-cursor-select-next-occurrence) :type 'user-error)
      (should (equal (multi-cursor-selections) before)))
    (should (equal
             (mapcar (lambda (selection)
                       (cons (plist-get selection :mark)
                             (plist-get selection :point)))
                     (multi-cursor-selections))
             '((7 . 10) (13 . 16))))))

(ert-deftest multi-cursor-creation-occurrence-previous-skips-and-does-not-wrap ()
  (with-temp-buffer
    (insert "foo x foo y foo")
    (goto-char 16)
    (set-mark 13)
    (activate-mark)
    (multi-cursor-select-previous-occurrence)
    (multi-cursor-select-previous-occurrence)
    (should-error (multi-cursor-select-previous-occurrence) :type 'user-error)
    (should (equal
             (mapcar (lambda (selection)
                       (cons (plist-get selection :mark)
                             (plist-get selection :point)))
                     (multi-cursor-selections))
             '((1 . 4) (7 . 10))))))

(ert-deftest multi-cursor-creation-occurrence-all-honors-case-and-narrowing ()
  (with-temp-buffer
    (insert "foo FOO foo OUT foo")
    (narrow-to-region 1 12)
    (goto-char 4)
    (set-mark 1)
    (activate-mark)
    (let ((case-fold-search t))
      (multi-cursor-select-all-occurrences))
    (should (equal
             (mapcar (lambda (selection)
                       (cons (plist-get selection :mark)
                             (plist-get selection :point)))
                     (multi-cursor-selections))
             '((5 . 8) (9 . 12)))))
  (with-temp-buffer
    (insert "foo FOO foo")
    (goto-char 4)
    (set-mark 1)
    (activate-mark)
    (let ((case-fold-search nil))
      (multi-cursor-select-all-occurrences))
    (should (equal
             (mapcar (lambda (selection)
                       (plist-get selection :point))
                     (multi-cursor-selections))
             '(12)))))

(ert-deftest multi-cursor-creation-occurrence-all-bulk-creates ()
  (with-temp-buffer
    (insert (mapconcat #'identity (make-list 300 "foo") " "))
    (goto-char 4)
    (set-mark 1)
    (activate-mark)
    (multi-cursor-select-all-occurrences)
    (should (= (multi-cursor-count) 300))))

(ert-deftest multi-cursor-creation-occurrence-symbol-fallback-is-atomic ()
  (with-temp-buffer
    (insert "foo foo")
    (goto-char 2)
    (multi-cursor-select-next-occurrence)
    (should mark-active)
    (should (= (region-beginning) 1))
    (should (= (region-end) 4))
    (should (equal
             (mapcar (lambda (selection)
                       (cons (plist-get selection :mark)
                             (plist-get selection :point)))
                     (multi-cursor-selections))
             '((5 . 8)))))
  (with-temp-buffer
    (insert "foo")
    (goto-char 2)
    (should-error (multi-cursor-select-next-occurrence) :type 'user-error)
    (should (= (point) 2))
    (should-not mark-active)
    (should-not multi-cursor-mode))
  (with-temp-buffer
    (insert "   ")
    (goto-char 2)
    (should-error (multi-cursor-select-all-occurrences) :type 'user-error)
    (should-not multi-cursor-mode)))

(ert-deftest multi-cursor-creation-occurrence-empty-region-signals ()
  (with-temp-buffer
    (insert "foo")
    (goto-char 2)
    (set-mark 2)
    (setq mark-active t
          use-empty-active-region t)
    (should-error (multi-cursor-select-all-occurrences) :type 'user-error)
    (should-not multi-cursor-mode)))

(ert-deftest multi-cursor-creation-mouse-is-opt-in-and-validates-event ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((event (list 'mouse-1
                         (list (selected-window) 7 '(0 . 0) 0))))
        (should (integerp (multi-cursor-add-at-mouse event)))))
    (should-error (multi-cursor-add-at-mouse 'not-an-event)
                  :type 'user-error)
    (should-error (multi-cursor-add-at-mouse 'left)
                  :type 'user-error)
    (should-not (where-is-internal 'multi-cursor-add-at-mouse global-map))))

(ert-deftest multi-cursor-creation-mouse-rejects-window-area ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((event (list 'mouse-1
                         (list (selected-window) 'mode-line
                               '(0 . 0) 0 nil 7))))
        (should-error (multi-cursor-add-at-mouse event) :type 'user-error)))
    (should-not multi-cursor-mode)))

(ert-deftest multi-cursor-creation-mouse-rejects-another-buffer ()
  (let ((other (generate-new-buffer " *multi-cursor-mouse-other*")))
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta")
          (goto-char 1)
          (let ((buffer (current-buffer)))
            (save-window-excursion
              (switch-to-buffer other)
              (with-current-buffer other (insert "other buffer"))
              (let ((event (list 'mouse-1
                                 (list (selected-window) 2 '(0 . 0) 0))))
                (with-current-buffer buffer
                  (should-error (multi-cursor-add-at-mouse event)
                                :type 'user-error)))))
          (should-not multi-cursor-mode))
      (kill-buffer other))))

(ert-deftest multi-cursor-creation-cycle-exchanges-primary-state ()
  (with-temp-buffer
    (insert "abcdefghijkl")
    (goto-char 1)
    (multi-cursor-add-selection 5 7 t)
    (multi-cursor-add-at-point 9)
    (let (last-message)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq last-message (apply #'format format-string args)))))
        (multi-cursor-cycle-forward))
      (should (equal last-message "Cursor 2 of 3")))
    (should (= (point) 5))
    (should (= (mark) 7))
    (should mark-active)
    (should (= (multi-cursor-count) 3))
    (should (member 1 (mapcar (lambda (selection)
                                (plist-get selection :point))
                              (multi-cursor-selections))))
    (let (last-message)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq last-message (apply #'format format-string args)))))
        (multi-cursor-cycle-backward))
      (should (equal last-message "Cursor 1 of 3")))
    (should (= (point) 1))
    (should-not mark-active)))

(ert-deftest multi-cursor-creation-cycle-wraps-without-mark-ring-side-effects ()
  (with-temp-buffer
    (insert "abcdefghijkl")
    (goto-char 12)
    (set-mark 10)
    (activate-mark)
    (let* ((id (multi-cursor-add-selection 4 6 t))
           (cursor (multi-cursor-tests--cursor id))
           (old-mark-ring (copy-sequence mark-ring))
           (window (selected-window)))
      (setf (multi-cursor--cursor-last-yank cursor) '(stale))
      (let ((inhibit-message t))
        (multi-cursor-cycle-forward))
      (should (= (point) 4))
      (should (= (mark) 6))
      (should mark-active)
      (should (eq (selected-window) window))
      (should (equal mark-ring old-mark-ring))
      (should-not (multi-cursor--cursor-last-yank cursor))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 12))
      (should (= (marker-position (multi-cursor--cursor-mark cursor)) 10)))))

(ert-deftest multi-cursor-creation-mode-line-shows-primary-inclusive-count ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (multi-cursor-add-at-point 7)
    (let ((lighter (cadr (assq 'multi-cursor-mode minor-mode-alist))))
      (should (equal (eval (cadr lighter) t) " MC:2")))))

(ert-deftest multi-cursor-creation-narrowing-removes-inaccessible-cursors ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (multi-cursor-add-at-point 4)
    (multi-cursor-add-at-point 12)
    (run-hooks 'pre-command-hook)
    (narrow-to-region 1 8)
    (let (last-message)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq last-message (apply #'format format-string args)))))
        (run-hooks 'post-command-hook))
      (should (equal last-message "Removed 1 inaccessible cursor")))
    (should (= (multi-cursor-count) 2))
    (should (equal (mapcar (lambda (selection)
                             (plist-get selection :point))
                           (multi-cursor-selections))
                   '(4)))))

(ert-deftest multi-cursor-policy-registration-validates-input ()
  (should-error
   (multi-cursor-register-command 'ignore 'unknown) :type 'error)
  (should-error
   (multi-cursor-register-command 'ignore 'batch-edit) :type 'error)
  (should-error
   (multi-cursor-register-command 'ignore 'custom-handler) :type 'error)
  (should-error
   (multi-cursor-register-command 'ignore 'run-once #'ignore) :type 'error)
  (should-error
   (multi-cursor-register-command 'ignore 'unsupported #'ignore) :type 'error))

(ert-deftest multi-cursor-policy-management-command-can-disable-mode ()
  (with-temp-buffer
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (should (eq (car (gethash 'multi-cursor-mode
                              multi-cursor--command-policies))
                'run-once))
    (command-execute 'multi-cursor-mode)
    (should-not multi-cursor-mode)))

(ert-deftest multi-cursor-policy-real-loop-run-once-and-prefixes ()
  (dolist (case '((nil "x") (3 "M-3 x") (- "M-- x")
                  ((4) "C-u x") ((16) "C-u C-u x")))
    (ert-with-test-buffer (:selected t)
      (insert "one two")
      (goto-char 1)
      (multi-cursor-add-at-point 5)
      (let ((multi-cursor-tests--command-log nil)
            (map (make-sparse-keymap)))
        (define-key map "x" #'multi-cursor-tests--run-once)
        (multi-cursor-tests--with-policy
            'multi-cursor-tests--run-once 'run-once nil
          (let ((minor-mode-map-alist
                 (cons (cons t map) minor-mode-map-alist)))
            (ert-play-keys (kbd (cadr case)))))
        (should (= (length multi-cursor-tests--command-log) 1))
        (should (= (caar multi-cursor-tests--command-log) 1))
        (should (equal (cadar multi-cursor-tests--command-log)
                       (car case)))))))

(ert-deftest multi-cursor-policy-real-loop-handler-and-recursion-guard ()
  (ert-with-test-buffer (:selected t)
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (let ((multi-cursor-tests--command-log nil)
          (map (make-sparse-keymap)))
      (define-key map "x" #'multi-cursor-tests--edit)
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--edit 'custom-handler
          #'multi-cursor-tests--handler
        (let ((minor-mode-map-alist
               (cons (cons t map) minor-mode-map-alist)))
          (ert-play-keys (kbd "C-u x"))))
      (should (equal (caar multi-cursor-tests--command-log)
                     'multi-cursor-tests--edit))
      (should (equal (cadar multi-cursor-tests--command-log) '(4)))
      (should (equal (nth 2 (car multi-cursor-tests--command-log))
                     [?x]))
      (should (eq (nth 6 (car multi-cursor-tests--command-log))
                  'multi-cursor-tests--edit))
      (should (eq (nth 7 (car multi-cursor-tests--command-log)) ?x))
      (setq multi-cursor-tests--command-log nil)
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--edit 'custom-handler
          (lambda (&rest _)
            (command-execute 'multi-cursor-tests--run-once))
        (let ((minor-mode-map-alist
               (cons (cons t map) minor-mode-map-alist)))
          (ert-play-keys "x")))
      (should (= (length multi-cursor-tests--command-log) 1)))))

(ert-deftest multi-cursor-policy-direct-forwarding-and-history-contract ()
  (with-temp-buffer
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (let ((multi-cursor-tests--command-log nil)
          (prefix-arg '(4)))
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--edit 'broadcast-movement
          #'multi-cursor-tests--handler
        (command-execute 'multi-cursor-tests--edit t [?z]))
      (let ((entry (car multi-cursor-tests--command-log)))
        (should (equal (nth 1 entry) '(4)))
        (should (equal (nth 2 entry) [?z]))
        (should (eq (nth 3 entry) t))
        (should-not (nth 4 entry))))
    (let ((command-history nil))
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--run-once 'run-once nil
        (command-execute 'multi-cursor-tests--run-once t [?x]))
      (should (equal (car command-history)
                     '(multi-cursor-tests--run-once))))))

(ert-deftest multi-cursor-policy-real-loop-unsupported-is-atomic ()
  (ert-with-test-buffer (:selected t)
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (let ((before (buffer-string)))
      (let ((map (make-sparse-keymap)))
        (define-key map "x" #'multi-cursor-tests--edit)
        (let ((minor-mode-map-alist
               (cons (cons t map) minor-mode-map-alist)))
          (should-error (ert-play-keys "x") :type 'user-error))
        (should (equal (buffer-string) before)))
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--edit 'unsupported nil
        (let ((delete-selection-mode t))
          (put 'multi-cursor-tests--edit 'delete-selection t)
          (unwind-protect
              (progn
                (goto-char 4)
                (set-mark 1)
                (activate-mark)
                (run-hooks 'delete-selection-pre-hook)
                (should-error (command-execute 'multi-cursor-tests--edit)
                              :type 'user-error)
                (should (equal (buffer-string) before)))
            (put 'multi-cursor-tests--edit 'delete-selection nil)))))))

(ert-deftest multi-cursor-policy-delete-selection-defers-to-handler ()
  (ert-with-test-buffer (:selected t)
    (require 'delsel)
    (insert "primary secondary")
    (goto-char 8)
    (set-mark 1)
    (activate-mark)
    (multi-cursor-add-selection 18 9 t)
    (let ((delete-selection-mode t)
          (saw-primary nil)
          (map (make-sparse-keymap)))
      (define-key map "x" #'multi-cursor-tests--edit)
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--edit 'batch-edit
          (lambda (&rest _)
            (setq saw-primary
                  (equal (buffer-substring (region-beginning) (region-end))
                         "primary")))
        (let ((pre-command-hook
               (cons #'delete-selection-pre-hook pre-command-hook))
              (minor-mode-map-alist
               (cons (cons t map) minor-mode-map-alist)))
          (ert-play-keys "x")))
      (should saw-primary)
      (should (equal (buffer-string) "primary secondary")))))

(ert-deftest multi-cursor-policy-real-loop-runs-hooks-once ()
  (ert-with-test-buffer (:selected t)
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (let ((pre 0) (post 0)
          (map (make-sparse-keymap)))
      (define-key map "x" #'multi-cursor-tests--run-once)
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--run-once 'run-once nil
        (let ((pre-command-hook
               (lambda ()
                 (when (eq this-command 'multi-cursor-tests--run-once)
                   (cl-incf pre))))
              (post-command-hook
               (lambda ()
                 (when (eq this-command 'multi-cursor-tests--run-once)
                   (cl-incf post))))
              (minor-mode-map-alist
               (cons (cons t map) minor-mode-map-alist)))
          (ert-play-keys "x")))
      (should (= pre 1))
      (should (= post 1)))))

(ert-deftest multi-cursor-policy-dispatch-guard-unwinds-on-error-and-quit ()
  (with-temp-buffer
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (dolist (case '((multi-cursor-tests--error . error)
                    (multi-cursor-tests--quit . quit)))
      (multi-cursor-tests--with-policy (car case) 'run-once nil
        (if (eq (cdr case) 'quit)
            (should (eq (condition-case nil
                            (progn (command-execute (car case)) nil)
                          (quit 'quit))
                        'quit))
          (should-error (command-execute (car case)) :type 'error)))
      (should-not multi-cursor--dispatching))))

(ert-deftest multi-cursor-policy-disabled-and-macro-paths-are-preserved ()
  (ert-with-test-buffer (:selected t)
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (let ((disabled 0) (ran 0)
          (multi-cursor-tests--command-log nil)
          (map (make-sparse-keymap)))
      (define-key map "x" #'multi-cursor-tests--run-once)
      (put 'multi-cursor-tests--run-once 'disabled t)
      (unwind-protect
          (multi-cursor-tests--with-policy
              'multi-cursor-tests--run-once 'run-once nil
            (let ((disabled-command-function
                   (lambda () (cl-incf disabled)))
                  (minor-mode-map-alist
                   (cons (cons t map) minor-mode-map-alist)))
              (ert-play-keys "x")))
        (put 'multi-cursor-tests--run-once 'disabled nil))
      (should (= disabled 1))
      (should-not multi-cursor-tests--command-log)
      (define-key map "x" [?y])
      (define-key map "y" (lambda () (interactive) (cl-incf ran)))
      (let ((macro-command (lookup-key map "y")))
        (multi-cursor-tests--with-policy macro-command 'run-once nil
          (let ((minor-mode-map-alist
                 (cons (cons t map) minor-mode-map-alist)))
            (ert-play-keys "x"))))
      (should (= ran 1)))))

(ert-deftest multi-cursor-policy-autoload-and-special-paths-are-preserved ()
  (ert-with-test-buffer (:selected t)
    (insert "one two")
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (let ((autoload-command 'multi-cursor-tests--autoloaded)
          (special-command (lambda () (interactive)
                             (push 'special multi-cursor-tests--command-log))))
      (ert-with-temp-file file
        :suffix ".el"
        :text ";;; -*- lexical-binding: t; -*-\n(defun multi-cursor-tests--autoloaded () (interactive) (setq multi-cursor-tests--command-log '(autoloaded)))\n"
        (autoload autoload-command file nil t)
        (unwind-protect
            (multi-cursor-tests--with-policy autoload-command 'run-once nil
              (let ((map (make-sparse-keymap)))
                (define-key map "x" autoload-command)
                (let ((minor-mode-map-alist
                       (cons (cons t map) minor-mode-map-alist)))
                  (ert-play-keys "x")))
              (should (equal multi-cursor-tests--command-log '(autoloaded))))
          (fmakunbound autoload-command)))
      (setq multi-cursor-tests--command-log nil)
      (command-execute special-command nil nil t)
      (should (equal multi-cursor-tests--command-log '(special))))))

(ert-deftest multi-cursor-movement-horizontal-preserves-selection-state ()
  (with-temp-buffer
    (insert "abcdefghijklmnop")
    (goto-char 2)
    (set-mark 1)
    (activate-mark)
    (setq temporary-goal-column 2)
    (let* ((first-id (multi-cursor-add-selection 6 5 t))
           (second-id (multi-cursor-add-selection 10 12 nil))
           (first (multi-cursor-tests--cursor first-id))
           (second (multi-cursor-tests--cursor second-id)))
      (setf (multi-cursor--cursor-goal-column first) 6
            (multi-cursor--cursor-goal-column second) 10
            (multi-cursor--cursor-last-yank first) 'old-yank
            (multi-cursor--cursor-last-yank second) 'old-yank)
      (command-execute 'forward-char)
      (should (= (point) 3))
      (should (= (mark) 1))
      (should mark-active)
      (should (= (marker-position (multi-cursor--cursor-point first)) 7))
      (should (= (marker-position (multi-cursor--cursor-mark first)) 5))
      (should (multi-cursor--cursor-mark-active first))
      (should (= (marker-position (multi-cursor--cursor-point second)) 11))
      (should (= (marker-position (multi-cursor--cursor-mark second)) 12))
      (should-not (multi-cursor--cursor-mark-active second))
      (should-not (multi-cursor--cursor-last-yank first))
      (should-not (multi-cursor--cursor-last-yank second)))))

(ert-deftest multi-cursor-movement-arrow-and-word-commands-are-broadcast ()
  (dolist (command '(left-char right-char left-word right-word
                     next-line previous-line))
    (let ((entry (gethash command multi-cursor--command-policies)))
      (should (eq (car entry) 'broadcast-movement))
      (should (eq (cdr entry) #'multi-cursor--movement-handler)))
    (should (memq command multi-cursor--movement-commands))))

(ert-deftest multi-cursor-movement-horizontal-arrows-preserve-bidi-command ()
  (dolist (command '(left-char right-char))
    (ert-with-test-buffer (:selected t)
      (insert "abc xyz\n\N{HEBREW LETTER ALEF}\N{HEBREW LETTER BET}\N{HEBREW LETTER GIMEL} "
              "\N{HEBREW LETTER DALET}\N{HEBREW LETTER HE}\N{HEBREW LETTER VAV}\n")
      (let* ((visual-order-cursor-movement nil)
             (starts '(2 10))
             (expected
              (cl-letf (((symbol-function
                          'current-bidi-paragraph-direction)
                         (lambda (&optional _buffer)
                           (if (< (point) 9)
                               'left-to-right
                             'right-to-left))))
                (mapcar (lambda (position)
                          (multi-cursor-tests--ordinary-movement-destination
                           command position))
                        starts)))
             (before (buffer-string))
             (window (selected-window)))
        (goto-char (car starts))
        (set-mark 1)
        (activate-mark)
        (multi-cursor-add-selection (cadr starts) 12 t)
        (cl-letf (((symbol-function 'current-bidi-paragraph-direction)
                   (lambda (&optional _buffer)
                     (if (< (point) 9)
                         'left-to-right
                       'right-to-left))))
          (command-execute command))
        ;; Logical-order arrow motion goes in opposite buffer directions in
        ;; the LTR and RTL paragraphs, proving each cursor's context is used.
        (should (= (* (- (car expected) (car starts))
                      (- (cadr expected) (cadr starts)))
                   -1))
        (should (= (point) (car expected)))
        (should (= (mark) 1))
        (should mark-active)
        (should
         (equal (mapcar (lambda (selection)
                          (plist-get selection :point))
                        (multi-cursor-selections))
                (cdr expected)))
        (should (eq (selected-window) window))
        (should (eq (current-buffer) (window-buffer window)))
        (should (equal (buffer-string) before))))))

(ert-deftest multi-cursor-movement-visual-order-arrows-reject-atomically ()
  (dolist (command '(left-char right-char))
    (with-temp-buffer
      (insert "abc \N{HEBREW LETTER ALEF}\N{HEBREW LETTER BET}\N{HEBREW LETTER GIMEL} xyz")
      (goto-char 2)
      (set-mark 1)
      (activate-mark)
      (let* ((visual-order-cursor-movement t)
             (cursor-id (multi-cursor-add-selection 6 8 t))
             (cursor (multi-cursor-tests--cursor cursor-id))
             (before (buffer-string)))
        (setf (multi-cursor--cursor-goal-column cursor) 4)
        (should-error (command-execute command) :type 'user-error)
        (should (= (point) 2))
        (should (= (mark) 1))
        (should mark-active)
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 6))
        (should (= (marker-position (multi-cursor--cursor-mark cursor)) 8))
        (should (multi-cursor--cursor-mark-active cursor))
        (should (= (multi-cursor--cursor-goal-column cursor) 4))
        (should (equal (buffer-string) before))))))

(ert-deftest multi-cursor-movement-shift-arrows-reject-atomically ()
  (ert-with-test-buffer (:selected t)
    (insert "abcdef")
    (goto-char 2)
    (let* ((this-command-keys-shift-translated nil)
           (cursor-id (multi-cursor-add-at-point 5))
           (cursor (multi-cursor-tests--cursor cursor-id))
           (before (multi-cursor-selections)))
      (should-error (ert-play-keys [S-right]) :type 'user-error)
      (should (= (point) 2))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))
      (should (equal (multi-cursor-selections) before)))))

(ert-deftest multi-cursor-movement-word-arrows-use-ordinary-semantics ()
  (dolist (command '(left-word right-word))
    (with-temp-buffer
      (insert "one two three four")
      (let* ((starts (if (eq command 'right-word) '(1 9) '(8 15)))
             (expected
              (mapcar (lambda (position)
                        (multi-cursor-tests--ordinary-movement-destination
                         command position))
                      starts)))
        (goto-char (car starts))
        (multi-cursor-add-at-point (cadr starts))
        (command-execute command)
        (should (= (point) (car expected)))
        (should (= (plist-get (car (multi-cursor-selections)) :point)
                   (cadr expected)))))))

(ert-deftest multi-cursor-movement-arrow-prefix-records-history-once ()
  (with-temp-buffer
    (insert "abcdefghijkl")
    (goto-char 5)
    (multi-cursor-add-at-point 9)
    (let ((command-history nil)
          (prefix-arg -2))
      (command-execute 'right-char t [right])
      (should (= (point) 3))
      (should (= (plist-get (car (multi-cursor-selections)) :point) 7))
      (should (equal command-history '((right-char -2)))))))

(ert-deftest multi-cursor-movement-arrow-events-reach-their-real-commands ()
  (dolist (case '((right right-char "abc\ndef\nghi" 1 5 2 6)
                  (left left-char "abc\ndef\nghi" 3 7 2 6)
                  (down next-line "abc\ndef\nghi" 2 6 6 10)
                  (up previous-line "abc\ndef\nghi" 10 6 6 2)))
    (let ((last-command nil)
          (temporary-goal-column 0))
      (ert-with-test-buffer (:selected t)
        (pcase-let ((`(,event ,command ,text ,primary ,secondary
                       ,expected-primary ,expected-secondary)
                     case))
          (insert text)
          (goto-char primary)
          (multi-cursor-add-at-point secondary)
          (let ((line-move-visual nil)
                (map (make-sparse-keymap)))
            (define-key map (vector event) command)
            (let ((minor-mode-map-alist
                   (cons (cons t map) minor-mode-map-alist)))
              (ert-play-keys (vector event))))
          (should (= (point) expected-primary))
          (should (= (plist-get (car (multi-cursor-selections)) :point)
                     expected-secondary)))))))

(ert-deftest multi-cursor-movement-word-and-line-boundaries ()
  (with-temp-buffer
    (insert "one two\nthree four\nfive six")
    (goto-char 1)
    (let ((cursor-id (multi-cursor-add-at-point 9)))
      (command-execute 'forward-word)
      (should (= (point) 4))
      (should (= (marker-position
                  (multi-cursor--cursor-point
                   (multi-cursor-tests--cursor cursor-id)))
                 14))
      (command-execute 'move-end-of-line)
      (should (= (point) 8))
      (should (= (marker-position
                  (multi-cursor--cursor-point
                   (multi-cursor-tests--cursor cursor-id)))
                 19))
      (command-execute 'move-beginning-of-line)
      (should (= (point) 1))
      (should (= (marker-position
                  (multi-cursor--cursor-point
                   (multi-cursor-tests--cursor cursor-id)))
                 9)))))

(ert-deftest multi-cursor-movement-logical-lines-keep-independent-goals ()
  (with-temp-buffer
    (insert "abcdef\nxy\nabcdef\nabcdef\n")
    (goto-char 4)
    (let* ((last-command nil)
           (temporary-goal-column 0)
           (cursor-id (multi-cursor-add-at-point 10))
           (cursor (multi-cursor-tests--cursor cursor-id)))
      (command-execute 'next-logical-line)
      (should (= (line-number-at-pos) 2))
      (should (= (current-column) 2))
      (should (= temporary-goal-column 3))
      (save-excursion
        (goto-char (multi-cursor--cursor-point cursor))
        (should (= (line-number-at-pos) 3))
        (should (= (current-column) 2)))
      (should (= (multi-cursor--cursor-goal-column cursor) 2))
      (let ((last-command 'next-logical-line))
        (command-execute 'next-logical-line))
      (should (= (line-number-at-pos) 3))
      (should (= (current-column) 3))
      (save-excursion
        (goto-char (multi-cursor--cursor-point cursor))
        (should (= (line-number-at-pos) 4))
        (should (= (current-column) 2)))
      (should (= (multi-cursor--cursor-goal-column cursor) 2)))))

(ert-deftest multi-cursor-movement-next-line-keeps-independent-goals ()
  (ert-with-test-buffer (:selected t)
    (insert "abcdef\nxy\nabcdef\nabcdef\n")
    (goto-char 4)
    (let* ((line-move-visual nil)
           (last-command nil)
           (cursor-id (multi-cursor-add-at-point 10))
           (cursor (multi-cursor-tests--cursor cursor-id)))
      (command-execute 'next-line)
      (should (= (line-number-at-pos) 2))
      (should (= (current-column) 2))
      (should (= temporary-goal-column 3))
      (save-excursion
        (goto-char (multi-cursor--cursor-point cursor))
        (should (= (line-number-at-pos) 3))
        (should (= (current-column) 2)))
      (should (= (multi-cursor--cursor-goal-column cursor) 2))
      (let ((last-command 'next-line))
        (command-execute 'next-line))
      (should (= (line-number-at-pos) 3))
      (should (= (current-column) 3))
      (save-excursion
        (goto-char (multi-cursor--cursor-point cursor))
        (should (= (line-number-at-pos) 4))
        (should (= (current-column) 2)))
      (should (= (multi-cursor--cursor-goal-column cursor) 2)))))

(ert-deftest multi-cursor-movement-visual-lines-reject-atomically ()
  (dolist (command '(next-line previous-line))
    (ert-with-test-buffer (:selected t)
      (insert "abcdef\nxy\nabcdef\n")
      (goto-char 4)
      (set-mark 2)
      (activate-mark)
      (let* ((line-move-visual t)
             (goal-column nil)
             (command-history '((sentinel)))
             (cursor-id (multi-cursor-add-selection 10 8 t))
             (cursor (multi-cursor-tests--cursor cursor-id))
             (before (buffer-string))
             (window (selected-window)))
        (setf (multi-cursor--cursor-goal-column cursor) 2)
        (should-error (command-execute command t) :type 'user-error)
        (should (= (point) 4))
        (should (= (mark) 2))
        (should mark-active)
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 10))
        (should (= (marker-position (multi-cursor--cursor-mark cursor)) 8))
        (should (multi-cursor--cursor-mark-active cursor))
        (should (= (multi-cursor--cursor-goal-column cursor) 2))
        (should (equal command-history '((sentinel))))
        (should (eq (selected-window) window))
        (should (equal (buffer-string) before))))))

(ert-deftest multi-cursor-movement-explicit-goal-allows-logical-line-arrows ()
  (ert-with-test-buffer (:selected t)
    (insert "abcdef\nxy\nabcdef\n")
    (goto-char 4)
    (let* ((line-move-visual t)
           (goal-column 1)
           (this-command-keys-shift-translated nil)
           (cursor-id (multi-cursor-add-at-point 9))
           (cursor (multi-cursor-tests--cursor cursor-id)))
      (command-execute 'next-line)
      (should (= (line-number-at-pos) 2))
      (should (= (current-column) 1))
      (save-excursion
        (goto-char (multi-cursor--cursor-point cursor))
        (should (= (line-number-at-pos) 3))
        (should (= (current-column) 1))))))

(ert-deftest multi-cursor-movement-next-line-never-adds-newlines ()
  (ert-with-test-buffer (:selected t)
    (insert "abc\ndef")
    (goto-char (point-max))
    (let* ((line-move-visual nil)
           (next-line-add-newlines t)
           (cursor-id (multi-cursor-add-at-point 2))
           (cursor (multi-cursor-tests--cursor cursor-id))
           (before (buffer-string)))
      (command-execute 'next-line)
      (should (= (point) (point-max)))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 6))
      (should (equal (buffer-string) before)))))

(ert-deftest multi-cursor-movement-boundaries-clamp-and-continue ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char (point-max))
    (let ((cursor-id (multi-cursor-add-at-point 3)))
      (command-execute 'forward-char)
      (should (= (point) (point-max)))
      (should (= (marker-position
                  (multi-cursor--cursor-point
                   (multi-cursor-tests--cursor cursor-id)))
                 4))))
  (with-temp-buffer
    (insert "abcdef")
    (goto-char (point-min))
    (let ((cursor-id (multi-cursor-add-at-point 5)))
      (command-execute 'backward-char)
      (should (= (point) (point-min)))
      (should (= (marker-position
                  (multi-cursor--cursor-point
                  (multi-cursor-tests--cursor cursor-id)))
                 4)))))

(ert-deftest multi-cursor-movement-line-arrows-clamp-and-continue ()
  (ert-with-test-buffer (:selected t)
    (insert "aa\nbb\ncc")
    (goto-char (point-max))
    (let ((line-move-visual nil)
          (cursor-id (multi-cursor-add-at-point 5)))
      (command-execute 'next-line)
      (should (= (point) (point-max)))
      (should (= (marker-position
                  (multi-cursor--cursor-point
                   (multi-cursor-tests--cursor cursor-id)))
                 8))))
  (ert-with-test-buffer (:selected t)
    (insert "aa\nbb\ncc")
    (goto-char (point-min))
    (let ((line-move-visual nil)
          (cursor-id (multi-cursor-add-at-point 5)))
      (command-execute 'previous-line)
      (should (= (point) (point-min)))
      (should (= (marker-position
                  (multi-cursor--cursor-point
                   (multi-cursor-tests--cursor cursor-id)))
                 2)))))

(ert-deftest multi-cursor-movement-right-char-error-restores-arrow-state ()
  (with-temp-buffer
    (insert "abcdefghijkl")
    (goto-char 2)
    (set-mark 1)
    (activate-mark)
    (setq temporary-goal-column 7)
    (let* ((early-id (multi-cursor-add-at-point 3))
           (late-id (multi-cursor-add-selection 5 7 t))
           (early (multi-cursor-tests--cursor early-id))
           (late (multi-cursor-tests--cursor late-id))
           (ordinary-right-char (symbol-function 'right-char))
           (window (selected-window)))
      (setf (multi-cursor--cursor-goal-column early) 4
            (multi-cursor--cursor-goal-column late) 9)
      (cl-letf (((symbol-function 'right-char)
                 (lambda (&optional argument)
                   (interactive "^p")
                   (if (= (point) 5)
                       (error "arrow movement test error")
                     (funcall ordinary-right-char argument)))))
        (should-error (command-execute 'right-char) :type 'error))
      (should (= (point) 2))
      (should (= (mark) 1))
      (should mark-active)
      (should (= temporary-goal-column 7))
      (should (= (marker-position (multi-cursor--cursor-point early)) 3))
      (should (= (multi-cursor--cursor-goal-column early) 4))
      (should (= (marker-position (multi-cursor--cursor-point late)) 5))
      (should (= (marker-position (multi-cursor--cursor-mark late)) 7))
      (should (multi-cursor--cursor-mark-active late))
      (should (= (multi-cursor--cursor-goal-column late) 9))
      (should (eq (selected-window) window)))))

(ert-deftest multi-cursor-movement-normalizes-collisions-after-commit ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char (point-max))
    (let* ((cursor-id (multi-cursor-add-at-point (1- (point-max))))
           (cursor (multi-cursor-tests--cursor cursor-id))
           (marker (multi-cursor--cursor-point cursor)))
      (command-execute 'forward-char)
      (should (= (point) (point-max)))
      (should-not multi-cursor--cursors)
      (should-not (marker-buffer marker)))))

(ert-deftest multi-cursor-movement-records-history-once ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 1)
    (multi-cursor-add-at-point 3)
    (let ((command-history nil)
          (prefix-arg 2))
      (command-execute 'forward-char t [?f])
      (should (equal command-history '((forward-char 2)))))))

(ert-deftest multi-cursor-movement-unexpected-error-restores-all-state ()
  (with-temp-buffer
    (insert "abcdefghijkl")
    (goto-char 2)
    (set-mark 1)
    (activate-mark)
    (setq temporary-goal-column 7)
    (let* ((early-id (multi-cursor-add-at-point 3))
           (cursor-id (multi-cursor-add-selection 5 7 t))
           (early (multi-cursor-tests--cursor early-id))
           (cursor (multi-cursor-tests--cursor cursor-id))
           (multi-cursor--movement-commands
            (cons 'multi-cursor-tests--movement-maybe-error
                  multi-cursor--movement-commands)))
      (setf (multi-cursor--cursor-goal-column early) 4
            (multi-cursor--cursor-last-yank early) 'early-yank
            (multi-cursor--cursor-goal-column cursor) 9
            (multi-cursor--cursor-last-yank cursor) 'late-yank)
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--movement-maybe-error 'broadcast-movement nil
        (should-error
         (command-execute 'multi-cursor-tests--movement-maybe-error)
         :type 'error))
      (should (= (point) 2))
      (should (= (mark) 1))
      (should mark-active)
      (should (= temporary-goal-column 7))
      (should (= (marker-position (multi-cursor--cursor-point early)) 3))
      (should (= (multi-cursor--cursor-goal-column early) 4))
      (should (eq (multi-cursor--cursor-last-yank early) 'early-yank))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))
      (should (= (marker-position (multi-cursor--cursor-mark cursor)) 7))
      (should (multi-cursor--cursor-mark-active cursor))
      (should (= (multi-cursor--cursor-goal-column cursor) 9))
      (should (eq (multi-cursor--cursor-last-yank cursor) 'late-yank)))))

(ert-deftest multi-cursor-movement-quit-restores-all-state ()
  (with-temp-buffer
    (insert "abcdefghijkl")
    (goto-char 2)
    (let* ((early-id (multi-cursor-add-at-point 3))
           (late-id (multi-cursor-add-at-point 5))
           (early (multi-cursor-tests--cursor early-id))
           (late (multi-cursor-tests--cursor late-id))
           (multi-cursor--movement-commands
            (cons 'multi-cursor-tests--movement-maybe-quit
                  multi-cursor--movement-commands)))
      (multi-cursor-tests--with-policy
          'multi-cursor-tests--movement-maybe-quit 'broadcast-movement nil
        (should (eq (condition-case nil
                        (progn
                          (command-execute
                           'multi-cursor-tests--movement-maybe-quit)
                          nil)
                      (quit 'quit))
                    'quit)))
      (should (= (point) 2))
      (should (= (marker-position (multi-cursor--cursor-point early)) 3))
      (should (= (marker-position (multi-cursor--cursor-point late)) 5)))))

(ert-deftest multi-cursor-creation-narrowed-unrelated-command-does-not-scan ()
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (multi-cursor-add-at-point 4)
    (narrow-to-region 1 8)
    (let ((calls 0))
      (cl-letf (((symbol-function 'multi-cursor--remove-inaccessible-cursors)
                 (lambda () (cl-incf calls))))
        (run-hooks 'pre-command-hook)
        (run-hooks 'post-command-hook))
      (should (= calls 0)))))

(ert-deftest multi-cursor-edit-self-insert-mixed-selections ()
  (with-temp-buffer
    (insert "0123456789")
    (goto-char 4)
    (set-mark 2)
    (activate-mark)
    (multi-cursor-add-at-point 6)
    (multi-cursor-add-selection 10 8 t)
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    (should (equal (buffer-string) "0X34X56X9"))
    (should (= (point) 3))
    (should-not mark-active)
    (should (equal (mapcar (lambda (state) (plist-get state :point))
                           (multi-cursor-selections))
                   '(6 9)))))

(ert-deftest multi-cursor-edit-delete-boundaries-are-per-cursor-no-ops ()
  (with-temp-buffer
    (insert "abcd")
    (goto-char (point-max))
    (multi-cursor-add-at-point 2)
    (command-execute 'delete-char)
    (should (equal (buffer-string) "acd"))
    (should (= (point) (point-max))))
  (with-temp-buffer
    (insert "abcd")
    (goto-char (point-min))
    (multi-cursor-add-at-point 4)
    (command-execute 'delete-backward-char)
    (should (equal (buffer-string) "abd"))
    (should (= (point) (point-min)))))

(ert-deftest multi-cursor-edit-default-delete-command-policies ()
  (dolist (command '(delete-forward-char delete-backward-char))
    (should (eq (car (gethash command multi-cursor--command-policies))
                'batch-edit)))
  ;; DEL resolves to the guarded raw backward command in this build.  The
  ;; higher-level untabifying command still needs a separate transaction.
  (should (eq (lookup-key global-map (kbd "DEL"))
              'delete-backward-char))
  (should (eq (car (gethash 'backward-delete-char-untabify
                            multi-cursor--command-policies))
              'unsupported))
  (should (eq (lookup-key global-map [deletechar]) 'delete-forward-char)))

(ert-deftest multi-cursor-edit-delete-forward-composed-graphemes ()
  (with-temp-buffer
    (insert "abX abY")
    (compose-region 1 3)
    (compose-region 5 7)
    (goto-char 1)
    (multi-cursor-add-at-point 5)
    (command-execute 'delete-forward-char)
    (should (equal (buffer-string) "X Y"))))

(ert-deftest multi-cursor-edit-delete-forward-mixed-active-selections ()
  (with-temp-buffer
    (insert "0123456789")
    (goto-char 4)
    (set-mark 2)
    (activate-mark)
    (multi-cursor-add-at-point 6)
    (multi-cursor-add-selection 10 8 t)
    (let ((delete-active-region t))
      (command-execute 'delete-forward-char))
    (should (equal (buffer-string) "03469"))))

(ert-deftest multi-cursor-edit-delete-forward-can-ignore-active-regions ()
  (with-temp-buffer
    (insert "0123456789")
    (goto-char 4)
    (set-mark 2)
    (activate-mark)
    (multi-cursor-add-at-point 6)
    (multi-cursor-add-selection 10 8 t)
    (let ((delete-active-region nil))
      (command-execute 'delete-forward-char))
    (should (equal (buffer-string) "0124678"))
    (should (= (mark) 2))
    (should-not mark-active)
    (let ((selection (cl-find-if
                      (lambda (item) (plist-get item :mark))
                      (multi-cursor-selections))))
      (should selection)
      (should-not (plist-get selection :mark-active)))))

(ert-deftest multi-cursor-edit-delete-forward-boundary-is-per-cursor-no-op ()
  (with-temp-buffer
    (insert "abX")
    (compose-region 1 3)
    (goto-char (point-max))
    (multi-cursor-add-at-point 1)
    (command-execute 'delete-forward-char)
    (should (equal (buffer-string) "X"))
    (should (= (point) (point-max)))))

(ert-deftest multi-cursor-edit-delete-forward-overlapping-grapheme-targets ()
  (with-temp-buffer
    (insert "abX")
    (compose-region 1 3)
    (goto-char 1)
    (let* ((id (multi-cursor-add-at-point 2))
           (cursor (multi-cursor-tests--cursor id))
           (marker (multi-cursor--cursor-point cursor)))
      (command-execute 'delete-forward-char)
      (should (equal (buffer-string) "X"))
      (should-not multi-cursor--cursors)
      (should-not (marker-buffer marker)))))

(ert-deftest multi-cursor-edit-default-delete-prefix-and-kill-reject-atomically ()
  (dolist (command '(delete-forward-char delete-backward-char))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 2)
      (multi-cursor-add-at-point 5)
      (let ((before (buffer-string))
            (kill-ring '("old"))
            (prefix-arg 1))
        (should-error (command-execute command) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (equal kill-ring '("old"))))))
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 3)
    (set-mark 1)
    (activate-mark)
    (multi-cursor-add-selection 6 4 t)
    (let ((before (buffer-string))
          (kill-ring '("old"))
          (delete-active-region 'kill))
      (should-error (command-execute 'delete-forward-char) :type 'user-error)
      (should (equal (buffer-string) before))
      (should (equal kill-ring '("old"))))))

(ert-deftest multi-cursor-edit-overwrite-backspace-rejects-atomically ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 3)
    (let* ((overwrite-mode t)
           (id (multi-cursor-add-at-point 6))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string)))
      (should-error (command-execute 'delete-backward-char)
                    :type 'user-error)
      (should (equal (buffer-string) before))
      (should (= (point) 3))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 6)))))

(ert-deftest multi-cursor-edit-default-delete-preflight-rolls-back ()
  (dolist (failure '(read-only field hook))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 5))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (before-change-functions
              (when (eq failure 'hook)
                (list (lambda (beg _end)
                        (when (= beg 2)
                          (error "Default delete hook failed")))))))
        (when (eq failure 'read-only)
          (put-text-property 5 6 'read-only t))
        (if (eq failure 'field)
            (cl-letf (((symbol-function 'constrain-to-field)
                       (lambda (new old &rest _)
                         (if (= old 5) old new))))
              (should-error (command-execute 'delete-forward-char)
                            :type 'user-error))
          (should-error (command-execute 'delete-forward-char)))
        (should (equal (buffer-substring-no-properties
                        (point-min) (point-max))
                       before))
        (should (= (point) 2))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))))))

(ert-deftest multi-cursor-edit-delete-forward-planning-mutation-rolls-back ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 5))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (original-find-composition (symbol-function 'find-composition))
           mutated)
      (cl-letf (((symbol-function 'find-composition)
                 (lambda (&rest arguments)
                   (unless mutated
                     (setq mutated t)
                     (insert "X")
                     (narrow-to-region 2 (point-max)))
                   (apply original-find-composition arguments))))
        (should-error (command-execute 'delete-forward-char) :type 'error))
      (should (equal (buffer-string) before))
      (should (= (point-min) 1))
      (should (= (point-max) 7))
      (should (= (point) 2))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 5)))))

(ert-deftest multi-cursor-edit-delete-forward-policy-mutation-rolls-back ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (let* ((delete-active-region t)
           (id (multi-cursor-add-selection 5 4 t))
           (cursor (multi-cursor-tests--cursor id))
           (original-find-composition (symbol-function 'find-composition)))
      (cl-letf (((symbol-function 'find-composition)
                 (lambda (&rest arguments)
                   (setq delete-active-region nil)
                   (apply original-find-composition arguments))))
        (should-error (command-execute 'delete-forward-char) :type 'error))
      (should (eq delete-active-region t))
      (should (equal (buffer-string) "abcdef"))
      (should (= (point) 2))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))
      (should (multi-cursor--cursor-mark-active cursor)))))

(ert-deftest multi-cursor-edit-delete-forward-mode-mutation-rolls-back ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 5))
           (cursor (multi-cursor-tests--cursor id))
           (original-find-composition (symbol-function 'find-composition))
           disabled)
      (cl-letf (((symbol-function 'find-composition)
                 (lambda (&rest arguments)
                   (unless disabled
                     (setq disabled t)
                     (multi-cursor-mode -1))
                   (apply original-find-composition arguments))))
        (should-error (command-execute 'delete-forward-char) :type 'error))
      (should multi-cursor-mode)
      (should (memq #'multi-cursor--end-session kill-buffer-hook))
      (should (memq #'multi-cursor--mark-redisplay-snapshot-dirty
                    after-change-functions))
      (should (equal (buffer-string) "abcdef"))
      (should (= (point) 2))
      (should (= (multi-cursor--cursor-id cursor) id))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 5)))))

(ert-deftest multi-cursor-edit-delete-forward-is-one-undo-unit ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcdef")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 5)
    (command-execute 'delete-forward-char)
    (should (equal (buffer-string) "acdf"))
    (multi-cursor-mode -1)
    (undo-boundary)
    (undo 1)
    (should (equal (buffer-string) "abcdef"))))

(ert-deftest multi-cursor-edit-default-delete-records-history-once ()
  (dolist (command '(delete-forward-char delete-backward-char))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 2)
      (multi-cursor-add-at-point 5)
      (let ((command-history nil))
        (command-execute command t)
        (should (equal command-history (list (list command 1))))))))

(ert-deftest multi-cursor-edit-real-delete-key-events ()
  (ert-with-test-buffer (:selected t)
    (insert "abcdef")
    (goto-char 2)
    (multi-cursor-add-at-point 5)
    (ert-play-keys [deletechar])
    (should (equal (buffer-string) "acdf")))
  (ert-with-test-buffer (:selected t)
    (insert "abcdef")
    (goto-char 3)
    (multi-cursor-add-at-point 6)
    (ert-play-keys (kbd "DEL"))
    (should (equal (buffer-string) "acdf")))
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 3)
    (multi-cursor-add-at-point 6)
    (let ((before (buffer-string)))
      (should-error (command-execute 'backward-delete-char-untabify)
                    :type 'user-error)
      (should (equal (buffer-string) before)))))

(ert-deftest multi-cursor-edit-insertion-at-exact-narrowed-end-grows-zv ()
  (with-temp-buffer
    (insert "outside abcd tail")
    (narrow-to-region 9 13)
    (goto-char (point-max))
    (multi-cursor-add-at-point (point-min))
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    (should (equal (buffer-string) "XabcdX"))
    (should (= (point-min) 9))
    (should (= (point-max) 15))))

(ert-deftest multi-cursor-edit-touching-selections-keep-primary-survivor ()
  (with-temp-buffer
    (insert "abcdefgh")
    (goto-char 4)
    (set-mark 2)
    (activate-mark)
    (let* ((id (multi-cursor-add-selection 6 4 t))
           (cursor (multi-cursor-tests--cursor id))
           (marker (multi-cursor--cursor-point cursor))
           (last-command-event ?X))
      (command-execute 'self-insert-command)
      (should (equal (buffer-string) "aXfgh"))
      (should-not multi-cursor--cursors)
      (should-not (marker-buffer marker)))))

(ert-deftest multi-cursor-edit-read-only-and-hook-errors-roll-back ()
  (dolist (failure '(read-only hook))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 5))
             (cursor (multi-cursor-tests--cursor id))
             (before-change-functions
              (when (eq failure 'hook)
                (list (lambda (beg _end)
                        (when (= beg 2)
                          (error "Middle edit failed")))))))
        (when (eq failure 'read-only)
          (put-text-property 2 3 'read-only t))
        (should-error (command-execute 'delete-char))
        (should (equal (buffer-substring-no-properties 1 (point-max))
                       "abcdef"))
        (should (= (point) 2))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   5))))))

(ert-deftest multi-cursor-edit-every-hook-failure-position-rolls-back ()
  (dolist (failure-beg '(6 4 2))
    (with-temp-buffer
      (insert "abcdefgh")
      (goto-char 2)
      (multi-cursor-add-at-point 4)
      (multi-cursor-add-at-point 6)
      (let ((before-change-functions
             (list (lambda (beg _end)
                     (when (= beg failure-beg)
                       (error "Change hook failed"))))))
        (should-error (command-execute 'delete-char)))
      (should (equal (buffer-string) "abcdefgh"))
      (should (= (point) 2))
      (should (equal (mapcar (lambda (state) (plist-get state :point))
                             (multi-cursor-selections))
                     '(4 6))))))

(ert-deftest multi-cursor-edit-pending-quit-rolls-back-before-modification ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (multi-cursor-add-at-point 5)
    (should (eq (condition-case nil
                    (let ((quit-flag t))
                      (command-execute 'delete-char)
                      nil)
                  (quit 'quit))
                'quit))
    (should (equal (buffer-string) "abcdef"))
    (should (= (point) 2))
    (should (equal (mapcar (lambda (state) (plist-get state :point))
                           (multi-cursor-selections))
                   '(5)))))

(ert-deftest multi-cursor-edit-remaps-inactive-marks-with-before-gravity ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (set-mark 2)
    (setq mark-active nil)
    (let* ((id (multi-cursor-add-selection 5 6 nil))
           (cursor (multi-cursor-tests--cursor id))
           (last-command-event ?X))
      (command-execute 'self-insert-command)
      (should (= (point) 3))
      (should (= (mark) 2))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 7))
      (should (= (marker-position (multi-cursor--cursor-mark cursor)) 8)))))

(ert-deftest multi-cursor-edit-position-transform-covers-ranges-and-gaps ()
  (let ((groups
         (vector (multi-cursor--edit-create :beg 2 :end 4 :string "X")
                 (multi-cursor--edit-create :beg 6 :end 6 :string "YY")))
        (positions [3 7]))
    (should
     (equal (mapcar (lambda (position)
                      (multi-cursor--remap-edit-position
                       position groups positions))
                    '(1 2 3 4 5 6 7))
            '(1 2 3 3 4 5 8)))))

(ert-deftest multi-cursor-edit-produces-one-undo-unit ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    (should (equal (buffer-string) "aXbcXd"))
    ;; Undo dispatch remains unsupported during a session at this checkpoint.
    (multi-cursor-mode -1)
    (undo-boundary)
    (undo 1)
    (should (equal (buffer-string) "abcd"))))

(ert-deftest multi-cursor-edit-batch-primitive-call-count-is-constant ()
  (unless (fboundp 'multi-cursor--apply-edits)
    (ert-skip "Fresh native multiple-cursor test binary is unavailable"))
  (dolist (cursor-count '(2 10 100 500))
    (with-temp-buffer
      (insert (make-string (+ 2 (* cursor-count 2)) ?a))
      (goto-char 1)
      (dotimes (index (1- cursor-count))
        (multi-cursor-add-at-point (+ 3 (* index 2))))
      (let ((apply-calls 0)
            (merge-calls 0)
            (apply-function (symbol-function 'multi-cursor--apply-edits))
            (merge-function (symbol-function 'multi-cursor--merge-edits))
            (last-command-event ?X))
        (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                   (lambda (edits)
                     (cl-incf apply-calls)
                     (funcall apply-function edits)))
                  ((symbol-function 'multi-cursor--merge-edits)
                   (lambda (edits)
                     (cl-incf merge-calls)
                     (funcall merge-function edits))))
          (multi-cursor--batch-edit
           'self-insert-command nil nil nil nil))
        (should (= apply-calls 1))
        (should (= merge-calls 1))
        (should (= (cl-count ?X (buffer-string)) cursor-count))))))

(ert-deftest multi-cursor-redisplay-publisher-reuses-clean-snapshot ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 1)
    (multi-cursor-add-at-point 4)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((multi-cursor--redisplay-window nil)
            snapshots)
        (cl-letf (((symbol-function 'multi-cursor--set-redisplay-snapshot)
                   (lambda (_window snapshot) (push snapshot snapshots)))
                  ((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) t)))
          (multi-cursor--publish-redisplay-snapshot (selected-window))
          (multi-cursor--publish-redisplay-snapshot (selected-window)))
        (should (= (length snapshots) 2))
        (should (eq (car snapshots) (cadr snapshots)))))))

(ert-deftest multi-cursor-redisplay-publishes-large-set-in-one-batch ()
  (with-temp-buffer
    (insert (make-string 1200 ?a))
    (goto-char 1)
    (dotimes (index 500)
      (multi-cursor-add-at-point (+ 2 (* index 2))))
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((multi-cursor--redisplay-window nil)
            (native-calls 0)
            (presentation-calls 0)
            published)
        (cl-letf (((symbol-function 'multi-cursor--set-redisplay-snapshot)
                   (lambda (_window snapshot)
                     (cl-incf native-calls)
                     (setq published snapshot)))
                  ((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) t))
                  ((symbol-function 'multi-cursor--sync-presentation)
                   (lambda (_window _snapshot _native-p)
                     (cl-incf presentation-calls))))
          (multi-cursor--publish-redisplay-snapshot (selected-window)))
        (should (= native-calls 1))
        (should (= presentation-calls 1))
        (should (vectorp published))
        ;; Two header elements followed by five immutable fields per cursor.
        (should (= (length published) (+ 2 (* 5 500))))))))

(ert-deftest multi-cursor-redisplay-publisher-rebuilds-stale-snapshot ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 1)
    (multi-cursor-add-at-point 4)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((multi-cursor--redisplay-window nil)
            snapshots)
        (cl-letf (((symbol-function 'multi-cursor--set-redisplay-snapshot)
                   (lambda (_window snapshot) (push snapshot snapshots)))
                  ((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) t)))
          (multi-cursor--publish-redisplay-snapshot (selected-window))
          (command-execute 'forward-char)
          (multi-cursor--publish-redisplay-snapshot (selected-window))
          (insert "X")
          (multi-cursor--publish-redisplay-snapshot (selected-window)))
        (setq snapshots (nreverse snapshots))
        (should (= (length snapshots) 3))
        (should-not (eq (nth 0 snapshots) (nth 1 snapshots)))
        (should-not (eq (nth 1 snapshots) (nth 2 snapshots)))
        (should-not (equal (nth 0 snapshots) (nth 1 snapshots)))
        (should-not (equal (aref (nth 1 snapshots) 1)
                           (aref (nth 2 snapshots) 1)))))))

(ert-deftest multi-cursor-redisplay-publisher-clears-on-mode-exit ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 1)
    (multi-cursor-add-at-point 4)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((multi-cursor--redisplay-window nil)
            snapshots)
        (cl-letf (((symbol-function 'multi-cursor--set-redisplay-snapshot)
                   (lambda (_window snapshot) (push snapshot snapshots)))
                  ((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) t)))
          (multi-cursor--publish-redisplay-snapshot (selected-window))
          (multi-cursor-mode -1)
          (multi-cursor--publish-redisplay-snapshot (selected-window)))
        (should (= (length snapshots) 3))
        (should (vectorp (nth 2 snapshots)))
        (should-not (nth 1 snapshots))
        (should-not (nth 0 snapshots))))))

(ert-deftest multi-cursor-redisplay-publisher-clears-previous-window ()
  (let ((first-buffer (generate-new-buffer " *multi-cursor-first*"))
        (second-buffer (generate-new-buffer " *multi-cursor-second*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer first-buffer)
          (with-current-buffer first-buffer
            (insert "first")
            (goto-char 1)
            (multi-cursor-add-at-point 3))
          (let* ((first-window (selected-window))
                 (second-window (split-window-right))
                 (multi-cursor--redisplay-window nil)
                 calls)
            (set-window-buffer second-window second-buffer)
            (with-current-buffer second-buffer
              (insert "second")
              (goto-char 1)
              (multi-cursor-add-at-point 3))
            (cl-letf
                (((symbol-function 'multi-cursor--set-redisplay-snapshot)
                  (lambda (window snapshot)
                    (push (list window snapshot) calls)))
                 ((symbol-function
                   'multi-cursor--native-cursor-decorations-p)
                  (lambda (_window) t)))
              (select-window first-window)
              (multi-cursor--publish-redisplay-snapshot first-window)
              (select-window second-window)
              (multi-cursor--publish-redisplay-snapshot second-window))
            (setq calls (nreverse calls))
            (should (= (length calls) 3))
            (should (eq (caar calls) first-window))
            (should (vectorp (cadar calls)))
            (should (eq (car (nth 1 calls)) first-window))
            (should-not (cadr (nth 1 calls)))
            (should (eq (car (nth 2 calls)) second-window))
            (should (vectorp (cadr (nth 2 calls))))))
      (kill-buffer first-buffer)
      (kill-buffer second-buffer))))

(ert-deftest multi-cursor-redisplay-primitive-rejects-invalid-snapshots ()
  (unless (and (fboundp 'multi-cursor--set-redisplay-snapshot)
               (subrp (symbol-function
                       'multi-cursor--set-redisplay-snapshot)))
    (ert-skip "Fresh native multiple-cursor test binary is unavailable"))
  (with-temp-buffer
    (insert "abcdef")
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((window (selected-window))
             (buffer (current-buffer))
             (tick (buffer-chars-modified-tick))
             (outside (1+ (point-max))))
        (dolist (snapshot
                 (list '(not a vector)
                       []
                       (vector buffer (1- tick) 1 2 nil nil nil)
                       (vector buffer tick 1 4 nil nil nil
                               2 2 nil nil nil)
                       (vector buffer tick 1 outside nil nil nil)
                       (vector buffer tick 1 2 nil nil 'sideways)))
          (should-error
           (multi-cursor--set-redisplay-snapshot window snapshot)))
        (let ((other-window (split-window-right)))
          (should-error
           (multi-cursor--set-redisplay-snapshot
            other-window
           (vector buffer tick 1 2 nil nil nil))))))))

(ert-deftest multi-cursor-redisplay-primitive-rejects-stale-same-snapshot ()
  "Identity reuse must not bypass the published character-change tick."
  (unless (and (fboundp 'multi-cursor--set-redisplay-snapshot)
               (subrp (symbol-function
                       'multi-cursor--set-redisplay-snapshot)))
    (ert-skip "Fresh native multiple-cursor test binary is unavailable"))
  (with-temp-buffer
    (insert "abcdef")
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((window (selected-window))
             (snapshot
              (vector (current-buffer) (buffer-chars-modified-tick)
                      1 4 nil nil 'forward)))
        (multi-cursor--set-redisplay-snapshot window snapshot)
        (insert "x")
        (unwind-protect
            (should-error
             (multi-cursor--set-redisplay-snapshot window snapshot)
             :type 'args-out-of-range)
          (multi-cursor--set-redisplay-snapshot window nil))))))

(ert-deftest multi-cursor-redisplay-resolves-sorted-snapshot-safely ()
  "A sorted published snapshot should survive a completed redisplay."
  (unless (and (fboundp 'multi-cursor--set-redisplay-snapshot)
               (subrp (symbol-function
                       'multi-cursor--set-redisplay-snapshot)))
    (ert-skip "Fresh native multiple-cursor test binary is unavailable"))
  (with-temp-buffer
    (dotimes (line 8)
      (insert (format "line %d: abcdefghijklmnopqrstuvwxyz\n" line)))
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((window (selected-window))
             (buffer (current-buffer))
             (tick (buffer-chars-modified-tick))
             (primary-point 6)
             (snapshot
              (vector buffer tick
                      1 3 nil nil 'forward
                      2 15 nil nil 'backward
                      3 40 nil nil nil
                      4 77 nil nil 'forward)))
        (goto-char primary-point)
        (multi-cursor--set-redisplay-snapshot window snapshot)
        (unwind-protect
            (progn
              (let ((redisplay-skip-initial-frame nil))
                (redisplay 'force))
              (should (= (point) primary-point))
              (should (= (window-point window) primary-point)))
          (multi-cursor--set-redisplay-snapshot window nil))))))

(ert-deftest multi-cursor-redisplay-discards-stale-published-snapshot-safely ()
  "A snapshot made stale before redisplay should not corrupt display state."
  (unless (and (fboundp 'multi-cursor--set-redisplay-snapshot)
               (subrp (symbol-function
                       'multi-cursor--set-redisplay-snapshot)))
    (ert-skip "Fresh native multiple-cursor test binary is unavailable"))
  (with-temp-buffer
    (insert "alpha beta gamma\n")
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((window (selected-window))
             (buffer (current-buffer))
             (tick (buffer-chars-modified-tick))
             (snapshot
              (vector buffer tick
                      1 7 nil nil 'forward)))
        (multi-cursor--set-redisplay-snapshot window snapshot)
        ;; Make the published tick and cursor position stale before the
        ;; redisplay cache is populated.
        (erase-buffer)
        (insert "x\n")
        (goto-char (point-min))
        (unwind-protect
            (progn
              (let ((redisplay-skip-initial-frame nil))
                (redisplay 'force))
              (should (= (point) (point-min)))
              (should (= (window-point window) (point-min))))
          (multi-cursor--set-redisplay-snapshot window nil))))))

(ert-deftest multi-cursor-redisplay-resolves-same-continuation-row-safely ()
  "Sorted cursors on one continued row should share redisplay resolution."
  (unless (and (fboundp 'multi-cursor--set-redisplay-snapshot)
               (subrp (symbol-function
                       'multi-cursor--set-redisplay-snapshot)))
    (ert-skip "Fresh native multiple-cursor test binary is unavailable"))
  (with-temp-buffer
    (insert (make-string 500 ?x) "\n")
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((window (selected-window))
             (buffer (current-buffer))
             (width (max 20 (window-body-width window)))
             (first (+ (point-min) width 3))
             (second (+ first 4))
             (snapshot
              (vector buffer (buffer-chars-modified-tick)
                      1 first nil nil 'forward
                      2 second nil nil 'backward)))
        (goto-char (point-min))
        (multi-cursor--set-redisplay-snapshot window snapshot)
        (unwind-protect
            (progn
              (let ((redisplay-skip-initial-frame nil))
                (redisplay 'force))
              (should (= (point) (point-min)))
              (should (= (window-point window) (point-min))))
          (multi-cursor--set-redisplay-snapshot window nil))))))

(ert-deftest multi-cursor-presentation-shows-only-active-secondary-regions ()
  (with-temp-buffer
    (insert "abcdefghij")
    (goto-char 1)
    (multi-cursor-add-selection 6 3 t)
    (multi-cursor-add-selection 9 8 nil)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((window (selected-window)))
        (cl-letf (((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) nil)))
          (multi-cursor--publish-redisplay-snapshot window))
        (should (= (length multi-cursor--region-overlays) 1))
        (let ((region (car multi-cursor--region-overlays)))
          (should (= (overlay-start region) 3))
          (should (= (overlay-end region) 6))
          (should (eq (overlay-get region 'face)
                      'multi-cursor-region-face))
          (should (equal (overlay-get region 'priority) '(nil . 100)))
          (should (eq (overlay-get region 'window) window)))
        (should (= (length multi-cursor--caret-overlays) 2))
        (should (equal (overlay-get (car multi-cursor--caret-overlays)
                                    'priority)
                       '(nil . 101)))))))

(ert-deftest multi-cursor-presentation-tracks-edits ()
  (with-temp-buffer
    (insert "abcdefghij")
    (goto-char 1)
    (multi-cursor-add-selection 6 3 t)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((window (selected-window)))
        (cl-letf (((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) nil)))
          (multi-cursor--publish-redisplay-snapshot window)
          (let ((old-region (car multi-cursor--region-overlays))
                (old-caret (car multi-cursor--caret-overlays)))
            (goto-char 2)
            (insert "XX")
            (multi-cursor--publish-redisplay-snapshot window)
            (should (eq (car multi-cursor--region-overlays) old-region))
            (should (eq (car multi-cursor--caret-overlays) old-caret))))
        (let ((region (car multi-cursor--region-overlays))
              (caret (car multi-cursor--caret-overlays)))
          (should (= (overlay-start region) 5))
          (should (= (overlay-end region) 8))
          (should (= (overlay-start caret) 8)))))))

(ert-deftest multi-cursor-presentation-native-and-fallback-carets-exclude-each-other ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 1)
    (multi-cursor-add-selection 4 2 t)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((window (selected-window))
            (multi-cursor--redisplay-window nil)
            published)
        (cl-letf (((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) nil))
                  ((symbol-function 'multi-cursor--set-redisplay-snapshot)
                   (lambda (_window snapshot) (push snapshot published))))
          (multi-cursor--publish-redisplay-snapshot window))
        (should (equal published '(nil)))
        (should (= (length multi-cursor--caret-overlays) 1))
        (should (= (length multi-cursor--region-overlays) 1))
        (should (eq (overlay-get (car multi-cursor--caret-overlays) 'face)
                    'multi-cursor-caret-face))
        (cl-letf (((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) t))
                  ((symbol-function 'multi-cursor--set-redisplay-snapshot)
                   (lambda (_window snapshot) (push snapshot published))))
          (multi-cursor--publish-redisplay-snapshot window))
        (should (vectorp (car published)))
        (should-not multi-cursor--caret-overlays)
        (should (= (length multi-cursor--region-overlays) 1))))))

(ert-deftest multi-cursor-presentation-follows-selected-window ()
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 1)
    (multi-cursor-add-at-point 4)
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer (current-buffer))
      (let* ((first (selected-window))
             (second (split-window-right))
             (multi-cursor--redisplay-window nil))
        (set-window-buffer second (current-buffer))
        (cl-letf (((symbol-function
                    'multi-cursor--native-cursor-decorations-p)
                   (lambda (_window) nil)))
          (select-window first)
          (multi-cursor--publish-redisplay-snapshot first)
          (should (eq (overlay-get (car multi-cursor--caret-overlays) 'window)
                      first))
          (select-window second)
          (multi-cursor--publish-redisplay-snapshot second)
          (should (eq (overlay-get (car multi-cursor--caret-overlays) 'window)
                      second)))))))

(ert-deftest multi-cursor-presentation-native-capability-validates-window ()
  (unless (and (fboundp 'multi-cursor--native-decorations-p)
               (subrp (symbol-function
                       'multi-cursor--native-decorations-p)))
    (ert-skip "Fresh native multiple-cursor test binary is unavailable"))
  (should-error (multi-cursor--native-decorations-p nil)
                :type 'wrong-type-argument)
  (save-window-excursion
    (let ((dead-window (split-window-right)))
      (delete-window dead-window)
      (should-error (multi-cursor--native-decorations-p dead-window)
                    :type 'error))))

(ert-deftest multi-cursor-presentation-cleans-up-on-disable-and-buffer-kill ()
  (dolist (event '(disable kill))
    (let ((buffer (generate-new-buffer " *multi-cursor-presentation*"))
          overlays)
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buffer)
            (with-current-buffer buffer
              (insert "abcdefgh")
              (goto-char 1)
              (multi-cursor-add-selection 7 3 t)
              (cl-letf (((symbol-function
                          'multi-cursor--native-cursor-decorations-p)
                         (lambda (_window) nil)))
                (multi-cursor--publish-redisplay-snapshot
                 (selected-window)))
              (setq overlays
                    (append multi-cursor--region-overlays
                            multi-cursor--caret-overlays))
              (should (= (length overlays) 2))
              (if (eq event 'disable)
                  (multi-cursor-mode -1)
                (kill-buffer buffer)))
            (dolist (overlay overlays)
              (should-not (overlay-buffer overlay))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest multi-cursor-keyboard-quit-deactivates-then-exits ()
  (with-temp-buffer
    (insert "abcdefghij")
    (goto-char 2)
    (push-mark 5 t t)
    (multi-cursor-add-selection 9 7 t)
    (let* ((before (buffer-string))
           (deactivations 0)
           (deactivate-mark-hook
            (list (lambda () (setq deactivations (1+ deactivations)))))
           (cursor (car multi-cursor--cursors))
           (secondary-mark
            (marker-position (multi-cursor--cursor-mark cursor)))
           (direction (multi-cursor--cursor-direction cursor)))
      (setf (multi-cursor--cursor-goal-column cursor) 12
            (multi-cursor--cursor-last-yank cursor) "token")
      (command-execute 'keyboard-quit)
      (should multi-cursor-mode)
      (should-not mark-active)
      (should (= deactivations 1))
      (should-not (multi-cursor--cursor-mark-active cursor))
      (should (= (mark) 5))
      (should (= (marker-position (multi-cursor--cursor-mark cursor))
                 secondary-mark))
      (should (eq (multi-cursor--cursor-direction cursor) direction))
      (should (= (multi-cursor--cursor-goal-column cursor) 12))
      (should (equal (multi-cursor--cursor-last-yank cursor) "token"))
      (should (equal (buffer-string) before))
      (command-execute 'keyboard-quit)
      (should (= deactivations 1))
      (should-not multi-cursor-mode)
      (should-not multi-cursor--cursors)
      (should (equal (buffer-string) before)))))

(ert-deftest multi-cursor-kill-region-publishes-buffer-order-text-once ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    ;; Make the primary selection the later one, so cursor creation order
    ;; cannot accidentally define the kill-ring payload order.
    (goto-char 9)
    (set-mark 7)
    (activate-mark)
    (multi-cursor-add-selection 5 3 t)
    (let* ((kill-ring nil)
           (kill-ring-yank-pointer nil)
           (last-command 'unrelated)
           (interprogram-cut-calls nil)
           (interprogram-cut-function
            (lambda (text &optional _push)
              (push text interprogram-cut-calls))))
      (command-execute 'kill-region)
      (should (equal (buffer-string) "aabbcc"))
      (should (equal kill-ring '("XXYY")))
      (should (eq kill-ring-yank-pointer kill-ring))
      (should (equal interprogram-cut-calls '("XXYY")))
      (should (eq this-command 'kill-region)))))

(ert-deftest multi-cursor-kill-region-appends-by-primary-direction ()
  (dolist (backward '(nil t))
    (with-temp-buffer
      (insert "aaXXbbYYcc")
      (if backward
          (progn (goto-char 7) (set-mark 9))
        (goto-char 9) (set-mark 7))
      (activate-mark)
      (multi-cursor-add-selection 5 3 t)
      (let ((kill-ring (list "OLD"))
            (kill-ring-yank-pointer nil)
            (last-command 'kill-region)
            (interprogram-cut-function nil))
        (command-execute 'kill-region)
        (should (equal (buffer-string) "aabbcc"))
        (should (equal kill-ring
                       (list (if backward "XXYYOLD" "OLDXXYY"))))))))

(ert-deftest multi-cursor-kill-region-overlap-keeps-payload-and-deletes-union ()
  (with-temp-buffer
    (insert "abcdefghij")
    (goto-char 7)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 9 5 t)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (interprogram-cut-function nil))
      (command-execute 'kill-region)
      (should (equal (buffer-string) "abij"))
      ;; Each cursor contributes its original text, but overlapping buffer
      ;; text is deleted only once by the merged edit transaction.
      (should (equal kill-ring '("cdefefgh"))))))

(ert-deftest multi-cursor-copy-region-publishes-without-editing ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 9 7 t)
    (let* ((before (buffer-string))
           (kill-ring nil)
           (kill-ring-yank-pointer nil)
           (last-command 'unrelated)
           (cut-calls 0)
           (interprogram-cut-function
            (lambda (_text &optional _push) (cl-incf cut-calls))))
      (command-execute 'copy-region-as-kill)
      (should (equal (buffer-string) before))
      (should (equal kill-ring '("XXYY")))
      (should (eq kill-ring-yank-pointer kill-ring))
      (should (= cut-calls 1))
      ;; The real command loop consumes this flag after dispatch and
      ;; deactivates the primary mark in the ordinary way.
      (should deactivate-mark)
      (should-not (multi-cursor--cursor-mark-active
                   (car multi-cursor--cursors))))))

(ert-deftest multi-cursor-kill-ring-save-uses-copy-policy ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 9 7 t)
    (let ((before (buffer-string))
          (kill-ring nil)
          (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil))
      (should (eq (car (gethash 'kill-ring-save
                                multi-cursor--command-policies))
                  'custom-handler))
      (command-execute 'kill-ring-save)
      (should (equal (buffer-string) before))
      (should (equal kill-ring '("XXYY")))
      (should-not mark-active)
      (should-not (multi-cursor--cursor-mark-active
                   (car multi-cursor--cursors))))))

(ert-deftest multi-cursor-kill-preflight-failure-does-not-edit-or-publish ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 9 7 t)
    (put-text-property 7 9 'read-only t)
    (let* ((before (buffer-substring-no-properties 1 (point-max)))
           (kill-ring '("old"))
           (last-command 'unrelated)
           (cut-calls 0)
           (interprogram-cut-function
            (lambda (_text &optional _push) (cl-incf cut-calls))))
      (should-error (command-execute 'kill-region) :type 'text-read-only)
      (should (equal (buffer-substring-no-properties 1 (point-max))
                     before))
      (should (equal kill-ring '("old")))
      (should (= cut-calls 0)))))

(ert-deftest multi-cursor-kill-transaction-failure-rolls-back ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 9 7 t)
    (let ((before (buffer-string))
          (before-change-functions
           (list (lambda (beg _end)
                   (when (= beg 7)
                     (error "Kill change hook failed")))))
          (kill-ring '("old"))
          (last-command 'unrelated)
          (interprogram-cut-function nil))
      (should-error (command-execute 'kill-region) :type 'error)
      (should (equal (buffer-string) before))
      (should (equal kill-ring '("old")))
      (should (= (point) 5))
      (should mark-active)
      (should (equal (mapcar (lambda (selection)
                               (cons (plist-get selection :mark)
                                     (plist-get selection :point)))
                             (multi-cursor-selections))
                     '((7 . 9)))))))

(ert-deftest multi-cursor-kill-ring-update-failure-restores-everything ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 9 7 t)
    (let* ((before (buffer-string))
           (old-entry "old")
           (kill-ring (list old-entry))
           (kill-ring-yank-pointer kill-ring)
           (old-pointer kill-ring-yank-pointer)
           (kill-ring-max 'invalid)
           (last-command 'unrelated)
           (interprogram-cut-function nil))
      (should-error (command-execute 'kill-region)
                    :type 'wrong-type-argument)
      (should (equal (buffer-string) before))
      (should (equal kill-ring (list old-entry)))
      (should (eq kill-ring-yank-pointer old-pointer))
      (should (= (point) 5))
      (should mark-active)
      (should (equal (mapcar (lambda (selection)
                               (cons (plist-get selection :mark)
                                     (plist-get selection :point)))
                             (multi-cursor-selections))
                     '((7 . 9)))))))

(ert-deftest multi-cursor-kill-commands-record-replayable-history ()
  (dolist (command '(kill-region copy-region-as-kill kill-ring-save))
    (with-temp-buffer
      (insert "aaXXbbYYcc")
      (goto-char 5)
      (set-mark 3)
      (activate-mark)
      (multi-cursor-add-selection 9 7 t)
      (let ((command-history nil)
            (kill-ring nil)
            (kill-ring-yank-pointer nil)
            (interprogram-cut-function nil))
        (command-execute command t)
        (should (equal command-history
                       (list (list command 3 5 '(quote region)))))))))

(ert-deftest multi-cursor-kill-transform-error-restores-ring-and-buffer ()
  (dolist (command '(kill-region copy-region-as-kill))
    (with-temp-buffer
      (insert "aaXXbbYYcc")
      (goto-char 5)
      (set-mark 3)
      (activate-mark)
      (multi-cursor-add-selection 9 7 t)
      (let* ((before (buffer-string))
             (old-entry "OLD")
             (kill-ring (list old-entry))
             (kill-ring-yank-pointer kill-ring)
             (old-pointer kill-ring-yank-pointer)
             (last-command 'unrelated)
             (interprogram-cut-function nil)
             (kill-transform-function
              (lambda (_text)
                (setcar kill-ring "MUTATED")
                (setq kill-ring-yank-pointer nil)
                (error "Kill transform failed"))))
        (should-error (command-execute command) :type 'error)
        (should (equal (buffer-string) before))
        (should (equal kill-ring (list old-entry)))
        (should (eq kill-ring-yank-pointer old-pointer))
        (should (= (point) 5))
        (should mark-active)
        (should (multi-cursor--cursor-mark-active
                 (car multi-cursor--cursors)))))))

(ert-deftest multi-cursor-kill-transform-cursor-mutation-rolls-back ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (let* ((id (multi-cursor-add-selection 9 7 t))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (kill-ring nil)
           (kill-ring-yank-pointer nil)
           (last-command 'unrelated)
           (interprogram-cut-function nil)
           (kill-transform-function
            (lambda (text)
              (set-marker (multi-cursor--cursor-point cursor) 6)
              (setf (multi-cursor--cursor-goal-column cursor) 99)
              text)))
      (should-error (command-execute 'kill-region) :type 'error)
      (should (equal (buffer-string) before))
      (should-not kill-ring)
      (should (= (point) 5))
      (should mark-active)
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 9))
      (should (= (marker-position (multi-cursor--cursor-mark cursor)) 7))
      (should-not (multi-cursor--cursor-goal-column cursor))
      (should (multi-cursor--cursor-mark-active cursor)))))

(ert-deftest multi-cursor-kill-equal-start-payload-order-is-deterministic ()
  (with-temp-buffer
    (insert "abcdefghij")
    (goto-char 7)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 5 3 t)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (interprogram-cut-function nil))
      (command-execute 'kill-region)
      (should (equal (buffer-string) "abghij"))
      ;; Equal starts are ordered by stable cursor identity: primary first.
      (should (equal kill-ring '("cdefcd"))))))

(ert-deftest multi-cursor-kill-rejects-nonlinear-region-bounds ()
  (with-temp-buffer
    (insert "aaXXbbYYcc")
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (multi-cursor-add-selection 9 7 t)
    (let ((before (buffer-string))
          (kill-ring '("OLD"))
          (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil)
          (region-extract-function
           (lambda (method)
             (if (eq method 'bounds)
                 '((3 . 4) (4 . 5))
               (error "Unexpected extraction method")))))
      (should-error (command-execute 'kill-region) :type 'user-error)
      (should (equal (buffer-string) before))
      (should (equal kill-ring '("OLD")))
      (should (= (point) 5))
      (should mark-active)
      (should (multi-cursor--cursor-mark-active
               (car multi-cursor--cursors))))))

(ert-deftest multi-cursor-region-bounds-callback-mutation-rolls-back ()
  (dolist (mutation '(primary secondary buffer))
    (with-temp-buffer
      (insert "aaXXbbYYcc")
      (goto-char 5)
      (set-mark 3)
      (activate-mark)
      (let* ((id (multi-cursor-add-selection 9 7 t))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (kill-ring '("OLD"))
             (kill-ring-yank-pointer nil)
             (interprogram-cut-function nil)
             (region-extract-function
              (lambda (method)
                (unless (eq method 'bounds)
                  (error "Unexpected extraction method"))
                (pcase mutation
                  ('primary (goto-char 6))
                  ('secondary
                   (set-marker (multi-cursor--cursor-point cursor) 10))
                  ('buffer (insert "MUTATED")))
                '((3 . 5)))))
        (should-error (command-execute 'kill-region) :type 'error)
        (should (equal (buffer-string) before))
        (should (equal kill-ring '("OLD")))
        (should (= (point) 5))
        (should (= (mark) 3))
        (should mark-active)
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 9))
        (should (= (marker-position (multi-cursor--cursor-mark cursor)) 7))
        (should (multi-cursor--cursor-mark-active cursor))))))

(ert-deftest multi-cursor-yank-snapshots-interprogram-paste-once ()
  (with-temp-buffer
    (insert "ab--cd")
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 5))
           (paste-calls 0)
           (kill-ring '("old"))
           (kill-ring-yank-pointer nil)
           (interprogram-paste-function
            (lambda ()
              (cl-incf paste-calls)
              "P"))
           (last-command 'unrelated))
      (command-execute 'yank)
      (should (= paste-calls 1))
      (should (equal (buffer-string) "aPb--Pcd"))
      (should (= (point) 3))
      (should (= (mark) 2))
      (should-not mark-active)
      (let ((cursor (multi-cursor-tests--cursor id)))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 7))
        (should (= (marker-position (multi-cursor--cursor-mark cursor)) 6))
        (should-not (multi-cursor--cursor-mark-active cursor)))
      (should (eq this-command 'yank))
      (should (eq last-command 'unrelated)))))

(ert-deftest multi-cursor-yank-prefix-preserves-reversed-mark-direction ()
  (with-temp-buffer
    (insert "ab--cd")
    (goto-char 2)
    (let ((id (multi-cursor-add-at-point 5))
          (kill-ring '("XY"))
          (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil)
          (prefix-arg '(4)))
      (command-execute 'yank)
      (should (equal (buffer-string) "aXYb--XYcd"))
      (should (= (point) 2))
      (should (= (mark) 4))
      (should-not mark-active)
      (let ((cursor (multi-cursor-tests--cursor id)))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 7))
        (should (= (marker-position (multi-cursor--cursor-mark cursor)) 9))
        (should (eq (multi-cursor--cursor-direction cursor) 'backward))))))

(ert-deftest multi-cursor-yank-cons-prefix-records-quoted-history ()
  (with-temp-buffer
    (insert "ab--cd")
    (goto-char 2)
    (multi-cursor-add-at-point 5)
    (let ((command-history nil)
          (kill-ring '("XY"))
          (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil)
          (prefix-arg '(4)))
      (command-execute 'yank t)
      (should (equal command-history '((yank '(4)))))
      (should (equal (eval (cadar command-history) t) '(4))))))

(ert-deftest multi-cursor-yank-transform-cursor-mutation-rolls-back ()
  (with-temp-buffer
    (insert "abcd")
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 4))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (payload "X")
           (kill-ring (list payload))
           (kill-ring-yank-pointer nil)
           (interprogram-paste-function nil)
           (yank-transform-functions
            (list (lambda (text)
                    (set-marker (multi-cursor--cursor-point cursor) 3)
                    (setf (multi-cursor--cursor-last-yank cursor) 'mutated)
                    text))))
      (should-error (command-execute 'yank) :type 'error)
      (should (equal (buffer-string) before))
      (should (= (point) 2))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 4))
      (should-not (multi-cursor--cursor-last-yank cursor))
      (should (equal (car kill-ring) payload)))))

(ert-deftest multi-cursor-yank-replaces-selections-in-one-undo-unit ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "aaXXbbYYcc")
    (undo-boundary)
    (goto-char 5)
    (set-mark 3)
    (activate-mark)
    (let ((id (multi-cursor-add-selection 9 7 t))
          (kill-ring '("Z"))
          (kill-ring-yank-pointer nil)
          (interprogram-paste-function nil))
      (command-execute 'yank)
      (should (equal (buffer-string) "aaZbbZcc"))
      (should (= (point) 4))
      (should (= (mark) 3))
      (should-not mark-active)
      (let ((cursor (multi-cursor-tests--cursor id)))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 7))
        (should (= (marker-position (multi-cursor--cursor-mark cursor)) 6))
        (should-not (multi-cursor--cursor-mark-active cursor)))
      (multi-cursor-mode -1)
      (undo-boundary)
      (undo 1)
      (should (equal (buffer-string) "aaXXbbYYcc")))))

(ert-deftest multi-cursor-yank-rejects-custom-yank-handler-atomically ()
  (with-temp-buffer
    (insert "abcd")
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let* ((before (buffer-string))
           (payload (propertize "X" 'yank-handler '(ignore token)))
           (kill-ring (list payload))
           (kill-ring-yank-pointer nil)
           (interprogram-paste-function nil))
      (should-error (command-execute 'yank) :type 'user-error)
      (should (equal (buffer-string) before))
      (should (= (point) 2))
      (should (equal (mapcar (lambda (selection)
                               (plist-get selection :point))
                             (multi-cursor-selections))
                     '(4)))
      (should (equal-including-properties (car kill-ring) payload)))))

(ert-deftest multi-cursor-yank-property-handler-error-rolls-back-text ()
  (with-temp-buffer
    (insert "abcd")
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let* ((before (buffer-string))
           (payload (propertize "X" 'multi-cursor-test-property t))
           (kill-ring (list payload))
           (kill-ring-yank-pointer nil)
           (interprogram-paste-function nil)
           (yank-handled-properties
            (list
             (cons 'multi-cursor-test-property
                   (lambda (_value beg end)
                     (delete-region beg end)
                     (insert "MUTATED")
                     (error "Yank property handler failed"))))))
      (should-error (command-execute 'yank) :type 'error)
      (should (equal (buffer-string) before))
      (should (= (point) 2))
      (should (equal (mapcar (lambda (selection)
                               (plist-get selection :point))
                             (multi-cursor-selections))
                     '(4)))
      (should (equal-including-properties (car kill-ring) payload)))))

(ert-deftest multi-cursor-yank-pop-remains-unsupported ()
  (with-temp-buffer
    (insert "abcd")
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((before (buffer-string))
          (kill-ring '("new" "old"))
          (kill-ring-yank-pointer nil))
      (should (eq (car (gethash 'yank-pop multi-cursor--command-policies))
                  'unsupported))
      (should-error (command-execute 'yank-pop) :type 'user-error)
      (should (equal (buffer-string) before))
      (should (equal kill-ring '("new" "old"))))))

(provide 'multi-cursor-tests)

;;; multi-cursor-tests.el ends here

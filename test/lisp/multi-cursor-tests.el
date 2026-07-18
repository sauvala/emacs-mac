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

(defvar multi-cursor-tests--undo-change-count 0)

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

(defmacro multi-cursor-tests--with-plain-newline (&rest body)
  "Run BODY with every side-effectful ordinary newline feature disabled."
  (declare (indent 0) (debug t))
  `(let ((abbrev-mode nil)
         (auto-fill-function nil)
         (electric-indent-mode nil)
         (left-margin 0)
         (overwrite-mode nil)
         (post-self-insert-hook nil)
         (translation-table-for-input nil)
         (use-hard-newlines nil))
     ,@body))

(defmacro multi-cursor-tests--with-electric-newline (&rest body)
  "Run BODY with the bounded stock electric-newline contract enabled."
  (declare (indent 0) (debug t))
  `(let ((abbrev-mode nil)
         (auto-fill-function nil)
         (electric-indent-chars '(?\n))
         (electric-indent-functions nil)
         (electric-indent-functions-without-reindent '(indent-relative))
         (electric-indent-inhibit nil)
         (electric-indent-mode t)
         (indent-line-function #'indent-relative)
         (indent-line-ignored-functions '(indent-relative))
         (indent-tabs-mode nil)
         (left-margin 0)
         (overwrite-mode nil)
         (post-self-insert-hook
          '(electric-indent-post-self-insert-function))
         (syntax-propertize-function nil)
         (tab-width 8)
         (translation-table-for-input nil)
         (use-hard-newlines nil))
     ,@body))

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
  ;; DEL resolves to the guarded raw backward command in this build, but the
  ;; higher-level untabifying command is also a native batch edit.
  (should (eq (lookup-key global-map (kbd "DEL"))
              'delete-backward-char))
  (should (eq (car (gethash 'backward-delete-char-untabify
                            multi-cursor--command-policies))
              'batch-edit))
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

(ert-deftest multi-cursor-edit-transaction-cancels-with-failing-hooks-inhibited ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcdef")
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 5))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (states (multi-cursor--snapshot-edit-states))
           (groups
            (multi-cursor--merge-edits
             (mapcar
              (lambda (state)
                (multi-cursor--state-edit
                 state 'self-insert-command 1 "X"))
              states)))
           rolling-back)
      (let ((after-change-functions
             (list (lambda (&rest _)
                     (when rolling-back
                       (error "Rollback hook failed"))))))
        (should-error
         (multi-cursor--apply-edit-transaction
          states groups
          (lambda (&rest _)
            (setq rolling-back t)
            (error "Installer failed")))))
      (should (equal (buffer-string) before))
      (should (= (point) 2))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 5)))))

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
  (ert-with-test-buffer (:selected t)
    (insert "a\tX\nab\tY")
    (setq-local tab-width 4)
    (use-local-map (let ((map (make-sparse-keymap)))
                     (define-key map (kbd "DEL")
                                 #'backward-delete-char-untabify)
                     map))
    (goto-char 3)
    (multi-cursor-add-at-point 8)
    (let ((backward-delete-char-untabify-method 'untabify))
      (ert-play-keys (kbd "DEL")))
    (should (equal (buffer-string) "a  X\nab Y"))))

(ert-deftest multi-cursor-edit-backward-untabify-methods ()
  (with-temp-buffer
    (insert "abX\ncdY")
    (goto-char 3)
    (multi-cursor-add-at-point 7)
    (let ((backward-delete-char-untabify-method nil))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "aX\ncY")))
  (with-temp-buffer
    (insert "a\tX\nab\tY")
    (setq-local tab-width 4)
    (goto-char 3)
    (multi-cursor-add-at-point 8)
    (let ((backward-delete-char-untabify-method 'untabify))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "a  X\nab Y")))
  (with-temp-buffer
    (insert "a\tX\nab\tY")
    (setq-local tab-width 8)
    (goto-char 3)
    (multi-cursor-add-at-point 8)
    (let ((backward-delete-char-untabify-method 'untabify))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "a      X\nab     Y")))
  (with-temp-buffer
    (insert "a \t  X|b   Y")
    (goto-char 6)
    (multi-cursor-add-at-point 12)
    (let ((backward-delete-char-untabify-method 'hungry))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "aX|bY")))
  (with-temp-buffer
    (insert "a \t\n  X|b \n\tY")
    (goto-char 7)
    (multi-cursor-add-at-point 13)
    (let ((backward-delete-char-untabify-method 'all))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "aX|bY"))))

(ert-deftest multi-cursor-edit-backward-untabify-touching-tabs ()
  (with-temp-buffer
    (insert "\t\tX")
    (setq-local tab-width 4)
    (goto-char 3)
    (let* ((id (multi-cursor-add-at-point 2))
           (cursor (multi-cursor-tests--cursor id)))
      (let ((backward-delete-char-untabify-method 'untabify))
        (command-execute 'backward-delete-char-untabify))
      ;; Each tab independently becomes three spaces.  Touching replacements
      ;; must not be coalesced in a way that drops either expansion.
      (should (equal (buffer-string) "      X"))
      (should (= (point) 7))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 4)))))

(ert-deftest multi-cursor-edit-backward-untabify-same-start-no-op ()
  (dolist (primary-at-start '(t nil))
    (with-temp-buffer
      (insert "\tX")
      (setq-local tab-width 4)
      (goto-char (if primary-at-start 1 2))
      (let* ((id (multi-cursor-add-at-point
                  (if primary-at-start 2 1)))
             (cursor (multi-cursor-tests--cursor id)))
        (let ((backward-delete-char-untabify-method 'untabify))
          (command-execute 'backward-delete-char-untabify))
        (should (equal (buffer-string) "   X"))
        (should (= (point) (if primary-at-start 1 4)))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   (if primary-at-start 4 1)))
        (should (= (multi-cursor-count) 2))
        (should (= (multi-cursor--cursor-id cursor) id))))))

(ert-deftest multi-cursor-edit-backward-untabify-policy-mutation-rolls-back ()
  (dolist (policy '(method tab-width))
    (with-temp-buffer
      (insert "a\tX\nb\tY")
      (setq-local tab-width 4)
      (goto-char 3)
      (let* ((id (multi-cursor-add-at-point 7))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (original-constrain
              (symbol-function 'constrain-to-field))
             (backward-delete-char-untabify-method 'untabify))
        (cl-letf (((symbol-function 'constrain-to-field)
                   (lambda (&rest arguments)
                     (if (eq policy 'method)
                         (setq backward-delete-char-untabify-method 'hungry)
                       (setq tab-width 8))
                     (apply original-constrain arguments))))
          (should-error
           (command-execute 'backward-delete-char-untabify)
           :type 'error))
        (should (equal (buffer-string) before))
        (should (= tab-width 4))
        (should (eq backward-delete-char-untabify-method 'untabify))
        (should (= (point) 3))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   7))
        (should (= (multi-cursor-count) 2))))))

(ert-deftest multi-cursor-edit-backward-untabify-active-region-policy ()
  (with-temp-buffer
    (insert "0123456789")
    (goto-char 4)
    (set-mark 2)
    (activate-mark)
    (multi-cursor-add-selection 10 8 t)
    (let ((backward-delete-char-untabify-method 'all)
          (delete-active-region t))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "034569")))
  (with-temp-buffer
    (insert "abc def")
    (goto-char 4)
    (set-mark 1)
    (activate-mark)
    (multi-cursor-add-selection 8 5 t)
    (let ((backward-delete-char-untabify-method nil)
          (delete-active-region nil))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "ab de")))
  (with-temp-buffer
    (insert "0123456789")
    (goto-char 4)
    (set-mark 2)
    (activate-mark)
    (multi-cursor-add-selection 10 8 t)
    (let ((backward-delete-char-untabify-method 'all)
          (delete-active-region 'kill)
          (kill-ring '("old"))
          (before (buffer-string)))
      (should-error (command-execute 'backward-delete-char-untabify)
                    :type 'user-error)
      (should (equal (buffer-string) before))
      (should (equal kill-ring '("old")))))
  (with-temp-buffer
    (insert "\tXY")
    (setq-local tab-width 4)
    (goto-char 3)
    (set-mark 1)
    (activate-mark)
    (multi-cursor-add-at-point 2)
    (let ((backward-delete-char-untabify-method 'untabify)
          (delete-active-region t)
          (before (buffer-string)))
      ;; Deleting a selection that overlaps another cursor's tab expansion
      ;; has no unambiguous combined replacement, so reject it atomically.
      (should-error (command-execute 'backward-delete-char-untabify)
                    :type 'user-error)
      (should (equal (buffer-string) before))
      (should (= (point) 3)))))

(ert-deftest multi-cursor-edit-backward-untabify-narrowed-boundary-no-op ()
  (with-temp-buffer
    (insert "outside abcd tail")
    (narrow-to-region 9 13)
    (goto-char (point-min))
    (multi-cursor-add-at-point (point-max))
    (let ((backward-delete-char-untabify-method nil))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "abc"))
    (should (= (point) (point-min)))))

(ert-deftest multi-cursor-edit-backward-untabify-overlapping-whitespace ()
  (with-temp-buffer
    (insert "a    X")
    (goto-char 4)
    (multi-cursor-add-at-point 6)
    (let ((backward-delete-char-untabify-method 'hungry))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "aX")))
  (with-temp-buffer
    (insert "a \n\t X")
    (goto-char 4)
    (multi-cursor-add-at-point 6)
    (let ((backward-delete-char-untabify-method 'all))
      (command-execute 'backward-delete-char-untabify))
    (should (equal (buffer-string) "aX"))))

(ert-deftest multi-cursor-edit-backward-untabify-preflight-rolls-back ()
  (dolist (failure '(read-only field hook))
    (with-temp-buffer
      (insert "a\tX\nb\tY")
      (setq-local tab-width 4)
      (goto-char 3)
      (let* ((id (multi-cursor-add-at-point 7))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (before-change-functions
              (when (eq failure 'hook)
                (list (lambda (beg _end)
                        (when (= beg 2)
                          (error "Untabify hook failed")))))))
        (when (eq failure 'read-only)
          (put-text-property 6 7 'read-only t))
        (let ((backward-delete-char-untabify-method 'untabify))
          (if (eq failure 'field)
              (cl-letf (((symbol-function 'constrain-to-field)
                         (lambda (new old &rest _)
                           (if (= old 7) old new))))
                (should-error
                 (command-execute 'backward-delete-char-untabify)
                 :type 'user-error))
            (should-error
             (command-execute 'backward-delete-char-untabify))))
        (should (equal (buffer-substring-no-properties
                        (point-min) (point-max))
                       before))
        (should (= (point) 3))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   7))))))

(ert-deftest multi-cursor-edit-backward-untabify-one-apply-undo-and-history ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "a\tX\nb\tY")
    (setq-local tab-width 4)
    (undo-boundary)
    (goto-char 3)
    (multi-cursor-add-at-point 7)
    (let ((backward-delete-char-untabify-method 'untabify)
          (command-history nil)
          (apply-count 0)
          (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                 (lambda (edits)
                   (cl-incf apply-count)
                   (funcall original-apply edits))))
        (command-execute 'backward-delete-char-untabify t))
      (should (= apply-count 1))
      (should (equal command-history
                     '((backward-delete-char-untabify 1))))
      (should (equal (buffer-string) "a  X\nb  Y")))
    (multi-cursor-mode -1)
    (undo-boundary)
    (undo 1)
    (should (equal (buffer-string) "a\tX\nb\tY"))))

(ert-deftest multi-cursor-edit-backward-untabify-prefix-and-overwrite-reject ()
  (dolist (condition '(prefix overwrite))
    (with-temp-buffer
      (insert "a\tX\nb\tY")
      (goto-char 3)
      (let* ((id (multi-cursor-add-at-point 7))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (kill-ring '("old"))
             (prefix-arg (and (eq condition 'prefix) 1))
             (overwrite-mode (eq condition 'overwrite))
             (backward-delete-char-untabify-method 'untabify))
        (should-error (command-execute 'backward-delete-char-untabify)
                      :type 'user-error)
        (should (equal (buffer-string) before))
        (should (equal kill-ring '("old")))
        (should (= (point) 3))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   7))))))

(ert-deftest multi-cursor-edit-newline-policy-and-real-return ()
  (let ((entry (gethash 'newline multi-cursor--command-policies)))
    (should (eq (car entry) 'batch-edit))
    (should (functionp (cdr entry))))
  (ert-with-test-buffer (:selected t)
    (should (eq (key-binding (kbd "RET")) 'newline))
    (should (eq (key-binding (kbd "C-j"))
                'electric-newline-and-maybe-indent))
    (should (eq (key-binding (kbd "TAB")) 'indent-for-tab-command))
    (should-not (gethash 'electric-newline-and-maybe-indent
                         multi-cursor--command-policies))
    (let ((tab-entry (gethash 'indent-for-tab-command
                              multi-cursor--command-policies)))
      (should (eq (car tab-entry) 'custom-handler))
      (should (functionp (cdr tab-entry))))
    (insert "ab\ncd")
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 5))
           (cursor (multi-cursor-tests--cursor id)))
      (multi-cursor-tests--with-plain-newline
        (ert-play-keys (kbd "RET")))
      (should (equal (buffer-string) "a\nb\nc\nd"))
      (should (= (point) 3))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 7)))))

(ert-deftest multi-cursor-edit-newline-unknown-keys-reject-atomically ()
  (dolist (command '(electric-newline-and-maybe-indent))
    (with-temp-buffer
      (insert "abcd")
      (goto-char 2)
      (multi-cursor-add-at-point 4)
      (let ((before (buffer-string)))
        (should-not (gethash command multi-cursor--command-policies))
        (should-error (command-execute command) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (= (point) 2))))))

(ert-deftest multi-cursor-edit-newline-same-position-coalesces ()
  ;; The public API prevents a secondary cursor at the primary point.  Test
  ;; replacement-safe merging directly so stale duplicate electric plans
  ;; coalesce without losing their common replacement payload.
  (let* ((primary (multi-cursor--edit-state-create
                   :id 0 :primary t :point 4 :mark 4))
         (secondary (multi-cursor--edit-state-create
                     :id 1 :point 4 :mark 3))
         (groups
          (multi-cursor--merge-edits
           (list
            (multi-cursor--edit-create
             :beg 2 :end 4 :string "\n  " :survivor primary
             :members (list primary))
            (multi-cursor--edit-create
             :beg 2 :end 4 :string "\n  " :survivor secondary
             :members (list secondary)))
           t)))
    (should (= (length groups) 1))
    (should (equal (multi-cursor--edit-string (car groups)) "\n  "))
    (should
     (multi-cursor--edit-state-primary
      (multi-cursor--edit-survivor (car groups))))
    (dolist (state (list primary secondary))
      (should
       (= (multi-cursor--remap-electric-newline-mark
           (multi-cursor--edit-state-mark state)
           (vconcat groups) [5])
          2)))
    (should-error
     (multi-cursor--merge-edits
      (list
       (multi-cursor--edit-create
        :beg 2 :end 4 :string "\n " :survivor primary
        :members (list primary))
       (multi-cursor--edit-create
        :beg 3 :end 4 :string "\n  " :survivor secondary
        :members (list secondary)))
      t)
     :type 'user-error)))

(ert-deftest multi-cursor-edit-newline-bounds-and-narrowing ()
  (with-temp-buffer
    (insert "outside abcd tail")
    (narrow-to-region 9 13)
    (goto-char (point-min))
    (let* ((id (multi-cursor-add-at-point (point-max)))
           (cursor (multi-cursor-tests--cursor id)))
      (multi-cursor-tests--with-plain-newline
        (command-execute 'newline))
      (should (equal (buffer-string) "\nabcd\n"))
      (should (= (point-min) 9))
      (should (= (point-max) 15))
      (should (= (point) 10))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 15)))))

(ert-deftest multi-cursor-edit-newline-prefix-and-selection-reject ()
  (dolist (prefix '(0 2 -1 (4)))
    (with-temp-buffer
      (insert "abcd")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 4))
             (cursor (multi-cursor-tests--cursor id))
             (prefix-arg prefix)
             (before (buffer-string)))
        (multi-cursor-tests--with-plain-newline
          (should-error (command-execute 'newline) :type 'user-error))
        (should (equal (buffer-string) before))
        (should (= (point) 2))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   4)))))
  (dolist (active-at '(primary secondary))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 3)
      (if (eq active-at 'primary)
          (progn
            (set-mark 1)
            (activate-mark)
            (multi-cursor-add-at-point 6))
        (multi-cursor-add-selection 6 4 t))
      (let ((before (buffer-string)))
        (multi-cursor-tests--with-plain-newline
          (should-error (command-execute 'newline) :type 'user-error))
        (should (equal (buffer-string) before))
        (should (= (multi-cursor-count) 2))))))

(ert-deftest multi-cursor-edit-newline-effect-gates-reject-atomically ()
  (dolist (gate '(minibuffer overwrite abbrev auto-fill hard-newline
                             translation-table
                             left-margin electric-indent post-hook))
    (with-temp-buffer
      (insert "abcd")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 4))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string)))
        (multi-cursor-tests--with-plain-newline
          (pcase gate
            ('overwrite (setq overwrite-mode 'overwrite-mode-textual))
            ('abbrev (setq abbrev-mode t))
            ('auto-fill (setq auto-fill-function #'ignore))
            ('hard-newline (setq use-hard-newlines t))
            ('translation-table
             (setq translation-table-for-input
                   (make-char-table 'translation-table)))
            ('left-margin (setq left-margin 2))
            ('electric-indent (setq electric-indent-mode t))
            ('post-hook (setq post-self-insert-hook (list #'ignore))))
          (if (eq gate 'minibuffer)
              (cl-letf (((symbol-function 'minibufferp)
                         (lambda (&optional _buffer) t)))
                (should-error (command-execute 'newline)
                              :type 'user-error))
            (should-error (command-execute 'newline) :type 'user-error)))
        (should (equal (buffer-string) before))
        (should (= (point) 2))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   4))))))

(ert-deftest multi-cursor-edit-newline-adjacent-properties-reject-atomically ()
  (dolist (placement '(primary-before primary-after primary-both
                                      secondary-before secondary-after
                                      secondary-both))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 3)
      (let* ((id (multi-cursor-add-at-point 6))
             (cursor (multi-cursor-tests--cursor id)))
        (when (memq placement '(primary-before primary-both))
          (put-text-property 2 3 'multi-cursor-test-property placement))
        (when (memq placement '(primary-after primary-both))
          (put-text-property 3 4 'multi-cursor-test-property placement))
        (when (memq placement '(secondary-before secondary-both))
          (put-text-property 5 6 'multi-cursor-test-property placement))
        (when (memq placement '(secondary-after secondary-both))
          (put-text-property 6 7 'multi-cursor-test-property placement))
        (let ((before (buffer-substring (point-min) (point-max))))
          (multi-cursor-tests--with-plain-newline
            (should-error (command-execute 'newline) :type 'user-error))
          (should (equal-including-properties
                   (buffer-substring (point-min) (point-max)) before))
          (should (= (point) 3))
          (should multi-cursor-mode)
          (should (= (multi-cursor-count) 2))
          (should (= (multi-cursor--cursor-id cursor) id))
          (should (= (marker-position
                      (multi-cursor--cursor-point cursor))
                     6)))))))

(ert-deftest multi-cursor-edit-newline-inaccessible-preceding-property-rejects ()
  (with-temp-buffer
    (insert "xabc")
    (put-text-property 1 2 'multi-cursor-test-property 'outside)
    (narrow-to-region 2 5)
    (goto-char (point-min))
    (let* ((id (multi-cursor-add-at-point (point-max)))
           (cursor (multi-cursor-tests--cursor id))
           (before (save-restriction
                     (widen)
                     (buffer-substring (point-min) (point-max)))))
      (multi-cursor-tests--with-plain-newline
        (should-error (command-execute 'newline) :type 'user-error))
      (should (equal-including-properties
               (save-restriction
                 (widen)
                 (buffer-substring (point-min) (point-max)))
               before))
      (should (= (point-min) 2))
      (should (= (point-max) 5))
      (should (= (point) 2))
      (should multi-cursor-mode)
      (should (= (multi-cursor-count) 2))
      (should (= (multi-cursor--cursor-id cursor) id))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 5)))))

(ert-deftest multi-cursor-edit-newline-preflight-rolls-back ()
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
                          (error "Newline hook failed")))))))
        (when (eq failure 'read-only)
          (setq buffer-read-only t))
        (multi-cursor-tests--with-plain-newline
          (if (eq failure 'field)
              (cl-letf (((symbol-function 'constrain-to-field)
                         (lambda (new old &rest _)
                           (if (= old 5) (1+ new) new))))
                (should-error (command-execute 'newline)
                              :type 'user-error))
            (should-error (command-execute 'newline))))
        (should (equal (buffer-substring-no-properties
                        (point-min) (point-max))
                       before))
        (should (= (point) 2))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   5))))))

(ert-deftest multi-cursor-edit-newline-policy-mutation-rolls-back ()
  (dolist (policy '(electric-indent post-hook translation-table))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 5))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (original-left-margin
              (symbol-function 'current-left-margin)))
        (multi-cursor-tests--with-plain-newline
          (cl-letf (((symbol-function 'current-left-margin)
                     (lambda ()
                       (pcase policy
                         ('electric-indent
                          (setq electric-indent-mode t))
                         ('post-hook
                          (setq post-self-insert-hook (list #'ignore)))
                         ('translation-table
                          (setq translation-table-for-input
                                (make-char-table 'translation-table))))
                       (funcall original-left-margin))))
            (should-error (command-execute 'newline) :type 'error)))
        (should (equal (buffer-string) before))
        (should (= (point) 2))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   5))))))

(ert-deftest multi-cursor-edit-newline-one-apply-undo-and-history ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((command-history nil)
          (apply-count 0)
          (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (multi-cursor-tests--with-plain-newline
        (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                   (lambda (edits)
                     (cl-incf apply-count)
                     (funcall original-apply edits))))
          (command-execute 'newline t)))
      (should (= apply-count 1))
      (should (equal command-history '((newline nil 1))))
      (should (equal (buffer-string) "a\nbc\nd")))
    (multi-cursor-mode -1)
    (undo-boundary)
    (undo 1)
    (should (equal (buffer-string) "abcd"))))

(ert-deftest multi-cursor-edit-newline-electric-stock-relative-ret ()
  (dolist (mode '(fundamental-mode text-mode))
    (dolist (syntax-function '(nil ignore))
      (ert-with-test-buffer (:selected t)
        (funcall mode)
        (insert "  alpha   \n    beta\t ")
        (goto-char (point-min))
        (end-of-line)
        (let* ((secondary-position
                (save-excursion
                  (forward-line 1)
                  (line-end-position)))
               (id (multi-cursor-add-at-point secondary-position))
               (cursor (multi-cursor-tests--cursor id)))
          (multi-cursor-tests--with-electric-newline
            (setq syntax-propertize-function syntax-function)
            (ert-play-keys (kbd "RET")))
          (should (equal (buffer-string)
                         "  alpha\n  \n    beta\n    "))
          (should (= (line-number-at-pos (point)) 2))
          (should (= (current-column) 2))
          (save-excursion
            (goto-char (marker-position
                        (multi-cursor--cursor-point cursor)))
            (should (= (line-number-at-pos) 4))
            (should (= (current-column) 4))))))))

(ert-deftest multi-cursor-edit-newline-electric-canonical-tabs-and-adjacent-lines ()
  (with-temp-buffer
    (insert "\t  alpha \t\n   beta ")
    (goto-char (point-min))
    (end-of-line)
    (let* ((secondary-position
            (save-excursion
              (forward-line 1)
              (line-end-position)))
           (id (multi-cursor-add-at-point secondary-position))
           (cursor (multi-cursor-tests--cursor id)))
      (multi-cursor-tests--with-electric-newline
        (let ((indent-tabs-mode t)
              (tab-width 4))
          (command-execute 'newline)))
      (should (equal (buffer-string)
                     "\t  alpha\n\t  \n   beta\n   "))
      (let ((tab-width 4))
        (should (= (current-column) 6))
        (save-excursion
          (goto-char (marker-position
                      (multi-cursor--cursor-point cursor)))
          (should (= (current-column) 3)))))))

(ert-deftest multi-cursor-edit-newline-electric-invalid-tab-width-uses-eight ()
  (dolist (bad-width '(invalid 0 -1 1001))
    (with-temp-buffer
      (insert "\t  alpha \n beta ")
      (goto-char (point-min))
      (end-of-line)
      (multi-cursor-add-at-point (point-max))
      (multi-cursor-tests--with-electric-newline
        (let ((indent-tabs-mode t)
              (tab-width bad-width))
          (command-execute 'newline)))
      (should (equal (buffer-string)
                     "\t  alpha\n\t  \n beta\n ")))))

(ert-deftest multi-cursor-edit-newline-electric-remaps-inactive-marks ()
  (with-temp-buffer
    (insert "  aa\n    bb")
    (goto-char 5)
    (set-mark 3)
    (setq mark-active nil)
    (let* ((id (multi-cursor-add-selection 12 6 nil))
           (cursor (multi-cursor-tests--cursor id)))
      (multi-cursor-tests--with-electric-newline
        (command-execute 'newline))
      (should (equal (buffer-string) "  aa\n  \n    bb\n    "))
      (should (= (point) 8))
      (should (= (mark t) 3))
      (should-not mark-active)
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 20))
      (should (= (marker-position
                  (multi-cursor--cursor-mark cursor))
                 9))
      (should-not (multi-cursor--cursor-mark-active cursor)))))

(ert-deftest multi-cursor-edit-newline-electric-marks-in-replacement-go-to-beg ()
  (with-temp-buffer
    (insert "  aa  \n    bb\t ")
    (goto-char (point-min))
    (end-of-line)
    (set-mark (point))
    (setq mark-active nil)
    (let* ((id (multi-cursor-add-selection
                (point-max) (1- (point-max)) nil))
           (cursor (multi-cursor-tests--cursor id)))
      (multi-cursor-tests--with-electric-newline
        (command-execute 'newline))
      (should (equal (buffer-string) "  aa\n  \n    bb\n    "))
      (should (= (point) 8))
      (should (= (mark t) 5))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 20))
      (should (= (marker-position
                  (multi-cursor--cursor-mark cursor))
                 15))
      (should-not mark-active)
      (should-not (multi-cursor--cursor-mark-active cursor))
      (should (= (multi-cursor-count) 2)))))

(ert-deftest multi-cursor-edit-newline-electric-narrowed-physical-lines ()
  (with-temp-buffer
    (insert "outside\n  a  \n    b  \noutside")
    (goto-char (point-min))
    (forward-line 1)
    (let ((beg (point)))
      (forward-line 1)
      (end-of-line)
      (narrow-to-region beg (point)))
    (goto-char (point-min))
    (end-of-line)
    (let* ((old-min (point-min))
           (old-max (point-max))
           (id (multi-cursor-add-at-point old-max))
           (cursor (multi-cursor-tests--cursor id)))
      (multi-cursor-tests--with-electric-newline
        (command-execute 'newline))
      (should (equal (buffer-string) "  a\n  \n    b\n    "))
      (should (= (point-min) old-min))
      (should (= (point-max) (+ old-max 4)))
      (should (= (point) (+ old-min 6)))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 (point-max))))))

(ert-deftest multi-cursor-edit-newline-electric-rejects-mid-physical-line ()
  (with-temp-buffer
    (insert "  a\n  alpha suffix")
    (goto-char (point-min))
    (end-of-line)
    (let ((id (multi-cursor-add-at-point
               (save-excursion
                 (forward-line 1)
                 (search-forward "alpha")
                 (point)))))
      (narrow-to-region (point-min)
                        (marker-position
                         (multi-cursor--cursor-point
                          (multi-cursor-tests--cursor id))))
      (let ((before
             (save-restriction
               (widen)
               (buffer-string)))
            (command-history nil))
        (multi-cursor-tests--with-electric-newline
          (should-error (command-execute 'newline)
                        :type 'user-error))
        (should (equal
                 (save-restriction
                   (widen)
                   (buffer-string))
                 before))
        (should-not command-history)))))

(ert-deftest multi-cursor-edit-newline-electric-property-gates ()
  (dolist (gate '(buffer-read-only text-leading text-trailing
                                   inheritance-boundary overlay-read-only))
    (with-temp-buffer
      (insert "  a  \n    b  ")
      (goto-char (point-min))
      (end-of-line)
      (let* ((primary-position (point))
             (id (multi-cursor-add-at-point (point-max)))
             (cursor (multi-cursor-tests--cursor id))
             overlay)
        (pcase gate
          ('buffer-read-only (setq buffer-read-only t))
          ('text-leading
           (put-text-property 1 2 'multi-cursor-test-property gate))
          ('text-trailing
           (put-text-property (1- primary-position) primary-position
                              'multi-cursor-test-property gate))
          ('inheritance-boundary
           (put-text-property primary-position (1+ primary-position)
                              'multi-cursor-test-property gate))
          ('overlay-read-only
           (setq overlay
                 (make-overlay (1- primary-position) primary-position))
           (overlay-put overlay 'read-only t)))
        (let ((before
               (buffer-substring (point-min) (point-max)))
              (command-history nil))
          (multi-cursor-tests--with-electric-newline
            (should-error (command-execute 'newline)))
          (should (equal-including-properties
                   (buffer-substring (point-min) (point-max))
                   before))
          (should (= (point) primary-position))
          (should (= (marker-position
                      (multi-cursor--cursor-point cursor))
                     (point-max)))
          (should-not command-history))
        (when overlay
          (delete-overlay overlay))))))

(ert-deftest multi-cursor-edit-newline-electric-field-boundary-rejects ()
  (with-temp-buffer
    (insert "  alpha  \n    beta  ")
    (goto-char (point-min))
    (end-of-line)
    (let* ((primary-position (point))
           (id (multi-cursor-add-at-point (point-max)))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (command-history nil)
           (original-constrain (symbol-function 'constrain-to-field)))
      (multi-cursor-tests--with-electric-newline
        (cl-letf (((symbol-function 'constrain-to-field)
                   (lambda (new old &rest arguments)
                     (if (= old primary-position)
                         (1+ new)
                       (apply original-constrain new old arguments)))))
          (should-error (command-execute 'newline)
                        :type 'user-error)))
      (should (equal (buffer-string) before))
      (should (= (point) primary-position))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 (point-max)))
      (should-not command-history))))

(ert-deftest multi-cursor-edit-newline-electric-does-not-invoke-callbacks ()
  (with-temp-buffer
    (insert "  alpha\n    beta")
    (goto-char (point-min))
    (end-of-line)
    (multi-cursor-add-at-point (point-max))
    (let ((post-calls 0)
          (indent-calls 0)
          (syntax-calls 0))
      (multi-cursor-tests--with-electric-newline
        (setq syntax-propertize-function #'ignore)
        (cl-letf (((symbol-function
                    'electric-indent-post-self-insert-function)
                   (lambda ()
                     (cl-incf post-calls)))
                  ((symbol-function 'indent-relative)
                   (lambda (&rest _)
                     (cl-incf indent-calls)))
                  ((symbol-function 'syntax-propertize)
                   (lambda (&rest _)
                     (cl-incf syntax-calls)))
                  ((symbol-function 'ignore)
                   (lambda (&rest _)
                     (cl-incf syntax-calls))))
          (command-execute 'newline)))
      (should (equal (buffer-string)
                     "  alpha\n  \n    beta\n    "))
      (should (zerop post-calls))
      (should (zerop indent-calls))
      (should (zerop syntax-calls)))))

(ert-deftest multi-cursor-edit-newline-electric-rejects-custom-contexts ()
  (dolist (gate '(non-eol electric-function custom-indent
                          emacs-lisp-indent c-indent custom-syntax
                          layout missing-trigger ignored-functions
                          reindent-functions unsafe-hook))
    (with-temp-buffer
      (insert "  a\n    b")
      (goto-char 4)
      (let* ((id (multi-cursor-add-at-point (point-max)))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (command-history nil)
             called)
        (multi-cursor-tests--with-electric-newline
          (pcase gate
            ('non-eol (backward-char))
            ('electric-function
             (setq electric-indent-functions
                   (list (lambda (_character)
                           (setq called t)))))
            ('custom-indent
             (setq indent-line-function
                   (lambda ()
                     (setq called t))))
            ('emacs-lisp-indent
             (setq indent-line-function #'lisp-indent-line))
            ('c-indent
             (setq indent-line-function 'c-indent-line))
            ('custom-syntax
             (setq syntax-propertize-function
                   (lambda (_start _end)
                     (setq called t))))
            ('layout
             (setq electric-indent-inhibit 'electric-layout-mode))
            ('missing-trigger
             (setq electric-indent-chars '(?\t)))
            ('ignored-functions
             (setq indent-line-ignored-functions nil))
            ('reindent-functions
             (setq electric-indent-functions-without-reindent nil))
            ('unsafe-hook
             (setq post-self-insert-hook
                   (list (lambda ()
                           (setq called t))))))
          (should-error (command-execute 'newline)
                        :type 'user-error))
        (should (equal (buffer-string) before))
        (should (= (point) (if (eq gate 'non-eol) 3 4)))
        (should (= (marker-position
                    (multi-cursor--cursor-point cursor))
                   (point-max)))
        (should-not called)
        (should-not command-history)))))

(ert-deftest multi-cursor-edit-newline-electric-planning-mutation-rolls-back ()
  (with-temp-buffer
    (insert "  a\n    b")
    (goto-char 4)
    (let* ((id (multi-cursor-add-at-point (point-max)))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (command-history nil)
           (original-left-margin
            (symbol-function 'current-left-margin)))
      (multi-cursor-tests--with-electric-newline
        (cl-letf (((symbol-function 'current-left-margin)
                   (lambda ()
                     (setq tab-width 4)
                     (funcall original-left-margin))))
          (should-error (command-execute 'newline)
                        :type 'error))
        (should (= tab-width 8)))
      (should (equal (buffer-string) before))
      (should (= (point) 4))
      (should (= (marker-position
                  (multi-cursor--cursor-point cursor))
                 (point-max)))
      (should-not command-history))))

(ert-deftest multi-cursor-edit-newline-electric-detects-new-local-binding ()
  (with-temp-buffer
    (insert "  a\n    b")
    (goto-char 4)
    (multi-cursor-add-at-point (point-max))
    (should-not (local-variable-p 'translation-table-for-input))
    (let ((original-left-margin
           (symbol-function 'current-left-margin))
          (command-history nil)
          (before (buffer-string)))
      (multi-cursor-tests--with-electric-newline
        (cl-letf (((symbol-function 'current-left-margin)
                   (lambda ()
                     (setq-local translation-table-for-input nil)
                     (funcall original-left-margin))))
          (should-error (command-execute 'newline)
                        :type 'error))
        (should-not (local-variable-p 'translation-table-for-input)))
      (should (equal (buffer-string) before))
      (should-not command-history))))

(ert-deftest multi-cursor-edit-newline-electric-restores-default-mutation ()
  (with-temp-buffer
    (insert "  a\n    b")
    (goto-char 4)
    (multi-cursor-add-at-point (point-max))
    (should-not (local-variable-p 'translation-table-for-input))
    (let ((original-default
           (copy-tree (default-value 'translation-table-for-input)))
          (command-history nil)
          (before (buffer-string)))
      (unwind-protect
          (multi-cursor-tests--with-electric-newline
            (let ((after-change-functions
                   (list
                    (lambda (&rest _)
                      (setq-default
                       translation-table-for-input '(changed))))))
              (should-error (command-execute 'newline)
                            :type 'error))
            (should
             (equal (default-value 'translation-table-for-input)
                    original-default))
            (should-not (local-variable-p 'translation-table-for-input)))
        (set-default 'translation-table-for-input original-default))
      (should (equal (buffer-string) before))
      (should-not command-history))))

(ert-deftest multi-cursor-edit-newline-electric-restores-mutated-char-table ()
  (let ((original-default (default-value 'translation-table-for-input))
        (table (make-char-table 'translation-table nil)))
    (set-char-table-range table ?a ?a)
    (unwind-protect
        (progn
          (set-default 'translation-table-for-input table)
          (with-temp-buffer
            (insert "  a\n    b")
            (goto-char 4)
            (multi-cursor-add-at-point (point-max))
            (setq-local translation-table-for-input nil)
            (let ((original-left-margin
                   (symbol-function 'current-left-margin))
                  (before (buffer-string))
                  (command-history nil))
              (multi-cursor-tests--with-electric-newline
                (cl-letf (((symbol-function 'current-left-margin)
                           (lambda ()
                             (set-char-table-range table ?a ?b)
                             (funcall original-left-margin))))
                  (should-error (command-execute 'newline)
                                :type 'error))
                (should (eq (default-value 'translation-table-for-input)
                            table))
                (should (= (char-table-range table ?a) ?a))
                (should (null translation-table-for-input)))
              (should (equal (buffer-string) before))
              (should-not command-history))))
      (set-default 'translation-table-for-input original-default))))

(ert-deftest multi-cursor-edit-newline-electric-rejects-equal-replacements ()
  (let ((original-default (default-value 'translation-table-for-input))
        (table (make-char-table 'translation-table nil)))
    (unwind-protect
        (progn
          (set-default 'translation-table-for-input table)
          (with-temp-buffer
            (insert "  a\n    b")
            (goto-char 4)
            (multi-cursor-add-at-point (point-max))
            (setq-local translation-table-for-input nil)
            (let ((chars (list ?\n))
                  (before (buffer-string))
                  (command-history nil))
              (multi-cursor-tests--with-electric-newline
                (setq-local electric-indent-chars chars)
                (let ((after-change-functions
                       (list
                        (lambda (&rest _)
                          (setq electric-indent-chars (list ?\n))
                          (setq-default
                           translation-table-for-input
                           (copy-sequence table))))))
                  (should-error (command-execute 'newline)
                                :type 'error))
                (should (eq electric-indent-chars chars))
                (should
                 (eq (default-value 'translation-table-for-input)
                     table)))
              (should (equal (buffer-string) before))
              (should-not command-history))))
      (set-default 'translation-table-for-input original-default))))

(ert-deftest multi-cursor-edit-newline-electric-rejects-equal-list-tail ()
  (with-temp-buffer
    (insert "  a\n    b")
    (goto-char 4)
    (multi-cursor-add-at-point (point-max))
    (let* ((chars (list ?\n ?x))
           (tail (cdr chars))
           (before (buffer-string))
           (command-history nil))
      (multi-cursor-tests--with-electric-newline
        (setq-local electric-indent-chars chars)
        (let ((after-change-functions
               (list
                (lambda (&rest _)
                  (setcdr chars (copy-sequence tail))))))
          (should-error (command-execute 'newline)
                        :type 'error))
        (should (eq electric-indent-chars chars))
        (should (eq (cdr chars) tail))
        (should (equal chars '(?\n ?x))))
      (should (equal (buffer-string) before))
      (should-not command-history))))

(ert-deftest multi-cursor-edit-newline-electric-rejects-equal-vector-child ()
  (with-temp-buffer
    (insert "  a\n    b")
    (goto-char 4)
    (multi-cursor-add-at-point (point-max))
    (let* ((child (list ?x))
           (vector (vector child))
           (chars (list ?\n vector))
           (before (buffer-string))
           (command-history nil))
      (multi-cursor-tests--with-electric-newline
        (setq-local electric-indent-chars chars)
        (let ((after-change-functions
               (list
                (lambda (&rest _)
                  (aset vector 0 (copy-sequence child))))))
          (should-error (command-execute 'newline)
                        :type 'error))
        (should (eq electric-indent-chars chars))
        (should (eq (aref vector 0) child))
        (should (equal chars (list ?\n (vector (list ?x))))))
      (should (equal (buffer-string) before))
      (should-not command-history))))

(ert-deftest multi-cursor-edit-newline-electric-restores-char-table-parent ()
  (let ((original-default (default-value 'translation-table-for-input))
        (parent (make-char-table 'translation-table nil))
        (table (make-char-table 'translation-table nil)))
    (set-char-table-range parent ?a ?a)
    (set-char-table-parent table parent)
    (unwind-protect
        (progn
          (set-default 'translation-table-for-input table)
          (with-temp-buffer
            (insert "  a\n    b")
            (goto-char 4)
            (multi-cursor-add-at-point (point-max))
            (setq-local translation-table-for-input nil)
            (let ((original-left-margin
                   (symbol-function 'current-left-margin))
                  (before (buffer-string))
                  (command-history nil))
              (multi-cursor-tests--with-electric-newline
                (cl-letf (((symbol-function 'current-left-margin)
                           (lambda ()
                             (set-char-table-range parent ?a ?b)
                             (funcall original-left-margin))))
                  (should-error (command-execute 'newline)
                                :type 'error))
                (should
                 (eq (default-value 'translation-table-for-input)
                     table))
                (should (eq (char-table-parent table) parent))
                (should (= (char-table-range parent ?a) ?a)))
              (should (equal (buffer-string) before))
              (should-not command-history))))
      (set-default 'translation-table-for-input original-default))))

(ert-deftest multi-cursor-edit-newline-electric-rejects-nested-equal-references ()
  (dolist (location '(default range extra-slot parent))
    (let ((original-default
           (default-value 'translation-table-for-input))
          (leaf (make-char-table 'translation-table nil))
          (middle (make-char-table 'translation-table nil))
          (table (make-char-table 'translation-table nil)))
      (set-char-table-range leaf ?a ?a)
      (set-char-table-parent middle leaf)
      (pcase location
        ('default (set-char-table-range table nil middle))
        ('range (set-char-table-range table ?b middle))
        ('extra-slot (set-char-table-extra-slot table 0 middle))
        ('parent (set-char-table-parent table middle)))
      (unwind-protect
          (progn
            (set-default 'translation-table-for-input table)
            (with-temp-buffer
              (insert "  a\n    b")
              (goto-char 4)
              (multi-cursor-add-at-point (point-max))
              (setq-local translation-table-for-input nil)
              (let ((before (buffer-string))
                    (command-history nil)
                    (replacement (copy-sequence middle)))
                (multi-cursor-tests--with-electric-newline
                  (let ((after-change-functions
                         (list
                          (lambda (&rest _)
                            (set-char-table-parent
                             middle (copy-sequence leaf))
                            (pcase location
                              ('default
                               (set-char-table-range
                                table nil replacement))
                              ('range
                               (set-char-table-range
                                table ?b replacement))
                              ('extra-slot
                               (set-char-table-extra-slot
                                table 0 replacement))
                              ('parent
                               (set-char-table-parent
                                table replacement)))))))
                    (should-error (command-execute 'newline)
                                  :type 'error))
                  (should
                   (eq (default-value 'translation-table-for-input)
                       table))
                  (should
                   (eq
                    (pcase location
                      ('default (char-table-range table nil))
                      ('range (char-table-range table ?b))
                      ('extra-slot (char-table-extra-slot table 0))
                      ('parent (char-table-parent table)))
                    middle))
                  (should (eq (char-table-parent middle) leaf))
                  (should (= (char-table-range leaf ?a) ?a)))
                (should (equal (buffer-string) before))
                (should-not command-history))))
        (set-default 'translation-table-for-input original-default)))))

(ert-deftest multi-cursor-edit-newline-electric-restores-option-aliases ()
  (dolist (failure '(unrelated mutation))
    (with-temp-buffer
      (insert "  a\n    b")
      (goto-char 4)
      (multi-cursor-add-at-point (point-max))
      (let ((chars (list ?\n))
            (hooks (list #'electric-indent-post-self-insert-function
                         #'blink-paren-post-self-insert-function))
            (original-left-margin
             (symbol-function 'current-left-margin))
            (before (buffer-string))
            (command-history nil))
        (multi-cursor-tests--with-electric-newline
          (setq-local electric-indent-chars chars)
          (setq-local post-self-insert-hook hooks)
          (cl-letf (((symbol-function 'current-left-margin)
                     (lambda ()
                       (if (eq failure 'unrelated)
                           (error "Unrelated electric planning failure")
                         (setcar chars ?\t)
                         (setcar hooks #'ignore)
                         (funcall original-left-margin)))))
            (should-error (command-execute 'newline)
                          :type 'error))
          (should (eq electric-indent-chars chars))
          (should (eq post-self-insert-hook hooks))
          (should (equal chars '(?\n)))
          (should
           (equal hooks
                  '(electric-indent-post-self-insert-function
                    blink-paren-post-self-insert-function))))
        (should (equal (buffer-string) before))
        (should-not command-history)))))

(ert-deftest multi-cursor-edit-newline-electric-dead-buffer-restores-default ()
  (let ((original-default (default-value 'translation-table-for-input))
        (source (generate-new-buffer " *multi-cursor-dead-newline*"))
        condition)
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "  a\n    b")
            (goto-char 4)
            (multi-cursor-add-at-point (point-max))
            (multi-cursor-tests--with-electric-newline
              (let ((after-change-functions
                     (list
                      (lambda (&rest _)
                        (setq-default
                         translation-table-for-input '(changed))
                        (kill-buffer source)))))
                (setq condition
                      (should-error (command-execute 'newline)
                                    :type 'error)))))
          (should-not (buffer-live-p source))
          (should
           (eq (default-value 'translation-table-for-input)
               original-default))
          (should-not
           (string-match-p
            "Selecting deleted buffer"
            (error-message-string condition))))
      (when (buffer-live-p source)
        (kill-buffer source))
      (set-default 'translation-table-for-input original-default))))

(ert-deftest multi-cursor-edit-newline-electric-blank-line-targets-zero ()
  (with-temp-buffer
    (insert " \t \n  text")
    (goto-char (point-min))
    (end-of-line)
    (multi-cursor-add-at-point (point-max))
    (multi-cursor-tests--with-electric-newline
      (command-execute 'newline))
    (should (equal (buffer-string) "\n\n  text\n  "))
    (should (= (point) 2))))

(ert-deftest multi-cursor-edit-newline-electric-hook-rollback ()
  (dolist (failure '(error option local-binding
                     session buffer restriction))
    (with-temp-buffer
      (let ((source (current-buffer))
            (other (generate-new-buffer " *multi-cursor-newline-hook*")))
        (unwind-protect
            (progn
              (insert "  a  \n    b  ")
              (goto-char (point-min))
              (end-of-line)
              (let* ((primary-position (point))
                     (id (multi-cursor-add-at-point (point-max)))
                     (cursor (multi-cursor-tests--cursor id))
                     (before (buffer-string))
                     (before-min (point-min))
                     (before-max (point-max))
                     (command-history nil)
                     (before-change-functions
                      (when (eq failure 'error)
                        (list (lambda (&rest _)
                                (error "Electric newline hook failed")))))
                     (after-change-functions
                      (unless (eq failure 'error)
                        (list
                         (lambda (&rest _)
                           (pcase failure
                             ('option
                              (setq electric-indent-chars nil))
                             ('local-binding
                              (setq-local translation-table-for-input nil))
                             ('session
                              (multi-cursor-mode -1))
                             ('buffer
                              (set-buffer other))
                             ('restriction
                              (narrow-to-region
                               (point-min) (1- (point-max))))))))))
                (ert-info ((format "Hook failure kind: %S" failure))
                (multi-cursor-tests--with-electric-newline
                  (should-error (command-execute 'newline))
                  (should (equal electric-indent-chars '(?\n)))
                  (when (eq failure 'local-binding)
                    (should-not
                     (local-variable-p 'translation-table-for-input))))
                (with-current-buffer source
                  (should (equal (buffer-string) before))
                  (should (= (point-min) before-min))
                  (should (= (point-max) before-max))
                  (should (= (point) primary-position))
                  (should multi-cursor-mode)
                  (should (= (multi-cursor-count) 2))
                  (should (= (marker-position
                              (multi-cursor--cursor-point cursor))
                             before-max))
                  (should-not command-history)))))
          (when (buffer-live-p other)
            (kill-buffer other)))))))

(ert-deftest multi-cursor-edit-newline-electric-one-apply-undo-and-history ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "  a  \n    b  ")
    (undo-boundary)
    (goto-char (point-min))
    (end-of-line)
    (multi-cursor-add-at-point (point-max))
    (let ((command-history nil)
          (apply-count 0)
          (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (multi-cursor-tests--with-electric-newline
        (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                   (lambda (edits)
                     (cl-incf apply-count)
                     (funcall original-apply edits))))
          (command-execute 'newline t)))
      (should (= apply-count 1))
      (should (equal command-history '((newline nil 1))))
      (should (equal (buffer-string) "  a\n  \n    b\n    ")))
    (multi-cursor-mode -1)
    (undo-boundary)
    (undo 1)
    (should (equal (buffer-string) "  a  \n    b  "))))

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

(ert-deftest multi-cursor-undo-redo-restores-active-session-state ()
  "Undo and redo keep the session live and restore its exact state."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 4))
           (cursor (multi-cursor-tests--cursor id))
           (before (multi-cursor--session-fingerprint)))
      (setf (multi-cursor--cursor-goal-column cursor) 7
            (multi-cursor--cursor-last-yank cursor) "before")
      (setq before (multi-cursor--session-fingerprint))
      (let ((last-command-event ?X))
        (command-execute 'self-insert-command))
      (let ((after (multi-cursor--session-fingerprint)))
        (should (equal (buffer-string) "aXbcXd"))
        (should multi-cursor-mode)
        (command-execute 'undo)
        (should multi-cursor-mode)
        (should (equal (buffer-string) "abcd"))
        (should (equal (multi-cursor--session-fingerprint) before))
        (command-execute 'undo-redo)
        (should multi-cursor-mode)
        (should (equal (buffer-string) "aXbcXd"))
        (should (equal (multi-cursor--session-fingerprint) after))))))

(ert-deftest multi-cursor-undo-restores-cursor-released-by-merged-edit ()
  "Undo recreates a cursor removed when overlapping edits are merged."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcdefgh")
    (undo-boundary)
    (goto-char 4)
    (set-mark 2)
    (activate-mark)
    (let* ((id (multi-cursor-add-selection 6 4 t))
           (cursor (multi-cursor-tests--cursor id))
           (point-marker (multi-cursor--cursor-point cursor))
           (mark-marker (multi-cursor--cursor-mark cursor))
           (before (multi-cursor--session-fingerprint)))
      (let ((last-command-event ?X))
        (command-execute 'self-insert-command))
      (let ((after (multi-cursor--session-fingerprint)))
        (should (equal (buffer-string) "aXfgh"))
        (should-not multi-cursor--cursors)
        (should-not (marker-buffer point-marker))
        (should-not (marker-buffer mark-marker))
        (command-execute 'undo)
        (should (equal (buffer-string) "abcdefgh"))
        (should (equal (multi-cursor--session-fingerprint) before))
        (should (eq (multi-cursor-tests--cursor id) cursor))
        (should (eq (marker-buffer point-marker) (current-buffer)))
        (should (eq (marker-buffer mark-marker) (current-buffer)))
        (command-execute 'undo-redo)
        (should (equal (buffer-string) "aXfgh"))
        (should (equal (multi-cursor--session-fingerprint) after))
        (should-not (marker-buffer point-marker))
        (should-not (marker-buffer mark-marker))))))

(ert-deftest multi-cursor-undo-failed-transaction-does-not-consume-history ()
  "A failed broadcast edit leaves the previous undo generation available."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (let ((id (multi-cursor-add-at-point 4)))
      (let ((last-command-event ?X))
        (command-execute 'self-insert-command))
      (let ((after-success (multi-cursor--session-fingerprint))
            (before-failure (buffer-string))
            (before-change-functions
             (list (lambda (&rest _)
                     (error "Injected multi-cursor failure")))))
        (let ((last-command-event ?Y))
          (should-error (command-execute 'self-insert-command) :type 'error))
        (should (equal (buffer-string) before-failure))
        (should (equal (multi-cursor--session-fingerprint) after-success))
        (command-execute 'undo)
        (should (equal (buffer-string) "abcd"))
        (should (= (point) 2))
        (should (= (marker-position
                    (multi-cursor--cursor-point
                     (multi-cursor-tests--cursor id)))
                   4))))))

(ert-deftest multi-cursor-undo-rejects-history-predating-session ()
  "Undo fails closed rather than applying an unrelated pre-session edit."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "base")
    (undo-boundary)
    (insert "-older")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 7)
    (let ((before-text (buffer-string))
          (before-state (multi-cursor--session-fingerprint)))
      (should-error (command-execute 'undo) :type 'user-error)
      (should (equal (buffer-string) before-text))
      (should (equal (multi-cursor--session-fingerprint) before-state)))))

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

(ert-deftest multi-cursor-word-kill-policy-and-stock-bindings ()
  "Word-kill commands are dispatched by bounded native handlers."
  (dolist (command '(kill-word backward-kill-word))
    (should (eq (car (gethash command multi-cursor--command-policies))
                'custom-handler)))
  ;; These ordinary bindings are the entry points users exercise.  The
  ;; dispatcher must recognize their commands rather than replaying them.
  (should (eq (key-binding (kbd "M-d")) 'kill-word))
  (should (eq (key-binding (kbd "M-DEL")) 'backward-kill-word)))

(ert-deftest multi-cursor-word-kill-forward-and-backward-use-word-ranges ()
  "Forward and backward commands delete their individual word ranges once."
  (dolist (command-and-positions
           '((kill-word 1 6)
             (backward-kill-word 4 9)))
    (pcase-let ((`(,command ,primary ,secondary) command-and-positions))
      (with-temp-buffer
        (insert "one--two  three")
        (goto-char primary)
        (multi-cursor-add-at-point secondary)
        (let ((kill-ring nil)
              (kill-ring-yank-pointer nil)
              (last-command 'unrelated)
              (interprogram-cut-function nil))
          (command-execute command)
          (should (equal (buffer-string) "--  three"))
          ;; Payload order follows original buffer order, not cursor order or
          ;; the direction in which individual ranges were traversed.
          (should (equal kill-ring '("onetwo"))))))))

(ert-deftest multi-cursor-word-kill-honors-signed-and-zero-prefixes ()
  "Word-kill accepts numeric prefix arguments, including zero."
  (dolist (case '((kill-word 2 1 7 " " "aa bbcc dd")
                  (kill-word -1 6 12 "aa  cc " "bbdd")
                  (backward-kill-word -1 1 7 " bb  dd" "aacc")
                  (backward-kill-word 1 6 12 "aa  cc " "bbdd")))
    (pcase-let ((`(,command ,argument ,primary ,secondary ,expected ,killed)
                 case))
      (with-temp-buffer
        (insert "aa bb cc dd")
        (goto-char primary)
        (multi-cursor-add-at-point secondary)
        (let ((kill-ring nil)
              (kill-ring-yank-pointer nil)
              (last-command 'unrelated)
              (interprogram-cut-function nil))
          (let ((prefix-arg argument))
            (command-execute command))
          (should (equal (buffer-string) expected))
          (should (equal kill-ring (list killed)))))))
  (with-temp-buffer
    (insert "aa bb cc")
    (goto-char 1)
    (multi-cursor-add-at-point 7)
    (let ((before (buffer-string))
          (kill-ring '("old"))
          (kill-ring-yank-pointer nil)
          (command-history nil)
          (cut-calls 0))
      (let ((interprogram-cut-function
             (lambda (text &optional _push)
               (should (equal text ""))
               (cl-incf cut-calls))))
        (let ((prefix-arg 0))
          (command-execute 'kill-word t)))
      (should (equal (buffer-string) before))
      ;; Stock `kill-word' delegates zero to `kill-region', which publishes
      ;; one empty kill.  It is observable to the kill ring and clipboard.
      (should (equal kill-ring '("" "old")))
      (should (eq this-command 'kill-region))
      ;; It is still a real interactive command even though every planned
      ;; range is empty, so replay history retains its explicit zero prefix.
      (should (equal command-history '((kill-word 0))))
      (should (= cut-calls 1)))))

(ert-deftest multi-cursor-word-kill-all-boundary-publishes-one-empty-kill ()
  "An all-empty stock word kill updates the kill ring and clipboard once."
  (with-temp-buffer
    (insert "alpha")
    (goto-char (point-max))
    ;; An enabled session with its primary at EOB has only empty planned
    ;; ranges; no duplicate secondary cursor is necessary.
    (multi-cursor-mode 1)
    (let ((kill-ring '("old"))
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (cut-calls 0))
      (let ((interprogram-cut-function
             (lambda (text &optional _push)
               (should (equal text ""))
               (cl-incf cut-calls))))
        (command-execute 'kill-word))
      (should (equal (buffer-string) "alpha"))
      (should (equal kill-ring '("" "old")))
      (should (eq this-command 'kill-region))
      (should (= cut-calls 1)))))

(ert-deftest multi-cursor-word-kill-mixed-boundary-is-a-per-cursor-no-op ()
  "A cursor at a word-motion boundary does not prevent the other kills."
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 1)
    (multi-cursor-add-at-point (point-max))
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (interprogram-cut-function nil))
      (command-execute 'kill-word)
      (should (equal (buffer-string) " beta"))
      (should (equal kill-ring '("alpha"))))))

(ert-deftest multi-cursor-word-kill-ignores-and-deactivates-regions ()
  "Word killing starts at point even when every cursor has an active region."
  (with-temp-buffer
    (insert "alpha beta gamma delta")
    (goto-char 1)
    (set-mark 11)
    (activate-mark)
    (multi-cursor-add-selection 18 12 t)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (interprogram-cut-function nil))
      (command-execute 'kill-word)
      (should (equal (buffer-string) " beta gamma "))
      (should (equal kill-ring '("alphadelta")))
      (should-not mark-active)
      (should-not (multi-cursor--cursor-mark-active
                   (car multi-cursor--cursors))))))

(ert-deftest multi-cursor-word-kill-respects-subword-boundaries ()
  "The bounded handler uses ordinary `forward-word' semantics, including subword."
  (skip-unless (fboundp 'subword-mode))
  (with-temp-buffer
    (insert "camelCase otherThing")
    (goto-char 1)
    (multi-cursor-add-at-point 11)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (interprogram-cut-function nil))
      (subword-mode 1)
      (command-execute 'kill-word)
      (should (equal (buffer-string) "Case Thing"))
      (should (equal kill-ring '("camelother"))))))

(ert-deftest multi-cursor-word-kill-preserves-overlap-payload-in-buffer-order ()
  "Overlapping word ranges contribute original payloads but delete their union."
  (with-temp-buffer
    (insert "alphabet")
    (goto-char 3)
    ;; Add the earlier point afterwards to ensure sorting is by source range.
    (multi-cursor-add-at-point 1)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (interprogram-cut-function nil))
      (command-execute 'kill-word)
      (should (equal (buffer-string) ""))
      (should (equal kill-ring '("alphabetphabet"))))))

(ert-deftest multi-cursor-word-kill-overlap-appends-by-primary-direction ()
  "An earlier overlapping secondary cursor cannot reverse a forward append."
  (with-temp-buffer
    (insert "alphabet")
    ;; The primary range starts later, but it is still a forward `kill-word'.
    (goto-char 3)
    (multi-cursor-add-at-point 1)
    (let ((kill-ring (list (copy-sequence "OLD")))
          (kill-ring-yank-pointer nil)
          (last-command 'kill-region)
          (interprogram-cut-function nil))
      (command-execute 'kill-word)
      (should (equal (buffer-string) ""))
      (should (equal kill-ring '("OLDalphabetphabet"))))))

(ert-deftest multi-cursor-word-kill-rejects-custom-filter-atomically ()
  "A custom substring filter is rejected before it can affect kill payloads."
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (let* ((id (multi-cursor-add-at-point 12))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (old-entry (copy-sequence "old"))
           (kill-ring (list old-entry))
           (kill-ring-yank-pointer kill-ring)
           (old-pointer kill-ring-yank-pointer)
           (filter-calls 0)
           (cut-calls 0)
           (last-command 'unrelated)
           (filter-buffer-substring-function
            (lambda (&rest _arguments)
              (cl-incf filter-calls)
              "filtered"))
           (interprogram-cut-function
            (lambda (&rest _arguments)
              (cl-incf cut-calls))))
      (should-error (command-execute 'kill-word) :type 'user-error)
      (should (equal (buffer-string) before))
      (should (equal kill-ring (list old-entry)))
      (should (eq kill-ring-yank-pointer old-pointer))
      (should (= filter-calls 0))
      (should (= cut-calls 0))
      (should multi-cursor-mode)
      (should (= (point) 1))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 12)))))

(ert-deftest multi-cursor-word-kill-appends-and-prepends-by-primary-direction ()
  "Successive word kills follow the ordinary `kill-region' merge direction."
  (dolist (case '((kill-word 1 4 "OLDaabb")
                  (backward-kill-word 6 12 "bbddOLD")))
    (pcase-let ((`(,command ,primary ,secondary ,expected) case))
      (with-temp-buffer
        (insert "aa bb cc dd")
        (goto-char primary)
        (multi-cursor-add-at-point secondary)
        (let ((kill-ring (list (copy-sequence "OLD")))
              (kill-ring-yank-pointer nil)
              ;; A following ordinary kill observes this exact command tag.
              (last-command 'kill-region)
              (interprogram-cut-function nil))
          (command-execute command)
          (should (equal kill-ring (list expected))))))))

(ert-deftest multi-cursor-word-kill-failures-are-atomic-before-publication ()
  "Preflight, hook, and kill-transform failures leave all native state intact."
  (dolist (failure '(read-only hook transform))
    (with-temp-buffer
      (insert "alpha beta gamma")
      (goto-char 1)
      (let* ((id (multi-cursor-add-at-point 12))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (kill-ring '("old"))
             (kill-ring-yank-pointer kill-ring)
             (cut-calls 0)
             (last-command 'unrelated)
             (before-change-functions
              (when (eq failure 'hook)
                (list (lambda (_beg _end) (error "word-kill hook failed")))))
             (kill-transform-function
              (when (eq failure 'transform)
                (lambda (_text) (error "word-kill transform failed"))))
             (interprogram-cut-function
              (lambda (&rest _) (cl-incf cut-calls))))
        (when (eq failure 'read-only)
          (put-text-property 12 17 'read-only t))
        (should-error (command-execute 'kill-word))
        (should (equal (buffer-string) before))
        (should (equal kill-ring '("old")))
        (should (= cut-calls 0))
        (should (= (point) 1))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 12))))))

(ert-deftest multi-cursor-word-kill-exports-once-after-commit ()
  "The clipboard is notified once, only after the central transaction succeeds."
  (with-temp-buffer
    (insert "alpha beta gamma")
    (goto-char 1)
    (multi-cursor-add-at-point 12)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (observed nil))
      (let ((interprogram-cut-function
             (lambda (text &optional _push)
               (push (cons text (buffer-string)) observed))))
        (command-execute 'kill-word))
      (should (equal kill-ring '("alphagamma")))
      (should (equal observed '(("alphagamma" . " beta ")))))))

(ert-deftest multi-cursor-word-kill-one-apply-history-undo-and-redo ()
  "One word-kill invocation is one transaction, history entry, and generation."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "alpha beta gamma")
    (undo-boundary)
    (goto-char 1)
    (multi-cursor-add-at-point 12)
    (let ((command-history nil)
          (kill-ring nil)
          (kill-ring-yank-pointer nil)
          (last-command 'unrelated)
          (interprogram-cut-function nil)
          (apply-count 0)
          (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                 (lambda (edits)
                   (cl-incf apply-count)
                   (funcall original-apply edits))))
        (command-execute 'kill-word t))
      (should (= apply-count 1))
      (should (equal command-history '((kill-word 1))))
      (should (equal (buffer-string) " beta "))
      (command-execute 'undo)
      (should (equal (buffer-string) "alpha beta gamma"))
      (command-execute 'undo-redo)
      (should (equal (buffer-string) " beta ")))))

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

;;;; Bounded literal TAB insertion

(ert-deftest multi-cursor-tab-literal-inserts-tabs-at-mixed-columns ()
  "TAB broadcasts literal tab insertion when every cursor takes that branch."
  (with-temp-buffer
    (insert "ab\ncdef")
    (setq-local indent-tabs-mode t)
    (setq-local tab-always-indent nil)
    (setq-local indent-line-function #'indent-to-left-margin)
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 7))
           (cursor (multi-cursor-tests--cursor id)))
      (command-execute 'indent-for-tab-command)
      (should (equal (buffer-string) "a\tb\ncde\tf"))
      (should (= (point) 3))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 9)))))

(ert-deftest multi-cursor-tab-literal-tabs-ignore-invalid-tab-width ()
  "Literal tabs do not consult `tab-width', as vanilla `insert-tab' does."
  (dolist (width '(0 not-an-integer))
    ;; `tab-width' has an interactive custom setter which rejects symbols;
    ;; dynamic binding deliberately exercises `insert-tab' itself, which does
    ;; not consult the value when `indent-tabs-mode' is non-nil.
    (let ((tab-width width))
      (with-temp-buffer
        (insert "ab\ncdef")
        (setq-local indent-tabs-mode t)
        (setq-local tab-always-indent nil)
        (setq-local indent-line-function #'indent-to-left-margin)
        (goto-char 2)
        (let* ((id (multi-cursor-add-at-point 7))
               (cursor (multi-cursor-tests--cursor id)))
          (command-execute 'indent-for-tab-command)
          (should (equal (buffer-string) "a\tb\ncde\tf"))
          (should (= (point) 3))
          (should (= (marker-position (multi-cursor--cursor-point cursor))
                     9)))))))

(ert-deftest multi-cursor-tab-literal-inserts-spaces-at-mixed-columns ()
  "Space TAB mode advances each cursor to its own next tab stop."
  (with-temp-buffer
    (insert "ab\ncdef")
    (setq-local indent-tabs-mode nil)
    (setq-local tab-always-indent nil)
    (setq-local tab-width 4)
    (setq-local indent-line-function #'indent-to-left-margin)
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 7))
           (cursor (multi-cursor-tests--cursor id)))
      (command-execute 'indent-for-tab-command)
      (should (equal (buffer-string) "a   b\ncde f"))
      (should (= (point) 5))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 11)))))

(ert-deftest multi-cursor-tab-literal-after-indentation-uses-indent-relative ()
  "TAB inserts literally after indentation without calling `indent-relative'."
  (with-temp-buffer
    ;; These are ordinary indented lines, not the special
    ;; `indent-to-left-margin' case.  Both points are strictly after their
    ;; line indentation, which selects `insert-tab' with
    ;; `tab-always-indent' nil.
    (insert "  alpha\n    beta")
    (setq-local indent-tabs-mode nil)
    (setq-local tab-always-indent nil)
    (setq-local tab-width 4)
    (setq-local indent-line-function #'indent-relative)
    (goto-char 5)
    (let* ((id (multi-cursor-add-at-point 15))
           (cursor (multi-cursor-tests--cursor id)))
      (command-execute 'indent-for-tab-command)
      (should (equal (buffer-string) "  al    pha\n    be  ta"))
      (should (= (point) 9))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 21)))))

(ert-deftest multi-cursor-tab-literal-rejects-mixed-indentation-contexts ()
  "TAB rejects atomically when any cursor would indent rather than insert."
  (with-temp-buffer
    (insert "  alpha\n    beta")
    (setq-local indent-tabs-mode nil)
    (setq-local tab-always-indent nil)
    (setq-local tab-width 4)
    (setq-local indent-line-function #'indent-relative)
    ;; The primary point is after indentation, but the secondary point is
    ;; within its line's indentation.  Native batching must not guess how to
    ;; combine literal insertion with `indent-relative'.
    (goto-char 5)
    (let* ((id (multi-cursor-add-at-point 11))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (before-state (multi-cursor--session-fingerprint))
           ;; `command-execute' is below the ordinary command loop, so bind
           ;; its command-loop state explicitly rather than inherit a prior
           ;; ERT command's `last-command'.
           (this-command 'indent-for-tab-command)
           (last-command 'other-window))
      (should-error (command-execute 'indent-for-tab-command) :type 'user-error)
      (should (equal (buffer-string) before))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (= (point) 5))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 11)))))

(ert-deftest multi-cursor-tab-literal-consecutive-tab-allows-indent-relative ()
  "A consecutive TAB uses the literal branch even within indentation."
  (with-temp-buffer
    (insert "    alpha\n  beta")
    (setq-local indent-tabs-mode nil)
    (setq-local tab-always-indent nil)
    (setq-local tab-width 4)
    (setq-local indent-line-function #'indent-relative)
    ;; Both points are within their line indentation.  `last-command' makes
    ;; this command the second TAB, selecting the explicit consecutive-TAB
    ;; `insert-tab' arm in `indent-for-tab-command'.
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 12))
           (cursor (multi-cursor-tests--cursor id))
           (this-command 'indent-for-tab-command)
           (last-command 'indent-for-tab-command))
      (command-execute 'indent-for-tab-command)
      (should (equal (buffer-string) "       alpha\n     beta"))
      (should (= (point) 5))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 18)))))

(ert-deftest multi-cursor-tab-literal-rejects-unsafe-contexts-atomically ()
  "TAB refuses branches with semantics that cannot be modeled natively."
  (dolist (condition '(prefix primary-selection secondary-selection abbrev
                               completion custom-indent))
    (with-temp-buffer
      (insert "ab\ncdef")
      (setq-local indent-tabs-mode nil)
      (setq-local tab-always-indent nil)
      (setq-local indent-line-function #'indent-to-left-margin)
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 7))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (prefix-arg (and (eq condition 'prefix) 1))
             (abbrev-mode (eq condition 'abbrev)))
        (pcase condition
          ('primary-selection
           (set-mark 1)
           (activate-mark))
          ('secondary-selection
           (setf (multi-cursor--cursor-mark cursor) (copy-marker 5))
           (setf (multi-cursor--cursor-mark-active cursor) t))
          ('completion
           (setq-local tab-always-indent 'complete))
          ('custom-indent
           (setq-local indent-line-function #'ignore)
           (setq-local tab-always-indent t)))
        (let ((before-state (multi-cursor--session-fingerprint)))
          (should-error (command-execute 'indent-for-tab-command) :type 'user-error)
          (should (equal (buffer-string) before))
          (should (equal (multi-cursor--session-fingerprint) before-state)))))))

(ert-deftest multi-cursor-tab-literal-rejects-minibuffer-atomically ()
  "TAB is never broadcast from a minibuffer session."
  (let ((minibuffer (window-buffer (minibuffer-window))))
    (with-current-buffer minibuffer
      (erase-buffer)
      (insert "abcd")
      (goto-char 2)
      (multi-cursor-add-at-point 4)
      (let ((before (buffer-string))
            (before-state (multi-cursor--session-fingerprint)))
        (should (minibufferp))
        (should-error (command-execute 'indent-for-tab-command) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (equal (multi-cursor--session-fingerprint) before-state))))))

(ert-deftest multi-cursor-tab-literal-preflight-rejects-unsafe-insertions ()
  "Read-only buffers and inaccessible cursors abort TAB before any edit."
  (dolist (gate '(buffer-read-only inaccessible-secondary))
    (with-temp-buffer
      (insert "alpha beta gamma")
      (setq-local indent-tabs-mode t)
      (setq-local tab-always-indent nil)
      (setq-local indent-line-function #'indent-to-left-margin)
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 12))
             (cursor (multi-cursor-tests--cursor id)))
        (pcase gate
          ('buffer-read-only
           (setq buffer-read-only t))
          ('inaccessible-secondary
           ;; The session's post-command cleanup would release this cursor
           ;; after a completed narrowing command.  Invoke TAB immediately
           ;; so the central range preflight must reject its inaccessible
           ;; insertion point without changing either cursor.
           (narrow-to-region 1 8)))
        (let ((before (buffer-string))
              (before-state (multi-cursor--session-fingerprint)))
          (should-error (command-execute 'indent-for-tab-command))
          (should (equal (buffer-string) before))
          (should (equal (multi-cursor--session-fingerprint) before-state))
          (should (= (point) 2))
          (should (= (marker-position (multi-cursor--cursor-point cursor))
                     12)))))))

(ert-deftest multi-cursor-tab-literal-option-drift-rolls-back-atomically ()
  "Changing TAB options during the transaction leaves text and cursors intact."
  (with-temp-buffer
    (insert "ab\ncdef")
    (setq-local indent-tabs-mode nil)
    (setq-local tab-always-indent nil)
    (setq-local tab-width 4)
    (setq-local indent-line-function #'indent-to-left-margin)
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 7))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (before-state (multi-cursor--session-fingerprint))
           (after-change-functions
            (list (lambda (&rest _)
                    (setq-local tab-width 8)))))
      (should-error (command-execute 'indent-for-tab-command))
      (should (equal (buffer-string) before))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 7)))))

(ert-deftest multi-cursor-tab-literal-default-drift-rolls-back-atomically ()
  "A failed TAB transaction restores guarded process-wide defaults."
  (let ((original-default (default-value 'tab-width)))
    (unwind-protect
        (with-temp-buffer
          (insert "ab\ncdef")
          (setq-local indent-tabs-mode nil)
          (setq-local tab-always-indent nil)
          (setq-local tab-width 4)
          (setq-local indent-line-function #'indent-to-left-margin)
          (goto-char 2)
          (multi-cursor-add-at-point 7)
          (let ((before (buffer-string))
                (before-state (multi-cursor--session-fingerprint))
                (after-change-functions
                 (list (lambda (&rest _)
                         (setq-default tab-width (1+ original-default))))))
            (should-error (command-execute 'indent-for-tab-command))
            (should (equal (buffer-string) before))
            (should (equal (multi-cursor--session-fingerprint) before-state))
            (should (equal (default-value 'tab-width) original-default))))
      (setq-default tab-width original-default))))

(ert-deftest multi-cursor-tab-literal-uses-one-apply-and-undo-generation ()
  "A literal TAB command is one native transaction and session generation."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "ab\ncdef")
    (undo-boundary)
    (setq-local indent-tabs-mode nil)
    (setq-local tab-always-indent nil)
    (setq-local tab-width 4)
    (setq-local indent-line-function #'indent-to-left-margin)
    (goto-char 2)
    (multi-cursor-add-at-point 7)
    (let ((apply-count 0)
          (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                 (lambda (edits)
                   (cl-incf apply-count)
                   (funcall original-apply edits))))
        (command-execute 'indent-for-tab-command))
      (should (= apply-count 1))
      (should (= (length multi-cursor--undo-generations) 1))
      (should (equal (buffer-string) "a   b\ncde f")))))

(ert-deftest multi-cursor-undo-multiple-generations-are-lifo-and-redo-fifo ()
  "Two active-session edits undo and redo one generation at a time."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    (let ((after-first (multi-cursor--session-fingerprint)))
      (let ((last-command-event ?Y))
        (command-execute 'self-insert-command))
      (let ((after-second (multi-cursor--session-fingerprint)))
        (should (equal (buffer-string) "aXYbcXYd"))
        (should (= (length multi-cursor--undo-generations) 2))
        (command-execute 'undo)
        (should (equal (buffer-string) "aXbcXd"))
        (should (equal (multi-cursor--session-fingerprint) after-first))
        (command-execute 'undo)
        (should (equal (buffer-string) "abcd"))
        (should-not multi-cursor--undo-generations)
        (should (= (length multi-cursor--redo-generations) 2))
        (command-execute 'undo-redo)
        (should (equal (buffer-string) "aXbcXd"))
        (should (equal (multi-cursor--session-fingerprint) after-first))
        (command-execute 'undo-redo)
        (should (equal (buffer-string) "aXYbcXYd"))
        (should (equal (multi-cursor--session-fingerprint) after-second))
        (should-not multi-cursor--redo-generations)))))

(ert-deftest multi-cursor-undo-new-edit-discards-redo-history ()
  "A successful replacement edit makes the former redo branch unavailable."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    (let ((last-command-event ?Y))
      (command-execute 'self-insert-command))
    (command-execute 'undo)
    (should (equal (buffer-string) "aXbcXd"))
    (should multi-cursor--redo-generations)
    (let ((last-command-event ?Z))
      (command-execute 'self-insert-command))
    (should (equal (buffer-string) "aXZbcXZd"))
    (should-not multi-cursor--redo-generations)
    (let ((before-text (buffer-string))
          (before-state (multi-cursor--session-fingerprint)))
      (should-error (command-execute 'undo-redo) :type 'user-error)
      (should (equal (buffer-string) before-text))
      (should (equal (multi-cursor--session-fingerprint) before-state)))))

(ert-deftest multi-cursor-undo-rejects-external-edit-atomically ()
  "An edit outside the broadcast transaction makes session undo fail closed."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    ;; This edit intentionally bypasses the multi-cursor dispatcher.
    (goto-char (point-max))
    (insert "!")
    (let ((before-text (buffer-string))
          (before-state (multi-cursor--session-fingerprint))
          (before-undo (copy-tree multi-cursor--undo-generations)))
      (should-error (command-execute 'undo) :type 'user-error)
      (should (equal (buffer-string) before-text))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (equal multi-cursor--undo-generations before-undo)))))

(ert-deftest multi-cursor-undo-rejects-nonunit-prefix-atomically ()
  "Session undo accepts only a single generation per invocation."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    (let ((before-text (buffer-string))
          (before-state (multi-cursor--session-fingerprint))
          (before-undo (copy-tree multi-cursor--undo-generations)))
      ;; `command-execute' is not a command-loop prefix simulator; exercise
      ;; the registered handler with the prefix it receives from that loop.
      (should-error (multi-cursor--session-undo 'undo 2 nil nil nil)
                    :type 'user-error)
      (should (equal (buffer-string) before-text))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (equal multi-cursor--undo-generations before-undo)))))

(ert-deftest multi-cursor-undo-runs-change-hooks ()
  "Ordinary modification hooks remain observable during session undo."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (multi-cursor-add-at-point 4)
    (let ((last-command-event ?X))
      (command-execute 'self-insert-command))
    (let ((multi-cursor-tests--undo-change-count 0)
          (after-change-functions
           (list (lambda (&rest _args)
                   (cl-incf multi-cursor-tests--undo-change-count)))))
      (command-execute 'undo)
      (should (equal (buffer-string) "abcd"))
      (should (> multi-cursor-tests--undo-change-count 0)))))

;;; Bounded native `open-line' (C-o).

(ert-deftest multi-cursor-edit-open-line-policy-and-real-c-o ()
  "C-o is a separately planned native edit, not ordinary replay."
  (let ((entry (gethash 'open-line multi-cursor--command-policies)))
    (should (eq (car entry) 'custom-handler))
    (should (functionp (cdr entry))))
  (ert-with-test-buffer (:selected t)
    (should (eq (key-binding (kbd "C-o")) 'open-line))
    (insert "ab\ncd")
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 5))
           (cursor (multi-cursor-tests--cursor id)))
      (ert-play-keys (kbd "C-o"))
      (should (equal (buffer-string) "a\nb\nc\nd"))
      ;; `open-line' leaves both cursors before their newly inserted newline.
      (should (= (point) 2))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 6)))))

(ert-deftest multi-cursor-edit-open-line-mixed-points-and-inactive-marks ()
  "Open line preserves inactive marks while remapping their positions."
  (with-temp-buffer
    (insert "abc\n  def")
    ;; The primary is mid-line and has an inactive backward mark.  The
    ;; secondary is at BOL and has an inactive forward mark.
    (goto-char 2)
    (set-mark 1)
    ;; There is no command-loop turn between these setup forms, so make the
    ;; inactive state explicit rather than relying on `deactivate-mark'.
    (setq mark-active nil)
    (let* ((id (multi-cursor-add-selection 5 7 nil))
           (cursor (multi-cursor-tests--cursor id)))
      (command-execute 'open-line)
      (should (equal (buffer-string) "a\nbc\n\n  def"))
      (should (= (point) 2))
      (should (= (mark t) 1))
      (should-not mark-active)
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 6))
      (should (= (marker-position (multi-cursor--cursor-mark cursor)) 9))
      (should-not (multi-cursor--cursor-mark-active cursor)))))

(ert-deftest multi-cursor-edit-open-line-prefix-selection-and-effect-policy ()
  "Contexts whose ordinary C-o has nonlocal semantics fail closed."
  (dolist (case '(prefix selection minibuffer fill-prefix left-margin
                         hard-newline translation))
    (with-temp-buffer
      (insert "ab\ncd")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 5))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (prefix-arg (and (eq case 'prefix) 2))
             (fill-prefix (and (eq case 'fill-prefix) "> "))
             (use-hard-newlines (eq case 'hard-newline))
             (translation-table-for-input
              (and (eq case 'translation)
                   (make-char-table 'translation-table))))
        (pcase case
          ('selection
           (set-mark 1)
           (activate-mark))
          ('left-margin
           ;; This is a line-local display property, so only the secondary
           ;; cursor has a margin.  The planner must inspect each position.
           (put-text-property 4 6 'left-margin 2)))
        (if (eq case 'minibuffer)
            (cl-letf (((symbol-function 'minibufferp)
                       (lambda (&optional _buffer) t)))
              (should-error (command-execute 'open-line) :type 'user-error))
          (should-error (command-execute 'open-line) :type 'user-error))
        (should (equal (buffer-string) before))
        (should (= (point) 2))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))))))

(ert-deftest multi-cursor-edit-open-line-properties-and-narrowing-reject ()
  "Text-property and accessibility boundaries are checked before edits."
  (dolist (case '(primary-before primary-after
                  secondary-before secondary-after
                  inaccessible-secondary))
    (with-temp-buffer
      (insert "abcdef")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 5))
             (cursor (multi-cursor-tests--cursor id))
             before)
        (pcase case
          ('primary-before
           (put-text-property 1 2 'multi-cursor-test-property t))
          ('primary-after
           (put-text-property 2 3 'multi-cursor-test-property t))
          ('secondary-before
           (put-text-property 4 5 'multi-cursor-test-property t))
          ('secondary-after
           (put-text-property 5 6 'multi-cursor-test-property t))
          ('inaccessible-secondary
           ;; Keep the session record deliberately stale to ensure the
           ;; handler refuses to edit only the accessible primary cursor.
           (narrow-to-region 1 4)))
        (setq before
              (save-restriction
                (widen)
                (buffer-substring (point-min) (point-max))))
        (should-error (command-execute 'open-line) :type 'user-error)
        (should
         (equal-including-properties
          (save-restriction
            (widen)
            (buffer-substring (point-min) (point-max)))
          before))
        (should (= (point) 2))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))))))

(ert-deftest multi-cursor-edit-open-line-does-not-run-insertion-side-effects ()
  "C-o remains literal even when ordinary insertion features are enabled."
  (dolist (effect '(abbrev auto-fill electric post-self-insert overwrite))
    (with-temp-buffer
      (insert "ab\ncd")
      (goto-char 2)
      (let* ((id (multi-cursor-add-at-point 5))
             (cursor (multi-cursor-tests--cursor id))
             (called nil)
             (side-effect (lambda (&rest _args)
                            (setq called t)
                            (error "C-o ran an insertion side effect"))))
        (pcase effect
          ('abbrev
           (setq abbrev-mode t)
           ;; `expand-abbrev' must not be reached by the bounded handler.
           (cl-letf (((symbol-function 'expand-abbrev) side-effect))
             (command-execute 'open-line)))
          ('auto-fill
           (let ((auto-fill-function side-effect))
             (command-execute 'open-line)))
          ('electric
           (let ((electric-indent-mode t)
                 (electric-indent-functions (list side-effect)))
             (command-execute 'open-line)))
          ('post-self-insert
           (let ((post-self-insert-hook (list side-effect)))
             (command-execute 'open-line)))
          ('overwrite
           (let ((overwrite-mode 'overwrite-mode-textual))
             (command-execute 'open-line))))
        (should-not called)
        (should (equal (buffer-string) "a\nb\nc\nd"))
        (should (= (point) 2))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 6))))))

(ert-deftest multi-cursor-edit-open-line-preflight-and-hook-rollback ()
  "Read-only, field, and hook failures leave a complete C-o session intact."
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
                          (error "Open-line hook failed")))))))
        (when (eq failure 'read-only)
          (setq buffer-read-only t))
        (if (eq failure 'field)
            (cl-letf (((symbol-function 'constrain-to-field)
                       (lambda (new old &rest _)
                         (if (= old 5) (1+ new) new))))
              (should-error (command-execute 'open-line) :type 'user-error))
          (should-error (command-execute 'open-line)))
        (should (equal (buffer-substring-no-properties 1 (point-max)) before))
        (should (= (point) 2))
        (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))))))

(ert-deftest multi-cursor-edit-open-line-one-apply-history-undo-and-redo ()
  "A successful C-o is one atomic editable session generation."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "abcd")
    (undo-boundary)
    (goto-char 2)
    (let* ((id (multi-cursor-add-at-point 4))
           (cursor (multi-cursor-tests--cursor id))
           (before-state (multi-cursor--session-fingerprint))
           (command-history nil)
           (apply-count 0)
           (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                 (lambda (edits)
                   (cl-incf apply-count)
                   (funcall original-apply edits))))
        (command-execute 'open-line t))
      (should (= apply-count 1))
      (should (equal command-history '((open-line 1))))
      (should (equal (buffer-string) "a\nbc\nd"))
      (should (= (point) 2))
      (should (= (marker-position (multi-cursor--cursor-point cursor)) 5))
      (let ((after-state (multi-cursor--session-fingerprint)))
        (command-execute 'undo)
        (should (equal (buffer-string) "abcd"))
        (should (equal (multi-cursor--session-fingerprint) before-state))
        (command-execute 'undo-redo)
        (should (equal (buffer-string) "a\nbc\nd"))
        (should (equal (multi-cursor--session-fingerprint) after-state))))))

(ert-deftest multi-cursor-edit-open-line-same-point-distinct-marks-reject ()
  "Do not silently discard a cursor when two insertions share a point.

The cursor records are deliberately distinct only by their inactive marks.
Choosing either cursor as the merged-edit survivor would lose observable
session state, so the bounded operation must reject before modification."
  (with-temp-buffer
    (insert "abcdefgh")
    (goto-char 2)
    (let* ((first-id (multi-cursor-add-selection 5 4 nil))
           (second-id (multi-cursor-add-selection 5 7 nil))
           (first (multi-cursor-tests--cursor first-id))
           (second (multi-cursor-tests--cursor second-id))
           (before-text (buffer-string))
           (before-state (multi-cursor--session-fingerprint)))
      (should (= (multi-cursor-count) 3))
      (should-error (command-execute 'open-line) :type 'user-error)
      (should (equal (buffer-string) before-text))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (= (marker-position (multi-cursor--cursor-point first)) 5))
      (should (= (marker-position (multi-cursor--cursor-mark first)) 4))
      (should (= (marker-position (multi-cursor--cursor-point second)) 5))
      (should (= (marker-position (multi-cursor--cursor-mark second)) 7)))))

(ert-deftest multi-cursor-edit-open-line-adjacent-cursors-stay-distinct ()
  "Touching insertion points each own a newline, including across a line end."
  (dolist (case '(("abcd" 2 3 1 4 "a\nb\ncd" 2 4 1 6)
                  ;; The two points straddle the existing newline: neither
                  ;; insertion may be coalesced with that boundary or the
                  ;; other cursor's adjacent insertion.
                  ("ab\ncd" 3 4 1 5 "ab\n\n\ncd" 3 5 1 7)))
    (pcase-let ((`(,initial ,primary-point ,secondary-point
                           ,primary-mark ,secondary-mark
                           ,result ,expected-primary ,expected-secondary
                           ,expected-primary-mark ,expected-secondary-mark)
                 case))
      (with-temp-buffer
        (buffer-enable-undo)
        (insert initial)
        (undo-boundary)
        (goto-char primary-point)
        (set-mark primary-mark)
        (setq mark-active nil)
        (let* ((id (multi-cursor-add-selection
                    secondary-point secondary-mark nil))
               (cursor (multi-cursor-tests--cursor id))
               (before-state (multi-cursor--session-fingerprint)))
          (command-execute 'open-line)
          (should (equal (buffer-string) result))
          (should (= (point) expected-primary))
          (should (= (mark t) expected-primary-mark))
          (should (= (marker-position (multi-cursor--cursor-point cursor))
                     expected-secondary))
          (should (= (marker-position (multi-cursor--cursor-mark cursor))
                     expected-secondary-mark))
          (let ((after-state (multi-cursor--session-fingerprint)))
            (command-execute 'undo)
            (should (equal (buffer-string) initial))
            (should (equal (multi-cursor--session-fingerprint) before-state))
            (command-execute 'undo-redo)
            (should (equal (buffer-string) result))
            (should (equal (multi-cursor--session-fingerprint) after-state))))))))

;;;; Bounded stock Emacs Lisp TAB indentation

(defmacro multi-cursor-tests--with-bounded-elisp-indent (&rest body)
  "Run BODY with the supported stock Emacs Lisp TAB contract."
  (declare (indent 0) (debug t))
  `(progn
     ;; Use buffer-local values rather than dynamic bindings.  This makes a
     ;; test's `setq-local' mutation visible to the bounded handler, which is
     ;; the property its option-drift checks must protect.
     (setq-local abbrev-mode nil
                 indent-tabs-mode nil
                 lisp-indent-offset 2
                 tab-always-indent t
                 tab-width 8)
     ,@body))

(defun multi-cursor-tests--session-edit-state-positions ()
  "Return point, mark, and activity for every cursor in session order."
  (mapcar (lambda (state)
            (list (multi-cursor--edit-state-point state)
                  (multi-cursor--edit-state-mark state)
                  (multi-cursor--edit-state-active state)))
          (multi-cursor--snapshot-edit-states)))

(defun multi-cursor-tests--stock-elisp-indent-oracle (text states)
  "Return stock ascending TAB result for TEXT and inactive STATES.

STATES is ordered primary first and contains (POINT MARK ACTIVE) triples.
The native path must produce this same text and cursor state without
replaying a command against its live session one cursor at a time."
  (with-temp-buffer
    (insert text)
    (emacs-lisp-mode)
    (multi-cursor-tests--with-bounded-elisp-indent
      (let ((records
             (mapcar
              (lambda (state)
                (list (copy-marker (nth 0 state))
                      (and (nth 1 state) (copy-marker (nth 1 state)))
                      (nth 2 state)))
              states)))
        (unwind-protect
            (progn
              ;; Keep every target live while applying stock TAB in source
              ;; order.  This is the observable reference for nested forms:
              ;; a selected child line sees the parent line already indented.
              (dolist (record
                       (sort (copy-sequence records)
                             (lambda (left right)
                               (< (marker-position (car left))
                                  (marker-position (car right))))))
                (goto-char (marker-position (car record)))
                (set-marker (mark-marker) (and (nth 1 record)
                                                (marker-position
                                                 (nth 1 record))))
                (setq mark-active (nth 2 record))
                (let ((this-command 'indent-for-tab-command)
                      (last-command 'other-command))
                  (indent-for-tab-command))
                ;; A point on indentation moves to its first nonblank;
                ;; preserve that command result across later source edits.
                (set-marker (car record) (point)))
              (list (buffer-string)
                    (mapcar
                     (lambda (record)
                       (list (marker-position (car record))
                             (and (nth 1 record)
                                  (marker-position (nth 1 record)))
                             (nth 2 record)))
                     records)))
          (dolist (record records)
            (set-marker (car record) nil)
            (when (nth 1 record)
              (set-marker (nth 1 record) nil))))))))

(ert-deftest multi-cursor-tab-elisp-dispatches-and-indents-sibling-lines ()
  "Bounded TAB recognizes stock Lisp indentation, not literal insertion."
  (let ((entry (gethash 'indent-for-tab-command
                        multi-cursor--command-policies)))
    (should (eq (car entry) 'custom-handler))
    (should (functionp (cdr entry))))
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun alpha ()\n(foo)\n(bar))")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((primary (point))
           (primary-mark (point-min))
           (secondary (save-excursion (forward-line 1) (point)))
           (secondary-mark primary)
           (states (list (list primary primary-mark nil)
                         (list secondary secondary-mark nil)))
           (expected
            (multi-cursor-tests--stock-elisp-indent-oracle
             (buffer-string) states)))
      (goto-char primary)
      (set-mark primary-mark)
      (setq mark-active nil)
      (let ((id (multi-cursor-add-selection secondary secondary-mark nil)))
        (multi-cursor-tests--with-bounded-elisp-indent
          (command-execute 'indent-for-tab-command))
        (should (equal (buffer-string) "(defun alpha ()\n  (foo)\n  (bar))"))
        (should (equal (buffer-string) (nth 0 expected)))
        (should (equal (multi-cursor-tests--session-edit-state-positions)
                       (nth 1 expected)))
        (should (= (multi-cursor--cursor-id
                    (multi-cursor-tests--cursor id))
                   id))))))

(ert-deftest multi-cursor-tab-elisp-parent-child-matches-stock-ascending ()
  "A selected child line is planned from the selected parent result."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun sample (value)\n(when value\n(message \"%s\" value)))")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((parent (point))
           (child (save-excursion (forward-line 1) (point)))
           (states (list (list parent (point-min) nil)
                         (list child parent nil)))
           (expected
            (multi-cursor-tests--stock-elisp-indent-oracle
             (buffer-string) states)))
      (goto-char parent)
      (set-mark (point-min))
      (setq mark-active nil)
      (multi-cursor-add-selection child parent nil)
      (multi-cursor-tests--with-bounded-elisp-indent
        (command-execute 'indent-for-tab-command))
      (should (equal (buffer-string)
                     "(defun sample (value)\n  (when value\n    (message \"%s\" value)))"))
      (should (equal (buffer-string) (nth 0 expected)))
      (should (equal (multi-cursor-tests--session-edit-state-positions)
                     (nth 1 expected))))))

(ert-deftest multi-cursor-tab-elisp-same-line-rejects-atomically ()
  "Two independent cursor records on one Lisp line are not coalesced."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(progn\n(foo))")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((id (multi-cursor-add-at-point (+ (point) 2)))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (before-state (multi-cursor--session-fingerprint)))
      (multi-cursor-tests--with-bounded-elisp-indent
        (should-error (command-execute 'indent-for-tab-command) :type 'user-error))
      (should (equal (buffer-string) before))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (= (marker-position (multi-cursor--cursor-point cursor))
                 (+ (point-min) 9))))))

(ert-deftest multi-cursor-tab-elisp-honors-tabs-and-spaces ()
  "Lisp indentation preserves `indent-tabs-mode' byte-for-byte."
  (dolist (case '((t "\t") (nil "        ")))
    (pcase-let ((`(,tabs ,padding) case))
      (with-temp-buffer
        (emacs-lisp-mode)
        (insert "(progn\n(foo)\n(bar))")
        (goto-char (point-min))
        (forward-line 1)
        (let ((secondary (save-excursion (forward-line 1) (point))))
          (multi-cursor-add-at-point secondary)
          (let ((indent-tabs-mode tabs)
                (lisp-indent-offset 8)
                (tab-always-indent t)
                (tab-width 8))
            (command-execute 'indent-for-tab-command))
          (should (equal (buffer-string)
                         (concat "(progn\n" padding "(foo)\n"
                                 padding "(bar))"))))))))

(ert-deftest multi-cursor-tab-elisp-rejects-comment-and-string-lines ()
  "Comment and string-line TAB is deliberately outside the bounded contract."
  (dolist (contents '("(progn\n;; comment\n(foo))"
                      "(progn\n\"string literal\"\n(foo))"))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert contents)
      (goto-char (point-min))
      (forward-line 1)
      (let* ((id (multi-cursor-add-at-point
                  (save-excursion (forward-line 1) (point))))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (before-state (multi-cursor--session-fingerprint)))
        (multi-cursor-tests--with-bounded-elisp-indent
          (should-error (command-execute 'indent-for-tab-command)
                        :type 'user-error))
        (should (equal (buffer-string) before))
        (should (equal (multi-cursor--session-fingerprint) before-state))
        (should (= (marker-position (multi-cursor--cursor-point cursor))
                   (save-excursion (goto-char (point-min))
                                   (forward-line 2) (point))))))))

(ert-deftest multi-cursor-tab-elisp-narrowing-requires-complete-lines ()
  "Full physical lines work under narrowing; partial ones fail closed."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "outside\n(progn\n(foo)\n(bar))\noutside")
    (goto-char (point-min))
    (forward-line 1)
    (let ((first (point)))
      (forward-line 2)
      (end-of-line)
      (narrow-to-region first (point)))
    (goto-char (point-min))
    (forward-line 1)
    (let* ((secondary (save-excursion (forward-line 1) (point)))
           (old-min (point-min))
           (old-max (point-max)))
      (multi-cursor-add-at-point secondary)
      (multi-cursor-tests--with-bounded-elisp-indent
        (command-execute 'indent-for-tab-command))
      (should (equal (buffer-string) "(progn\n  (foo)\n  (bar))"))
      (should (= (point-min) old-min))
      (should (= (point-max) (+ old-max 4)))))
  (dolist (case '(partial-line inaccessible-secondary))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(progn\n(foo)\n(bar))")
      (goto-char (point-min))
      (forward-line 1)
      (let* ((primary (point))
             (secondary (save-excursion (forward-line 1) (point)))
             (id (multi-cursor-add-at-point secondary))
             (cursor (multi-cursor-tests--cursor id)))
        (pcase case
          ('partial-line
           (goto-char secondary)
           (narrow-to-region primary (1+ secondary)))
          ('inaccessible-secondary
           (narrow-to-region primary (1- secondary))))
        (goto-char primary)
        (let ((before (save-restriction (widen) (buffer-string)))
              (before-state (multi-cursor--session-fingerprint)))
          (multi-cursor-tests--with-bounded-elisp-indent
            (should-error (command-execute 'indent-for-tab-command)
                          :type 'user-error))
          (should (equal (save-restriction (widen) (buffer-string)) before))
          (should (equal (multi-cursor--session-fingerprint) before-state))
          (should (= (marker-position (multi-cursor--cursor-point cursor))
                     secondary)))))))

(ert-deftest multi-cursor-tab-elisp-rejects-properties-and-read-only ()
  "Every planned indentation range is preflighted before native mutation."
  (dolist (gate '(buffer text overlay))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(progn\n (foo)\n (bar))")
      (goto-char (point-min))
      (forward-line 1)
      (let* ((primary (point))
             (secondary (save-excursion (forward-line 1) (point)))
             (id (multi-cursor-add-at-point secondary))
             (cursor (multi-cursor-tests--cursor id))
             overlay)
        (pcase gate
          ('buffer (setq buffer-read-only t))
          ('text (put-text-property primary (1+ primary) 'read-only t))
          ('overlay
           (setq overlay (make-overlay primary (1+ primary)))
           (overlay-put overlay 'read-only t)))
        (let ((before (buffer-string))
              (before-state (multi-cursor--session-fingerprint)))
          (multi-cursor-tests--with-bounded-elisp-indent
            (should-error (command-execute 'indent-for-tab-command)))
          (should (equal (buffer-string) before))
          (should (equal (multi-cursor--session-fingerprint) before-state))
          (should (= (marker-position (multi-cursor--cursor-point cursor))
                     secondary)))
        (when overlay (delete-overlay overlay))))))

(ert-deftest multi-cursor-tab-elisp-rejects-unsupported-mode-and-overrides ()
  "Only unadvised stock `lisp-indent-line' in Emacs Lisp mode is accepted."
  (dolist (case '(wrong-mode custom-indent functional-indent advice))
    (with-temp-buffer
      ;; Changing a major mode ends an active session, so establish the
      ;; negative mode before adding its secondary cursor.
      (if (eq case 'wrong-mode)
          (fundamental-mode)
        (emacs-lisp-mode))
      (insert "(progn\n(foo)\n(bar))")
      (goto-char (point-min))
      (forward-line 1)
      (let* ((secondary (save-excursion (forward-line 1) (point)))
             (id (multi-cursor-add-at-point secondary))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (before-state (multi-cursor--session-fingerprint))
             (called nil)
             (wrapper
              (lambda (original &rest arguments)
                (setq called t)
                (apply original arguments))))
        (pcase case
          ('custom-indent (setq-local indent-line-function #'ignore))
          ('functional-indent
           (setq-local lisp-indent-function (lambda (&rest _) 0)))
          ('advice (advice-add 'lisp-indent-line :around wrapper)))
        (unwind-protect
            (multi-cursor-tests--with-bounded-elisp-indent
              (should-error (command-execute 'indent-for-tab-command)
                            :type 'user-error))
          (when (eq case 'advice)
            (advice-remove 'lisp-indent-line wrapper)))
        (should-not called)
        (should (equal (buffer-string) before))
        (should (equal (multi-cursor--session-fingerprint) before-state))
        (should (= (marker-position (multi-cursor--cursor-point cursor))
                   secondary))))))

(ert-deftest multi-cursor-tab-elisp-option-drift-and-hook-failure-roll-back ()
  "Option changes and failing modification hooks leave no partial indentation."
  (dolist (failure '(option hook))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(progn\n(foo)\n(bar))")
      (goto-char (point-min))
      (forward-line 1)
      (let* ((secondary (save-excursion (forward-line 1) (point)))
             (id (multi-cursor-add-at-point secondary))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string))
             (before-state (multi-cursor--session-fingerprint))
             (after-change-functions
              (when (eq failure 'option)
                (list (lambda (&rest _) (setq-local lisp-indent-offset 4)))))
             (before-change-functions
              (when (eq failure 'hook)
                (list (lambda (beg &rest _)
                        (when (= beg (point))
                          (error "Indent hook failed")))))))
        (multi-cursor-tests--with-bounded-elisp-indent
          (should-error (command-execute 'indent-for-tab-command)))
        (should (equal (buffer-string) before))
        (should (equal (multi-cursor--session-fingerprint) before-state))
        (should (= (marker-position (multi-cursor--cursor-point cursor))
                   secondary))
        (when (eq failure 'option)
          (should (= lisp-indent-offset 2)))))))

(ert-deftest multi-cursor-tab-elisp-one-apply-history-undo-and-redo ()
  "One Lisp TAB is one native edit and one active-session generation."
  (with-temp-buffer
    (buffer-enable-undo)
    (emacs-lisp-mode)
    (insert "(progn\n(foo)\n(bar))")
    (undo-boundary)
    (goto-char (point-min))
    (forward-line 1)
    (let* ((secondary (save-excursion (forward-line 1) (point)))
           (id (multi-cursor-add-at-point secondary))
           (cursor (multi-cursor-tests--cursor id))
           (before-state (multi-cursor--session-fingerprint))
           (command-history nil)
           (apply-count 0)
           (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (multi-cursor-tests--with-bounded-elisp-indent
        (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                   (lambda (edits)
                     (cl-incf apply-count)
                     (funcall original-apply edits))))
          (command-execute 'indent-for-tab-command t)))
      (should (= apply-count 1))
      (should (equal command-history '((indent-for-tab-command))))
      (should (= (length multi-cursor--undo-generations) 1))
      (should (equal (buffer-string) "(progn\n  (foo)\n  (bar))"))
      (should (= (multi-cursor--cursor-id
                  (multi-cursor-tests--cursor id))
                 id))
      (let ((after-state (multi-cursor--session-fingerprint)))
        (command-execute 'undo)
        (should (equal (buffer-string) "(progn\n(foo)\n(bar))"))
        (should (equal (multi-cursor--session-fingerprint) before-state))
        (command-execute 'undo-redo)
        (should (equal (buffer-string) "(progn\n  (foo)\n  (bar))"))
        (should (equal (multi-cursor--session-fingerprint) after-state))))))

(ert-deftest multi-cursor-tab-elisp-already-correct-is-not-an-edit ()
  "No-op Lisp TAB moves points as stock does without creating undo history."
  (with-temp-buffer
    (buffer-enable-undo)
    (emacs-lisp-mode)
    (insert "(progn\n  (foo)\n  (bar))")
    (undo-boundary)
    (goto-char (point-min))
    (forward-line 1)
    (let* ((primary (point))
           (secondary (save-excursion (forward-line 1) (point)))
           (states (list (list primary nil nil)
                         (list secondary nil nil)))
           (expected
            (multi-cursor-tests--stock-elisp-indent-oracle
             (buffer-string) states))
           (id (multi-cursor-add-at-point secondary))
           (cursor (multi-cursor-tests--cursor id))
           (apply-count 0)
           (original-apply (symbol-function 'multi-cursor--apply-edits)))
      (multi-cursor-tests--with-bounded-elisp-indent
        (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                   (lambda (edits)
                     (cl-incf apply-count)
                     (funcall original-apply edits))))
          (command-execute 'indent-for-tab-command)))
      (should (= apply-count 0))
      (should-not multi-cursor--undo-generations)
      (should (equal (buffer-string) "(progn\n  (foo)\n  (bar))"))
      (should (equal (multi-cursor-tests--session-edit-state-positions)
                     (nth 1 expected))))))

(ert-deftest multi-cursor-tab-elisp-topology-hook-rolls-back-atomically ()
  "A hook adding a cursor aborts and restores the original session exactly."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(progn\n(foo)\n(bar))")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((secondary (save-excursion (forward-line 1) (point)))
           (id (multi-cursor-add-at-point secondary))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (before-state (multi-cursor--session-fingerprint))
           (mutated nil)
           (after-change-functions
            (list (lambda (&rest _)
                    (unless mutated
                      (setq mutated t)
                      (multi-cursor-add-at-point (point-max)))))))
      (multi-cursor-tests--with-bounded-elisp-indent
        (should-error (command-execute 'indent-for-tab-command)))
      (should mutated)
      (should (equal (buffer-string) before))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (= (multi-cursor--cursor-id
                  (multi-cursor-tests--cursor id))
                 id))
      (should (= (marker-position (multi-cursor--cursor-point cursor))
                 secondary)))))

(ert-deftest multi-cursor-tab-elisp-restores-mutated-tab-and-abbrev-options ()
  "Local and default TAB options cannot drift during a native transaction."
  (dolist (mutation '(tab-local tab-default abbrev-local abbrev-default))
    (let ((old-tab-default (default-value 'tab-always-indent))
          (old-abbrev-default (default-value 'abbrev-mode)))
      (unwind-protect
          (with-temp-buffer
            (emacs-lisp-mode)
            (insert "(progn\n(foo)\n(bar))")
            (goto-char (point-min))
            (forward-line 1)
            (let* ((secondary (save-excursion (forward-line 1) (point)))
                   (id (multi-cursor-add-at-point secondary))
                   (cursor (multi-cursor-tests--cursor id))
                   (before (buffer-string))
                   (before-state (multi-cursor--session-fingerprint))
                   (mutated nil)
                   (after-change-functions
                    (list
                     (lambda (&rest _)
                       (unless mutated
                         (setq mutated t)
                         (pcase mutation
                           ('tab-local (setq-local tab-always-indent nil))
                           ('tab-default (setq-default tab-always-indent nil))
                           ('abbrev-local (setq-local abbrev-mode t))
                           ('abbrev-default (setq-default abbrev-mode t))))))))
              (multi-cursor-tests--with-bounded-elisp-indent
                (should-error (command-execute 'indent-for-tab-command)))
              (should mutated)
              (should (equal (buffer-string) before))
              (should (equal (multi-cursor--session-fingerprint) before-state))
              (should (= (marker-position (multi-cursor--cursor-point cursor))
                         secondary))
              (should (eq tab-always-indent t))
              (should-not abbrev-mode)))
        (setq-default tab-always-indent old-tab-default)
        (setq-default abbrev-mode old-abbrev-default)))))

(ert-deftest multi-cursor-tab-elisp-prefix-rewriting-hook-rolls-back ()
  "A successful hook that changes planned indentation aborts the transaction."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(progn\n(foo)\n(bar))")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((secondary (save-excursion (forward-line 1) (point)))
           (id (multi-cursor-add-at-point secondary))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (before-state (multi-cursor--session-fingerprint))
           (rewritten nil)
           (after-change-functions
            (list
             (lambda (beg end _old)
               (unless rewritten
                 (setq rewritten t)
                 (save-excursion
                   (goto-char beg)
                   (delete-region beg end)
                   (insert ">>")))))))
      (multi-cursor-tests--with-bounded-elisp-indent
        (should-error (command-execute 'indent-for-tab-command)))
      (should rewritten)
      (should (equal (buffer-string) before))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (= (marker-position (multi-cursor--cursor-point cursor))
                 secondary)))))

(ert-deftest multi-cursor-tab-elisp-field-boundary-in-prefix-rejects ()
  "A field boundary in the replaced indentation is checked before editing."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(progn\n (foo)\n (bar))")
    (goto-char (point-min))
    (forward-line 1)
    (let* ((primary (point))
           (secondary (save-excursion (forward-line 1) (point)))
           (id (multi-cursor-add-at-point secondary))
           (cursor (multi-cursor-tests--cursor id))
           (before (buffer-string))
           (before-state (multi-cursor--session-fingerprint))
           (original-constrain (symbol-function 'constrain-to-field)))
      ;; The leading space is the replacement range.  Model a field
      ;; constraint that refuses to cross that range at either cursor.
      (cl-letf (((symbol-function 'constrain-to-field)
                 (lambda (new old &rest arguments)
                   (if (memq old (list primary secondary))
                       (1+ new)
                     (apply original-constrain new old arguments)))))
        (multi-cursor-tests--with-bounded-elisp-indent
          (should-error (command-execute 'indent-for-tab-command)
                        :type 'user-error)))
      (should (equal (buffer-string) before))
      (should (equal (multi-cursor--session-fingerprint) before-state))
      (should (= (marker-position (multi-cursor--cursor-point cursor))
                 secondary)))))

(ert-deftest multi-cursor-tab-elisp-rejects-empty-active-regions ()
  "Empty active regions retain region-TAB semantics and are never guessed."
  (dolist (case '(primary secondary))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(progn\n(foo)\n(bar))")
      (goto-char (point-min))
      (forward-line 1)
      (let* ((primary (point))
             (secondary (save-excursion (forward-line 1) (point)))
             (id (if (eq case 'secondary)
                     (multi-cursor-add-selection secondary secondary t)
                   (multi-cursor-add-at-point secondary)))
             (cursor (multi-cursor-tests--cursor id))
             (before (buffer-string)))
        (when (eq case 'primary)
          (set-mark primary)
          (activate-mark))
        (let ((before-state (multi-cursor--session-fingerprint)))
          (multi-cursor-tests--with-bounded-elisp-indent
            (should-error (command-execute 'indent-for-tab-command)
                          :type 'user-error))
          (should (equal (buffer-string) before))
          (should (equal (multi-cursor--session-fingerprint) before-state))
          (should (= (marker-position (multi-cursor--cursor-point cursor))
                     secondary)))))))

(ert-deftest multi-cursor-tab-elisp-mixed-change-and-noop-is-one-generation ()
  "Changed and already-correct lines share one exact undoable transaction."
  (with-temp-buffer
    (buffer-enable-undo)
    (emacs-lisp-mode)
    (insert "(progn\n(foo)\n  (bar))")
    (undo-boundary)
    (goto-char (point-min))
    (forward-line 1)
    (let* ((primary (point))
           (secondary (save-excursion (forward-line 1) (point)))
           (states (list (list primary nil nil)
                         (list secondary nil nil)))
           (expected
            (multi-cursor-tests--stock-elisp-indent-oracle
             (buffer-string) states))
           (id (multi-cursor-add-at-point secondary))
           (before-state (multi-cursor--session-fingerprint)))
      (multi-cursor-tests--with-bounded-elisp-indent
        (command-execute 'indent-for-tab-command))
      (should (= (length multi-cursor--undo-generations) 1))
      (should (equal (buffer-string) (nth 0 expected)))
      (should (equal (multi-cursor-tests--session-edit-state-positions)
                     (nth 1 expected)))
      (let ((after-state (multi-cursor--session-fingerprint)))
        (command-execute 'undo)
        (should (equal (buffer-string) "(progn\n(foo)\n  (bar))"))
        (should (equal (multi-cursor--session-fingerprint) before-state))
        (command-execute 'undo-redo)
        (should (equal (buffer-string) (nth 0 expected)))
        (should (equal (multi-cursor--session-fingerprint) after-state))
        (should (= (multi-cursor--cursor-id
                    (multi-cursor-tests--cursor id))
                   id))))))

(provide 'multi-cursor-tests)

;;; multi-cursor-tests.el ends here

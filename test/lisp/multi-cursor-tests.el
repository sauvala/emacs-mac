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
(require 'cl-lib)
(require 'multi-cursor)

(defun multi-cursor-tests--cursor (id)
  "Return the internal test cursor whose stable identifier is ID."
  (cl-find id multi-cursor--cursors
           :key #'multi-cursor--cursor-id))

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

(provide 'multi-cursor-tests)

;;; multi-cursor-tests.el ends here

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

(provide 'multi-cursor-tests)

;;; multi-cursor-tests.el ends here

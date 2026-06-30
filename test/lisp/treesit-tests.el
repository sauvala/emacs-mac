;;; treesit-tests.el --- Test suite for treesit. -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'font-lock)
(require 'treesit)

(defvar font-lock--commit-queue)
(defvar font-lock--commit-timer)

(declare-function font-lock--dispatch-commits "font-lock" ())

(ert-deftest treesit-font-lock-fontify-region-yields-between-settings ()
  "Tree-sitter font-lock leaves remaining settings queued on input."
  (let ((old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        (treesit-font-lock-settings
         '((query-a t feature-a nil nil elisp)
           (query-b t feature-b nil nil elisp)))
        (treesit-font-lock-async nil)
        (treesit--font-lock-fast-mode nil)
        (treesit-range-settings nil)
        (treesit-font-lock-defer-on-input t)
        (font-lock-commit-defer-on-input nil)
        (fontified nil)
        (input-checks 0))
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "abc")
          (cl-letf (((symbol-function 'treesit-local-parsers-on)
                     (lambda (&rest _) nil))
                    ((symbol-function 'treesit-parser-list)
                     (lambda (&optional _) '(parser)))
                    ((symbol-function 'treesit-parser-root-node)
                     (lambda (_) 'node))
                    ((symbol-function 'treesit-node-language)
                     (lambda (_) 'elisp))
                    ((symbol-function 'treesit--font-lock-fontify-region-1)
                     (lambda (_node query _start _end _override _loudly)
                       (push query fontified)))
                    ((symbol-function 'input-pending-p)
                     (lambda (&optional _)
                       (setq input-checks (1+ input-checks))
                       (= input-checks 1))))
            (treesit-font-lock-fontify-region (point-min) (point-max))
            (should (equal fontified '(query-a)))
            (should (= (length font-lock--commit-queue) 1))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (let ((treesit-font-lock-defer-on-input nil))
              (should (equal (font-lock--dispatch-commits)
                             '(:processed 1 :dropped 0 :remaining 0))))
            (should (equal fontified '(query-b query-a)))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

;;; treesit-tests.el ends here

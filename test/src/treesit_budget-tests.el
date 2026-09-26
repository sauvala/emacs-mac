;;; treesit_budget-tests.el --- tests for src/treesit_budget.c  -*- lexical-binding: t; -*-

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

;; Stage 1 of budgeted tree-sitter parsing only times parses; see
;; `.wayfinder/issues/treesit-budgeted-parse.md'.

;;; Code:

(require 'ert)
(require 'treesit)

(declare-function treesit-budget-stats "treesit_budget.c")

(ert-deftest treesit-budget-stats-counts-parses ()
  "Each parse the buffer needs is counted once; an unchanged buffer is not."
  (skip-unless (treesit-language-available-p 'json))
  (with-temp-buffer
    (insert "[1]")
    (let ((parser (treesit-parser-create 'json)))
      (treesit-budget-stats t)
      (treesit-parser-root-node parser)
      (should (equal (plist-get (treesit-budget-stats) :parses) 1))
      (treesit-parser-root-node parser)
      (should (equal (plist-get (treesit-budget-stats) :parses) 1))
      (insert ",2")
      (treesit-parser-root-node parser)
      (should (equal (plist-get (treesit-budget-stats) :parses) 2)))))

;; A parse of a megabyte of JSON takes well over 8 ms; one of "[1]"
;; takes microseconds.
(defun treesit-budget-tests--big-json ()
  (concat "[" (mapconcat #'number-to-string (number-sequence 1 150000) ",")
          "]"))

(ert-deftest treesit-budget-stats-times-parses ()
  "Parse time is summed, its maximum kept, and long parses are counted."
  (skip-unless (treesit-language-available-p 'json))
  (with-temp-buffer
    (insert "[1]")
    (let ((parser (treesit-parser-create 'json)))
      (treesit-budget-stats t)
      (treesit-parser-root-node parser)
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :over-1ms) 0))
        (should (< 0 (plist-get stats :seconds) 0.001)))
      (erase-buffer)
      (insert (treesit-budget-tests--big-json))
      (treesit-parser-root-node parser)
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :parses) 2))
        (should (equal (plist-get stats :over-1ms) 1))
        (should (equal (plist-get stats :over-3ms) 1))
        (should (equal (plist-get stats :over-8ms) 1))
        (should (< 0.008 (plist-get stats :max-seconds)
                   (plist-get stats :seconds))))
      (treesit-budget-stats t)
      (should (equal (plist-get (treesit-budget-stats) :over-1ms) 0)))))

(ert-deftest treesit-budget-parse-reports-progress ()
  "Parses go through the progress callback that budgeting will use.
The callback never halts in stage 1, so the tree is complete."
  (skip-unless (treesit-language-available-p 'json))
  (skip-unless (<= 15 (treesit-library-abi-version)))
  (with-temp-buffer
    (insert (treesit-budget-tests--big-json))
    (let ((parser (treesit-parser-create 'json)))
      (treesit-budget-stats t)
      (should (equal (treesit-node-type
                      (treesit-node-child (treesit-parser-root-node parser)
                                          0))
                     "array"))
      (should (< 100 (plist-get (treesit-budget-stats) :progress-calls)))
      (should-not (treesit-node-check (treesit-parser-root-node parser)
                                      'has-error)))))

(provide 'treesit_budget-tests)
;;; treesit_budget-tests.el ends here

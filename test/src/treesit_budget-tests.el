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

;; Budgeted tree-sitter parsing times every parse and stops one that
;; runs past `treesit-budget-parse-limit'; see
;; `.wayfinder/issues/treesit-budgeted-parse.md'.

;;; Code:

(require 'ert)
(require 'treesit)

(declare-function treesit-budget-stats "treesit_budget.c")
(declare-function treesit-budget-gave-up-p "treesit_budget.c")
(declare-function treesit-budget-retry "treesit_budget.c")
(defvar treesit-budget-parse-limit)

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
  "Reparse time is summed, its maximum kept, and long reparses are counted."
  (skip-unless (treesit-language-available-p 'json))
  (with-temp-buffer
    (insert "[1]")
    (let ((parser (treesit-parser-create 'json)))
      (treesit-budget-stats t)
      (treesit-parser-root-node parser)
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :over-1ms) 0))
        (should (< 0 (plist-get stats :first-seconds) 0.001)))
      (erase-buffer)
      (insert (treesit-budget-tests--big-json))
      (treesit-parser-root-node parser)
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :parses) 2))
        (should (equal (plist-get stats :over-1ms) 1))
        (should (equal (plist-get stats :over-3ms) 1))
        (should (equal (plist-get stats :over-8ms) 1))
        (should (< 0.008 (plist-get stats :max-seconds)))
        (should (<= (plist-get stats :max-seconds)
                    (plist-get stats :seconds))))
      (treesit-budget-stats t)
      (should (equal (plist-get (treesit-budget-stats) :over-1ms) 0)))))

(ert-deftest treesit-budget-stats-separates-first-parses ()
  "A parse without a previous tree is a first parse, counted apart.
Only reparses count toward the long-parse counts, since stage 2 keeps
first parses synchronous."
  (skip-unless (treesit-language-available-p 'json))
  (with-temp-buffer
    (insert (treesit-budget-tests--big-json))
    (let ((parser (treesit-parser-create 'json)))
      (treesit-budget-stats t)
      (treesit-parser-root-node parser)
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :parses) 1))
        (should (equal (plist-get stats :first-parses) 1))
        (should (< 0.008 (plist-get stats :first-max-seconds)))
        (should (equal (plist-get stats :over-1ms) 0))
        (should (equal (plist-get stats :max-seconds) 0.0)))
      (goto-char (point-max))
      (insert " ")
      (treesit-parser-root-node parser)
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :parses) 2))
        (should (equal (plist-get stats :first-parses) 1))))))

(ert-deftest treesit-budget-parse-reports-progress ()
  "Parses go through the progress callback that enforces the limit.
Under the limit the callback never halts, so the tree is complete."
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

;; With a limit of 0 the first progress callback halts the parse, and
;; the big JSON needs many callbacks.

(defun treesit-budget-tests--root-summary (parser)
  "Return a summary of PARSER's tree that differs if the trees differ."
  (let ((root (treesit-parser-root-node parser)))
    (list (treesit-node-end root)
          (treesit-node-child-count (treesit-node-child root 0))
          (treesit-subtree-stat root))))

(defun treesit-budget-tests--empty-root-p (parser)
  "Return non-nil if PARSER's tree is that of an empty input."
  (let ((root (treesit-parser-root-node parser)))
    (and (equal (treesit-node-child-count root) 0)
         (equal (treesit-node-start root) (treesit-node-end root)))))

(ert-deftest treesit-budget-limit-halts-parse ()
  "A parse past the limit halts, and its parser gives up.
It then parses an empty input, without errors and without counting a
parse, even after an edit and with no limit."
  (skip-unless (treesit-language-available-p 'json))
  (skip-unless (<= 15 (treesit-library-abi-version)))
  (with-temp-buffer
    (insert (treesit-budget-tests--big-json))
    (let ((parser (treesit-parser-create 'json))
          (treesit-budget-parse-limit 0)
          (inhibit-message t))
      (treesit-budget-stats t)
      (should (treesit-budget-tests--empty-root-p parser))
      (should (treesit-budget-gave-up-p parser))
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :halts) 1))
        (should (equal (plist-get stats :parses) 1)))
      (let ((treesit-budget-parse-limit nil))
        (goto-char (point-max))
        (insert " ")
        (goto-char (point-min))
        (insert "[0,")
        (should (treesit-budget-tests--empty-root-p parser))
        (should (treesit-budget-gave-up-p parser)))
      (let ((stats (treesit-budget-stats)))
        (should (equal (plist-get stats :halts) 1))
        (should (equal (plist-get stats :parses) 1))))))

(ert-deftest treesit-budget-retry-parses-again ()
  "After a halted reparse and a retry, the tree equals a full parse.
Edits made while the parser had given up are included."
  (skip-unless (treesit-language-available-p 'json))
  (skip-unless (<= 15 (treesit-library-abi-version)))
  (with-temp-buffer
    (insert "[1]")
    (let ((parser (treesit-parser-create 'json))
          (inhibit-message t))
      (treesit-parser-root-node parser)
      (goto-char (point-max))
      (insert (treesit-budget-tests--big-json))
      (let ((treesit-budget-parse-limit 0))
        (should (treesit-budget-tests--empty-root-p parser)))
      (goto-char (point-min))
      (insert "[2],")
      (should (treesit-budget-tests--empty-root-p parser))
      (should (equal (treesit-budget-retry) 1))
      (should-not (treesit-budget-gave-up-p parser))
      (should (equal (treesit-budget-retry) 0))
      (let ((treesit-budget-parse-limit nil))
        (should (equal (treesit-budget-tests--root-summary parser)
                       (treesit-budget-tests--root-summary
                        (treesit-parser-create 'json nil t))))
        ;; Incremental reparses work again after the retry.
        (goto-char (point-min))
        (insert "[3],")
        (should (equal (treesit-budget-tests--root-summary parser)
                       (treesit-budget-tests--root-summary
                        (treesit-parser-create 'json nil t))))))))

(ert-deftest treesit-budget-gave-up-outdates-nodes ()
  "Nodes of a tree dropped by a retry are outdated, not dangling."
  (skip-unless (treesit-language-available-p 'json))
  (skip-unless (<= 15 (treesit-library-abi-version)))
  (with-temp-buffer
    (insert (treesit-budget-tests--big-json))
    (let* ((parser (treesit-parser-create 'json))
           (inhibit-message t)
           (root (let ((treesit-budget-parse-limit 0))
                   (treesit-parser-root-node parser))))
      (should (treesit-budget-gave-up-p parser))
      (treesit-budget-retry)
      (should (treesit-node-check root 'outdated)))))

(ert-deftest treesit-budget-no-limit ()
  "With the limit nil, no parse halts."
  (skip-unless (treesit-language-available-p 'json))
  (with-temp-buffer
    (insert (treesit-budget-tests--big-json))
    (let ((parser (treesit-parser-create 'json))
          (treesit-budget-parse-limit nil))
      (treesit-budget-stats t)
      (treesit-parser-root-node parser)
      (should-not (treesit-budget-gave-up-p parser))
      (should (equal (plist-get (treesit-budget-stats) :halts) 0)))))

(provide 'treesit_budget-tests)
;;; treesit_budget-tests.el ends here

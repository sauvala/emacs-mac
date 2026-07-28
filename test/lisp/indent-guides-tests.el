;;; indent-guides-tests.el --- Tests for indent-guides  -*- lexical-binding: t; -*-

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
(require 'indent-guides)

(ert-deftest indent-guides-tests--spacing-from-tab-width ()
  "A mode with no known indent variable falls back to `tab-width'."
  (with-temp-buffer
    (fundamental-mode)
    (setq-local tab-width 3)
    (should (equal (indent-guides--guess-spacing) 3))))

(ert-deftest indent-guides-tests--spacing-from-mode-variable ()
  "A mode's own indent variable wins over `tab-width'."
  (with-temp-buffer
    (emacs-lisp-mode)
    (setq-local lisp-body-indent 2)
    (setq-local tab-width 8)
    (should (equal (indent-guides--guess-spacing) 2))))

(ert-deftest indent-guides-tests--spacing-ignores-bad-value ()
  "A non-positive indent variable falls back to `tab-width'."
  (with-temp-buffer
    (emacs-lisp-mode)
    (setq-local lisp-body-indent 0)
    (setq-local tab-width 5)
    (should (equal (indent-guides--guess-spacing) 5))))

(ert-deftest indent-guides-tests--mode-enables-display ()
  "Enabling the mode turns on the display variable and sets spacing."
  (with-temp-buffer
    (fundamental-mode)
    (setq-local tab-width 4)
    (indent-guides-mode 1)
    (should display-indent-guides)
    (should (equal display-indent-guides-spacing 4))
    (indent-guides-mode -1)
    (should-not display-indent-guides)
    (should-not display-indent-guides-scope)))

(ert-deftest indent-guides-tests--scope-vector-shape ()
  "The published scope value is a well-formed vector."
  (let ((v (indent-guides--scope-vector 2 '((1 . 5)))))
    (should (vectorp v))
    (should (equal (length v) 3))
    (should (equal (aref v 0) 2))
    (should (equal (aref v 1) 1))
    (should (equal (aref v 2) 5))))

(ert-deftest indent-guides-tests--scope-vector-multiple-ranges ()
  "Several ranges produce one pair each after the depth."
  (let ((v (indent-guides--scope-vector 3 '((1 . 5) (9 . 12)))))
    (should (equal (length v) 5))
    (should (equal (append v nil) '(3 1 5 9 12)))))

(ert-deftest indent-guides-tests--scope-vector-is-usable-by-redisplay ()
  "A published scope vector actually caps the depth redisplay computes."
  (with-temp-buffer
    (insert "                a\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (should (equal (length (internal--indent-guide-stops 1)) 4))
    (setq-local display-indent-guides-scope
                (indent-guides--scope-vector 2 (list (cons (point-min)
                                                           (point-max)))))
    (should (equal (length (internal--indent-guide-stops 1)) 2))))

(ert-deftest indent-guides-tests--no-string-ranges-outside-string ()
  "Point outside a string publishes no string ranges."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun f ()\n  1)\n")
    (goto-char (point-min))
    (should-not (indent-guides--string-ranges))))

(ert-deftest indent-guides-tests--string-ranges-inside-string ()
  "Point inside a multi-line string publishes that string's range."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun f ()\n  \"a\nb\")\n")
    ;; Move point inside the string, which starts at the double quote.
    (goto-char (point-min))
    (search-forward "\"")
    (let ((ranges (indent-guides--string-ranges)))
      (should ranges)
      (should (= (length ranges) 1))
      (should (< (caar ranges) (point)))
      (should (>= (cdar ranges) (point))))))

(provide 'indent-guides-tests)
;;; indent-guides-tests.el ends here

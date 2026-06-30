;;; jit-lock-tests.el --- tests for jit-lock  -*- lexical-binding:t -*-

;; Copyright (C) 2016-2026 Free Software Foundation, Inc.

;; Author: Dmitry Gutov <dgutov@yandex.ru>

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

;;; Code:

(require 'cl-lib)
(require 'jit-lock)
(require 'ert-x)

(defun jit-lock-tests--setup-buffer ()
  (setq font-lock-defaults '(nil t))
  (let (noninteractive)
    (font-lock-mode)))

(ert-deftest jit-lock-fontify-now-fontifies-a-new-buffer ()
  (ert-with-test-buffer (:name "xxx")
    (jit-lock-tests--setup-buffer)
    (insert "xyz")
    (jit-lock-fontify-now (point-min) (point-max))
    (should-not (text-property-not-all (point-min) (point-max) 'fontified t))))

(ert-deftest jit-lock-fontify-now-mends-the-gaps ()
  (ert-with-test-buffer (:name "xxx")
    (jit-lock-tests--setup-buffer)
    (insert "aaabbbcccddd")
    (with-silent-modifications
      (put-text-property 1 4 'fontified t)
      (put-text-property 7 10 'fontified t))
    (jit-lock-fontify-now (point-min) (point-max))
    (should-not (text-property-not-all (point-min) (point-max) 'fontified t))))

(ert-deftest jit-lock-fontify-now-does-not-refontify-unnecessarily ()
  (ert-with-test-buffer (:name "xxx")
    (setq font-lock-defaults
          (list '(((lambda () (error "Don't call me")))) t))
    (let (noninteractive)
      (font-lock-mode))
    (insert "aaa")
    (with-silent-modifications
      (put-text-property (point-min) (point-max) 'fontified t))
    (jit-lock-fontify-now (point-min) (point-max))))

(ert-deftest jit-lock-function-defers-while-input-is-pending ()
  (ert-with-test-buffer (:name "xxx")
    (let ((jit-lock-defer-time nil)
          (jit-lock-defer-on-input t)
          (jit-lock-defer-timer nil)
          (jit-lock-defer-buffers nil)
          fontified)
      (cl-letf (((symbol-function 'input-pending-p) (lambda (&optional _) t)))
        (unwind-protect
            (progn
              (jit-lock-register
               (lambda (_start _end)
                 (setq fontified t)))
              (insert "xyz")
              (jit-lock-function (point-min))
              (should-not fontified)
              (should (memq (current-buffer) jit-lock-defer-buffers))
              (should (eq (get-text-property (point-min) 'fontified)
                          'defer)))
          (jit-lock-mode nil))))))

(ert-deftest jit-lock-function-fontifies-immediately-without-input ()
  (ert-with-test-buffer (:name "xxx")
    (let ((jit-lock-defer-time nil)
          (jit-lock-defer-on-input t)
          (jit-lock-defer-timer nil)
          (jit-lock-defer-buffers nil)
          fontified)
      (cl-letf (((symbol-function 'input-pending-p) (lambda (&optional _) nil)))
        (unwind-protect
            (progn
              (jit-lock-register
               (lambda (_start _end)
                 (setq fontified t)))
              (insert "xyz")
              (jit-lock-function (point-min))
              (should fontified)
              (should-not (memq (current-buffer) jit-lock-defer-buffers))
              (should (eq (get-text-property (point-min) 'fontified) t)))
          (jit-lock-mode nil))))))

;;; jit-lock-tests.el ends here

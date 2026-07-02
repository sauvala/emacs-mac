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

(ert-deftest jit-lock-deferred-fontify-yields-while-input-is-pending ()
  (ert-with-test-buffer (:name "xxx")
    (insert "xyz")
    (with-silent-modifications
      (put-text-property (point-min) (point-max) 'fontified 'defer))
    (let ((jit-lock-defer-on-input t)
          (jit-lock-defer-timer (timer-create))
          (jit-lock--defer-timer-input-only t)
          (jit-lock-defer-buffers (list (current-buffer)))
          redisplayed)
      (cl-letf (((symbol-function 'input-pending-p) (lambda (&optional _) t))
                ((symbol-function 'redisplay)
                 (lambda (&optional _force)
                   (setq redisplayed t)
                   t)))
        (jit-lock-deferred-fontify)
        (should-not redisplayed)
        (should (memq (current-buffer) jit-lock-defer-buffers))
        (should (eq (get-text-property (point-min) 'fontified) 'defer))
        (should (timerp jit-lock-defer-timer))))))

(ert-deftest jit-lock-deferred-fontify-yields-before-redisplay-on-input ()
  (ert-with-test-buffer (:name "xxx")
    (insert "xyz")
    (with-silent-modifications
      (put-text-property (point-min) (point-max) 'fontified 'defer))
    (let ((jit-lock-defer-on-input t)
          (jit-lock-defer-timer (timer-create))
          (jit-lock--defer-timer-input-only t)
          (jit-lock-defer-buffers (list (current-buffer)))
          (input-checks 0)
          redisplayed)
      (cl-letf (((symbol-function 'input-pending-p)
                 (lambda (&optional _)
                   (setq input-checks (1+ input-checks))
                   (> input-checks 1)))
                ((symbol-function 'redisplay)
                 (lambda (&optional _force)
                   (setq redisplayed t)
                   t)))
        (jit-lock-deferred-fontify)
        (should-not redisplayed)
        (should (memq (current-buffer) jit-lock-defer-buffers))
        (should (timerp jit-lock-defer-timer))))))

(ert-deftest jit-lock-deferred-fontify-yields-between-buffers ()
  (let ((buffer-a (generate-new-buffer "jit-lock-a"))
        (buffer-b (generate-new-buffer "jit-lock-b"))
        (jit-lock-defer-on-input t)
        (jit-lock-defer-timer (timer-create))
        (jit-lock--defer-timer-input-only t)
        (input-checks 0)
        redisplayed
        jit-lock-defer-buffers)
    (unwind-protect
        (progn
          (dolist (buffer (list buffer-a buffer-b))
            (with-current-buffer buffer
              (insert "xyz")
              (with-silent-modifications
                (put-text-property (point-min) (point-max)
                                   'fontified 'defer))))
          (setq jit-lock-defer-buffers (list buffer-a buffer-b))
          (cl-letf (((symbol-function 'input-pending-p)
                     (lambda (&optional _)
                       (setq input-checks (1+ input-checks))
                       (= input-checks 2)))
                    ((symbol-function 'redisplay)
                     (lambda (&optional _force)
                       (setq redisplayed t)
                       t)))
            (jit-lock-deferred-fontify)
            (should-not redisplayed)
            (with-current-buffer buffer-a
              (should-not (eq (get-text-property (point-min) 'fontified)
                              'defer)))
            (with-current-buffer buffer-b
              (should (eq (get-text-property (point-min) 'fontified)
                          'defer)))
            (should (equal jit-lock-defer-buffers
                           (list buffer-a buffer-b)))
            (should (timerp jit-lock-defer-timer))))
      (when (buffer-live-p buffer-a)
        (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b)
        (kill-buffer buffer-b)))))

(ert-deftest jit-lock-deferred-fontify-yields-between-regions ()
  (ert-with-test-buffer (:name "xxx")
    (insert "aa bb cc")
    (with-silent-modifications
      (put-text-property 1 3 'fontified 'defer)
      (put-text-property 4 6 'fontified t)
      (put-text-property 7 9 'fontified 'defer))
    (let ((jit-lock-defer-on-input t)
          (jit-lock-defer-timer (timer-create))
          (jit-lock--defer-timer-input-only t)
          (jit-lock-defer-buffers (list (current-buffer)))
          (input-checks 0)
          redisplayed)
      (cl-letf (((symbol-function 'input-pending-p)
                 (lambda (&optional _)
                   (setq input-checks (1+ input-checks))
                   (> input-checks 1)))
                ((symbol-function 'redisplay)
                 (lambda (&optional _force)
                   (setq redisplayed t)
                   t)))
        (jit-lock-deferred-fontify)
        (should-not redisplayed)
        (should (memq (current-buffer) jit-lock-defer-buffers))
        (should-not (eq (get-text-property 1 'fontified) 'defer))
        (should (eq (get-text-property 7 'fontified) 'defer))
        (should (timerp jit-lock-defer-timer))))))

;;; jit-lock-tests.el ends here

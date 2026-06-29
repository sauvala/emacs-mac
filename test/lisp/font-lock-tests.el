;;; font-lock-tests.el --- Test suite for font-lock. -*- lexical-binding: t -*-

;; Copyright (C) 2019-2026 Free Software Foundation, Inc.

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
(require 'elisp-worker)
(require 'font-lock)

(defvar font-lock--async-worker-pool)
(defvar font-lock-async-keywords)
(defvar font-lock--commit-queue)
(defvar font-lock--commit-timer)
(defvar font-lock-commit-dispatch-budget)

(declare-function font-lock--async-fontify-region "font-lock"
                  (beg end keywords))
(declare-function font-lock--async-shutdown-workers "font-lock" ())
(declare-function font-lock--dispatch-commits "font-lock" ())
(declare-function font-lock--queue-commit "font-lock"
                  (buffer tick function &rest args))

(defun font-lock-tests--async-workers-idle-p ()
  "Return non-nil if async font-lock workers have no outstanding callbacks."
  (and font-lock--async-worker-pool
       (let ((idle t))
         (dolist (worker (elisp-worker-pool-workers font-lock--async-worker-pool))
           (when (elisp-worker-callbacks worker)
             (setq idle nil)))
         idle)))

(defun font-lock-tests--wait-for-async-font-lock-idle ()
  "Wait for async font-lock workers and queued commits to become idle."
  (with-timeout (3 (ert-fail "Timed out waiting for async font-lock"))
    (while (not (and (font-lock-tests--async-workers-idle-p)
                     (not font-lock--commit-queue)))
      (accept-process-output nil 0.01)
      (when font-lock--commit-queue
        (font-lock--dispatch-commits)))))

(ert-deftest font-lock-test-append-anonymous-face ()
  "Ensure `font-lock-append-text-property' does not splice anonymous faces."
  (with-temp-buffer
    (insert "foo")
    (add-text-properties 1 3 '(face italic))
    (font-lock-append-text-property 1 3 'face '(:strike-through t))
    (should (equal (get-text-property 1 'face (current-buffer))
                   '(italic (:strike-through t))))))

(ert-deftest font-lock-test-prepend-anonymous-face ()
  "Ensure `font-lock-prepend-text-property' does not splice anonymous faces."
  (with-temp-buffer
    (insert "foo")
    (add-text-properties 1 3 '(face italic))
    (font-lock-prepend-text-property 1 3 'face '(:strike-through t))
    (should (equal (get-text-property 1 'face (current-buffer))
                   '((:strike-through t) italic)))))

(ert-deftest font-lock-commit-queue-drops-stale-buffer-tick ()
  "Queued font-lock commits are dropped after the source buffer changes."
  (let ((old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        (called nil))
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "abc")
          (let ((tick (buffer-chars-modified-tick)))
            (font-lock--queue-commit
             (current-buffer) tick
             (lambda ()
               (setq called t)))
            (insert "d")
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (should (equal (font-lock--dispatch-commits)
                           '(:processed 0 :dropped 1 :remaining 0)))
            (should-not called)))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-commit-queue-respects-dispatch-budget ()
  "A tiny font-lock commit budget leaves backlog for a later timer turn."
  (let ((font-lock-commit-dispatch-budget 0.000001)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        (seen nil))
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "abc")
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (dotimes (i 2)
              (font-lock--queue-commit
               buffer tick
               (lambda (value)
                 (sit-for 0.001)
                 (push value seen))
               i))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (should (equal (font-lock--dispatch-commits)
                           '(:processed 1 :dropped 0 :remaining 1)))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (let ((font-lock-commit-dispatch-budget nil))
              (should (equal (font-lock--dispatch-commits)
                             '(:processed 1 :dropped 0 :remaining 0))))
            (should (equal seen '(1 0)))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-async-fontifies-simple-regexp-from-worker ()
  "Worker-computed font-lock spans are committed to an unchanged buffer."
  (let ((old-pool font-lock--async-worker-pool)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--async-worker-pool nil
          font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta alpha")
          (font-lock--async-fontify-region
           (point-min) (point-max)
           '(("alpha" . font-lock-keyword-face)))
          (with-timeout (3 (ert-fail "Timed out waiting for async font-lock"))
            (while (not (get-text-property 1 'face))
              (accept-process-output nil 0.01)
              (when font-lock--commit-queue
                (font-lock--dispatch-commits))))
          (should (eq (get-text-property 1 'face)
                      'font-lock-keyword-face))
          (should-not (get-text-property 7 'face))
          (should (eq (get-text-property 12 'face)
                      'font-lock-keyword-face)))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when font-lock--async-worker-pool
        (font-lock--async-shutdown-workers))
      (setq font-lock--async-worker-pool old-pool
            font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-async-drops-stale-worker-result ()
  "Worker-computed font-lock spans are dropped after buffer mutation."
  (let ((old-pool font-lock--async-worker-pool)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--async-worker-pool nil
          font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "alpha")
          (font-lock--async-fontify-region
           (point-min) (point-max)
           '(("alpha" . font-lock-keyword-face)))
          (insert " changed")
          (font-lock-tests--wait-for-async-font-lock-idle)
          (should-not (get-text-property 1 'face)))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when font-lock--async-worker-pool
        (font-lock--async-shutdown-workers))
      (setq font-lock--async-worker-pool old-pool
            font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-default-fontify-region-can-use-async-keywords ()
  "The default region fontifier can schedule eligible keywords asynchronously."
  (let ((old-pool font-lock--async-worker-pool)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--async-worker-pool nil
          font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta alpha")
          (let ((font-lock-async-keywords t)
                (font-lock-keywords '(("alpha" . font-lock-keyword-face)))
                (font-lock-keywords-only t)
                (font-lock-keywords-case-fold-search nil)
                (font-lock-set-defaults t)
                (font-lock-syntax-table nil)
                (font-lock-syntactic-keywords nil)
                (font-lock-syntactically-fontified 0)
                (font-lock-extend-region-functions nil))
            (font-lock-default-fontify-region (point-min) (point-max) nil)
            (should-not (get-text-property 1 'face))
            (with-timeout (3 (ert-fail "Timed out waiting for default async font-lock"))
              (while (not (get-text-property 1 'face))
                (accept-process-output nil 0.01)
                (when font-lock--commit-queue
                  (font-lock--dispatch-commits))))
            (should (eq (get-text-property 1 'face)
                        'font-lock-keyword-face))
            (should-not (get-text-property 7 'face))
            (should (eq (get-text-property 12 'face)
                        'font-lock-keyword-face))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when font-lock--async-worker-pool
        (font-lock--async-shutdown-workers))
      (setq font-lock--async-worker-pool old-pool
            font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

;; font-lock-tests.el ends here

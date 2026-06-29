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
(require 'font-lock)

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

;; font-lock-tests.el ends here

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
(require 'cl-lib)
(require 'ert)
(require 'elisp-worker)
(require 'font-lock)

(defvar font-lock--async-worker-pool)
(defvar font-lock-async-keywords)
(defvar font-lock--async-pending-jobs)
(defvar font-lock--commit-queue)
(defvar font-lock--commit-queue-tail)
(defvar font-lock--commit-timer)
(defvar font-lock--pending-redisplay-requests)
(defvar font-lock-commit-dispatch-budget)
(defvar font-lock-async-commit-span-batch-size)

(declare-function font-lock--async-fontify-region "font-lock"
                  (beg end keywords))
(declare-function font-lock--apply-async-spans "font-lock" (spans))
(declare-function font-lock--async-shutdown-workers "font-lock" ())
(declare-function font-lock--dispatch-commits "font-lock" ())
(declare-function font-lock--queue-commit "font-lock"
                  (buffer tick function &rest args))
(declare-function font-lock--queue-span-commits "font-lock"
                  (buffer tick function spans &rest args))
(declare-function jit-lock-force-redisplay "jit-lock" (start end))

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

(ert-deftest font-lock-apply-async-spans-honors-symbolic-overrides ()
  "Async span commits preserve symbolic override semantics."
  (with-temp-buffer
    (insert "abcdefghijkl")
    (put-text-property 1 4 'face 'font-lock-string-face)
    (put-text-property 4 7 'face 'font-lock-string-face)
    (put-text-property 7 10 'face 'font-lock-string-face)
    (font-lock--apply-async-spans
     '((1 4 font-lock-keyword-face append)
       (4 7 font-lock-keyword-face prepend)
       (7 10 font-lock-keyword-face keep)
       (10 13 font-lock-keyword-face keep)))
    (should (equal (get-text-property 1 'face)
                   '(font-lock-string-face font-lock-keyword-face)))
    (should (equal (get-text-property 4 'face)
                   '(font-lock-keyword-face font-lock-string-face)))
    (should (eq (get-text-property 7 'face)
                'font-lock-string-face))
    (should (eq (get-text-property 10 'face)
                'font-lock-keyword-face))))

(ert-deftest font-lock-commit-queue-drops-stale-buffer-tick ()
  "Queued font-lock commits are dropped after the source buffer changes."
  (let ((old-queue font-lock--commit-queue)
        (old-tail font-lock--commit-queue-tail)
        (old-timer font-lock--commit-timer)
        (called nil))
    (setq font-lock--commit-queue nil
          font-lock--commit-queue-tail nil
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
            font-lock--commit-queue-tail old-tail
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-commit-queue-maintains-tail-pointer ()
  "Queued font-lock commits maintain an append tail and reset it on drain."
  (let ((old-queue font-lock--commit-queue)
        (old-tail font-lock--commit-queue-tail)
        (old-timer font-lock--commit-timer))
    (setq font-lock--commit-queue nil
          font-lock--commit-queue-tail nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "abc")
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (font-lock--queue-commit buffer tick #'ignore 1)
            (should (eq font-lock--commit-queue-tail
                        (last font-lock--commit-queue)))
            (font-lock--queue-commit buffer tick #'ignore 2)
            (should (eq font-lock--commit-queue-tail
                        (last font-lock--commit-queue)))
            (should (= (length font-lock--commit-queue) 2))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (should (equal (font-lock--dispatch-commits)
                           '(:processed 2 :dropped 0 :remaining 0)))
            (should-not font-lock--commit-queue)
            (should-not font-lock--commit-queue-tail)))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-queue-tail old-tail
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-queue-span-commits-splits-large-span-lists ()
  "Large async span lists are split into multiple queued commits."
  (let ((font-lock-async-commit-span-batch-size 1)
        (font-lock-commit-defer-on-input nil)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (font-lock--queue-span-commits
             buffer tick #'font-lock--apply-async-spans
             '((1 2 font-lock-keyword-face)
               (3 4 font-lock-string-face)))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (should (= (length font-lock--commit-queue) 2))
            (should (equal (nth 3 (car font-lock--commit-queue))
                           '(((1 2 font-lock-keyword-face)))))
            (should (equal (nth 3 (cadr font-lock--commit-queue))
                           '(((3 4 font-lock-string-face)))))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-queue-span-commits-yields-while-input-is-pending ()
  "Async span commit queueing leaves remaining split work for later."
  (let ((font-lock-async-commit-span-batch-size 1)
        (font-lock-commit-defer-on-input t)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (cl-letf (((symbol-function 'input-pending-p)
                       (lambda (&optional _) t)))
              (font-lock--queue-span-commits
               buffer tick #'ignore
               '((1 2 font-lock-keyword-face)
                 (3 4 font-lock-string-face)
                 (5 6 font-lock-comment-face))
               :extra))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (should (= (length font-lock--commit-queue) 2))
            (should (eq (nth 2 (car font-lock--commit-queue))
                        #'ignore))
            (should (equal (nth 3 (car font-lock--commit-queue))
                           '(((1 2 font-lock-keyword-face)) :extra)))
            (should (eq (nth 2 (cadr font-lock--commit-queue))
                        #'font-lock--queue-span-commit-continuation))
            (should (equal (nth 3 (cadr font-lock--commit-queue))
                           `(,tick
                             ,#'ignore
                             ((3 4 font-lock-string-face)
                              (5 6 font-lock-comment-face))
                             :extra)))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-queue-span-commits-is-bounded-without-input ()
  "Async span commit queueing uses a continuation for remaining split work."
  (let ((font-lock-async-commit-span-batch-size 1)
        (font-lock-commit-defer-on-input t)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (cl-letf (((symbol-function 'input-pending-p)
                       (lambda (&optional _) nil)))
              (font-lock--queue-span-commits
               buffer tick #'ignore
               '((1 2 font-lock-keyword-face)
                 (3 4 font-lock-string-face)
                 (5 6 font-lock-comment-face))))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (should (= (length font-lock--commit-queue) 2))
            (should (eq (nth 2 (car font-lock--commit-queue))
                        #'ignore))
            (should (eq (nth 2 (cadr font-lock--commit-queue))
                        #'font-lock--queue-span-commit-continuation))
            (should (equal (nth 3 (cadr font-lock--commit-queue))
                           `(,tick
                             ,#'ignore
                             ((3 4 font-lock-string-face)
                              (5 6 font-lock-comment-face)))))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-commit-queue-forces-redisplay-for-returned-region ()
  "Queued commits can request redisplay after applying async faces."
  (let ((old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        calls)
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "abc")
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (cl-letf (((symbol-function 'jit-lock-force-redisplay)
                       (lambda (start end)
                         (push (list (marker-buffer start)
                                     (marker-position start)
                                     (marker-position end))
                               calls))))
              (font-lock--queue-commit
               buffer tick
               (lambda ()
                 '(font-lock-redisplay 1 . 4)))
              (when (timerp font-lock--commit-timer)
                (cancel-timer font-lock--commit-timer)
                (setq font-lock--commit-timer nil))
              (should (equal (font-lock--dispatch-commits)
                             '(:processed 1 :dropped 0 :remaining 0)))
              (should (equal calls
                             `((,buffer 1 4)))))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-commit-queue-coalesces-redisplay-requests ()
  "Queued commits coalesce redisplay requests in one dispatch turn."
  (let ((old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        calls)
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "abcdef")
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (cl-letf (((symbol-function 'jit-lock-force-redisplay)
                       (lambda (start end)
                         (push (list (marker-buffer start)
                                     (marker-position start)
                                     (marker-position end))
                               calls))))
              (font-lock--queue-commit
               buffer tick
               (lambda ()
                 '(font-lock-redisplay 1 . 3)))
              (font-lock--queue-commit
               buffer tick
               (lambda ()
                 '(font-lock-redisplay 4 . 7)))
              (when (timerp font-lock--commit-timer)
                (cancel-timer font-lock--commit-timer)
                (setq font-lock--commit-timer nil))
              (should (equal (font-lock--dispatch-commits)
                             '(:processed 2 :dropped 0 :remaining 0)))
              (should (equal calls
                             `((,buffer 1 7)))))))
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
                 (let ((end (+ (float-time) 0.001)))
                   (while (< (float-time) end)))
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

(ert-deftest font-lock-commit-queue-yields-while-input-is-pending ()
  "Font-lock commit dispatch leaves backlog while input is pending."
  (let ((font-lock-commit-dispatch-budget nil)
        (font-lock-commit-defer-on-input t)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        seen)
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
                 (push value seen))
               i))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (cl-letf (((symbol-function 'input-pending-p)
                       (lambda (&optional _) t)))
              (should (equal (font-lock--dispatch-commits)
                             '(:processed 1 :dropped 0 :remaining 1))))
            (should (timerp font-lock--commit-timer))
            (should (equal seen '(0)))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-commit-queue-defers-redisplay-on-input ()
  "Font-lock commit dispatch defers redisplay requests while input is pending."
  (let ((font-lock-commit-dispatch-budget nil)
        (font-lock-commit-defer-on-input t)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        (old-redisplay font-lock--pending-redisplay-requests)
        (input-pending t)
        calls)
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil
          font-lock--pending-redisplay-requests nil)
    (unwind-protect
        (with-temp-buffer
          (insert "abc")
          (let ((buffer (current-buffer))
                (tick (buffer-chars-modified-tick)))
            (font-lock--queue-commit
             buffer tick
             (lambda ()
               '(font-lock-redisplay 1 . 3)))
            (when (timerp font-lock--commit-timer)
              (cancel-timer font-lock--commit-timer)
              (setq font-lock--commit-timer nil))
            (cl-letf (((symbol-function 'input-pending-p)
                       (lambda (&optional _)
                         input-pending))
                      ((symbol-function 'jit-lock-force-redisplay)
                       (lambda (start end)
                         (push (list (marker-buffer start)
                                     (marker-position start)
                                     (marker-position end))
                               calls))))
              (should (equal (font-lock--dispatch-commits)
                             '(:processed 1 :dropped 0 :remaining 0)))
              (should-not calls)
              (should (timerp font-lock--commit-timer))
              (should (equal font-lock--pending-redisplay-requests
                             `((,buffer 1 . 3))))
              (setq input-pending nil)
              (should (equal (font-lock--dispatch-commits)
                             '(:processed 0 :dropped 0 :remaining 0)))
              (should (equal calls
                             `((,buffer 1 3)))))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer
            font-lock--pending-redisplay-requests old-redisplay))))

(ert-deftest font-lock-commit-queue-yields-during-redisplay-flush ()
  "Font-lock redisplay flushing yields and preserves remaining requests."
  (let ((font-lock-commit-dispatch-budget nil)
        (font-lock-commit-defer-on-input t)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        (old-redisplay font-lock--pending-redisplay-requests)
        (input-checks 0)
        calls
        buffer-a
        buffer-b)
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil
          font-lock--pending-redisplay-requests nil)
    (unwind-protect
        (progn
          (setq buffer-a (generate-new-buffer "font-lock-a")
                buffer-b (generate-new-buffer "font-lock-b"))
          (with-current-buffer buffer-a
            (insert "abc"))
          (with-current-buffer buffer-b
            (insert "def"))
          (font-lock--queue-commit
           buffer-a (with-current-buffer buffer-a
                      (buffer-chars-modified-tick))
           (lambda ()
             '(font-lock-redisplay 1 . 3)))
          (font-lock--queue-commit
           buffer-b (with-current-buffer buffer-b
                      (buffer-chars-modified-tick))
           (lambda ()
             '(font-lock-redisplay 1 . 3)))
          (when (timerp font-lock--commit-timer)
            (cancel-timer font-lock--commit-timer)
            (setq font-lock--commit-timer nil))
          (cl-letf (((symbol-function 'input-pending-p)
                     (lambda (&optional _)
                       (setq input-checks (1+ input-checks))
                       (> input-checks 2)))
                    ((symbol-function 'jit-lock-force-redisplay)
                     (lambda (start end)
                       (push (list (marker-buffer start)
                                   (marker-position start)
                                   (marker-position end))
                             calls))))
            (should (equal (font-lock--dispatch-commits)
                           '(:processed 2 :dropped 0 :remaining 0)))
            (should (equal calls
                           `((,buffer-b 1 3))))
            (should (timerp font-lock--commit-timer))
            (should (equal font-lock--pending-redisplay-requests
                           `((,buffer-a 1 . 3))))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when (buffer-live-p buffer-a)
        (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b)
        (kill-buffer buffer-b))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer
            font-lock--pending-redisplay-requests old-redisplay))))

(ert-deftest font-lock-commit-queue-budgets-redisplay-flush ()
  "Font-lock redisplay flushing respects the dispatch time budget."
  (let ((font-lock-commit-dispatch-budget 0.5)
        (font-lock-commit-defer-on-input t)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        (old-redisplay font-lock--pending-redisplay-requests)
        calls
        buffer-a
        buffer-b)
    (setq font-lock--commit-queue nil
          font-lock--commit-timer nil
          font-lock--pending-redisplay-requests nil)
    (unwind-protect
        (progn
          (setq buffer-a (generate-new-buffer "font-lock-budget-a")
                buffer-b (generate-new-buffer "font-lock-budget-b"))
          (with-current-buffer buffer-a
            (insert "abc"))
          (with-current-buffer buffer-b
            (insert "def"))
          (font-lock--queue-commit
           buffer-a (with-current-buffer buffer-a
                      (buffer-chars-modified-tick))
           (lambda ()
             '(font-lock-redisplay 1 . 3)))
          (font-lock--queue-commit
           buffer-b (with-current-buffer buffer-b
                      (buffer-chars-modified-tick))
           (lambda ()
             '(font-lock-redisplay 1 . 3)))
          (when (timerp font-lock--commit-timer)
            (cancel-timer font-lock--commit-timer)
            (setq font-lock--commit-timer nil))
          (cl-letf (((symbol-function 'input-pending-p)
                     (lambda (&optional _) nil))
                    ((symbol-function 'float-time)
                     (lambda (&optional _time)
                       (if calls 1 0)))
                    ((symbol-function 'jit-lock-force-redisplay)
                     (lambda (start end)
                       (push (list (marker-buffer start)
                                   (marker-position start)
                                   (marker-position end))
                             calls))))
            (should (equal (font-lock--dispatch-commits)
                           '(:processed 2 :dropped 0 :remaining 0)))
            (should (= (length calls) 1))
            (pcase-let ((`((,flushed-buffer 1 3)) calls)
                        (`((,pending-buffer 1 . 3))
                         font-lock--pending-redisplay-requests))
              (should (memq flushed-buffer (list buffer-a buffer-b)))
              (should (memq pending-buffer (list buffer-a buffer-b)))
              (should-not (eq flushed-buffer pending-buffer)))
            (should (timerp font-lock--commit-timer))
            (should (= (length font-lock--pending-redisplay-requests)
                       1))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when (buffer-live-p buffer-a)
        (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b)
        (kill-buffer buffer-b))
      (setq font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer
            font-lock--pending-redisplay-requests old-redisplay))))

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

(ert-deftest font-lock-async-deduplicates-pending-region-work ()
  "Duplicate async font-lock work is not resubmitted while pending."
  (let ((old-pool font-lock--async-worker-pool)
        (old-pending font-lock--async-pending-jobs)
        submissions)
    (setq font-lock--async-worker-pool nil
          font-lock--async-pending-jobs (make-hash-table :test #'equal))
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta alpha")
          (cl-letf (((symbol-function 'elisp-worker-pool-async-eval)
                     (lambda (_pool form &rest _args)
                       (push form submissions))))
            (font-lock--async-fontify-region
             (point-min) (point-max)
             '(("alpha" . font-lock-keyword-face)))
            (font-lock--async-fontify-region
             (point-min) (point-max)
             '(("alpha" . font-lock-keyword-face)))
            (should (= (length submissions) 1))))
      (when font-lock--async-worker-pool
        (font-lock--async-shutdown-workers))
      (setq font-lock--async-worker-pool old-pool
            font-lock--async-pending-jobs old-pending))))

(ert-deftest font-lock-async-forces-redisplay-after-worker-commit ()
  "Async font-lock commits request redisplay after applying faces."
  (let ((old-pool font-lock--async-worker-pool)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        calls)
    (setq font-lock--async-worker-pool nil
          font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta")
          (let ((buffer (current-buffer))
                (font-lock-keywords-case-fold-search nil))
            (cl-letf (((symbol-function 'jit-lock-force-redisplay)
                       (lambda (start end)
                         (push (list (marker-buffer start)
                                     (marker-position start)
                                     (marker-position end))
                               calls))))
              (font-lock--async-fontify-region
               (point-min) (point-max)
               '(("alpha" . font-lock-keyword-face)))
              (font-lock-tests--wait-for-async-font-lock-idle)
              (should (eq (get-text-property 1 'face)
                          'font-lock-keyword-face))
              (should (equal calls
                             `((,buffer 1 6)))))))
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

(ert-deftest font-lock-async-skips-queue-for-stale-worker-result ()
  "Stale worker-computed font-lock spans are not queued for commit."
  (let ((old-pool font-lock--async-worker-pool)
        (old-pending font-lock--async-pending-jobs)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer)
        success-fn)
    (setq font-lock--async-worker-pool nil
          font-lock--async-pending-jobs (make-hash-table :test #'equal)
          font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "alpha")
          (cl-letf (((symbol-function 'elisp-worker-pool-async-eval)
                     (lambda (_pool _form &rest args)
                       (setq success-fn (plist-get args :success-fn)))))
            (font-lock--async-fontify-region
             (point-min) (point-max)
             '(("alpha" . font-lock-keyword-face)))
            (insert " changed")
            (funcall success-fn '((1 6 font-lock-keyword-face)))
            (should-not font-lock--commit-queue)
            (should (= (hash-table-count font-lock--async-pending-jobs)
                       0))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when font-lock--async-worker-pool
        (font-lock--async-shutdown-workers))
      (setq font-lock--async-worker-pool old-pool
            font-lock--async-pending-jobs old-pending
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

(ert-deftest font-lock-default-fontify-region-uses-async-keywords-by-default ()
  "Eligible keyword fontification is asynchronous without local opt-in."
  (let ((old-pool font-lock--async-worker-pool)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--async-worker-pool nil
          font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta alpha")
          (let ((font-lock-keywords '(("alpha" . font-lock-keyword-face)))
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

(ert-deftest font-lock-default-fontify-region-can-use-compiled-async-keywords ()
  "The async keyword path accepts compiled simple keyword specs."
  (let ((old-pool font-lock--async-worker-pool)
        (old-queue font-lock--commit-queue)
        (old-timer font-lock--commit-timer))
    (setq font-lock--async-worker-pool nil
          font-lock--commit-queue nil
          font-lock--commit-timer nil)
    (unwind-protect
        (with-temp-buffer
          (insert "alpha beta alpha")
          (let* ((font-lock-set-defaults t)
                 (compiled-keywords
                  (font-lock-compile-keywords
                   '(("alpha" . font-lock-keyword-face))))
                 (font-lock-async-keywords t)
                 (font-lock-keywords compiled-keywords)
                 (font-lock-keywords-only t)
                 (font-lock-keywords-case-fold-search nil)
                 (font-lock-syntax-table nil)
                 (font-lock-syntactic-keywords nil)
                 (font-lock-syntactically-fontified 0)
                 (font-lock-extend-region-functions nil))
            (font-lock-default-fontify-region (point-min) (point-max) nil)
            (should-not (get-text-property 1 'face))
            (with-timeout (3 (ert-fail "Timed out waiting for compiled async font-lock"))
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

(ert-deftest font-lock-default-fontify-region-can-use-async-override-keywords ()
  "The async keyword path accepts simple specs with override."
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
                (font-lock-keywords '(("alpha" 0 font-lock-keyword-face t)))
                (font-lock-keywords-only t)
                (font-lock-keywords-case-fold-search nil)
                (font-lock-set-defaults t)
                (font-lock-syntax-table nil)
                (font-lock-syntactic-keywords nil)
                (font-lock-syntactically-fontified 0)
                (font-lock-extend-region-functions nil))
            (font-lock-default-fontify-region (point-min) (point-max) nil)
            (should-not (get-text-property 1 'face))
            (with-timeout (3 (ert-fail "Timed out waiting for override async font-lock"))
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

(ert-deftest font-lock-default-fontify-region-can-use-async-symbolic-overrides ()
  "The async keyword path accepts simple specs with symbolic overrides."
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
                (font-lock-keywords
                 '(("alpha" 0 font-lock-keyword-face append)))
                (font-lock-keywords-only t)
                (font-lock-keywords-case-fold-search nil)
                (font-lock-set-defaults t)
                (font-lock-syntax-table nil)
                (font-lock-syntactic-keywords nil)
                (font-lock-syntactically-fontified 0)
                (font-lock-extend-region-functions nil))
            (font-lock-default-fontify-region (point-min) (point-max) nil)
            (should-not (get-text-property 1 'face))
            (with-timeout (3 (ert-fail "Timed out waiting for symbolic override async font-lock"))
              (while (not (get-text-property 1 'face))
                (accept-process-output nil 0.01)
                (when font-lock--commit-queue
                  (font-lock--dispatch-commits))))
            (should (get-text-property 1 'face))
            (should-not (get-text-property 7 'face))
            (should (get-text-property 12 'face))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when font-lock--async-worker-pool
        (font-lock--async-shutdown-workers))
      (setq font-lock--async-worker-pool old-pool
            font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

(ert-deftest font-lock-default-fontify-region-can-use-async-laxmatch-keywords ()
  "The async keyword path accepts simple specs with lax matching."
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
                (font-lock-keywords
                 '(("alpha\\|\\(beta\\)" 1 font-lock-keyword-face nil t)))
                (font-lock-keywords-only t)
                (font-lock-keywords-case-fold-search nil)
                (font-lock-set-defaults t)
                (font-lock-syntax-table nil)
                (font-lock-syntactic-keywords nil)
                (font-lock-syntactically-fontified 0)
                (font-lock-extend-region-functions nil))
            (font-lock-default-fontify-region (point-min) (point-max) nil)
            (should-not (get-text-property 7 'face))
            (with-timeout (3 (ert-fail "Timed out waiting for laxmatch async font-lock"))
              (while (not (get-text-property 7 'face))
                (accept-process-output nil 0.01)
                (when font-lock--commit-queue
                  (font-lock--dispatch-commits))))
            (should-not (get-text-property 1 'face))
            (should (eq (get-text-property 7 'face)
                        'font-lock-keyword-face))
            (should-not (get-text-property 12 'face))))
      (when (timerp font-lock--commit-timer)
        (cancel-timer font-lock--commit-timer))
      (when font-lock--async-worker-pool
        (font-lock--async-shutdown-workers))
      (setq font-lock--async-worker-pool old-pool
            font-lock--commit-queue old-queue
            font-lock--commit-timer old-timer))))

;; font-lock-tests.el ends here

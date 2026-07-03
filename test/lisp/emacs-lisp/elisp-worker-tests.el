;;; elisp-worker-tests.el --- Tests for elisp-worker.el  -*- lexical-binding: t; -*-

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

(require 'benchmark)
(require 'ert)
(require 'elisp-worker)

(ert-deftest elisp-worker-async-eval-does-not-block-caller ()
  "Submitting worker Lisp returns before the worker job completes."
  (let ((worker (elisp-worker-start))
        result
        elapsed)
    (unwind-protect
        (progn
          (setq elapsed
                (benchmark-elapse
                  (elisp-worker-async-eval
                   worker
                   '(progn
                      (sleep-for 0.2)
                      (+ 19 23))
                   :success-fn (lambda (value)
                                 (setq result value)))))
          (should (< elapsed 0.1))
          (with-timeout (3 (ert-fail "Timed out waiting for worker result"))
            (while (not result)
              (accept-process-output nil 0.01)))
          (should (= result 42)))
      (elisp-worker-shutdown worker))))

(ert-deftest elisp-worker-async-eval-reports-errors ()
  "Worker Lisp errors are reported to the request error callback."
  (let ((worker (elisp-worker-start))
        error-message)
    (unwind-protect
        (progn
          (elisp-worker-async-eval
           worker
           '(error "worker failed")
           :error-fn (lambda (message _data)
                       (setq error-message message)))
          (with-timeout (3 (ert-fail "Timed out waiting for worker error"))
            (while (not error-message)
              (accept-process-output nil 0.01)))
          (should (string-match-p "worker failed" error-message)))
      (elisp-worker-shutdown worker))))

(ert-deftest elisp-worker-async-eval-round-trips-newline-strings ()
  "Worker requests can contain strings with embedded newlines."
  (let ((worker (elisp-worker-start))
        result
        error-message)
    (unwind-protect
        (progn
          (elisp-worker-async-eval
           worker
           '(concat "alpha\n" "beta")
           :success-fn (lambda (value)
                         (setq result value))
           :error-fn (lambda (message _data)
                       (setq error-message message)))
          (with-timeout (3 (ert-fail "Timed out waiting for worker newline result"))
            (while (and (not result) (not error-message))
              (accept-process-output nil 0.01)))
          (should-not error-message)
          (should (equal result "alpha\nbeta")))
      (elisp-worker-shutdown worker))))

(ert-deftest elisp-worker-filter-yields-while-input-is-pending ()
  "Worker response dispatch leaves backlog while input is pending."
  (skip-unless (executable-find "cat"))
  (let ((elisp-worker-response-dispatch-budget nil)
        (elisp-worker-response-dispatch-defer-on-input t)
        (elisp-worker-response-parse-defer-on-input nil)
        (worker (elisp-worker--make))
        called
        proc)
    (unwind-protect
        (progn
          (setq proc (make-process
                      :name "elisp-worker-filter-test"
                      :buffer (generate-new-buffer
                               " *elisp-worker-filter-test*")
                      :command (list "cat")
                      :connection-type 'pipe
                      :noquery t))
          (process-put proc 'elisp-worker worker)
          (setf (elisp-worker-process worker) proc)
          (dotimes (i 3)
            (push (cons (1+ i)
                        (list :success-fn
                              (lambda (value)
                                (push value called))))
                  (elisp-worker-callbacks worker)))
          (cl-letf (((symbol-function 'input-pending-p)
                     (lambda (&optional _) t)))
            (elisp-worker--filter
             proc
             (concat
              (mapconcat
               #'prin1-to-string
               '((:id 1 :status ok :value 1)
                 (:id 2 :status ok :value 2)
                 (:id 3 :status ok :value 3))
               "\n")
              "\n")))
          (should (= (length called) 1))
          (should (= (length (elisp-worker-pending-responses worker)) 2))
          (should (timerp (elisp-worker-dispatch-timer worker))))
      (when (and worker (timerp (elisp-worker-dispatch-timer worker)))
        (cancel-timer (elisp-worker-dispatch-timer worker)))
      (when proc
        (when (process-live-p proc)
          (set-process-sentinel proc #'ignore)
          (delete-process proc))
        (when-let* ((buffer (process-buffer proc)))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest elisp-worker-filter-parsing-yields-while-input-is-pending ()
  "Worker response parsing leaves raw output backlog while input is pending."
  (skip-unless (executable-find "cat"))
  (let ((elisp-worker-response-dispatch-budget nil)
        (elisp-worker-response-dispatch-defer-on-input nil)
        (elisp-worker-response-parse-budget nil)
        (elisp-worker-response-parse-defer-on-input t)
        (worker (elisp-worker--make))
        called
        input-pending
        proc)
    (unwind-protect
        (progn
          (setq proc (make-process
                      :name "elisp-worker-parse-test"
                      :buffer (generate-new-buffer
                               " *elisp-worker-parse-test*")
                      :command (list "cat")
                      :connection-type 'pipe
                      :noquery t))
          (process-put proc 'elisp-worker worker)
          (setf (elisp-worker-process worker) proc)
          (dotimes (i 3)
            (push (cons (1+ i)
                        (list :success-fn
                              (lambda (value)
                                (push value called))))
                  (elisp-worker-callbacks worker)))
          (setq input-pending t)
          (cl-letf (((symbol-function 'input-pending-p)
                     (lambda (&optional _) input-pending)))
            (elisp-worker--filter
             proc
             (concat
              (mapconcat
               #'prin1-to-string
               '((:id 1 :status ok :value 1)
                 (:id 2 :status ok :value 2)
                 (:id 3 :status ok :value 3))
               "\n")
              "\n")))
          (should (= (length called) 1))
          (should (string-match-p ":id 2" (elisp-worker-partial-output worker)))
          (should (timerp (elisp-worker-parse-timer worker)))
          (setq input-pending nil)
          (cl-letf (((symbol-function 'input-pending-p)
                     (lambda (&optional _) input-pending)))
            (elisp-worker--filter proc ""))
          (should (= (length called) 3))
          (should (string-empty-p (elisp-worker-partial-output worker)))
          (should-not (elisp-worker-parse-timer worker)))
      (when (and worker (timerp (elisp-worker-parse-timer worker)))
        (cancel-timer (elisp-worker-parse-timer worker)))
      (when proc
        (when (process-live-p proc)
          (set-process-sentinel proc #'ignore)
          (delete-process proc))
        (when-let* ((buffer (process-buffer proc)))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest elisp-worker-pool-runs-jobs-concurrently ()
  "A worker pool can run independent Lisp jobs in parallel processes."
  (let ((pool (elisp-worker-pool-start 2))
        (results nil)
        elapsed)
    (unwind-protect
        (progn
          (setq elapsed
                (benchmark-elapse
                  (dotimes (i 2)
                    (elisp-worker-pool-async-eval
                     pool
                     `(progn
                        (sleep-for 0.25)
                        ,i)
                     :success-fn (lambda (value)
                                   (push value results))))
                  (with-timeout (4 (ert-fail "Timed out waiting for pool"))
                    (while (< (length results) 2)
                      (accept-process-output nil 0.01)))))
          (should (< elapsed 0.45))
          (should (equal (sort results #'<) '(0 1))))
      (elisp-worker-pool-shutdown pool))))

(ert-deftest elisp-worker-pool-prefers-idle-worker ()
  "Worker pool scheduling prefers workers with less pending work."
  (let* ((busy-worker (elisp-worker--make
                       :callbacks '((1 . (:success-fn ignore))
                                    (2 . (:success-fn ignore)))))
         (idle-worker (elisp-worker--make))
         (pool (elisp-worker-pool--make
                :workers (list busy-worker idle-worker)
                :cursor 0
                :target-size 2
                :name "worker-scheduling-test")))
    (should (eq (elisp-worker-pool--next-worker pool) idle-worker))
    (should (= (elisp-worker-pool-cursor pool) 0))))

(ert-deftest elisp-worker-pool-start-lazy-grows-after-startup ()
  "A lazy worker pool starts one worker and grows later."
  (let ((pool (elisp-worker-pool-start-lazy 2 "lazy-worker-test")))
    (unwind-protect
        (progn
          (should (= (length (elisp-worker-pool-workers pool)) 1))
          (with-timeout (3 (ert-fail "Timed out waiting for lazy worker pool"))
            (while (< (length (elisp-worker-pool-workers pool)) 2)
              (accept-process-output nil 0.01)))
          (should (= (length (elisp-worker-pool-workers pool)) 2)))
      (elisp-worker-pool-shutdown pool))))

;;; elisp-worker-tests.el ends here

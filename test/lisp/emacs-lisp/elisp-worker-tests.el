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

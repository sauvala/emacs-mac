;;; mac-performance-benchmark-tests.el --- Tests for macOS GUI benchmark harness -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Free Software Foundation, Inc.

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

;; Unit tests for test/src/mac-performance-benchmark.el helpers.

;;; Code:

(require 'ert)

(load-file (expand-file-name "mac-performance-benchmark.el"
                             (file-name-directory
                              (or load-file-name buffer-file-name))))

(ert-deftest mac-performance-benchmark-latency-summary ()
  "Latency summaries should report count, total, p50, p95, and max."
  (let* ((summary (mac-performance--latency-summary
                   '((redisplay 0.004 0.003 0.002 0.001)
                     (typing-command 0.010))))
         (redisplay (alist-get 'redisplay summary))
         (typing (alist-get 'typing-command summary)))
    (should (= (plist-get redisplay :count) 4))
    (should (= (plist-get redisplay :total-seconds) 0.010))
    (should (= (plist-get redisplay :p50-seconds) 0.002))
    (should (= (plist-get redisplay :p95-seconds) 0.004))
    (should (= (plist-get redisplay :max-seconds) 0.004))
    (should (= (plist-get typing :count) 1))
    (should (= (plist-get typing :p50-seconds) 0.010))
    (should (= (plist-get typing :p95-seconds) 0.010))))

(ert-deftest mac-performance-benchmark-records-latency-samples ()
  "Timed benchmark blocks should be recorded while collection is enabled."
  (let ((mac-performance--collect-latency t)
        mac-performance--latency-samples)
    (should (eq (mac-performance--time-latency 'sample #'ignore) nil))
    (let ((summary (mac-performance--latency-summary
                    mac-performance--latency-samples)))
      (should (= (plist-get (alist-get 'sample summary) :count) 1))
      (should (numberp (plist-get (alist-get 'sample summary)
                                  :max-seconds))))))

(ert-deftest mac-performance-benchmark-records-command-loop-latency ()
  "Keyboard macros should record command-loop command latency."
  (with-temp-buffer
    (switch-to-buffer (current-buffer))
    (let ((mac-performance--collect-latency t)
          mac-performance--latency-samples)
      (mac-performance--execute-kbd-macro-with-command-latency [?a ?b])
      (let ((summary (mac-performance--latency-summary
                      mac-performance--latency-samples)))
        (should (equal (buffer-string) "ab"))
        (should (= (plist-get (alist-get 'command-loop-command summary)
                              :count)
                   2))
        (should (= (plist-get (alist-get 'command-loop-macro summary)
                              :count)
                   1))))))

(ert-deftest mac-performance-benchmark-registers-latency-scenarios ()
  "The benchmark harness should include typing and process-output workloads."
  (should (assoc "command-loop-input" mac-performance--scenarios))
  (should (assoc "typing-source" mac-performance--scenarios))
  (should (assoc "process-output" mac-performance--scenarios))
  (should (assoc "coding-edit-churn" mac-performance--scenarios))
  (should (assoc "coding-input-pressure" mac-performance--scenarios))
  (should (assoc "coding-deferred-actions" mac-performance--scenarios)))

(ert-deftest mac-performance-benchmark-compares-results ()
  "Benchmark result comparison should report elapsed and latency ratios."
  (let* ((baseline '(:status ok :iterations 10
                     :results ((:name "coding-edit-churn"
                                :seconds 2.0
                                :latency ((typing-command
                                           :count 2
                                           :p95-seconds 0.020))))))
         (candidate '(:status ok :iterations 10
                      :results ((:name "coding-edit-churn"
                                 :seconds 1.0
                                 :latency ((typing-command
                                            :count 2
                                            :p95-seconds 0.010))))))
         (summary (mac-performance-compare-results baseline candidate))
         (row (car (plist-get summary :scenarios))))
    (should (equal (plist-get row :name) "coding-edit-churn"))
    (should (= (plist-get row :baseline-seconds) 2.0))
    (should (= (plist-get row :candidate-seconds) 1.0))
    (should (= (plist-get row :seconds-ratio) 0.5))
    (should (= (plist-get row :typing-command-p95-ratio) 0.5))))

(provide 'mac-performance-benchmark-tests)

;;; mac-performance-benchmark-tests.el ends here

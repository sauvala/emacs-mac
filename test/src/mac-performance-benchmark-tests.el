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
  (should (assoc "process-output" mac-performance--scenarios)))

(provide 'mac-performance-benchmark-tests)

;;; mac-performance-benchmark-tests.el ends here

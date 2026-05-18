;;; source-invariants.el --- Tests for macOS benchmark harness source  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect the macOS performance benchmark harness.  They keep the
;; harness aligned with the mac-port-specific scenarios and counters listed in
;; docs/emacs-mac-performance-findings.md.

;;; Code:

(require 'ert)

(defun mac-benchmark-tests--source ()
  "Return the contents of test/src/mac-performance-benchmark.el."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "test/src/mac-performance-benchmark.el"
                       source-directory))
    (buffer-string)))

(defun mac-benchmark-tests--repo-source (file)
  "Return the contents of FILE relative to `source-directory'."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file source-directory))
    (buffer-string)))

(ert-deftest mac-benchmark-covers-mac-performance-scenarios ()
  "The benchmark harness should cover mac-port GUI performance scenarios."
  (let ((source (mac-benchmark-tests--source)))
    (dolist (pattern '("mac-performance-run-benchmarks"
                       "mac-performance--scenario-scroll-source"
                       "mac-performance--scenario-mixed-script"
                       "mac-performance--scenario-emoji"
                       "mac-performance--scenario-inline-images"
                       "mac-performance--scenario-modeline-fringe"
                       "mac-metal-render-stats"
                       "mac-metal-clip-overdraw-stats"
                       "mac-select-latency-stats"))
      (should (string-match-p pattern source)))))

(ert-deftest mac-benchmark-covers-metal-presentation-coalescing-counters ()
  "Metal render stats should expose async presentation coalescing counters."
  (let ((header (mac-benchmark-tests--repo-source "src/macmetal.h"))
        (implementation (mac-benchmark-tests--repo-source "src/macmetal.m"))
        (macterm (mac-benchmark-tests--repo-source "src/macterm.c")))
    (dolist (pattern '("presentation_requests"
                       "presentation_coalesced_requests"
                       "presentation_task_runs"
                       "presentation_final_reschedules"))
      (should (string-match-p pattern header))
      (should (string-match-p pattern implementation)))
    (dolist (pattern '(":presentation-requests"
                       ":presentation-coalesced-requests"
                       ":presentation-task-runs"
                       ":presentation-final-reschedules"))
      (should (string-match-p pattern macterm)))
    (should (string-match-p "dispatch_async[[:space:]\n]*(dispatch_get_main_queue"
                            implementation))
    (should (string-match-p "emacs_metal_schedule_presentation"
                            implementation))))

(ert-deftest mac-benchmark-has-scheduled-startup-runner ()
  "The benchmark harness should support unattended GUI startup runs."
  (let ((source (mac-benchmark-tests--source)))
    (dolist (pattern '("mac-performance-run-benchmarks-and-exit"
                       "mac-performance-benchmark-startup-delay"
                       "run-with-timer"
                       "mac-performance--record-progress"
                       "with-temp-file"
                       "kill-emacs 0"
                       "kill-emacs 1"))
      (should (string-match-p pattern source)))))

;;; source-invariants.el ends here

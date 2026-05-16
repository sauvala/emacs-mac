;;; source-invariants.el --- Tests for macOS AppKit source invariants  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect macOS AppKit source directly.  They catch regressions in
;; event-loop instrumentation that is difficult to exercise in batch tests.

;;; Code:

(require 'ert)

(defun macappkit-tests--source (file)
  "Return the contents of src/FILE."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "src/" file) source-directory))
    (buffer-string)))

(defun macappkit-tests--function-body (function-name next-marker)
  "Return FUNCTION-NAME source body from src/macappkit.m up to NEXT-MARKER."
  (let ((source (macappkit-tests--source "macappkit.m")))
    (should (string-match (concat "\n" (regexp-quote function-name) " (")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match (regexp-quote next-marker) source start))
      (substring source start (match-beginning 0)))))

(ert-deftest macappkit-select-records-latency-stats ()
  "The AppKit select emulation should expose event-loop latency counters."
  (let ((body (macappkit-tests--function-body
               "mac_select"
               "\n\f\n/***********************************************************************\n\t\t\t       Startup")))
    (should (string-match-p "mac_select_latency_stats" body))
    (should (string-match-p "mac_record_select_latency" body))
    (should (string-match-p "gui_wait_seconds" body))
    (should (string-match-p "run_loop_iterations" body)))
  (let ((mac-source (macappkit-tests--source "mac.c"))
        (header-source (macappkit-tests--source "macterm.h")))
    (should (string-match-p "mac-select-latency-stats" mac-source))
    (should (string-match-p "defsubr (&Smac_select_latency_stats)" mac-source))
    (should (string-match-p "mac_get_select_latency_stats" header-source))))

;;; source-invariants.el ends here

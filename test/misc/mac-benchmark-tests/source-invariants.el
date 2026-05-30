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
    (should (string-match-p "emacs_metal_schedule_presentation"
                            implementation))))

(ert-deftest mac-benchmark-metal-presentation-uses-presenter-queue ()
  "Metal presentation should not acquire drawables on the main queue."
  (let ((implementation (mac-benchmark-tests--repo-source "src/macmetal.m")))
    (dolist (pattern '("presenter_queue"
                       "emacs_metal_presenter_queue_label"
                       "dispatch_queue_create"
                       "dispatch_async[[:space:]\n]*(ctx->presenter_queue"
                       "@autoreleasepool"))
      (should (string-match-p pattern implementation)))
    (should-not
     (string-match-p
      "dispatch_async[[:space:]\n]*(dispatch_get_main_queue[[:space:]\n]*()[[:ascii:]]*nextDrawable"
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

(ert-deftest mac-benchmark-gc-clip-hot-path-has-inline-storage ()
  "Mac GC clipping should avoid heap storage for common small clip lists."
  (let ((header (mac-benchmark-tests--repo-source "src/macgui.h"))
        (macterm (mac-benchmark-tests--repo-source "src/macterm.c"))
        (macappkit (mac-benchmark-tests--repo-source "src/macappkit.m"))
        (benchmark (mac-benchmark-tests--source)))
    (dolist (pattern '("MAC_GC_INLINE_CLIP_RECTANGLES"
                       "clip_rects_count"
                       "CGRect clip_rects\\[MAC_GC_INLINE_CLIP_RECTANGLES\\]"
                       "mac_gc_clip_rects"))
      (should (string-match-p pattern header)))
    (dolist (pattern '("mac-gc-clip-stats"
                       ":set-calls"
                       ":inline-sets"
                       ":heap-sets"
                       ":redundant-sets"
                       ":reset-calls"))
      (should (string-match-p pattern macterm)))
    (should (string-match-p "mac_gc_clip_rects" macappkit))
    (should (string-match-p "mac-gc-clip-stats" benchmark))))

(ert-deftest mac-benchmark-metal-skips-redundant-clip-state ()
  "Metal rendering should count and skip redundant clip state updates."
  (let ((header (mac-benchmark-tests--repo-source "src/macmetal.h"))
        (implementation (mac-benchmark-tests--repo-source "src/macmetal.m"))
        (macterm (mac-benchmark-tests--repo-source "src/macterm.c")))
    (dolist (pattern '("clip_set_rect_calls"
                       "clip_set_rect_skips"
                       "clip_set_rects_calls"
                       "clip_set_rects_skips"
                       "clip_reset_calls"
                       "clip_reset_skips"))
      (should (string-match-p pattern header))
      (should (string-match-p pattern implementation)))
    (dolist (pattern '("clip_regions_equal"
                       "clip_set_region_if_changed"))
      (should (string-match-p pattern implementation)))
    (dolist (pattern '(":clip-set-rect-calls"
                       ":clip-set-rect-skips"
                       ":clip-set-rects-calls"
                       ":clip-set-rects-skips"
                       ":clip-reset-calls"
                       ":clip-reset-skips"))
      (should (string-match-p pattern macterm)))))

;;; source-invariants.el ends here

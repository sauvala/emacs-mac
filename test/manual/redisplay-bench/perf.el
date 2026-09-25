;;; perf.el --- redisplay latency baseline for the mac port  -*- lexical-binding: t -*-

;; Times (FN) followed by (redisplay t) for scrolling, typing and full
;; redraws of src/xdisp.c in c-mode, and records GC counts.  Run from
;; a GUI Emacs, not batch:
;;
;;   GCT=800000 REPO=$PWD PERF_OUT=/tmp/out.eld \
;;     mac/Emacs.app/Contents/MacOS/Emacs -Q \
;;     -l test/manual/redisplay-bench/perf.el --eval '(perf-run)'
;;
;; GCT sets gc-cons-threshold (default 800000).  The output is a list
;; of (SCENARIO :n :min :median :p90 :max :gcs :gc-ms), times in ms.
;; See docs/nemesis-performance-roadmap.md for the recorded baseline.

;;; Code:

(setq gc-cons-threshold (string-to-number (or (getenv "GCT") "800000")))
(defvar perf-out (getenv "PERF_OUT"))
(defvar perf-results nil)
(defun perf-time (name n fn)
  (garbage-collect)
  (let* ((gcs gcs-done) (gct gc-elapsed)
         (times nil))
    (dotimes (_ n)
      (let ((t0 (float-time)))
        (funcall fn)
        (redisplay t)
        (push (* 1000 (- (float-time) t0)) times)))
    (setq times (sort times #'<))
    (push (list name :n n :min (car times)
                :median (nth (/ n 2) times)
                :p90 (nth (floor (* n 0.9)) times)
                :max (car (last times))
                :gcs (- gcs-done gcs) :gc-ms (* 1000 (- gc-elapsed gct)))
          perf-results)))
(defun perf-run ()
  (set-frame-size nil 200 60)
  (find-file (expand-file-name "src/xdisp.c" (getenv "REPO")))
  (delete-other-windows)
  (redisplay t)
  (sleep-for 1)
  (when (getenv "PERF_WAIT") (sleep-for (string-to-number (getenv "PERF_WAIT"))))
  (goto-char (point-min))
  (perf-time 'scroll-page 150 (lambda () (scroll-up-command)))
  (goto-char (point-min))
  (perf-time 'scroll-line 400 (lambda () (scroll-up-line 1)))
  (goto-char (point-min)) (forward-line 20000)
  (perf-time 'next-line 400 (lambda () (next-line 1)))
  (end-of-line)
  (perf-time 'typing 400 (lambda () (self-insert-command 1 ?x)))
  (perf-time 'full-redraw 100 (lambda () (redraw-frame)))
  (display-line-numbers-mode 1)
  (goto-char (point-min))
  (perf-time 'scroll-page-dln 150 (lambda () (scroll-up-command)))
  (perf-time 'typing-dln 300 (lambda () (self-insert-command 1 ?y)))
  (display-line-numbers-mode -1)
  (set-buffer-modified-p nil)
  (with-temp-file perf-out (prin1 (nreverse perf-results) (current-buffer)))
  (kill-emacs 0))

;;; fixture-tests.el --- ERT tests for the mac-app-loop fixture's pure helpers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers only the pure helpers in fixture.el (log line formatting/parsing
;; and log summarizing).  It deliberately does not exercise anything that
;; touches a real GUI, a real file, or wall-clock timing beyond what
;; `format-time-string' does with an explicit TIME argument, so it can run
;; in plain `--batch' mode as part of S0 verification:
;;
;;   /Applications/Emacs.app/Contents/MacOS/Emacs -Q --batch \
;;     -L test/manual/mac-app-loop -l fixture-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

(eval-and-compile
  (defvar mac-app-loop-tests--dir
    (file-name-directory
     (or load-file-name byte-compile-current-file
         buffer-file-name default-directory))))
;; fixture.el provides feature `mac-app-loop-fixture' but is named
;; differently from that feature, so pass its path explicitly.
(require 'mac-app-loop-fixture
         (expand-file-name "fixture" mac-app-loop-tests--dir))

(defconst mac-app-loop-tests--fixed-time (encode-time 0 0 12 1 1 2024)
  "A fixed, arbitrary time used so formatting tests are deterministic.")

(ert-deftest mac-app-loop-tests-timestamp-is-deterministic ()
  (should (equal (mac-app-loop--timestamp mac-app-loop-tests--fixed-time)
                 (mac-app-loop--timestamp mac-app-loop-tests--fixed-time))))

(ert-deftest mac-app-loop-tests-format-log-line ()
  (should (equal (mac-app-loop--format-log-line "TS" "TAG" "a=1 b=2")
                 "TS\tTAG\ta=1 b=2")))

(ert-deftest mac-app-loop-tests-format-log-line-empty-data ()
  (should (equal (mac-app-loop--format-log-line "TS" "TAG" "")
                 "TS\tTAG\t"))
  (should (equal (mac-app-loop--format-log-line "TS" "TAG" nil)
                 "TS\tTAG\t")))

(ert-deftest mac-app-loop-tests-parse-log-line-roundtrip ()
  (let* ((line (mac-app-loop--format-log-line "2024-01-01T12:00:00.000" "COMMAND"
                                               "this-command=foo last-input-event=bar")))
    (should (equal (mac-app-loop--parse-log-line line)
                   (list "2024-01-01T12:00:00.000" "COMMAND"
                         "this-command=foo last-input-event=bar")))))

(ert-deftest mac-app-loop-tests-parse-log-line-malformed ()
  (should (null (mac-app-loop--parse-log-line "not a log line")))
  (should (null (mac-app-loop--parse-log-line "only\tone-tab-missing-third-field")))
  (should (null (mac-app-loop--parse-log-line "")))
  (should (null (mac-app-loop--parse-log-line nil))))

(ert-deftest mac-app-loop-tests-parse-log-line-data-may-contain-more-text ()
  ;; DATA is the remainder of the line and may itself legitimately not
  ;; contain further tabs in practice, but the parser must not choke on
  ;; ordinary punctuation/spaces within it.
  (let ((line "TS\tFRAME-SIZE\tframe=#<frame> pixel-width=800 pixel-height=600"))
    (should (equal (mac-app-loop--parse-log-line line)
                   (list "TS" "FRAME-SIZE" "frame=#<frame> pixel-width=800 pixel-height=600")))))

(ert-deftest mac-app-loop-tests-summarize-empty-log ()
  (let ((summary (mac-app-loop--summarize-lines nil)))
    (should (equal (plist-get summary :lines) 0))
    (should (equal (plist-get summary :commands) 0))
    (should (equal (plist-get summary :frame-size-events) 0))
    (should (equal (plist-get summary :heartbeat-ticks) 0))
    (should (equal (plist-get summary :max-heartbeat-gap) 0.0))))

(ert-deftest mac-app-loop-tests-summarize-synthetic-log ()
  (let* ((lines (list
                 (mac-app-loop--format-log-line "T0" "SESSION-START" "x=1")
                 (mac-app-loop--format-log-line "T1" "COMMAND" "this-command=self-insert-command")
                 (mac-app-loop--format-log-line "T2" "COMMAND" "this-command=forward-char")
                 (mac-app-loop--format-log-line "T3" "FRAME-SIZE" "frame=f pixel-width=100 pixel-height=100")
                 (mac-app-loop--format-log-line "T4" "HEARTBEAT" "gap=0.1002")
                 (mac-app-loop--format-log-line "T5" "HEARTBEAT" "gap=0.4321")
                 (mac-app-loop--format-log-line "T6" "HEARTBEAT" "gap=0.0998")
                 "garbage line with no tabs at all"))
         (summary (mac-app-loop--summarize-lines lines)))
    (should (equal (plist-get summary :lines) 7))
    (should (equal (plist-get summary :malformed) 1))
    (should (equal (plist-get summary :commands) 2))
    (should (equal (plist-get summary :frame-size-events) 1))
    (should (equal (plist-get summary :heartbeat-ticks) 3))
    (should (= (plist-get summary :max-heartbeat-gap) 0.4321))))

(ert-deftest mac-app-loop-tests-busy-loop-runs-for-approximately-requested-time ()
  ;; A short, bounded sanity check that the busy loop actually spins for
  ;; roughly the requested duration and does real work (nonzero iterations).
  ;; Not a timing/perf assertion beyond a generous bound, so it stays fast
  ;; and non-flaky in batch mode.
  (let ((start (float-time))
        (iterations (mac-app-loop--busy-loop 0.05)))
    (should (> iterations 0))
    (should (>= (- (float-time) start) 0.05))
    (should (< (- (float-time) start) 2.0))))

(provide 'fixture-tests)

;;; fixture-tests.el ends here

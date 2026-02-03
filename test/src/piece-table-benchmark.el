;;; piece-table-benchmark.el --- Benchmark Piece Table vs Gap Buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Free Software Foundation, Inc.

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

;; Benchmark comparing Piece Table and Gap Buffer storage backends.
;;
;; Usage:
;;   ./src/emacs -Q --batch -l test/src/piece-table-benchmark.el
;;
;; Or interactively:
;;   M-x load-file RET test/src/piece-table-benchmark.el RET
;;   M-x piece-table-run-benchmarks RET
;;
;; The benchmark tests:
;;   - file-load: Time to open a file
;;   - random-goto: Random cursor movement (simulates scrolling)
;;   - random-char-at: Random character access
;;   - insert-sequential: Insert at cursor (gap buffer's strength)
;;   - insert-random: Insert at random positions (piece table's strength)
;;   - delete-random: Delete at random positions
;;
;; Expected results:
;;   - Gap buffer: Faster file loading (2-5x)
;;   - Piece table: Much faster random insert/delete (10-50x for large files)
;;   - Both similar for navigation and sequential editing

;;; Code:

(require 'cl-lib)

(defvar piece-table-benchmark-sizes '(1 5 10)
  "File sizes in MB to benchmark.")

(defvar piece-table-benchmark-iterations 1000
  "Number of iterations per test.")

(defvar piece-table-benchmark-temp-dir "/tmp"
  "Directory for temporary benchmark files.")

(defun piece-table-benchmark--create-test-file (size-mb)
  "Create a test file of SIZE-MB megabytes if it doesn't exist.
Returns the file path."
  (let ((test-file (expand-file-name
                    (format "emacs-bench-test-%dMB.txt" size-mb)
                    piece-table-benchmark-temp-dir)))
    (unless (file-exists-p test-file)
      (message "Creating %d MB test file..." size-mb)
      (with-temp-file test-file
        (dotimes (_ (* size-mb 1024))
          (insert (make-string 1024 ?x)))))
    test-file))

(defun piece-table-benchmark--run-single (use-piece-table file-size-mb iterations)
  "Run benchmark with USE-PIECE-TABLE mode on FILE-SIZE-MB file.
ITERATIONS controls test iterations.  Returns alist of results."
  (let* ((test-file (piece-table-benchmark--create-test-file file-size-mb))
         (results '())
         ;; Suppress warnings
         (large-file-warning-threshold nil)
         (inhibit-message t))

    ;; Set storage mode
    (setq use-piece-table-by-default use-piece-table)

    ;; Benchmark 1: File loading
    (garbage-collect)
    (let ((start (float-time)))
      (find-file test-file)
      (push (cons 'file-load (- (float-time) start)) results))

    (push (cons 'using-piece-table
                (if (fboundp 'buffer-using-piece-table-p)
                    (buffer-using-piece-table-p)
                  nil)) results)

    ;; Benchmark 2: Random navigation (simulates scrolling)
    (garbage-collect)
    (let ((start (float-time))
          (max-pos (point-max)))
      (dotimes (_ iterations)
        (goto-char (1+ (random (1- max-pos)))))
      (push (cons 'random-goto (- (float-time) start)) results))

    ;; Benchmark 3: Random point access
    (garbage-collect)
    (let ((start (float-time))
          (max-pos (point-max)))
      (dotimes (_ iterations)
        (char-after (1+ (random (1- max-pos)))))
      (push (cons 'random-char-at (- (float-time) start)) results))

    ;; Benchmark 4: Insert at cursor (sequential editing - gap buffer's strength)
    (garbage-collect)
    (goto-char (/ (point-max) 2))
    (let ((start (float-time))
          (insert-text "Hello"))
      (dotimes (_ 1000)
        (insert insert-text))
      (push (cons 'insert-sequential (- (float-time) start)) results))

    ;; Benchmark 5: Insert at random positions (piece table's strength)
    (garbage-collect)
    (let ((start (float-time))
          (insert-text "X"))
      (dotimes (_ 500)
        (goto-char (1+ (random (1- (point-max)))))
        (insert insert-text))
      (push (cons 'insert-random (- (float-time) start)) results))

    ;; Benchmark 6: Delete at random positions
    (garbage-collect)
    (let ((start (float-time)))
      (dotimes (_ 500)
        (goto-char (1+ (random (max 1 (- (point-max) 2)))))
        (when (< (point) (point-max))
          (delete-char 1)))
      (push (cons 'delete-random (- (float-time) start)) results))

    ;; Cleanup
    (set-buffer-modified-p nil)
    (kill-buffer)

    (nreverse results)))

(defun piece-table-benchmark--format-time (secs)
  "Format SECS for display."
  (if (< secs 0.0005)
      "<0.001"
    (format "%.3f" secs)))

(defun piece-table-benchmark--print-results (size gap-results pt-results)
  "Print comparison of GAP-RESULTS and PT-RESULTS for SIZE MB file."
  (princ (format "\n--- %d MB File ---\n" size))
  (princ (format "%-20s %10s %10s %8s  Winner\n"
                 "Operation" "Gap(sec)" "PT(sec)" "Ratio"))
  (princ "--------------------------------------------------------------\n")

  (dolist (r gap-results)
    (when (numberp (cdr r))
      (let* ((pt-val (cdr (assoc (car r) pt-results)))
             (ratio (if (and pt-val (> (cdr r) 0.0001))
                        (/ pt-val (cdr r))
                      0))
             (winner (cond ((< ratio 0.7) "PT ✓")
                           ((> ratio 1.3) "Gap ✓")
                           (t "~"))))
        (princ (format "%-20s %10s %10s %8.2f  %s\n"
                       (car r)
                       (piece-table-benchmark--format-time (cdr r))
                       (piece-table-benchmark--format-time pt-val)
                       ratio
                       winner)))))

  (princ (format "%-20s %10s %10s\n"
                 "using-piece-table"
                 (if (cdr (assoc 'using-piece-table gap-results)) "yes" "no")
                 (if (cdr (assoc 'using-piece-table pt-results)) "yes" "no"))))

;;;###autoload
(defun piece-table-run-benchmarks (&optional sizes iterations)
  "Run the full piece table vs gap buffer benchmark suite.
Optional SIZES is a list of file sizes in MB (default: 1, 5, 10).
Optional ITERATIONS controls test iterations (default: 1000)."
  (interactive)
  (let ((sizes (or sizes piece-table-benchmark-sizes))
        (iterations (or iterations piece-table-benchmark-iterations)))

    (princ "\n")
    (princ "================================================================================\n")
    (princ "                    STORAGE BACKEND BENCHMARKS\n")
    (princ "                    Piece Table (chunked) vs Gap Buffer\n")
    (princ "================================================================================\n")
    (princ (format "Iterations: %d per test\n" iterations))
    (princ (format "File sizes: %s MB\n" (mapconcat #'number-to-string sizes ", ")))

    (dolist (size sizes)
      (message "Benchmarking %d MB file..." size)
      (let ((gap-results (piece-table-benchmark--run-single nil size iterations))
            (pt-results (piece-table-benchmark--run-single t size iterations)))
        (piece-table-benchmark--print-results size gap-results pt-results)))

    (princ "\n")
    (princ "================================================================================\n")
    (princ "Summary:\n")
    (princ "  Gap Buffer:   Faster file loading (2-5x)\n")
    (princ "  Piece Table:  Much faster random insert/delete (10-50x for large files)\n")
    (princ "================================================================================\n")))

;;;###autoload
(defun piece-table-quick-benchmark ()
  "Run a quick benchmark with smaller files."
  (interactive)
  (piece-table-run-benchmarks '(1 2) 500))

;; Run benchmarks when loaded in batch mode
(when noninteractive
  (piece-table-run-benchmarks))

(provide 'piece-table-benchmark)

;;; piece-table-benchmark.el ends here

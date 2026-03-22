;;; rope-benchmark.el --- Benchmark Rope vs Gap Buffer -*- lexical-binding: t; -*-

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

;; Benchmark comparing Rope and Gap Buffer storage backends.
;;
;; Usage:
;;   ./src/emacs -Q --batch -l test/src/rope-benchmark.el
;;
;; Or interactively:
;;   M-x load-file RET test/src/rope-benchmark.el RET
;;   M-x rope-run-benchmarks RET
;;
;; The benchmark tests:
;;   - file-load: Time to open a file
;;   - random-goto: Random cursor movement (simulates scrolling)
;;   - random-char-at: Random character access
;;   - insert-sequential: Insert at cursor (gap buffer's strength)
;;   - insert-random: Insert at random positions (rope's strength)
;;   - delete-random: Delete at random positions
;;
;; Expected results:
;;   - Gap buffer: Faster file loading (direct mmap vs tree build)
;;   - Rope: Much faster random insert/delete (O(log n) vs O(n))
;;   - Both similar for navigation and sequential editing

;;; Code:

(require 'cl-lib)

(defvar rope-benchmark-sizes '(1 5 10)
  "File sizes in MB to benchmark.")

(defvar rope-benchmark-iterations 1000
  "Number of iterations per test.")

(defvar rope-benchmark-temp-dir "/tmp"
  "Directory for temporary benchmark files.")

(defun rope-benchmark--create-test-file (size-mb)
  "Create a test file of SIZE-MB megabytes if it doesn't exist.
Returns the file path."
  (let ((test-file (expand-file-name
                    (format "emacs-bench-test-%dMB.txt" size-mb)
                    rope-benchmark-temp-dir)))
    (unless (file-exists-p test-file)
      (message "Creating %d MB test file..." size-mb)
      (with-temp-file test-file
        (dotimes (_ (* size-mb 1024))
          (insert (make-string 1024 ?x)))))
    test-file))

(defun rope-benchmark--run-single (use-rope file-size-mb iterations)
  "Run benchmark with USE-ROPE mode on FILE-SIZE-MB file.
ITERATIONS controls test iterations.  Returns alist of results."
  (let* ((test-file (rope-benchmark--create-test-file file-size-mb))
         (results '())
         ;; Suppress warnings
         (large-file-warning-threshold nil)
         (inhibit-message t))

    ;; Set storage mode
    (setq use-rope-by-default use-rope)

    ;; Benchmark 1: File loading
    (garbage-collect)
    (let ((start (float-time)))
      (find-file test-file)
      (push (cons 'file-load (- (float-time) start)) results))

    (push (cons 'using-rope
                (if (fboundp 'buffer-using-rope-p)
                    (buffer-using-rope-p)
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

    ;; Benchmark 5: Insert at random positions (rope's strength)
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

(defun rope-benchmark--format-time (secs)
  "Format SECS for display."
  (if (< secs 0.0005)
      "<0.001"
    (format "%.3f" secs)))

(defun rope-benchmark--print-results (size gap-results rope-results)
  "Print comparison of GAP-RESULTS and ROPE-RESULTS for SIZE MB file."
  (princ (format "\n--- %d MB File ---\n" size))
  (princ (format "%-20s %10s %10s %8s  Winner\n"
                 "Operation" "Gap(sec)" "Rope(sec)" "Ratio"))
  (princ "--------------------------------------------------------------\n")

  (dolist (r gap-results)
    (when (numberp (cdr r))
      (let* ((rope-val (cdr (assoc (car r) rope-results)))
             (ratio (if (and rope-val (> (cdr r) 0.0001))
                        (/ rope-val (cdr r))
                      0))
             (winner (cond ((< ratio 0.7) "Rope")
                           ((> ratio 1.3) "Gap")
                           (t "~"))))
        (princ (format "%-20s %10s %10s %8.2f  %s\n"
                       (car r)
                       (rope-benchmark--format-time (cdr r))
                       (rope-benchmark--format-time rope-val)
                       ratio
                       winner)))))

  (princ (format "%-20s %10s %10s\n"
                 "using-rope"
                 (if (cdr (assoc 'using-rope gap-results)) "yes" "no")
                 (if (cdr (assoc 'using-rope rope-results)) "yes" "no"))))

;;;###autoload
(defun rope-run-benchmarks (&optional sizes iterations)
  "Run the full rope vs gap buffer benchmark suite.
Optional SIZES is a list of file sizes in MB (default: 1, 5, 10).
Optional ITERATIONS controls test iterations (default: 1000)."
  (interactive)
  (let ((sizes (or sizes rope-benchmark-sizes))
        (iterations (or iterations rope-benchmark-iterations)))

    (princ "\n")
    (princ "================================================================================\n")
    (princ "                    STORAGE BACKEND BENCHMARKS\n")
    (princ "                    Rope (B-tree) vs Gap Buffer\n")
    (princ "================================================================================\n")
    (princ (format "Iterations: %d per test\n" iterations))
    (princ (format "File sizes: %s MB\n" (mapconcat #'number-to-string sizes ", ")))

    (dolist (size sizes)
      (message "Benchmarking %d MB file..." size)
      (let ((gap-results (rope-benchmark--run-single nil size iterations))
            (rope-results (rope-benchmark--run-single t size iterations)))
        (rope-benchmark--print-results size gap-results rope-results)))

    (princ "\n")
    (princ "================================================================================\n")
    (princ "Summary:\n")
    (princ "  Gap Buffer:  Faster file loading (direct mmap vs tree construction)\n")
    (princ "  Rope:        Faster random insert/delete (O(log n) vs O(n) gap moves)\n")
    (princ "================================================================================\n")))

;;;###autoload
(defun rope-quick-benchmark ()
  "Run a quick benchmark with smaller files."
  (interactive)
  (rope-run-benchmarks '(1 2) 500))

;; Run benchmarks when loaded in batch mode
(when noninteractive
  (rope-run-benchmarks))

(provide 'rope-benchmark)

;;; rope-benchmark.el ends here

;;; multi-cursor-benchmarks.el --- Native multiple-cursor benchmarks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; Reproducible, threshold-free scaling benchmarks for native multiple
;; cursors.  Fixture construction is outside every timed form.  Results report
;; latency distributions and operation counts; they do not encode machine-
;; dependent pass/fail timing limits.
;;
;; Run the default matrix from the source tree with:
;;
;;   src/emacs -Q --batch -L ./lisp/ -L test/benchmarks \
;;     -l test/benchmarks/multi-cursor-benchmarks.el \
;;     --eval '(multi-cursor-benchmark-batch)'
;;
;; For a quick smoke run:
;;
;;   --eval '(multi-cursor-benchmark-batch t)'
;;
;; Include the allocation-heavy 100 MiB cases explicitly with:
;;
;;   --eval '(let ((multi-cursor-benchmark-include-large t))
;;             (multi-cursor-benchmark-batch))'
;;
;; Batch runs measure editing and redisplay orchestration without a graphical
;; frame.  Invoke `multi-cursor-benchmark-batch' interactively in a Mac GUI
;; build when native painter counter samples are required.

;;; Code:

(require 'benchmark)
(require 'cl-lib)
(require 'multi-cursor)

(defvar multi-cursor-benchmark-counts '(1 2 10 100 1000)
  "Total cursor counts in the full benchmark matrix.")

(defvar multi-cursor-benchmark-sizes
  '((10k . 10240) (1m . 1048576))
  "Named buffer character counts in the default benchmark matrix.")

(defvar multi-cursor-benchmark-large-sizes '((100m . 104857600))
  "Allocation-heavy buffer sizes available to the benchmark matrix.")

(defvar multi-cursor-benchmark-include-large nil
  "Non-nil includes `multi-cursor-benchmark-large-sizes' in full runs.")

(defvar multi-cursor-benchmark-contents '(ascii combining bidi)
  "Text fixture kinds in the full benchmark matrix.")

(defvar multi-cursor-benchmark-distributions '(clustered even)
  "Cursor distributions in the full benchmark matrix.")

(defvar multi-cursor-benchmark-operations
  '(insert delete horizontal vertical normalize redisplay-edit)
  "Operations measured for each native multiple-cursor fixture.")

(defvar multi-cursor-benchmark-iterations 7
  "Number of independently prepared samples per benchmark case.")

(defconst multi-cursor-benchmark--mac-counter-functions
  '(mac-gc-clip-stats
    mac-metal-render-stats
    mac-metal-clip-overdraw-stats
    mac-select-latency-stats)
  "Optional Mac rendering counters sampled around measured forms.")

(defun multi-cursor-benchmark--mac-counters (&optional reset)
  "Return available Mac counter snapshots, resetting first when RESET."
  (delq nil
        (mapcar (lambda (function)
                  (when (fboundp function)
                    (cons function (funcall function reset))))
                multi-cursor-benchmark--mac-counter-functions)))

(defun multi-cursor-benchmark--chunk (content)
  "Return a repeatable line chunk for CONTENT."
  (pcase content
    ('ascii "alpha beta gamma delta epsilon 0123456789\n")
    ('combining "a\u0301 e\u0308 n\u0303 alpha beta gamma 0123456789\n")
    ('bidi "left abc \u05d0\u05d1\u05d2 \u0633\u0644\u0627\u0645 right 0123456789\n")
    (_ (error "Unknown content kind: %S" content))))

(defun multi-cursor-benchmark--text (size content)
  "Build a fixture with SIZE characters of CONTENT."
  (let ((chunk (multi-cursor-benchmark--chunk content)))
    (with-temp-buffer
      (while (< (buffer-size) size)
        (insert chunk))
      (buffer-substring-no-properties (point-min) (1+ size)))))

(defun multi-cursor-benchmark--positions (size count distribution)
  "Return COUNT distinct safe positions for SIZE and DISTRIBUTION."
  (let ((usable (- size 3)))
    (cl-loop
     for index below count
     collect
     (pcase distribution
       ('clustered (+ 2 (* index 2)))
       ('even (+ 2 (floor (* index usable) (max 1 count))))
       (_ (error "Unknown cursor distribution: %S" distribution))))))

(defun multi-cursor-benchmark--native-setup (positions operation)
  "Install native cursors at POSITIONS for OPERATION."
  (goto-char (car positions))
  (dolist (position (cdr positions))
    (multi-cursor-add-at-point position))
  (when (eq operation 'normalize)
    ;; Fixture disorder is deliberate and remains outside the measured form.
    (setq multi-cursor--cursors (nreverse multi-cursor--cursors))))

(defun multi-cursor-benchmark--package-available-p ()
  "Return non-nil when the multiple-cursors.el comparison seam is available."
  (and (require 'multiple-cursors-core nil t)
       (fboundp 'mc/create-fake-cursor-at-point)
       (fboundp 'mc/execute-command-for-all-cursors)))

(defun multi-cursor-benchmark--package-setup (positions _operation)
  "Install multiple-cursors.el fake cursors at POSITIONS."
  (goto-char (car positions))
  (dolist (position (cdr positions))
    (goto-char position)
    (mc/create-fake-cursor-at-point))
  (goto-char (car positions)))

(defun multi-cursor-benchmark--command (operation)
  "Return the interactive command corresponding to OPERATION."
  (pcase operation
    ((or 'insert 'redisplay-edit) 'self-insert-command)
    ('delete 'delete-char)
    ('horizontal 'forward-char)
    ('vertical 'next-logical-line)
    (_ nil)))

(defun multi-cursor-benchmark--exercise (provider operation)
  "Exercise OPERATION through PROVIDER."
  (let ((command (multi-cursor-benchmark--command operation))
        (last-command-event ?X))
    (pcase provider
      ('native
       (if (eq operation 'normalize)
           (multi-cursor--normalized-cursors)
         (command-execute command)))
      ('single
       (if (eq operation 'normalize)
           nil
         (command-execute command)))
      ('package
       (if (eq operation 'normalize)
           (mc/all-fake-cursors)
         (mc/execute-command-for-all-cursors command))))
    (when (eq operation 'redisplay-edit)
      (force-window-update (current-buffer))
      (redisplay 'force))))

(defun multi-cursor-benchmark--allocation-delta (before after)
  "Return allocation counter deltas from BEFORE to AFTER."
  (cl-mapcar #'- after before))

(defun multi-cursor-benchmark--undo-length ()
  "Return the current undo-list length as a stable scalar metric."
  (if (listp buffer-undo-list) (length buffer-undo-list) 0))

(defun multi-cursor-benchmark--validate-edit (operation count original-size)
  "Validate measured OPERATION for COUNT cursors and ORIGINAL-SIZE."
  (pcase operation
    ((or 'insert 'redisplay-edit)
     (unless (= (cl-count ?X (buffer-string)) count)
       (error "Insertion touched %d cursors, expected %d"
              (cl-count ?X (buffer-string)) count)))
    ('delete
     (unless (= (buffer-size) (- original-size count))
       (error "Deletion changed size by %d, expected %d"
              (- original-size (buffer-size)) count)))))

(defun multi-cursor-benchmark--sample
    (provider text count distribution operation)
  "Measure PROVIDER on TEXT with COUNT cursors.

DISTRIBUTION places the cursors and OPERATION selects the measured action."
  (with-temp-buffer
    ;; Fixture construction must not retain a potentially huge setup undo
    ;; record or contribute to the measured undo growth.
    (let ((buffer-undo-list t))
      (insert text))
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (let* ((positions
            (multi-cursor-benchmark--positions
             (length text) count distribution))
           (before-hooks 0)
           (after-hooks 0)
           (apply-calls 0)
           (apply-function
            (and (fboundp 'multi-cursor--apply-edits)
                 (symbol-function 'multi-cursor--apply-edits))))
      (pcase provider
        ('native (multi-cursor-benchmark--native-setup positions operation))
        ('single (goto-char (car positions)))
        ('package (multi-cursor-benchmark--package-setup positions operation)))
      (setq before-change-functions
            (list (lambda (&rest _) (cl-incf before-hooks)))
            after-change-functions
            (list (lambda (&rest _) (cl-incf after-hooks))))
      (let ((memory-before (memory-use-counts))
            (undo-before (multi-cursor-benchmark--undo-length))
            (original-size (buffer-size))
            result)
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (multi-cursor-benchmark--mac-counters t)
          (if apply-function
              (cl-letf (((symbol-function 'multi-cursor--apply-edits)
                         (lambda (edits)
                           (cl-incf apply-calls)
                           (funcall apply-function edits))))
                (setq result
                      (benchmark-run 1
                        (multi-cursor-benchmark--exercise
                         provider operation))))
            (setq result
                  (benchmark-run 1
                    (multi-cursor-benchmark--exercise provider operation)))))
        (multi-cursor-benchmark--validate-edit operation count original-size)
        (list :elapsed (nth 0 result)
              :gc-count (nth 1 result)
              :gc-time (nth 2 result)
              :allocations
              (multi-cursor-benchmark--allocation-delta
               memory-before (memory-use-counts))
              :undo-growth
              (- (multi-cursor-benchmark--undo-length) undo-before)
              :before-hooks before-hooks
              :after-hooks after-hooks
              :apply-calls apply-calls
              :mac-counters (multi-cursor-benchmark--mac-counters))))))

(defun multi-cursor-benchmark--percentile (numbers percentile)
  "Return PERCENTILE from NUMBERS using nearest-rank selection."
  (let* ((sorted (sort (copy-sequence numbers) #'<))
         (rank (max 0 (1- (ceiling (* percentile (length sorted)))))))
    (nth rank sorted)))

(defun multi-cursor-benchmark--median (numbers)
  "Return the median of NUMBERS."
  (multi-cursor-benchmark--percentile numbers 0.5))

(defun multi-cursor-benchmark--sum-allocation (sample)
  "Return the sum of allocation counters in SAMPLE."
  (apply #'+ (plist-get sample :allocations)))

(defun multi-cursor-benchmark--summarize-mac-counters (samples)
  "Return per-field median Mac counters from SAMPLES."
  (let ((functions
         (delete-dups
          (apply #'append
                 (mapcar
                  (lambda (sample)
                    (mapcar #'car (plist-get sample :mac-counters)))
                  samples)))))
    (mapcar
     (lambda (function)
       (let* ((plists
               (delq nil
                     (mapcar
                      (lambda (sample)
                        (cdr (assq function
                                   (plist-get sample :mac-counters))))
                      samples)))
              (keys (and plists
                         (cl-loop for (key _value) on (car plists) by #'cddr
                                  collect key))))
         (cons
          function
          (cl-loop
           for key in keys
           append
           (let ((values (delq nil (mapcar (lambda (plist)
                                             (plist-get plist key))
                                           plists))))
             (list key
                   (and values
                        (multi-cursor-benchmark--median values))))))))
     functions)))

(defun multi-cursor-benchmark--summarize (samples)
  "Summarize benchmark SAMPLES without imposing timing thresholds."
  (let ((elapsed (mapcar (lambda (sample) (plist-get sample :elapsed))
                         samples)))
    (list
     :median (multi-cursor-benchmark--median elapsed)
     :p95 (multi-cursor-benchmark--percentile elapsed 0.95)
     :gc-count (apply #'+ (mapcar (lambda (s) (plist-get s :gc-count))
                                  samples))
     :gc-time (apply #'+ (mapcar (lambda (s) (plist-get s :gc-time))
                                 samples))
     :allocations
     (multi-cursor-benchmark--median
      (mapcar #'multi-cursor-benchmark--sum-allocation samples))
     :undo-growth
     (multi-cursor-benchmark--median
      (mapcar (lambda (s) (plist-get s :undo-growth)) samples))
     :before-hooks
     (multi-cursor-benchmark--median
      (mapcar (lambda (s) (plist-get s :before-hooks)) samples))
     :after-hooks
     (multi-cursor-benchmark--median
      (mapcar (lambda (s) (plist-get s :after-hooks)) samples))
     :apply-calls
     (multi-cursor-benchmark--median
      (mapcar (lambda (s) (plist-get s :apply-calls)) samples))
     :mac-counters (multi-cursor-benchmark--summarize-mac-counters samples))))

(defun multi-cursor-benchmark--print-header ()
  "Print the benchmark TSV header."
  (princ
   (concat "provider\tcontent\tsize\tdistribution\tcursors\toperation"
           "\tmedian_s\tp95_s\tgc_count\tgc_s\talloc_units"
           "\tundo_growth\tbefore_hooks\tafter_hooks\tapply_calls"
           "\tmac_counter_medians\n")))

(defun multi-cursor-benchmark--print-result
    (provider content size distribution count operation summary)
  "Print a benchmark SUMMARY row.

The row identifies PROVIDER, CONTENT, SIZE, DISTRIBUTION, COUNT, and OPERATION."
  (princ
   (format
    "%s\t%s\t%s\t%s\t%d\t%s\t%.9f\t%.9f\t%d\t%.9f\t%d\t%d\t%d\t%d\t%d\t%S\n"
    provider content size distribution count operation
    (plist-get summary :median) (plist-get summary :p95)
    (plist-get summary :gc-count) (plist-get summary :gc-time)
    (plist-get summary :allocations) (plist-get summary :undo-growth)
    (plist-get summary :before-hooks) (plist-get summary :after-hooks)
    (plist-get summary :apply-calls) (plist-get summary :mac-counters))))

;;;###autoload
(defun multi-cursor-benchmark-batch (&optional quick)
  "Run the native cursor matrix and print TSV results.

With QUICK non-nil, use a small smoke matrix.  When multiple-cursors.el is on
`load-path', also run its public fake-cursor execution seam."
  (interactive "P")
  (let* ((counts (if quick '(1 10 100) multi-cursor-benchmark-counts))
         (sizes
          (if quick
              '((10k . 10240))
            (append multi-cursor-benchmark-sizes
                    (and multi-cursor-benchmark-include-large
                         multi-cursor-benchmark-large-sizes))))
         (contents (if quick '(ascii) multi-cursor-benchmark-contents))
         (distributions
          (if quick '(even) multi-cursor-benchmark-distributions))
         (iterations (if quick 3 multi-cursor-benchmark-iterations))
         (package-p (multi-cursor-benchmark--package-available-p)))
    (multi-cursor-benchmark--print-header)
    (dolist (content contents)
      (dolist (size-entry sizes)
        (let ((text (multi-cursor-benchmark--text
                     (cdr size-entry) content)))
          (dolist (distribution distributions)
            (dolist (operation multi-cursor-benchmark-operations)
              (dolist (provider (append '(single native)
                                        (and package-p '(package))))
                (dolist (count (if (eq provider 'single) '(1) counts))
                  (unless (and (eq provider 'package)
                               (eq operation 'normalize))
                    (let (samples)
                      (dotimes (_ iterations)
                        (push (multi-cursor-benchmark--sample
                               provider text count distribution operation)
                              samples))
                      (multi-cursor-benchmark--print-result
                       provider content (car size-entry) distribution count
                       operation
                       (multi-cursor-benchmark--summarize samples)))))))))))
    (unless package-p
      (princ "# multiple-cursors.el unavailable; package rows omitted\n"))))

(provide 'multi-cursor-benchmarks)

;;; multi-cursor-benchmarks.el ends here

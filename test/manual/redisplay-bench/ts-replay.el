;;; ts-replay.el --- replay typing on real files and time tree-sitter reparses  -*- lexical-binding: t -*-

;; Approximates a day of editing for the budgeted-parse stage 1 gate:
;; visits real files with their tree-sitter parser and makes the edits
;; typing makes, reparsing after each one as a command would.  Needs a
;; build with `treesit-budget-stats'.  Batch is enough:
;;
;;   TS_REPLAY_FILES=/path/list.txt Emacs -Q --batch \
;;     -l test/manual/redisplay-bench/ts-replay.el -f ts-replay-run
;;
;; The file list holds one absolute file name per line.  Edit sites are
;; chosen with a fixed seed, so reruns are comparable.  TS_REPLAY_SITES
;; sets the number of sites per file (default 30).  The output is one
;; plist per edit kind plus a total, times in ms.

;;; Code:

(require 'cl-lib)
(require 'treesit)

(defvar ts-replay-languages
  '(("\\.py\\'" . python) ("\\.tsx\\'" . tsx) ("\\.ts\\'" . typescript)
    ("\\.jsx?\\'" . javascript) ("\\.json\\'" . json)
    ("\\.ya?ml\\'" . yaml) ("\\.go\\'" . go) ("\\.rs\\'" . rust)))

(defvar ts-replay-times nil
  "Alist of (KIND . reparse times in seconds).")

(defvar ts-replay-file nil
  "The file being replayed.")

(defvar ts-replay-slow nil
  "Reparses over 50 ms, as (MS KIND FILE LINE TEXT-BEFORE-POINT).")

(defun ts-replay--language (file)
  (cdr (cl-find-if (lambda (e) (string-match-p (car e) file))
                   ts-replay-languages)))

(defun ts-replay--reparse (parser kind)
  "Reparse PARSER and record the time under KIND."
  (treesit-budget-stats t)
  (treesit-parser-root-node parser)
  (let ((s (plist-get (treesit-budget-stats) :seconds)))
    (push s (alist-get kind ts-replay-times))
    (when (> s 0.05)
      (let ((entry (list (round (* 1000 s)) kind ts-replay-file
                         (line-number-at-pos)
                         (buffer-substring-no-properties
                          (line-beginning-position) (point)))))
        (push entry ts-replay-slow)
        (message "slow: %S" entry)))))

(defun ts-replay--goto-code-line ()
  "Move to a random non-blank line; return nil if there is none."
  (let ((lines (count-lines (point-min) (point-max))) (tries 20) found)
    (while (and (not found) (> tries 0))
      (goto-char (point-min))
      (forward-line (random (max 1 lines)))
      (setq found (not (looking-at-p "[ \t]*$")))
      (setq tries (1- tries)))
    found))

(defun ts-replay--site (parser)
  "Make every kind of edit at a random site, undoing each one."
  (when (ts-replay--goto-code-line)
    ;; A word typed at the end of the line, one reparse per key, then
    ;; deleted with backspace.
    (end-of-line)
    (dolist (c (string-to-list " foo"))
      (insert c) (ts-replay--reparse parser 'type))
    (dotimes (_ 4)
      (delete-char -1) (ts-replay--reparse parser 'backspace))
    ;; A new line.
    (insert "\n") (ts-replay--reparse parser 'newline)
    (delete-char -1) (ts-replay--reparse parser 'backspace)
    ;; Openers typed at the indentation, where they change the most.
    (back-to-indentation)
    (dolist (opener '("\"" "'" "(" "{" "["))
      (insert opener) (ts-replay--reparse parser 'opener)
      (delete-char -1) (ts-replay--reparse parser 'backspace))))

(defun ts-replay--file (file sites)
  (setq ts-replay-file file)
  (let ((lang (ts-replay--language file)))
    (when (and lang (treesit-language-available-p lang))
      (with-temp-buffer
        (insert-file-contents file)
        (let ((parser (treesit-parser-create lang)))
          (treesit-parser-root-node parser)
          (dotimes (_ sites) (ts-replay--site parser)))
        (buffer-size)))))

(defun ts-replay--summary (times)
  (let* ((ms (sort (mapcar (lambda (s) (* 1000 s)) times) #'<))
         (n (length ms)))
    (list :n n
          :median (nth (/ n 2) ms)
          :p99 (nth (min (1- n) (floor (* n 0.99))) ms)
          :max (car (last ms))
          :over-1ms (cl-count-if (lambda (x) (> x 1)) ms)
          :over-3ms (cl-count-if (lambda (x) (> x 3)) ms)
          :over-8ms (cl-count-if (lambda (x) (> x 8)) ms))))

(defun ts-replay-run ()
  (random "ts-replay")
  (let* ((files (with-temp-buffer
                  (insert-file-contents (getenv "TS_REPLAY_FILES"))
                  (split-string (buffer-string) "\n" t)))
         (sites (string-to-number (or (getenv "TS_REPLAY_SITES") "30")))
         (visited 0) (bytes 0))
    (dolist (file files)
      (let ((size (ignore-errors (ts-replay--file file sites))))
        (when size
          (setq visited (1+ visited) bytes (+ bytes size)))))
    (princ (format "files %d, %d KB, %d sites each\n"
                   visited (/ bytes 1024) sites))
    (dolist (e (reverse ts-replay-times))
      (princ (format "%-10s %S\n" (car e) (ts-replay--summary (cdr e)))))
    (princ (format "%-10s %S\n" 'all
                   (ts-replay--summary
                    (apply #'append (mapcar #'cdr ts-replay-times)))))
    (dolist (e (sort ts-replay-slow (lambda (a b) (> (car a) (car b)))))
      (princ (format "slow %S\n" e)))))

;;; ts-replay.el ends here

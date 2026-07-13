;;; source-invariants.el --- Multiple-cursor redisplay invariants  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; These tests inspect the generic redisplay sources directly.  They keep the
;; secondary-cursor contract backend-neutral and catch accidental coupling to
;; the single primary physical cursor.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defun multi-cursor-source-tests--root ()
  "Return the Emacs source root for this test invocation."
  (let* ((test-file (or load-file-name buffer-file-name default-directory))
         (configured (and (boundp 'source-directory) source-directory))
         (candidates
          (delete-dups
           (delq nil
                 (list configured
                       (and configured
                            (file-name-directory
                             (directory-file-name configured)))
                       (locate-dominating-file test-file "src"))))))
    (or (cl-find-if
         (lambda (directory)
           (file-exists-p (expand-file-name "src/dispnew.c" directory)))
         candidates)
        (ert-fail "Cannot locate the Emacs source directory"))))

(defun multi-cursor-source-tests--source (file)
  "Return the contents of source FILE relative to the source root."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name file (multi-cursor-source-tests--root)))
    (buffer-string)))

(defun multi-cursor-source-tests--function-body (file function)
  "Return C FUNCTION's complete body from source FILE."
  (with-temp-buffer
    (insert (multi-cursor-source-tests--source file))
    (c-mode)
    (goto-char (point-min))
    (should (re-search-forward
             (concat "^" (regexp-quote function)
                     "[[:space:]\n]*(")
             nil t))
    (should (search-forward "{" nil t))
    (let ((start (1- (point)))
          (end (scan-sexps (1- (point)) 1)))
      (should end)
      (buffer-substring-no-properties start end))))

(defun multi-cursor-source-tests--match-count (regexp string)
  "Return the number of nonoverlapping matches for REGEXP in STRING."
  (let ((start 0)
        (count 0))
    (while (string-match regexp string start)
      (setq start (match-end 0)
            count (1+ count)))
    count))

(ert-deftest multi-cursor-source-has-backend-neutral-decoration-descriptor ()
  "Generic headers should describe resolved cursors without backend state."
  (let ((headers (concat (multi-cursor-source-tests--source "src/window.h")
                         "\n"
                         (multi-cursor-source-tests--source
                          "src/dispextern.h"))))
    (should (string-match-p "struct[[:space:]\n]+cursor_decoration" headers))
    (dolist (field
             (list "struct[[:space:]\n]+glyph_row[[:space:]\n]+\\*row"
               (concat "int[[:space:]\n]+x[[:space:]\n]*,"
                       "[[:space:]\n]*y[[:space:]\n]*,"
                       "[[:space:]\n]*height")
               "int[[:space:]\n]+width"
               "enum[[:space:]\n]+text_cursor_kinds[[:space:]\n]+kind"
               "unsigned[[:space:]\n]+long[[:space:]\n]+color_pixel"
               "bool[[:space:]\n]+on"))
      (should (string-match-p field headers)))))

(ert-deftest multi-cursor-source-has-optional-batch-decoration-callback ()
  "The redisplay interface should expose one optional batch painter."
  (let ((header (multi-cursor-source-tests--source "src/dispextern.h")))
    (should
     (string-match-p
      (concat "void[[:space:]\n]*(\\*draw_window_cursor_decorations)"
              "[[:space:]\n]*(struct window \\*,"
              "[[:space:]\n]*const struct cursor_decoration \\*,"
              "[[:space:]\n]*ptrdiff_t)")
      header))))

(ert-deftest multi-cursor-source-draws-decorations-before-primary-cursor ()
  "Generic window completion should draw secondary cursors before primary."
  (let* ((body (multi-cursor-source-tests--function-body
                "src/dispnew.c" "gui_update_window_end"))
         (decorations (string-match "draw_window_cursor_decorations" body))
         (primary (string-match "display_and_set_cursor" body)))
    (should decorations)
    (should primary)
    (should (< decorations primary))))

(ert-deftest multi-cursor-source-decoration-painter-has-null-safe-seam ()
  "An empty cache or absent backend painter should be a safe no-op."
  (let ((body (multi-cursor-source-tests--function-body
               "src/dispnew.c" "draw_window_cursor_decorations")))
    (should
     (string-match-p
      "cursor_decorations?_count[[:space:]]*==[[:space:]]*0" body))
    (should
     (string-match-p
      (concat "if[[:space:]\n]*("
              "[^)]*draw_window_cursor_decorations[^)]*)")
      body))))

(ert-deftest multi-cursor-source-frees-window-decoration-caches ()
  "Window teardown should explicitly release resolved decoration caches."
  (let* ((source (multi-cursor-source-tests--source "src/window.c"))
         (name (and (string-match
                     (concat "\\(free_[[:alnum:]_]*cursor_decoration"
                             "[[:alnum:]_]*\\)[[:space:]\n]*(") source)
                    (match-string 1 source))))
    (should name)
    (let ((body (multi-cursor-source-tests--function-body
                 "src/window.c" name)))
      (should (string-match-p "xfree" body)))
    (should
     (>= (multi-cursor-source-tests--match-count
          (concat (regexp-quote name) "[[:space:]\n]*(") source)
         2))))

(provide 'multi-cursor-source-invariants)

;;; source-invariants.el ends here

;;; indent-guides.el --- Indentation guides  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Maintainer: emacs-devel@gnu.org
;; Keywords: convenience, faces

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

;; Display vertical guides in leading indentation.  The guides themselves
;; are drawn by the display engine; this file only decides where guides
;; should stop (`display-indent-guides-spacing') and publishes the scope
;; ranges the display engine reads (`display-indent-guides-scope').
;;
;; Nothing here runs during redisplay.  Tree-sitter queries and syntax
;; parsing happen after commands, and hand their results to the display
;; engine as plain integers.  That is deliberate: parsing is slow and can
;; signal, and redisplay is the wrong place for either.

;;; Code:

(defgroup indent-guides nil
  "Vertical guides in leading indentation."
  :group 'convenience
  :version "32.1")

(defcustom indent-guides-spacing-alist
  '((python-mode . python-indent-offset)
    (python-ts-mode . python-indent-offset)
    (c-mode . c-basic-offset)
    (c-ts-mode . c-ts-mode-indent-offset)
    (c++-mode . c-basic-offset)
    (c++-ts-mode . c-ts-mode-indent-offset)
    (emacs-lisp-mode . lisp-body-indent)
    (lisp-interaction-mode . lisp-body-indent)
    (js-mode . js-indent-level)
    (js-ts-mode . js-indent-level)
    (typescript-ts-mode . typescript-ts-mode-indent-offset)
    (ruby-mode . ruby-indent-level)
    (ruby-ts-mode . ruby-indent-level)
    (sh-mode . sh-basic-offset)
    (rust-ts-mode . rust-ts-mode-indent-offset)
    (go-ts-mode . go-ts-mode-indent-offset)
    (yaml-ts-mode . yaml-indent-offset))
  "Alist mapping major modes to the variable holding their indent width.
Used by `indent-guides-mode' to choose `display-indent-guides-spacing'.
Modes not listed here fall back to `tab-width'."
  :type '(alist :key-type symbol :value-type symbol)
  :version "32.1")

(defcustom indent-guides-no-descend-string t
  "Non-nil means do not deepen guides inside multi-line strings."
  :type 'boolean
  :version "32.1")

(defcustom indent-guides-treesit-scope
  '((python-ts-mode function_definition class_definition if_statement
                    for_statement while_statement with_statement)
    (c-ts-mode compound_statement)
    (c++-ts-mode compound_statement)
    (js-ts-mode statement_block function_declaration)
    (typescript-ts-mode statement_block function_declaration)
    (rust-ts-mode block)
    (go-ts-mode block))
  "Alist mapping major modes to tree-sitter node types that form a scope.
When the major mode has a tree-sitter parser and an entry here,
`indent-guides-mode' limits guide depth to the innermost such node
containing point."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :version "32.1")

(defun indent-guides--guess-spacing ()
  "Return the number of columns between guides for the current buffer."
  (let* ((var (alist-get major-mode indent-guides-spacing-alist))
         (val (and var (boundp var) (symbol-value var))))
    (if (and (integerp val) (> val 0))
        val
      tab-width)))

(defun indent-guides--scope-vector (depth ranges)
  "Build a value for `display-indent-guides-scope'.
DEPTH is the maximum guide depth inside RANGES, a list of (BEG . END)."
  (apply #'vector depth
         (apply #'append
                (mapcar (lambda (r) (list (car r) (cdr r))) ranges))))

(defun indent-guides--string-ranges ()
  "Return a list holding the range of the string around point, or nil.
Used to keep guides from descending into multi-line strings."
  (when indent-guides-no-descend-string
    (let ((state (syntax-ppss)))
      (when (nth 3 state)
        (let ((beg (nth 8 state)))
          (save-excursion
            (goto-char beg)
            (condition-case nil
                (progn (forward-sexp 1)
                       (list (cons beg (point))))
              (error (list (cons beg (point-max)))))))))))

(defun indent-guides--treesit-range ()
  "Return (BEG . END) of the innermost tree-sitter scope at point, or nil."
  (when (and (fboundp 'treesit-parser-list)
             (treesit-parser-list)
             (alist-get major-mode indent-guides-treesit-scope))
    (let* ((types (alist-get major-mode indent-guides-treesit-scope))
           (node (ignore-errors
                   (treesit-parent-until
                    (treesit-node-at (point))
                    (lambda (n)
                      (memq (intern (treesit-node-type n)) types))
                    t))))
      (when node
        (cons (treesit-node-start node) (treesit-node-end node))))))

(defun indent-guides--depth-at (pos)
  "Return the guide depth of the line containing POS."
  (length (internal--indent-guide-stops pos)))

(defun indent-guides--compute-scope ()
  "Return the scope value for the current buffer, or nil."
  (let ((strings (indent-guides--string-ranges)))
    (if strings
        ;; Inside a multi-line string: cap at the string's own depth, so
        ;; that indented string contents do not add guides.
        (indent-guides--scope-vector
         (indent-guides--depth-at (caar strings))
         strings)
      (let ((ts (indent-guides--treesit-range)))
        (when ts
          (indent-guides--scope-vector
           (1+ (indent-guides--depth-at (car ts)))
           (list ts)))))))

(defun indent-guides--update-scope ()
  "Recompute `display-indent-guides-scope' for the current buffer.
Redisplay only reads that variable, so windows showing this buffer have
to be told to redisplay when it changes.  Do that only on a real change,
to avoid forcing a redisplay after every command."
  (let ((new (indent-guides--compute-scope)))
    (unless (equal new display-indent-guides-scope)
      (setq display-indent-guides-scope new)
      (force-window-update (current-buffer)))))

(defvar-local indent-guides--saved-spacing nil
  "Value of `display-indent-guides-spacing' before the mode was enabled.")

;;;###autoload
(define-minor-mode indent-guides-mode
  "Display vertical guides in leading indentation.

The guides are drawn by the display engine.  This mode chooses the
column spacing for the current major mode and, where tree-sitter is
available, limits guide depth to the syntactic scope around point.

Customize the faces `indent-guide-1' through `indent-guide-8' to give
each nesting level its own color, and `indent-guide-current' for the
highlighted depth.  Set `display-indent-guides-highlight-current' to
highlight the guide of the block containing point."
  :lighter nil
  (if indent-guides-mode
      (progn
        (setq indent-guides--saved-spacing display-indent-guides-spacing)
        (setq display-indent-guides-spacing (indent-guides--guess-spacing))
        (setq display-indent-guides t)
        (add-hook 'post-command-hook #'indent-guides--update-scope nil t)
        (indent-guides--update-scope))
    (remove-hook 'post-command-hook #'indent-guides--update-scope t)
    (setq display-indent-guides nil)
    (setq display-indent-guides-scope nil)
    (when indent-guides--saved-spacing
      (setq display-indent-guides-spacing indent-guides--saved-spacing))))

;;;###autoload
(define-globalized-minor-mode global-indent-guides-mode
  indent-guides-mode
  (lambda () (when (derived-mode-p 'prog-mode) (indent-guides-mode 1))))

(provide 'indent-guides)
;;; indent-guides.el ends here

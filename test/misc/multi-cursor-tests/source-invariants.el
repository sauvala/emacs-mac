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
    (goto-char (point-min))
    (should (re-search-forward
             (concat "^" (regexp-quote function)
                     "[[:space:]\n]*(")
             nil t))
    (should (search-forward "{" nil t))
    (let* ((start (1- (point)))
           (depth 1)
           (state 'code)
           end)
      (while (and (> depth 0) (< (point) (point-max)))
        (let ((character (char-after))
              (next (char-after (1+ (point)))))
          (pcase state
            ('code
             (cond
              ((and (eq character ?/) (eq next ?*))
               (setq state 'comment)
               (forward-char 1))
              ((and (eq character ?/) (eq next ?/))
               (setq state 'line-comment)
               (forward-char 1))
              ((eq character ?\") (setq state 'string))
              ((eq character ?\') (setq state 'character))
              ((eq character ?{) (setq depth (1+ depth)))
              ((eq character ?}) (setq depth (1- depth)))))
            ('comment
             (when (and (eq character ?*) (eq next ?/))
               (setq state 'code)
               (forward-char 1)))
            ('line-comment
             (when (eq character ?\n)
               (setq state 'code)))
            ((or 'string 'character)
             (cond
              ((eq character ?\\) (forward-char 1))
              ((or (and (eq state 'string) (eq character ?\"))
                   (and (eq state 'character) (eq character ?\')))
               (setq state 'code)))))
          (forward-char 1)))
      (when (= depth 0)
        (setq end (point)))
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

(defun multi-cursor-source-tests--c-code-match-p (regexp source)
  "Return non-nil if REGEXP matches C code, not comments, in SOURCE."
  (with-temp-buffer
    (insert source)
    (c-mode)
    (syntax-propertize (point-max))
    (catch 'match
      (while (re-search-forward regexp nil t)
        (let ((state (syntax-ppss (match-beginning 0))))
          (unless (or (nth 3 state) (nth 4 state))
            (throw 'match t)))))))

(defun multi-cursor-source-tests--c-defun (file lisp-name-regexp)
  "Return a DEFUN form from FILE matching LISP-NAME-REGEXP."
  (let ((source (multi-cursor-source-tests--source file)))
    (should (string-match
             (concat "^DEFUN (\"" lisp-name-regexp "\"") source))
    (let ((start (match-beginning 0)))
      (substring source start
                 (or (string-match "^DEFUN (\"" source (1+ start))
                     (length source))))))

(defun multi-cursor-source-tests--elisp-defun (file function)
  "Return Lisp FUNCTION's defining form from FILE."
  (with-temp-buffer
    (insert (multi-cursor-source-tests--source file))
    (emacs-lisp-mode)
    (goto-char (point-min))
    (should (re-search-forward
             (concat "^(defun[[:space:]\n]+" (regexp-quote function)
                     "\\_>") nil t))
    (let* ((start (match-beginning 0))
           (end (scan-sexps start 1)))
      (should end)
      (buffer-substring-no-properties start end))))

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
               "src/dispnew.c" "paint_window_cursor_decorations")))
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

(ert-deftest multi-cursor-source-publishes-immutable-sorted-snapshot ()
  "Lisp should replace the selected window's sorted snapshot as one value."
  (let* ((source (multi-cursor-source-tests--source "lisp/multi-cursor.el"))
         (body (multi-cursor-source-tests--elisp-defun
                "lisp/multi-cursor.el"
                "multi-cursor--publish-redisplay-snapshot")))
    (should (string-match-p "pre-redisplay-functions" source))
    (should (string-match-p "multi-cursor--sorted-cursors" body))
    (should (string-match-p "buffer-chars-modified-tick" body))
    (should (string-match-p "current-buffer" body))
    (dolist (accessor '("multi-cursor--cursor-id"
                        "multi-cursor--cursor-point"
                        "multi-cursor--cursor-mark"
                        "multi-cursor--cursor-mark-active"
                        "multi-cursor--cursor-direction"))
      (should (string-match-p accessor body)))
    (should (string-match-p "(vconcat" body))
    (should (string-match-p "selected-window" body))
    (should (string-match-p "multi-cursor--set-redisplay-snapshot" body))
    (should (string-match-p "multi-cursor--redisplay-window" body))
    (should
     (>= (multi-cursor-source-tests--match-count
          "multi-cursor--set-redisplay-snapshot" body)
         2))
    (should-not (string-match-p "aset" body))))

(ert-deftest multi-cursor-source-window-traces-published-snapshot ()
  "The selected window should retain the published Lisp snapshot safely."
  (let* ((header (multi-cursor-source-tests--source "src/window.h"))
         (field (string-match
                 "Lisp_Object[[:space:]\n]+cursor_decorations_snapshot"
                 header))
         (desired
          (string-match
           "Lisp_Object[[:space:]\n]+desired_cursor_decorations_snapshot"
           header))
         (last-lisp (string-match "No Lisp data may follow" header)))
    (should field)
    (should desired)
    (should last-lisp)
    (should (< field last-lisp))
    (should (< desired last-lisp))
    (should
     (string-match-p "cursor_decorations_changed_p" header))))

(ert-deftest multi-cursor-source-snapshot-setter-invalidates-precisely ()
  "The dedicated setter should retain snapshots and request redisplay."
  (let ((body (multi-cursor-source-tests--c-defun
               "src/window.c" "multi-cursor--set-redisplay-snapshot")))
    (should (string-match-p "cursor_decorations_snapshot" body))
    (should (string-match-p "desired_cursor_decorations_snapshot" body))
    (should (string-match-p "cursor_decorations_changed_p" body))
    (should (string-match-p "redisplay" body))
    (should
     (string-match-p "Fequal\\|internal_equal\\|equal_no_quit" body))))

(ert-deftest multi-cursor-source-promotes-snapshot-after-completed-update ()
  "Only a completed window update should promote the desired snapshot."
  (let* ((body (multi-cursor-source-tests--function-body
                "src/dispnew.c" "update_window"))
         (completed (string-match "gui_update_window_end" body))
         (promotion (and completed
                         (string-match
                          "desired_cursor_decorations_snapshot"
                          body completed)))
         (clear (and promotion
                     (string-match
                      (concat "cursor_decorations_changed_p"
                              "[[:space:]]*=[[:space:]]*false")
                      body promotion))))
    (should completed)
    (should promotion)
    (should clear)
    (should (< completed promotion))
    (should (< promotion clear))))

(ert-deftest multi-cursor-source-invalidates-snapshot-with-window-state ()
  "Buffer replacement and matrix teardown should invalidate snapshots."
  (let ((buffer-setter (multi-cursor-source-tests--function-body
                        "src/window.c" "set_window_buffer"))
        (matrix-free (multi-cursor-source-tests--function-body
                      "src/dispnew.c" "free_window_matrices")))
    (should
     (string-match-p "desired_cursor_decorations_snapshot" buffer-setter))
    (should (string-match-p "cursor_decorations_changed_p" buffer-setter))
    (should (string-match-p "free_window_cursor_decorations" matrix-free))
    (should
     (string-match-p "desired_cursor_decorations_snapshot" matrix-free))
    (should (string-match-p "cursor_decorations_changed_p" matrix-free))))

(ert-deftest multi-cursor-source-changed-only-fast-path-guards ()
  "No-op and cursor-motion shortcuts should care only about snapshot change."
  (let ((predicate (multi-cursor-source-tests--function-body
                    "src/xdisp.c"
                    "window_cursor_decorations_changed_p")))
    (should (string-match-p "cursor_decorations_changed_p" predicate))
    (should-not (string-match-p "cursor_decorations_snapshot" predicate)))
  (dolist (function '("needs_no_redisplay" "try_cursor_movement"))
    (let ((body (multi-cursor-source-tests--function-body
                 "src/xdisp.c" function)))
      (should
       (or (string-match-p "w->cursor_decorations_changed_p" body)
           (string-match-p "window_cursor_decorations_changed_p" body)))
      (should-not (string-match-p "cursor_decorations_snapshot" body))
      (should-not (string-match-p "window_has_cursor_decorations_p" body)))))

(ert-deftest multi-cursor-source-active-snapshot-blocks-pixel-reuse ()
  "Direct scrolling should reject changed or currently active snapshots."
  (let ((predicate (multi-cursor-source-tests--function-body
                    "src/xdisp.c" "window_has_cursor_decorations_p")))
    (dolist (field '("cursor_decorations_changed_p"
                     "cursor_decorations_snapshot"
                     "desired_cursor_decorations_snapshot"))
      (should (string-match-p field predicate))))
  (dolist (function '("try_window_reusing_current_matrix" "try_window_id"))
    (let ((body (multi-cursor-source-tests--function-body
                 "src/xdisp.c" function)))
      (should
       (string-match-p "window_has_cursor_decorations_p" body))))
  (let ((body (multi-cursor-source-tests--function-body
               "src/dispnew.c" "update_window")))
    (dolist (field '("cursor_decorations_changed_p"
                     "cursor_decorations_snapshot"
                     "desired_cursor_decorations_snapshot"))
      (should (string-match-p field body)))
    (should
     (string-match-p
      "no_scrolling_p[[:space:]]*=[[:space:]]*true" body))))

(ert-deftest multi-cursor-source-row-resolver-has-arbitrary-target-contract ()
  "The row resolver should take an explicit target and result cursor."
  (let* ((source (multi-cursor-source-tests--source "src/xdisp.c"))
         (start (string-match "^resolve_cursor_pos_from_row[[:space:]\n]*("
                              source))
         (end (and start (string-match "{" source start)))
         (header (and end (substring source start end))))
    (should header)
    (should
     (string-match-p
      "ptrdiff_t[[:space:]]+target_charpos\\_>" header))
    (should
     (string-match-p
      (concat "struct[[:space:]]+cursor_pos"
              "[[:space:]]*\\*[[:space:]]*result\\_>")
      header))))

(ert-deftest multi-cursor-source-row-resolver-does-not-mutate-primary-state ()
  "The arbitrary-position resolver should only populate its result."
  (let ((body (multi-cursor-source-tests--function-body
               "src/xdisp.c" "resolve_cursor_pos_from_row")))
    (should (string-match-p "\\_<target_charpos\\_>" body))
    (should (string-match-p "result[[:space:]]*->" body))
    (should-not
     (multi-cursor-source-tests--c-code-match-p
      "\\_<PT\\_>\\|\\_<PT_BYTE\\_>" body))
    (should-not
     (multi-cursor-source-tests--c-code-match-p
      "w[[:space:]]*->[[:space:]]*cursor\\_>" body))
    (should-not
     (multi-cursor-source-tests--c-code-match-p
      "w[[:space:]]*->[[:space:]]*phys_cursor\\_>" body))
    (should-not
     (multi-cursor-source-tests--c-code-match-p "\\_<this_line_" body))))

(ert-deftest multi-cursor-source-primary-row-wrapper-preserves-state-updates ()
  "The primary wrapper should publish the result and update this-line state."
  (let ((body (multi-cursor-source-tests--function-body
               "src/xdisp.c" "set_cursor_from_row")))
    (should (string-match-p "resolve_cursor_pos_from_row[[:space:]\n]*(" body))
    (should (string-match-p "\\_<PT\\_>" body))
    (should
     (string-match-p
      "w[[:space:]]*->[[:space:]]*cursor[[:space:]]*=" body))
    (should
     (string-match-p
      "w[[:space:]]*==[[:space:]]*XWINDOW[[:space:]\n]*(selected_window)"
      body))
    (dolist (state '("this_line_buffer"
                     "this_line_start_pos"
                     "this_line_end_pos"
                     "this_line_y"
                     "this_line_pixel_height"
                     "this_line_vpos"
                     "this_line_start_x"
                     "delta_bytes"))
      (should (string-match-p (concat "\\_<" state "\\_>") body)))))

(ert-deftest multi-cursor-source-associates-decoration-rows-monotonically ()
  "Sorted cursor positions should share a forward base-row scan."
  (let ((body (multi-cursor-source-tests--function-body
               "src/xdisp.c" "resolve_window_cursor_decorations")))
    (should
     (string-match-p
      "for[[:space:]\n]*(ptrdiff_t i = 2;"
      body))
    (should (string-match-p (regexp-quote "i += 5") body))
    (should
     (string-match-p
      "target[[:space:]]*=[[:space:]]*XFIXNAT[[:space:]\n]*(AREF"
      body))
    (should (string-match-p "resolve_cursor_pos_from_row" body))
    (should (string-match-p (regexp-quote "++row") body))
    (should-not (string-match-p "--[[:space:]]*row\\_>" body))
    (should-not (string-match-p "pos_visible_in_window_p" body))
    (let ((reset (string-match
                  (concat "desired_cursor_decorations_count"
                          "[[:space:]]*=[[:space:]]*0")
                  body))
          (scan (string-match "resolve_cursor_pos_from_row" body)))
      (should reset)
      (should scan)
      (should (< reset scan)))))

(ert-deftest multi-cursor-source-rejects-stale-decoration-cache-input ()
  "Cache population should reject snapshots stale for buffer or tick."
  (let ((body (multi-cursor-source-tests--function-body
               "src/xdisp.c" "resolve_window_cursor_decorations")))
    (should (string-match-p "desired_cursor_decorations_valid_p" body))
    (should
     (string-match-p
      "EQ[[:space:]\n]*(AREF[[:space:]\n]*(snapshot,[[:space:]]*0)"
      body))
    (should (string-match-p "Fbuffer_chars_modified_tick" body))
    (let ((validation (string-match "Fbuffer_chars_modified_tick" body))
          (scan (string-match "resolve_cursor_pos_from_row" body))
          (valid (string-match
                  (concat "desired_cursor_decorations_valid_p"
                          "[[:space:]]*=[[:space:]]*true")
                  body (string-match "for[[:space:]\n]*(ptrdiff_t i" body))))
      (should validation)
      (should scan)
      (should valid)
      (should (< validation scan))
      (should (< scan valid)))))

(ert-deftest multi-cursor-source-damages-old-decorations-before-row-reuse ()
  "Old decoration pixels should be erased before row reuse."
  (let* ((update (multi-cursor-source-tests--function-body
                  "src/dispnew.c" "update_window"))
         (damage-call (string-match "damage_window_cursor_decorations" update))
         (scroll (string-match "scrolling_window" update))
         (damage (multi-cursor-source-tests--function-body
                  "src/dispnew.c" "damage_window_cursor_decorations")))
    (should damage-call)
    (should scroll)
    (should (< damage-call scroll))
    (should
     (string-match-p
      "paint_window_cursor_decorations[[:space:]\n]*(w,[[:space:]]*false)"
      damage))
    (let ((paint (multi-cursor-source-tests--function-body
                  "src/dispnew.c" "paint_window_cursor_decorations")))
      (should (string-match-p "cursor_decorations_count" paint))
      (should
       (string-match-p
        "\\.on[[:space:]]*=[[:space:]]*on_p[[:space:]]*&&"
        paint)))))

(ert-deftest multi-cursor-source-promotes-valid-decoration-cache-atomically ()
  "Completed glyph repair should publish one valid cache transaction."
  (let* ((update (multi-cursor-source-tests--function-body
                  "src/dispnew.c" "update_window"))
         (repair (string-match "set_window_cursor_after_update" update))
         (publish (string-match "publish_window_cursor_decorations" update))
         (gui-end (string-match "gui_update_window_end" update))
         (snapshot (and gui-end
                        (string-match
                         "wset_cursor_decorations_snapshot" update gui-end)))
         (body (multi-cursor-source-tests--function-body
                "src/dispnew.c" "publish_window_cursor_decorations")))
    (should repair)
    (should publish)
    (should gui-end)
    (should snapshot)
    (should (< repair publish))
    (should (< publish gui-end))
    (should (< gui-end snapshot))
    (should (string-match-p "desired_cursor_decorations_valid_p" body))
    (dolist (field '("cursor_decorations"
                     "cursor_decorations_count"
                     "cursor_decorations_capacity"))
      (should
       (string-match-p
        (concat "w->[[:space:]]*" field
                "[[:space:]]*=[[:space:]]*w->[[:space:]]*desired_"
                field)
        body)))
    (should
     (string-match-p
      "desired_cursor_decorations_count[[:space:]]*=[[:space:]]*0"
      body))))

(ert-deftest multi-cursor-source-stale-cache-remains-pending ()
  "A stale desired cache should neither publish nor clear change state."
  (let* ((body (multi-cursor-source-tests--function-body
                "src/dispnew.c" "update_window"))
         (publish (string-match "publish_window_cursor_decorations" body))
         (condition (and publish
                         (string-match
                          "if[[:space:]\n]*(cursor_decorations_published_p)"
                          body publish)))
         (clear (and condition
                     (string-match
                      (concat "cursor_decorations_changed_p"
                              "[[:space:]]*=[[:space:]]*false")
                      body condition))))
    (should publish)
    (should condition)
    (should clear)
    (should (< publish condition))
    (should (< condition clear))))

(ert-deftest multi-cursor-source-mac-installs-one-batch-cursor-painter ()
  "The Mac RIF should install the optional batch painter in its last slot."
  (let ((source (multi-cursor-source-tests--source "src/macterm.c")))
    (should
     (string-match-p
      (concat "mac_draw_window_cursor_decorations[[:space:]\n]*("
              "struct window \\*[^,]*,"
              "[[:space:]\n]*const struct cursor_decoration \\*[^,]*,"
              "[[:space:]\n]*ptrdiff_t")
      source))
    (should
     (string-match-p
      (concat "mac_hide_hourglass[[:space:]]*,"
              "[[:space:]\n]*NULL[[:space:]]*,"
              "[[:space:]\n]*mac_draw_window_cursor_decorations")
      source))))

(ert-deftest multi-cursor-source-mac-cursor-painter-is-stateless-batch ()
  "The Mac painter should draw inherited cursor shapes without primary state."
  (let ((body (multi-cursor-source-tests--function-body
               "src/macterm.c" "mac_draw_window_cursor_decorations"))
        (resolver (multi-cursor-source-tests--function-body
                   "src/macterm.c" "mac_resolve_cursor_decoration")))
    (should (string-match-p "\\_<count\\_>" body))
    (should (string-match-p "decorations" body))
    (should (string-match-p "DEFAULT_CURSOR" body))
    (should (string-match-p "mac_resolve_cursor_decoration" body))
    (should (string-match-p "DEFAULT_CURSOR" resolver))
    (should (string-match-p "FRAME_DESIRED_CURSOR" resolver))
    (should (string-match-p "cursor_type" resolver))
    (should (string-match-p "cursor_pixel" body))
    (should (string-match-p "window_box" body))
    (should (string-match-p "WINDOW_TEXT_TO_FRAME_PIXEL_X" body))
    (should (string-match-p "WINDOW_TO_FRAME_PIXEL_Y" body))
    (should (string-match-p "draw_glyphs" body))
    (should (string-match-p "DRAW_NORMAL_TEXT" body))
    (should (string-match-p "DRAW_MOUSE_FACE" body))
    (should (string-match-p "mac_cursor_decoration_restore_span" body))
    (should
     (string-match-p "calloc[[:space:]\n]*(nrows,[[:space:]]*sizeof" body))
    (should (string-match-p "span[[:space:]]*->[[:space:]]*used_p" body))
    (should
     (string-match-p
      "for[[:space:]\n]*(ptrdiff_t i = 0; i < count;" body))
    (should
     (string-match-p
      "for[[:space:]\n]*(ptrdiff_t vpos = 0; vpos < nrows;" body))
    (dolist (kind '("FILLED_BOX_CURSOR" "HOLLOW_BOX_CURSOR"
                    "BAR_CURSOR" "HBAR_CURSOR"))
      (should (string-match-p kind body)))
    (should (string-match-p "mac_cursor_decoration_command" body))
    (should (string-match-p "ncommands" body))
    (should
     (string-match-p "calloc[[:space:]\n]*(count,[[:space:]]*sizeof"
                     body))
    (should (string-match-p "free" body))
    (should (string-match-p "MAC_BEGIN_DRAW_TO_FRAME" body))
    (should (string-match-p "MAC_END_DRAW_TO_FRAME" body))
    (should
     (= (multi-cursor-source-tests--match-count
         "MAC_BEGIN_DRAW_TO_FRAME" body)
        1))
    (should-not
     (multi-cursor-source-tests--c-code-match-p
      "w[[:space:]]*->[[:space:]]*phys_cursor" body))
    (should-not
     (multi-cursor-source-tests--c-code-match-p
      "w[[:space:]]*->[[:space:]]*phys_cursor" resolver))
    (should-not (string-match-p "cursor_off_p" resolver))
    (dolist (primary-helper '("mac_draw_window_cursor"
                              "mac_draw_hollow_cursor"
                              "mac_draw_bar_cursor"))
      (should-not
       (multi-cursor-source-tests--c-code-match-p primary-helper body)))
    (should-not
     (multi-cursor-source-tests--c-code-match-p
      "dispatch_\\(?:async\\|sync\\)" body))))

(provide 'multi-cursor-source-invariants)

;;; source-invariants.el ends here

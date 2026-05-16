;;; source-invariants.el --- Tests for macOS font renderer source invariants  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect the macOS font renderer source directly.  They catch
;; regressions in performance-sensitive paths that are difficult to exercise in
;; non-GUI test runs.

;;; Code:

(require 'ert)

(defun macfont-tests--source ()
  "Return the contents of src/macfont.m."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "src/macfont.m" source-directory))
    (buffer-string)))

(defun macfont-tests--function-body (function-name)
  "Return the source body for FUNCTION-NAME in src/macfont.m."
  (let ((source (macfont-tests--source)))
    (should (string-match (concat "\n" (regexp-quote function-name) " (")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match (regexp-quote "\n#else  /* HAVE_NS */")
                            source start))
      (substring source start (match-beginning 0)))))

(ert-deftest macfont-draw-uses-stack-storage-for-short-glyph-strings ()
  "Short macfont draw calls should avoid heap allocation for glyph arrays."
  (let ((body (macfont-tests--function-body "macfont_draw")))
    (should (string-match-p "MACFONT_DRAW_STACK_GLYPHS" body))
    (should (string-match-p "stack_glyphs" body))
    (should (string-match-p "stack_positions" body))
    (should (string-match-p "len <= MACFONT_DRAW_STACK_GLYPHS" body))))

(ert-deftest macfont-metal-draw-reuses-coretext-glyph-arrays ()
  "The Metal text path should not copy glyph arrays before drawing."
  (let ((body (macfont-tests--function-body "macfont_draw")))
    (should-not (string-match-p "metal_glyphs" body))
    (should-not (string-match-p "metal_positions" body))
    (should (string-match-p
             (regexp-quote "emacs_metal_draw_glyphs (FRAME_METAL_CTX (f),")
             body))))

;;; source-invariants.el ends here

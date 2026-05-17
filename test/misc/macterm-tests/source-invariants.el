;;; source-invariants.el --- Tests for macOS terminal source invariants  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect macOS terminal source directly.  They catch regressions
;; in performance-sensitive paths that are difficult to exercise in non-GUI
;; test runs.

;;; Code:

(require 'ert)

(defun macterm-tests--source ()
  "Return the contents of src/macterm.c."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "src/macterm.c" source-directory))
    (buffer-string)))

(defun macterm-tests--function-body (function-name next-marker)
  "Return FUNCTION-NAME source body from src/macterm.c up to NEXT-MARKER."
  (let ((source (macterm-tests--source)))
    (should (string-match (concat "\n" (regexp-quote function-name) " (")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match (regexp-quote next-marker) source start))
      (substring source start (match-beginning 0)))))

(ert-deftest macterm-metal-cg-image-draw-uses-texture-cache ()
  "The Metal CGImage draw path should not upload and destroy every draw."
  (let ((body (macterm-tests--function-body
               "mac_draw_cg_image"
               "\n/* Mac replacement for XCreateBitmapFromBitmapData.  */")))
    (should (string-match-p "emacs_metal_get_cached_cg_image" body))
    (should-not (string-match-p "emacs_metal_upload_cg_image" body))
    (should-not (string-match-p "emacs_metal_destroy_texture" body))))

(ert-deftest macterm-metal-clip-union-records-overdraw-stats ()
  "The Metal clip union path should record exact and union clip areas."
  (let ((body (macterm-tests--function-body
               "mac_metal_apply_gc_clip"
               "\nuint32_t\nmac_metal_background_color")))
    (should (string-match-p "mac_metal_clip_exact_area" body))
    (should (string-match-p "mac_metal_clip_union_area" body))
    (should (string-match-p "CGRectUnion" body))
    (should (string-match-p "emacs_metal_set_clip_rects" body)))
  (let ((source (macterm-tests--source)))
    (should (string-match-p "mac-metal-clip-overdraw-stats" source))
    (should (string-match-p "defsubr (&Smac_metal_clip_overdraw_stats)" source))))

(ert-deftest macterm-exposes-metal-render-stats ()
  "The mac terminal should expose Metal render counters to Lisp."
  (let ((source (macterm-tests--source)))
    (should (string-match-p "mac-metal-render-stats" source))
    (should (string-match-p "emacs_metal_get_render_stats" source))
    (should (string-match-p ":present-blits" source))
    (should (string-match-p ":present-blit-bytes" source))
    (should (string-match-p ":scroll-blits" source))
    (should (string-match-p ":scroll-blit-bytes" source))
    (should (string-match-p ":next-drawable-calls" source))
    (should (string-match-p ":next-drawable-seconds" source))
    (should (string-match-p ":max-next-drawable-seconds" source))
    (should (string-match-p ":glyph-cache-hits" source))
    (should (string-match-p ":glyph-cache-misses" source))
    (should (string-match-p "defsubr (&Smac_metal_render_stats)" source))))

(ert-deftest macterm-exposes-metal-display-sync-toggle ()
  "The mac terminal should expose the Metal display-sync toggle to Lisp."
  (let ((source (macterm-tests--source)))
    (should (string-match-p "mac-metal-set-display-sync-enabled" source))
    (should (string-match-p "emacs_metal_set_display_sync_enabled" source))
    (should (string-match-p
             "defsubr (&Smac_metal_set_display_sync_enabled)" source))))

(ert-deftest macterm-exposes-metal-maximum-drawable-count-toggle ()
  "The mac terminal should expose Metal drawable-count tuning to Lisp."
  (let ((source (macterm-tests--source)))
    (should (string-match-p "mac-metal-set-maximum-drawable-count" source))
    (should (string-match-p "emacs_metal_set_maximum_drawable_count" source))
    (should (string-match-p
             "defsubr (&Smac_metal_set_maximum_drawable_count)" source))))

;;; source-invariants.el ends here

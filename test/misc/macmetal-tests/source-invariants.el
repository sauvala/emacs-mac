;;; source-invariants.el --- Tests for macOS Metal renderer source invariants  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect the Metal renderer source directly.  They are intended
;; to catch performance regressions in code that is only compiled when Emacs is
;; configured with --with-metal-rendering.

;;; Code:

(require 'ert)

(defun macmetal-tests--source ()
  "Return the contents of src/macmetal.m."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "src/macmetal.m" source-directory))
    (buffer-string)))

(defun macmetal-tests--function-body (function-name)
  "Return the source body for FUNCTION-NAME in src/macmetal.m."
  (let ((source (macmetal-tests--source)))
    (should (string-match (concat "\n" (regexp-quote function-name) " (")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match (pcase function-name
                              ("flush_render_batches"
                               "\n}\n\nvoid\nemacs_metal_frame_end")
                              ("glyph_cache_rasterize"
                               (regexp-quote "\n}\n\n/* Draw an array"))
                              (_ "\n}\n\n"))
                            source start))
      (substring source start (match-beginning 0)))))

(ert-deftest macmetal-flush-render-batches-reuses-frame-vertex-buffer ()
  "Metal batch flushing should not allocate and copy a fresh vertex buffer."
  (let ((body (macmetal-tests--function-body "flush_render_batches")))
    (should-not (string-match-p "newBufferWithBytes" body))
    (should (string-match-p
             (regexp-quote "ctx->vertex_buffers[ctx->current_buffer]")
             body))))

(ert-deftest macmetal-glyph-rasterize-reuses-scratch-pixel-buffer ()
  "Glyph cache misses should reuse context-owned scratch pixel storage."
  (let ((body (macmetal-tests--function-body "glyph_cache_rasterize")))
    (should (string-match-p "glyph_scratch_pixels" body))
    (should-not (string-match-p "pixels = calloc" body))
    (should-not (string-match-p "free (pixels)" body))))

(ert-deftest macmetal-batches-preserve-multiple-clip-rectangles ()
  "Metal batches should replay one vertex range through each active clip rect."
  (let ((source (macmetal-tests--source))
        (flush-body (macmetal-tests--function-body "flush_render_batches")))
    (should (string-match-p "emacs_metal_set_clip_rects" source))
    (should (string-match-p "clip_offset" source))
    (should (string-match-p "clip_count" source))
    (should (string-match-p "batch_clip_rects" source))
    (should (string-match-p "clip_index < batch->clip_count" flush-body))
    (should (string-match-p "batch->vertex_offset" flush-body))
    (should (string-match-p "batch->vertex_count" flush-body))))

(ert-deftest macmetal-records-render-counters ()
  "Metal should count hot renderer operations for performance analysis."
  (let ((source (macmetal-tests--source))
        (flush-body (macmetal-tests--function-body "flush_render_batches"))
        (upload-body (macmetal-tests--function-body
                      "emacs_metal_upload_cg_image")))
    (should (string-match-p "emacs_metal_render_stats" source))
    (should (string-match-p "emacs_metal_get_render_stats" source))
    (should (string-match-p "render_stats.flushes" flush-body))
    (should (string-match-p "render_stats.batches" flush-body))
    (should (string-match-p "render_stats.vertices" flush-body))
    (should (string-match-p "render_stats.texture_uploads" upload-body))
    (should (string-match-p "render_stats.texture_upload_bytes" upload-body))
    (should (string-match-p "command_buffer_seconds" source))))

(ert-deftest macmetal-glyph-cache-evicts-entries-instead-of-resetting ()
  "Glyph cache pressure should evict entries without resetting all atlas pages."
  (let ((source (macmetal-tests--source))
        (body (macmetal-tests--function-body "glyph_cache_rasterize")))
    (should (string-match-p "glyph_cache_evict_entries" source))
    (should (string-match-p "eviction_cursor" source))
    (should (string-match-p "last_used" source))
    (should-not (string-match-p "memset (gc->entries" body))
    (should-not (string-match-p "Reset all atlas pages" body))))

;;; source-invariants.el ends here

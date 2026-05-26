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
	      ("emacs_metal_dispatch_presentation_task"
	       "\n}\n\nstatic void\nemacs_metal_schedule_presentation")
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
	(presentation-body
	 (macmetal-tests--function-body "emacs_metal_dispatch_presentation_task"))
	(upload-body (macmetal-tests--function-body
		      "emacs_metal_upload_cg_image")))
    (should (string-match-p "emacs_metal_render_stats" source))
    (should (string-match-p "emacs_metal_get_render_stats" source))
    (should (string-match-p "render_stats.flushes" flush-body))
    (should (string-match-p "render_stats.batches" flush-body))
    (should (string-match-p "render_stats.vertices" flush-body))
    (should (string-match-p "render_stats.texture_uploads" upload-body))
    (should (string-match-p "render_stats.texture_upload_bytes" upload-body))
    (should (string-match-p "next_drawable_seconds" source))
    (should (string-match-p "render_stats.next_drawable_calls"
			    presentation-body))
    (should (string-match-p "render_stats.next_drawable_seconds"
			    presentation-body))
    (should (string-match-p "command_buffer_seconds" source))))

(ert-deftest macmetal-can-toggle-layer-display-sync ()
  "Metal should expose a layer display-sync toggle for pacing experiments."
  (let ((source (macmetal-tests--source)))
    (should (string-match-p "emacs_metal_set_display_sync_enabled" source))
    (should (string-match-p "setDisplaySyncEnabled:" source))
    (should (string-match-p "displaySyncEnabled" source))))

(ert-deftest macmetal-can-tune-maximum-drawable-count ()
  "Metal should expose CAMetalLayer drawable-count tuning for pacing tests."
  (let ((source (macmetal-tests--source)))
    (should (string-match-p "emacs_metal_set_maximum_drawable_count" source))
    (should (string-match-p "setMaximumDrawableCount:" source))
    (should (string-match-p "maximumDrawableCount" source))))

(ert-deftest macmetal-records-present-and-scroll-blits-separately ()
  "Metal should distinguish presentation blits from scroll-preservation blits."
  (let ((source (macmetal-tests--source))
	(presentation-body
	 (macmetal-tests--function-body "emacs_metal_dispatch_presentation_task"))
	(scroll-body (macmetal-tests--function-body "emacs_metal_scroll")))
    (should (string-match-p "present_blits" source))
    (should (string-match-p "present_blit_bytes" source))
    (should (string-match-p "scroll_blits" source))
    (should (string-match-p "scroll_blit_bytes" source))
    (should (string-match-p "render_stats.present_blits" presentation-body))
    (should (string-match-p "render_stats.present_blit_bytes"
			    presentation-body))
    (should (string-match-p "render_stats.scroll_blits" scroll-body))
    (should (string-match-p "render_stats.scroll_blit_bytes" scroll-body))))

(ert-deftest macmetal-skips-presentation-when-backbuffer-is-unchanged ()
  "Metal should avoid full-drawable presentation for no-op update cycles."
  (let ((source (macmetal-tests--source))
        (frame-end-body (macmetal-tests--function-body
                         "emacs_metal_frame_end"))
        (emit-body (macmetal-tests--function-body "emit_vertices"))
        (scroll-body (macmetal-tests--function-body "emacs_metal_scroll")))
    (should (string-match-p "backbuffer_dirty" source))
    (should (string-match-p "ctx->backbuffer_dirty = false" source))
    (should (string-match-p "ctx->backbuffer_dirty = true" emit-body))
    (should (string-match-p "ctx->backbuffer_dirty = true" scroll-body))
    (should (string-match-p "ctx->backbuffer_dirty = false" frame-end-body))
    (should (string-match-p
	     "if (!ctx->backbuffer_dirty)[\0-\377]*return;[^\0]*emacs_metal_schedule_presentation"
	     frame-end-body))))

(ert-deftest macmetal-scroll-can-avoid-staging-for-bounded-axis-aligned-copies ()
  "Axis-aligned scrolls should avoid staging when ordered direct chunks are bounded."
  (let ((source (macmetal-tests--source))
        (scroll-body (macmetal-tests--function-body "emacs_metal_scroll")))
    (should (string-match-p "METAL_SCROLL_DIRECT_MAX_BLITS" source))
    (should (string-match-p "scroll_backbuffer_in_place" source))
    (should (string-match-p "scroll_backbuffer_in_place" scroll-body))
    (should (string-match-p
             (regexp-quote "render_stats.scroll_blits += scroll_blit_count")
             scroll-body))
    (should (string-match-p
             (regexp-quote "render_stats.scroll_blit_bytes += scroll_blit_bytes")
             scroll-body))
    (should (string-match-p
             "scroll_blit_bytes = (uintmax_t) sw \\* sh \\* 4"
             source))))

(ert-deftest macmetal-records-glyph-cache-counters ()
  "Metal should count glyph cache hits and misses for tuning atlas behavior."
  (let ((source (macmetal-tests--source))
        (lookup-body (macmetal-tests--function-body "glyph_cache_lookup"))
        (rasterize-body (macmetal-tests--function-body
                         "glyph_cache_rasterize")))
    (should (string-match-p "glyph_cache_hits" source))
    (should (string-match-p "glyph_cache_misses" source))
    (should (string-match-p "render_stats.glyph_cache_hits" lookup-body))
    (should (string-match-p "render_stats.glyph_cache_misses" rasterize-body))))

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

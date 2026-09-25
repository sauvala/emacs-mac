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

(defun macmetal-tests--macterm-source ()
  "Return the contents of src/macterm.c."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "src/macterm.c" source-directory))
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
             (regexp-quote "ctx->current_vertex_buffer")
             body))))

(ert-deftest macmetal-spills-instead-of-dropping-overflowing-frames ()
  "Exhausting a frame's vertex buffer must not discard the rest of the frame."
  (let ((source (macmetal-tests--source))
        (emit-body (macmetal-tests--function-body "emit_vertices")))
    (should (string-match-p "rotate_spill_vertex_buffer" source))
    (should (string-match-p "spill_vertex_buffers" source))
    (should (string-match-p "rotate_spill_vertex_buffer" emit-body))
    (should (string-match-p "vertex_buffer_spills" source))))

(ert-deftest macmetal-triple-buffers-vertex-storage ()
  "Frame begin must not block on the immediately preceding frame."
  (should (string-match-p
           (regexp-quote "#define METAL_VERTEX_BUFFER_COUNT (3)")
           (macmetal-tests--source))))

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
    (should (string-match-p "METAL_STAT_INC (flushes)" flush-body))
    (should (string-match-p "METAL_STAT_ADD (batches" flush-body))
    (should (string-match-p "METAL_STAT_ADD (vertices" flush-body))
    (should (string-match-p "METAL_STAT_INC (texture_uploads)" upload-body))
    (should (string-match-p "METAL_STAT_ADD (texture_upload_bytes"
			    upload-body))
    (should (string-match-p "next_drawable_seconds" source))
    (should (string-match-p "METAL_SHARED_INC (next_drawable_calls)"
			    presentation-body))
    (should (string-match-p "next_drawable_ns" presentation-body))
    (should (string-match-p "command_buffer_seconds" source))))

(ert-deftest macmetal-counters-are-atomic ()
  "Counters are updated from the main thread, the presenter queue and
Metal's completion handler threads, so they must not be plain fields."
  (let ((source (macmetal-tests--source)))
    (should (string-match-p "struct metal_shared_counters" source))
    (should (string-match-p "_Atomic uintmax_t frames" source))
    (should (string-match-p "atomic_fetch_add_explicit" source))
    (should (string-match-p "metal_stat_max" source))
    ;; Elapsed times accumulate in nanoseconds: C11 has no atomic
    ;; arithmetic on floating point types.
    (should (string-match-p "_Atomic uint64_t command_buffer_ns" source))
    ;; Counters the main thread owns must stay plain, and must not share a
    ;; cache line with the ones other threads write.
    (should (string-match-p "struct metal_main_counters" source))
    (should (string-match-p (regexp-quote "(main_stats.field++)") source))
    (should (string-match-p "aligned (METAL_CACHE_LINE)" source))
    (should (string-match-p "METAL_STAT_INC (glyph_cache_hits)"
                            (macmetal-tests--function-body
                             "glyph_cache_lookup")))
    (should-not (string-match-p "atomic.*glyph_cache_hits" source))))

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
    (should (string-match-p "METAL_SHARED_INC (present_blits)"
			    presentation-body))
    (should (string-match-p "METAL_SHARED_ADD (present_blit_bytes"
			    presentation-body))
    (should (string-match-p "METAL_STAT_ADD (scroll_blits" scroll-body))
    (should (string-match-p "METAL_STAT_ADD (scroll_blit_bytes"
			    scroll-body))))

(ert-deftest macmetal-skips-presentation-when-backbuffer-is-unchanged ()
  "Metal should avoid full-drawable presentation for no-op update cycles."
  (let ((source (macmetal-tests--source))
        (frame-end-body (macmetal-tests--function-body
                         "emacs_metal_frame_end_1"))
        (emit-body (macmetal-tests--function-body "emit_vertices"))
        (scroll-body (macmetal-tests--function-body "emacs_metal_scroll")))
    (should (string-match-p "backbuffer_dirty" source))
    (should (string-match-p "ctx->backbuffer_dirty = false" source))
    (should (string-match-p "ctx->backbuffer_dirty = true" emit-body))
    (should (string-match-p "ctx->backbuffer_dirty = true" scroll-body))
    (should (string-match-p "ctx->backbuffer_dirty = false" frame-end-body))
    (should (string-match-p
	     "if (!(ctx->backbuffer_dirty || (present && ctx->presentation_held))[\0-\377]*return;[^\0]*emacs_metal_schedule_presentation"
	     frame-end-body))))

(ert-deftest macmetal-holds-presentation-of-garbaged-frame-clear ()
  "Clearing a garbaged frame must not be presented before its redraw.
redraw_frame clears the frame in an update of its own; presenting that
update showed a blank frame after each live-resize step."
  (let ((frame-end-body (macmetal-tests--function-body
                         "emacs_metal_frame_end_1"))
        (macterm (macmetal-tests--macterm-source)))
    (should (string-match-p "ctx->presentation_held = !present;" frame-end-body))
    (should (string-match-p "if (present)\n *emacs_metal_schedule_presentation"
                            frame-end-body))
    (should (string-match-p
             "FRAME_GARBAGED_P (f))\n *emacs_metal_frame_end_held"
             macterm))
    ;; A presentation still pending must not show the held clear.
    (should (string-match-p
             "if (!present)\n *emacs_metal_hold_presentation_source (ctx);\n *\\[cmd commit\\]"
             frame-end-body))
    ;; Nor may drawing outside an update, such as the internal border
    ;; that redisplay clears before it redraws the frame.
    (should (string-match-p
             "emacs_metal_frame_end_1 (ctx, !ctx->presentation_held);"
             (macmetal-tests--function-body
              "emacs_metal_end_implicit_frame")))))

(ert-deftest macmetal-held-frame-does-not-wait-for-a-drawable ()
  "A held frame must not wait for a pending presentation's copy.
The presenter gets its drawable first, which waits for the display
refresh; waiting for its copy stalled every redisplay of a garbaged
frame by about 16 ms.  Instead the held frame snapshots the
backbuffer's presentable contents, queued before its own drawing, and
the presenter copies from the snapshot until the next frame is
scheduled for presentation."
  (let ((frame-end (macmetal-tests--function-body "emacs_metal_frame_end_1"))
        (hold (macmetal-tests--function-body
               "emacs_metal_hold_presentation_source"))
        (schedule (macmetal-tests--function-body
                   "emacs_metal_schedule_presentation"))
        (present (macmetal-tests--function-body
                  "emacs_metal_dispatch_presentation_task")))
    (should-not (string-match-p "wait_for_presentation_copy" frame-end))
    ;; Snapshot only while a presentation has not committed its copy,
    ;; and not again over a held frame's drawing.
    (should (string-match-p
             (concat "!ctx->present_from_snapshot[\0-\377]*"
                     "ctx->presentation_scheduled[\0-\377]*"
                     "ctx->presentation_needs_reschedule[\0-\377]*"
                     "!ctx->presentation_committed")
             hold))
    ;; The snapshot is queued and the presenter redirected under the
    ;; lock the presenter chooses its source under.
    (should (string-match-p
             (concat "pthread_mutex_lock (&ctx->presentation_mutex);"
                     "[^\0]*toTexture:snapshot[^\0]*\\[cmd commit\\];\n"
                     " *ctx->present_from_snapshot = true;[^\0]*"
                     "pthread_mutex_unlock (&ctx->presentation_mutex);")
             hold))
    (should (string-match-p "snapshot.width != backbuffer.width" hold))
    (should (string-match-p
             (concat "pthread_mutex_lock (&ctx->presentation_mutex);"
                     "[^;]*\n *ctx->present_from_snapshot = false;\n"
                     " *if (ctx->presentation_valid && ctx->sync_presentation)")
             schedule))
    ;; The presenter picks its source, encodes and commits the copy
    ;; without releasing the lock.
    (should (string-match-p
             (concat "pthread_mutex_lock (&ctx->presentation_mutex);\n"
                     " *valid = ctx->presentation_valid;\n"
                     " *source = (ctx->present_from_snapshot\n"
                     " *\\? ctx->present_snapshot : ctx->backbuffer);"
                     "[^\0]*copyFromTexture:source"
                     "[^\0]*\\[cmd commit\\];\n"
                     " *ctx->presentation_committed = true;")
             present))
    ;; Between choosing the source and committing, the lock is released
    ;; only on the path that commits nothing (the completion handler
    ;; runs later and takes it itself).
    (should (string-match
             "source = (ctx->present_from_snapshot[^\0]*?\\[cmd commit\\];"
             present))
    (let ((region (replace-regexp-in-string
                   "addCompletedHandler:[^\0]*?\n *}\\];" ""
                   (match-string 0 present))))
      (should (= 2 (length (split-string region
                                         "pthread_mutex_unlock")))))))

(ert-deftest macmetal-presentation-task-snapshots-context-under-lock ()
  "The presenter queue must not read context fields the main thread stores."
  (let ((body (macmetal-tests--function-body
               "emacs_metal_dispatch_presentation_task")))
    (should (string-match-p
             (concat "pthread_mutex_lock (&ctx->presentation_mutex)"
                     "[\0-\377]*layer = ctx->layer;"
                     "[\0-\377]*pthread_mutex_unlock")
             body))
    (should (string-match-p
             (concat "pthread_mutex_lock (&ctx->presentation_mutex);"
                     "[^\0]*ctx->backbuffer);")
             body))
    (should-not (string-match-p "= ctx->backbuffer;" body))))

(ert-deftest macmetal-does-not-block-the-main-thread-on-resize ()
  "Backbuffer creation and resize must not stall redisplay on the GPU."
  (let ((create-body (macmetal-tests--function-body "create_backbuffer"))
        (resize-body (macmetal-tests--function-body
                      "emacs_metal_context_resize")))
    (should-not (string-match-p (regexp-quote "[cmd waitUntilCompleted]")
                                create-body))
    (should-not (string-match-p (regexp-quote "[cmd waitUntilCompleted]")
                                resize-body))))

(ert-deftest macmetal-draws-outside-redisplay-updates ()
  "Cursor, mouse face and visual bell drawing happens outside update_begin."
  (let ((source (macmetal-tests--source))
        (macterm (macmetal-tests--macterm-source)))
    (should (string-match-p "emacs_metal_ensure_frame" source))
    (should (string-match-p "emacs_metal_end_implicit_frame" source))
    (should (string-match-p "implicit_frame" source))
    (should (string-match-p "emacs_metal_end_implicit_frame" macterm))
    (dolist (fn '("emacs_metal_fill_rect" "emacs_metal_draw_rect"
                  "emacs_metal_draw_line" "emacs_metal_draw_glyphs"
                  "emacs_metal_scroll" "emacs_metal_draw_image_texture"))
      (should (string-match-p "emacs_metal_ensure_frame"
                              (macmetal-tests--function-body fn))))))

(ert-deftest macmetal-uses-byte-exact-color-render-targets ()
  "Metal render targets should preserve Emacs sRGB color bytes."
  (let ((source (macmetal-tests--source)))
    (should (string-match-p "MTLPixelFormatBGRA8Unorm" source))
    (should-not (string-match-p "MTLPixelFormatBGRA8Unorm_sRGB" source))))

(ert-deftest macmetal-scrolls-through-staging-texture ()
  "Scroll preservation should avoid same-texture overlapping blits."
  (let ((source (macmetal-tests--source))
        (scroll-body (macmetal-tests--function-body "emacs_metal_scroll")))
    (should (string-match-p "scroll_staging" scroll-body))
    (should (string-match-p "ctx->scroll_staging" scroll-body))
    (should-not (string-match-p "scroll_backbuffer_in_place" source))
    (should-not (string-match-p "METAL_SCROLL_DIRECT_MAX_BLITS" source))
    (should (string-match-p
             (regexp-quote "METAL_STAT_ADD (scroll_blits, scroll_blit_count)")
             scroll-body))
    (should (string-match-p
             (regexp-quote
              "METAL_STAT_ADD (scroll_blit_bytes, scroll_blit_bytes)")
             scroll-body))
    (should (string-match-p
             "scroll_blit_bytes = (uintmax_t) sw \\* sh \\* 4 \\* 2"
             scroll-body))))

(ert-deftest macmetal-clears-non-overlay-images-before-drawing ()
  "Metal image masks must replace backgrounds instead of leaving stale pixels."
  (let ((source (macmetal-tests--macterm-source)))
    (should (string-match-p
             (regexp-quote
              "if (!(flags & MAC_DRAW_CG_IMAGE_OVERLAY))\n      mac_erase_rectangle (f, gc, dest_x, dest_y, width, height, true);")
             source))))

(ert-deftest macmetal-records-glyph-cache-counters ()
  "Metal should count glyph cache hits and misses for tuning atlas behavior."
  (let ((source (macmetal-tests--source))
        (lookup-body (macmetal-tests--function-body "glyph_cache_lookup"))
        (rasterize-body (macmetal-tests--function-body
                         "glyph_cache_rasterize")))
    (should (string-match-p "glyph_cache_hits" source))
    (should (string-match-p "glyph_cache_misses" source))
    (should (string-match-p "METAL_STAT_INC (glyph_cache_hits)" lookup-body))
    (should (string-match-p "METAL_STAT_INC (glyph_cache_misses)"
			    rasterize-body))))

(ert-deftest macmetal-glyph-cache-owns-its-font-references ()
  "Entries are keyed on the CTFontRef address, so they must hold a reference."
  (let ((source (macmetal-tests--source))
        (rasterize-body (macmetal-tests--function-body
                         "glyph_cache_rasterize")))
    (should (string-match-p "glyph_cache_entry_clear" source))
    (should (string-match-p "CFRelease (entry->font)" source))
    (should (string-match-p "CFRetain (font)" rasterize-body))))

(ert-deftest macmetal-glyph-cache-probes-consistently ()
  "An entry stored beyond the distance lookups search is never found again."
  (let ((source (macmetal-tests--source))
        (lookup-body (macmetal-tests--function-body "glyph_cache_lookup"))
        (rasterize-body (macmetal-tests--function-body
                         "glyph_cache_rasterize")))
    (should (string-match-p "GLYPH_CACHE_MAX_PROBE" source))
    (should (string-match-p "probe < GLYPH_CACHE_MAX_PROBE" lookup-body))
    (should (string-match-p "probe < GLYPH_CACHE_MAX_PROBE" rasterize-body))
    (should-not (string-match-p "probe < GLYPH_CACHE_SIZE" rasterize-body))))

(ert-deftest macmetal-glyph-cache-is-keyed-by-backing-scale ()
  "Glyphs rasterized for one backing scale must not be reused at another scale."
  (let ((source (macmetal-tests--source))
        (hash-body (macmetal-tests--function-body "glyph_cache_hash"))
        (lookup-body (macmetal-tests--function-body "glyph_cache_lookup"))
        (rasterize-body (macmetal-tests--function-body
                         "glyph_cache_rasterize")))
    (should (string-match-p "uint8_t scale" source))
    (should (string-match-p "scale" hash-body))
    (should (string-match-p "scale" lookup-body))
    (should (string-match-p "entry->scale = ctx->scale" rasterize-body))))

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

(ert-deftest macmetal-fills-undrawn-areas-with-frame-background ()
  "Areas a growing window adds must not flash a fixed colour.
The backbuffer used to be cleared to white, which showed when a window
grew faster than redisplay."
  (let ((create (macmetal-tests--function-body "create_backbuffer"))
        (present (macmetal-tests--function-body
                  "emacs_metal_dispatch_presentation_task")))
    (should (string-match-p "clearColor = ctx->clear_color;" create))
    (should-not (string-match-p "MTLClearColorMake (1.0, 1.0, 1.0" create))
    (should (string-match-p
             "if (copy_w < dst.width || copy_h < dst.height)" present))
    (should (string-match-p "emacs_metal_set_clear_color (FRAME_METAL_CTX (f)"
                            (with-temp-buffer
                              (insert-file-contents
                               (expand-file-name "src/macappkit.m"
                                                 source-directory))
                              (buffer-string))))))

(ert-deftest macmetal-presents-live-resize-frames-with-transaction ()
  "Live-resize frames are presented in the window's Core Animation transaction.
Apple documents the order for `presentsWithTransaction': commit the
command buffer, wait until it is scheduled, then present the drawable
(not `presentDrawable:' on the command buffer).  In synchronous mode
the presenter queue is bypassed."
  (let ((present (macmetal-tests--function-body "emacs_metal_present_sync"))
        (schedule (macmetal-tests--function-body
                   "emacs_metal_schedule_presentation"))
        (set-sync (macmetal-tests--function-body
                   "emacs_metal_set_sync_presentation")))
    (should (string-match-p
             "\\[cmd commit\\];\n *\\[cmd waitUntilScheduled\\];\n *\\[drawable present\\];"
             present))
    (should-not (string-match-p "presentDrawable" present))
    (should (string-match-p
             "ctx->sync_presentation)[\0-\377]*ctx->sync_frame_ready = true;[\0-\377]*return;[\0-\377]*emacs_metal_dispatch_presentation_task"
             schedule))
    (should (string-match-p "presentsWithTransaction = flag" set-sync))
    ;; The presenter queue must be idle before the layer switches.
    (should (string-match-p
             "if (flag)\n[^;]*\n *emacs_metal_wait_for_presentation_copy (ctx);"
             set-sync))))

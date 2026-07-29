#ifndef EMACS_MACMETAL_H
#define EMACS_MACMETAL_H

#ifdef USE_METAL_RENDERING

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>

typedef struct emacs_metal_context emacs_metal_context_t;

struct emacs_metal_render_stats
{
  uintmax_t frames;
  uintmax_t flushes;
  uintmax_t batches;
  uintmax_t vertices;
  uintmax_t vertex_buffer_spills;
  uintmax_t scissor_draws;
  uintmax_t blits;
  uintmax_t blit_bytes;
  uintmax_t present_blits;
  uintmax_t present_blit_bytes;
  uintmax_t scroll_blits;
  uintmax_t scroll_blit_bytes;
  uintmax_t texture_uploads;
  uintmax_t texture_upload_bytes;
  uintmax_t glyph_cache_hits;
  uintmax_t glyph_cache_misses;
  uintmax_t clip_set_rect_calls;
  uintmax_t clip_set_rect_skips;
  uintmax_t clip_set_rects_calls;
  uintmax_t clip_set_rects_skips;
  uintmax_t clip_reset_calls;
  uintmax_t clip_reset_skips;
  uintmax_t next_drawable_calls;
  double next_drawable_seconds;
  double max_next_drawable_seconds;
  uintmax_t presentation_requests;
  uintmax_t presentation_coalesced_requests;
  uintmax_t presentation_task_runs;
  uintmax_t presentation_final_reschedules;
  uintmax_t command_buffers;
  double command_buffer_seconds;
  double max_command_buffer_seconds;
};

/* Context lifecycle */
extern emacs_metal_context_t *emacs_metal_context_create (void *view,
                                                           int width,
                                                           int height,
                                                           int scale);
extern void emacs_metal_context_resize (emacs_metal_context_t *ctx,
                                        int width, int height,
                                        int scale);
extern void emacs_metal_context_destroy (emacs_metal_context_t *ctx);
extern void emacs_metal_get_render_stats (struct emacs_metal_render_stats *,
                                          bool reset);
extern bool emacs_metal_set_display_sync_enabled (emacs_metal_context_t *ctx,
                                                  bool enabled);
extern bool emacs_metal_set_maximum_drawable_count (emacs_metal_context_t *ctx,
                                                    unsigned long count);

/* Frame begin/end */
extern void emacs_metal_frame_begin (emacs_metal_context_t *ctx);
extern void emacs_metal_frame_end (emacs_metal_context_t *ctx);

/* Drawing primitives */
extern void emacs_metal_fill_rect (emacs_metal_context_t *ctx,
                                   int x, int y, int w, int h,
                                   uint32_t color);
extern void emacs_metal_draw_rect (emacs_metal_context_t *ctx,
                                   int x, int y, int w, int h,
                                   uint32_t color);
extern void emacs_metal_draw_line (emacs_metal_context_t *ctx,
                                   int x1, int y1, int x2, int y2,
                                   uint32_t color);

/* Clipping */
extern void emacs_metal_set_clip_rect (emacs_metal_context_t *ctx,
                                       int x, int y, int w, int h);
extern void emacs_metal_set_clip_rects (emacs_metal_context_t *ctx,
                                        const CGRect *rects, int count);
extern void emacs_metal_reset_clip (emacs_metal_context_t *ctx);

/* Glyph rendering -- font is a CTFontRef cast to void* for C API */
extern void emacs_metal_draw_glyphs (emacs_metal_context_t *ctx,
                                     const CGGlyph *glyphs,
                                     const CGPoint *positions,
                                     int count,
                                     void *font,
                                     uint32_t color,
                                     float origin_x,
                                     float baseline_y);

/* Scrolling */
extern void emacs_metal_scroll (emacs_metal_context_t *ctx,
                                int x, int y, int w, int h,
                                int dx, int dy);

/* Image rendering */
extern void *emacs_metal_upload_cg_image (emacs_metal_context_t *ctx,
                                          void *cg_image,
                                          int width, int height,
                                          void *fill_color);
extern void *emacs_metal_get_cached_cg_image (emacs_metal_context_t *ctx,
                                              void *cg_image,
                                              int width, int height,
                                              void *fill_color);
extern void emacs_metal_draw_image_texture (emacs_metal_context_t *ctx,
                                            void *texture,
                                            int src_x, int src_y,
                                            int src_w, int src_h,
                                            int dst_x, int dst_y,
                                            int dst_w, int dst_h);
extern void emacs_metal_destroy_texture (void *texture);

#endif /* USE_METAL_RENDERING */
#endif /* EMACS_MACMETAL_H */

#ifndef EMACS_MACMETAL_H
#define EMACS_MACMETAL_H

#ifdef USE_METAL_RENDERING

#include <stdint.h>

typedef struct emacs_metal_context emacs_metal_context_t;

/* Context lifecycle */
extern emacs_metal_context_t *emacs_metal_context_create (void *view,
                                                           int width,
                                                           int height,
                                                           int scale);
extern void emacs_metal_context_resize (emacs_metal_context_t *ctx,
                                        int width, int height);
extern void emacs_metal_context_destroy (emacs_metal_context_t *ctx);

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
extern void emacs_metal_push_clip (emacs_metal_context_t *ctx,
                                   int x, int y, int w, int h);
extern void emacs_metal_pop_clip (emacs_metal_context_t *ctx);

/* Scrolling */
extern void emacs_metal_scroll (emacs_metal_context_t *ctx,
                                int x, int y, int w, int h,
                                int dx, int dy);

#endif /* USE_METAL_RENDERING */
#endif /* EMACS_MACMETAL_H */

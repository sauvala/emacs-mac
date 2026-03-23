#include <config.h>

#ifdef USE_METAL_RENDERING

#include "macmetal.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

struct emacs_metal_context
{
  id<MTLDevice> device;
  id<MTLCommandQueue> command_queue;
  CAMetalLayer *layer;
  id<MTLTexture> backbuffer;
  int width;
  int height;
  int scale;
};

emacs_metal_context_t *
emacs_metal_context_create (void *view, int width, int height, int scale)
{
  emacs_metal_context_t *ctx = calloc (1, sizeof *ctx);
  if (!ctx)
    return NULL;

  ctx->device = MTLCreateSystemDefaultDevice ();
  if (!ctx->device)
    {
      free (ctx);
      return NULL;
    }

  ctx->command_queue = [ctx->device newCommandQueue];
  ctx->width = width;
  ctx->height = height;
  ctx->scale = scale;

  return ctx;
}

void
emacs_metal_context_resize (emacs_metal_context_t *ctx, int width, int height)
{
  ctx->width = width;
  ctx->height = height;
}

void
emacs_metal_context_destroy (emacs_metal_context_t *ctx)
{
  if (!ctx)
    return;
  free (ctx);
}

void
emacs_metal_frame_begin (emacs_metal_context_t *ctx)
{
}

void
emacs_metal_frame_end (emacs_metal_context_t *ctx)
{
}

void
emacs_metal_fill_rect (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h,
                       uint32_t color)
{
}

void
emacs_metal_draw_rect (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h,
                       uint32_t color)
{
}

void
emacs_metal_draw_line (emacs_metal_context_t *ctx,
                       int x1, int y1, int x2, int y2,
                       uint32_t color)
{
}

void
emacs_metal_push_clip (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h)
{
}

void
emacs_metal_pop_clip (emacs_metal_context_t *ctx)
{
}

void
emacs_metal_scroll (emacs_metal_context_t *ctx,
                    int x, int y, int w, int h,
                    int dx, int dy)
{
}

#endif /* USE_METAL_RENDERING */

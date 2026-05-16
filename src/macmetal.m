#include <config.h>

#ifdef USE_METAL_RENDERING

#include "macmetal.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>

/* Shared Metal state, initialized once on first context creation.  */
static id<MTLDevice> shared_device;
static id<MTLLibrary> shared_library;
static id<MTLRenderPipelineState> shared_solid_pipeline;
static id<MTLRenderPipelineState> shared_textured_pipeline;

/* Glyph atlas constants and data structures.  */

#define GLYPH_ATLAS_SIZE (2048)
#define GLYPH_ATLAS_MAX_PAGES (8)
#define GLYPH_CACHE_SIZE (16384)  /* MUST be power of 2 for hash table */
#define SUBPIXEL_POSITIONS (4)

typedef struct {
    CTFontRef font;
    uint16_t glyph_id;
    uint8_t subpixel;
    uint16_t atlas_page;
    uint16_t atlas_x, atlas_y;
    uint16_t atlas_w, atlas_h;
    float bearing_x, bearing_y;
    float advance;
    bool is_color;
} glyph_cache_entry_t;

typedef struct {
    id<MTLTexture> texture;
    int shelf_y;
    int shelf_height;
    int cursor_x;
    bool is_rgba;
} glyph_atlas_page_t;

struct emacs_metal_glyph_cache {
    glyph_atlas_page_t pages[GLYPH_ATLAS_MAX_PAGES];
    int page_count;
    glyph_cache_entry_t entries[GLYPH_CACHE_SIZE];
    int entry_count;
};

/* MSL shader source.  */
static NSString *const metal_shader_source = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct Vertex {\n"
"    float2 position;\n"
"    float2 texcoord;\n"
"    uchar4 color;\n"
"    uint   texture_id;\n"
"};\n"
"\n"
"struct VertexOut {\n"
"    float4 position [[position]];\n"
"    float2 texcoord;\n"
"    float4 color;\n"
"    uint   texture_id;\n"
"};\n"
"\n"
"struct Uniforms {\n"
"    float2 viewport_size;\n"
"};\n"
"\n"
"vertex VertexOut vertex_main(uint vid [[vertex_id]],\n"
"                             const device Vertex *vertices [[buffer(0)]],\n"
"                             constant Uniforms &uniforms [[buffer(1)]]) {\n"
"    VertexOut out;\n"
"    float2 pos = vertices[vid].position;\n"
"    out.position = float4(pos / uniforms.viewport_size * 2.0 - 1.0,\n"
"                          0.0, 1.0);\n"
"    out.position.y = -out.position.y;\n"
"    out.texcoord = vertices[vid].texcoord;\n"
"    out.color = float4(vertices[vid].color) / 255.0;\n"
"    out.texture_id = vertices[vid].texture_id;\n"
"    return out;\n"
"}\n"
"\n"
"fragment float4 fragment_solid(VertexOut in [[stage_in]]) {\n"
"    return in.color;\n"
"}\n"
"\n"
"fragment float4 fragment_textured(VertexOut in [[stage_in]],\n"
"                                  texture2d<float> atlas [[texture(0)]]) {\n"
"    constexpr sampler s(filter::nearest);\n"
"    float4 tex = atlas.sample(s, in.texcoord);\n"
"    if (in.texture_id == 1) {\n"
"        /* R8Unorm glyph atlas: alpha is in .r channel */\n"
"        return float4(in.color.rgb, in.color.a * tex.r);\n"
"    }\n"
"    /* RGBA textures (color emoji, images): direct color */\n"
"    return tex * in.color;\n"
"}\n";

/* Vertex and batch data structures.  */

#define METAL_MAX_VERTICES (262144)
#define METAL_MAX_CLIP_STACK (32)
#define METAL_VERTEX_BUFFER_COUNT (2)
#define METAL_MAX_BATCHES (4096)
#define METAL_MAX_ACTIVE_CLIP_RECTS (128)
#define METAL_MAX_BATCH_CLIP_RECTS (16384)
#define METAL_IMAGE_CACHE_SIZE (64)

typedef struct {
    float position[2];
    float texcoord[2];
    uint8_t color[4];
    uint32_t texture_id;
} metal_vertex_t;

typedef struct {
    int x, y, w, h;
} metal_clip_rect_t;

typedef struct {
    metal_clip_rect_t rects[METAL_MAX_ACTIVE_CLIP_RECTS];
    int count;
} metal_clip_region_t;

typedef struct {
    int vertex_offset;
    int vertex_count;
    int clip_offset;
    int clip_count;
    id<MTLTexture> texture;
    bool is_glyph;
} metal_batch_t;

typedef struct {
    CGImageRef image;
    CGColorRef fill_color;
    int width, height;
    id<MTLTexture> texture;
    uint64_t last_used;
} metal_image_cache_entry_t;

struct emacs_metal_context
{
  id<MTLCommandQueue> command_queue;
  id<MTLCommandBuffer> frame_command_buffer;
  CAMetalLayer *layer;
  id<MTLTexture> backbuffer;

  id<MTLBuffer> vertex_buffers[METAL_VERTEX_BUFFER_COUNT];
  int current_buffer;
  metal_vertex_t *vertices;
  int vertex_count;

  metal_batch_t batches[METAL_MAX_BATCHES];
  int batch_count;
  metal_clip_rect_t batch_clip_rects[METAL_MAX_BATCH_CLIP_RECTS];
  int batch_clip_rect_count;
  id<MTLTexture> current_texture;
  bool current_is_glyph;

  metal_clip_region_t clip_stack[METAL_MAX_CLIP_STACK];
  int clip_depth;

  int width, height, scale;
  bool in_frame;

  id<MTLTexture> scroll_staging;
  int scroll_staging_w, scroll_staging_h;

  dispatch_semaphore_t buffer_semaphore;

  struct emacs_metal_glyph_cache *glyph_cache;
  uint8_t *glyph_scratch_pixels;
  size_t glyph_scratch_capacity;

  metal_image_cache_entry_t image_cache[METAL_IMAGE_CACHE_SIZE];
  uint64_t image_cache_clock;
};

static void flush_render_batches (emacs_metal_context_t *ctx,
                                  id<MTLCommandBuffer> cmd);

static uint8_t *
glyph_scratch_pixels (emacs_metal_context_t *ctx, size_t size)
{
  if (size == 0)
    return NULL;

  if (ctx->glyph_scratch_capacity < size)
    {
      uint8_t *pixels = realloc (ctx->glyph_scratch_pixels, size);
      if (!pixels)
        return NULL;

      ctx->glyph_scratch_pixels = pixels;
      ctx->glyph_scratch_capacity = size;
    }

  memset (ctx->glyph_scratch_pixels, 0, size);
  return ctx->glyph_scratch_pixels;
}

static void
clear_image_cache_entry (metal_image_cache_entry_t *entry)
{
  if (entry->image)
    CGImageRelease (entry->image);
  if (entry->fill_color)
    CGColorRelease (entry->fill_color);

  entry->image = NULL;
  entry->fill_color = NULL;
  entry->width = 0;
  entry->height = 0;
  entry->texture = nil;
  entry->last_used = 0;
}

static bool
cg_color_key_equal (CGColorRef a, CGColorRef b)
{
  if (a == b)
    return true;
  if (!a || !b)
    return false;

  return CGColorEqualToColor (a, b);
}

/* Create render pipeline states from the embedded shader source.  */

static bool
create_pipelines (void)
{
  NSError *error = nil;
  MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
  shared_library = [shared_device newLibraryWithSource:metal_shader_source
                                               options:options
                                                 error:&error];
  if (!shared_library)
    {
      NSLog (@"Metal: failed to compile shaders: %@", error);
      return false;
    }

  id<MTLFunction> vertex_fn
    = [shared_library newFunctionWithName:@"vertex_main"];
  id<MTLFunction> fragment_solid_fn
    = [shared_library newFunctionWithName:@"fragment_solid"];
  id<MTLFunction> fragment_textured_fn
    = [shared_library newFunctionWithName:@"fragment_textured"];

  if (!vertex_fn || !fragment_solid_fn || !fragment_textured_fn)
    {
      NSLog (@"Metal: failed to find shader functions");
      return false;
    }

  /* Solid pipeline.  Blending is enabled so explicitly-alpha colors can
     implement transparent backgrounds and visual-bell overlays.  */
  {
    MTLRenderPipelineDescriptor *desc
      = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertex_fn;
    desc.fragmentFunction = fragment_solid_fn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor
      = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor
      = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor
      = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor
      = MTLBlendFactorOneMinusSourceAlpha;

    shared_solid_pipeline
      = [shared_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!shared_solid_pipeline)
      {
        NSLog (@"Metal: failed to create solid pipeline: %@", error);
        return false;
      }
  }

  /* Textured pipeline — alpha blending (srcAlpha / oneMinusSrcAlpha).  */
  {
    MTLRenderPipelineDescriptor *desc
      = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertex_fn;
    desc.fragmentFunction = fragment_textured_fn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor
      = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor
      = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor
      = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor
      = MTLBlendFactorOneMinusSourceAlpha;

    shared_textured_pipeline
      = [shared_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!shared_textured_pipeline)
      {
        NSLog (@"Metal: failed to create textured pipeline: %@", error);
        return false;
      }
  }

  return true;
}

/* Create or recreate the offscreen backbuffer texture.  */

static bool
create_backbuffer (emacs_metal_context_t *ctx)
{
  MTLTextureDescriptor *desc
    = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                     width:(NSUInteger)(ctx->width * ctx->scale)
                                    height:(NSUInteger)(ctx->height * ctx->scale)
                                 mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModePrivate;

  id<MTLTexture> texture = [shared_device newTextureWithDescriptor:desc];
  if (!texture)
    {
      NSLog (@"Metal: failed to create backbuffer");
      return false;
    }

  /* Clear the new backbuffer to white to avoid garbage on first frame.  */
  id<MTLCommandBuffer> cmd = [ctx->command_queue commandBuffer];
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake (1.0, 1.0, 1.0, 1.0);

  id<MTLRenderCommandEncoder> encoder
    = [cmd renderCommandEncoderWithDescriptor:pass];
  [encoder endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];

  ctx->backbuffer = texture;
  return true;
}

/* Create double-buffered vertex buffers and the frame semaphore.  */

static bool
create_vertex_buffers (emacs_metal_context_t *ctx)
{
  NSUInteger size = METAL_MAX_VERTICES * sizeof (metal_vertex_t);

  for (int i = 0; i < METAL_VERTEX_BUFFER_COUNT; i++)
    {
      ctx->vertex_buffers[i]
        = [shared_device newBufferWithLength:size
                                     options:MTLResourceStorageModeShared];
      if (!ctx->vertex_buffers[i])
        {
          NSLog (@"Metal: failed to create vertex buffer %d", i);
          return false;
        }
    }

  ctx->buffer_semaphore
    = dispatch_semaphore_create (METAL_VERTEX_BUFFER_COUNT);
  ctx->current_buffer = 0;

  return true;
}

emacs_metal_context_t *
emacs_metal_context_create (void *view, int width, int height, int scale)
{
  /* Initialize shared state on first call.  */
  if (!shared_device)
    {
      shared_device = MTLCreateSystemDefaultDevice ();
      if (!shared_device)
        {
          NSLog (@"Metal: no GPU device available");
          return NULL;
        }

      if (!create_pipelines ())
        {
          shared_device = nil;
          return NULL;
        }
    }

  emacs_metal_context_t *ctx = calloc (1, sizeof *ctx);
  if (!ctx)
    return NULL;

  ctx->command_queue = [shared_device newCommandQueue];
  if (!ctx->command_queue)
    {
      free (ctx);
      return NULL;
    }

  /* Set up the CAMetalLayer from the view.  */
  if (view)
    {
      NSView *nsview = (__bridge NSView *)view;
      ctx->layer = (CAMetalLayer *)[nsview layer];
      if (ctx->layer)
        {
          ctx->layer.contentsScale = scale;
          ctx->layer.drawableSize = CGSizeMake (width * scale, height * scale);
        }
    }

  ctx->width = width;
  ctx->height = height;
  ctx->scale = scale;

  if (!create_backbuffer (ctx))
    {
      free (ctx);
      return NULL;
    }

  if (!create_vertex_buffers (ctx))
    {
      free (ctx);
      return NULL;
    }

  ctx->glyph_cache = calloc (1, sizeof (struct emacs_metal_glyph_cache));
  if (!ctx->glyph_cache)
    {
      free (ctx);
      return NULL;
    }

  return ctx;
}

void
emacs_metal_context_resize (emacs_metal_context_t *ctx, int width, int height,
                           int scale)
{
  if (scale < 1) scale = 1;
  if (ctx->width == width && ctx->height == height && ctx->scale == scale)
    return;

  id<MTLTexture> old_backbuffer = ctx->backbuffer;
  int old_width = ctx->width * ctx->scale;
  int old_height = ctx->height * ctx->scale;

  ctx->width = width;
  ctx->height = height;
  ctx->scale = scale;

  if (!create_backbuffer (ctx))
    {
      /* Restore old backbuffer on failure.  */
      ctx->backbuffer = old_backbuffer;
      return;
    }

  /* Blit old content into the new backbuffer.  */
  int copy_width = MIN (old_width, ctx->width * ctx->scale);
  int copy_height = MIN (old_height, ctx->height * ctx->scale);

  if (copy_width > 0 && copy_height > 0)
    {
      id<MTLCommandBuffer> cmd = [ctx->command_queue commandBuffer];
      id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
      [blit copyFromTexture:old_backbuffer
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake (0, 0, 0)
                 sourceSize:MTLSizeMake (copy_width, copy_height, 1)
                  toTexture:ctx->backbuffer
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake (0, 0, 0)];
      [blit endEncoding];
      [cmd commit];
      [cmd waitUntilCompleted];
    }
}

void
emacs_metal_context_destroy (emacs_metal_context_t *ctx)
{
  if (!ctx)
    return;

  for (int i = 0; i < METAL_VERTEX_BUFFER_COUNT; i++)
    ctx->vertex_buffers[i] = nil;

  ctx->backbuffer = nil;
  ctx->scroll_staging = nil;
  ctx->command_queue = nil;
  ctx->layer = nil;
  free (ctx->glyph_scratch_pixels);
  for (int i = 0; i < METAL_IMAGE_CACHE_SIZE; i++)
    clear_image_cache_entry (&ctx->image_cache[i]);

  if (ctx->glyph_cache)
    {
      for (int i = 0; i < ctx->glyph_cache->page_count; i++)
        ctx->glyph_cache->pages[i].texture = nil;
      free (ctx->glyph_cache);
    }

  free (ctx);
}

void
emacs_metal_frame_begin (emacs_metal_context_t *ctx)
{
  dispatch_semaphore_wait (ctx->buffer_semaphore, DISPATCH_TIME_FOREVER);

  ctx->current_buffer = (ctx->current_buffer + 1) % METAL_VERTEX_BUFFER_COUNT;
  ctx->vertices = [ctx->vertex_buffers[ctx->current_buffer] contents];
  ctx->vertex_count = 0;
  ctx->batch_count = 0;
  ctx->batch_clip_rect_count = 0;
  ctx->current_texture = nil;
  ctx->current_is_glyph = false;

  /* Default clip to full frame in pixels.  */
  ctx->clip_depth = 1;
  ctx->clip_stack[0].count = 1;
  ctx->clip_stack[0].rects[0] = (metal_clip_rect_t){
    .x = 0, .y = 0,
    .w = ctx->width * ctx->scale,
    .h = ctx->height * ctx->scale
  };

  ctx->in_frame = true;
  ctx->frame_command_buffer = [ctx->command_queue commandBuffer];
}

/* Render all pending batches into the backbuffer and reset batch state.
   Uses LoadActionLoad so existing backbuffer content is preserved.  */
static void
flush_render_batches (emacs_metal_context_t *ctx, id<MTLCommandBuffer> cmd)
{
  if (ctx->batch_count == 0)
    return;
  if (ctx->vertex_count == 0)
    {
      ctx->batch_count = 0;
      return;
    }

  id<MTLBuffer> draw_buffer = ctx->vertex_buffers[ctx->current_buffer];
  if (!draw_buffer)
    return;

  MTLRenderPassDescriptor *pass
    = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = ctx->backbuffer;
  pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> encoder
    = [cmd renderCommandEncoderWithDescriptor:pass];

  float viewport_size[2] = {
    (float)(ctx->width * ctx->scale),
    (float)(ctx->height * ctx->scale)
  };

  [encoder setVertexBuffer:draw_buffer
                    offset:0
                   atIndex:0];
  [encoder setVertexBytes:viewport_size
                   length:sizeof (viewport_size)
                  atIndex:1];

  for (int i = 0; i < ctx->batch_count; i++)
    {
      metal_batch_t *batch = &ctx->batches[i];
      if (batch->vertex_count <= 0
          || batch->clip_count <= 0)
        continue;

      /* Select pipeline state.  */
      if (batch->texture)
        [encoder setRenderPipelineState:shared_textured_pipeline];
      else
        [encoder setRenderPipelineState:shared_solid_pipeline];

      /* Set texture if needed.  */
      if (batch->texture)
        [encoder setFragmentTexture:batch->texture atIndex:0];

      for (int clip_index = 0; clip_index < batch->clip_count; clip_index++)
        {
          metal_clip_rect_t *clip =
            &ctx->batch_clip_rects[batch->clip_offset + clip_index];
          if (clip->w <= 0 || clip->h <= 0)
            continue;

          MTLScissorRect scissor = {
            .x = (NSUInteger)clip->x,
            .y = (NSUInteger)clip->y,
            .width = (NSUInteger)clip->w,
            .height = (NSUInteger)clip->h
          };
          [encoder setScissorRect:scissor];

          [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:(NSUInteger)batch->vertex_offset
                      vertexCount:(NSUInteger)batch->vertex_count];
        }
    }

  [encoder endEncoding];

  ctx->batch_count = 0;
  ctx->batch_clip_rect_count = 0;
}

void
emacs_metal_frame_end (emacs_metal_context_t *ctx)
{
  if (!ctx->in_frame)
    return;

  ctx->in_frame = false;

  /* Get the next drawable from the layer.  */
  id<CAMetalDrawable> drawable = nil;
  if (ctx->layer)
    drawable = [ctx->layer nextDrawable];

  if (!drawable)
    {
      dispatch_semaphore_signal (ctx->buffer_semaphore);
      ctx->frame_command_buffer = nil;
      return;
    }

  id<MTLCommandBuffer> cmd = ctx->frame_command_buffer;
  if (!cmd)
    cmd = [ctx->command_queue commandBuffer];

  /* Render all pending batches into the backbuffer.  */
  flush_render_batches (ctx, cmd);

  /* Blit backbuffer to drawable texture.  */
  {
    id<MTLTexture> dst = drawable.texture;
    NSUInteger copy_w = MIN (ctx->backbuffer.width, dst.width);
    NSUInteger copy_h = MIN (ctx->backbuffer.height, dst.height);

    if (copy_w > 0 && copy_h > 0)
      {
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromTexture:ctx->backbuffer
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake (0, 0, 0)
                   sourceSize:MTLSizeMake (copy_w, copy_h, 1)
                    toTexture:dst
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake (0, 0, 0)];
        [blit endEncoding];
      }
  }

  /* Present and signal semaphore on completion.  */
  [cmd presentDrawable:drawable];

  __block dispatch_semaphore_t sema = ctx->buffer_semaphore;
  [cmd addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
    dispatch_semaphore_signal (sema);
  }];

  [cmd commit];
  ctx->frame_command_buffer = nil;
}

/* Local MIN/MAX for integer arithmetic if not already defined.  */
#ifndef METAL_MIN
# define METAL_MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef METAL_MAX
# define METAL_MAX(a, b) ((a) > (b) ? (a) : (b))
#endif

/* --- Batch management helpers --- */

static bool
clip_rects_equal (metal_clip_rect_t a, metal_clip_rect_t b)
{
  return a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h;
}

static metal_clip_rect_t
intersect_clip_rects (metal_clip_rect_t a, metal_clip_rect_t b)
{
  int ix = METAL_MAX (a.x, b.x);
  int iy = METAL_MAX (a.y, b.y);
  int ix2 = METAL_MIN (a.x + a.w, b.x + b.w);
  int iy2 = METAL_MIN (a.y + a.h, b.y + b.h);

  return (metal_clip_rect_t){
    .x = ix, .y = iy,
    .w = METAL_MAX (0, ix2 - ix),
    .h = METAL_MAX (0, iy2 - iy)
  };
}

static void
set_clip_to_cg_rect_union (emacs_metal_context_t *ctx, const CGRect *rects,
                           int count)
{
  CGRect union_rect = rects[0];

  for (int i = 1; i < count; i++)
    union_rect = CGRectUnion (union_rect, rects[i]);

  int x = floor (CGRectGetMinX (union_rect));
  int y = floor (CGRectGetMinY (union_rect));
  int x2 = ceil (CGRectGetMaxX (union_rect));
  int y2 = ceil (CGRectGetMaxY (union_rect));

  emacs_metal_set_clip_rect (ctx, x, y, x2 - x, y2 - y);
}

static bool
batch_clip_matches (emacs_metal_context_t *ctx, metal_batch_t *batch,
                    metal_clip_region_t *clip)
{
  if (batch->clip_count != clip->count)
    return false;

  for (int i = 0; i < clip->count; i++)
    if (!clip_rects_equal (ctx->batch_clip_rects[batch->clip_offset + i],
                           clip->rects[i]))
      return false;

  return true;
}

static bool
store_batch_clip (emacs_metal_context_t *ctx, metal_batch_t *batch,
                  metal_clip_region_t *clip)
{
  if (clip->count <= 0
      || ctx->batch_clip_rect_count + clip->count > METAL_MAX_BATCH_CLIP_RECTS)
    return false;

  batch->clip_offset = ctx->batch_clip_rect_count;
  batch->clip_count = clip->count;

  memcpy (&ctx->batch_clip_rects[batch->clip_offset], clip->rects,
          sizeof clip->rects[0] * clip->count);
  ctx->batch_clip_rect_count += clip->count;

  return true;
}

/* Return the current batch if it is compatible with (texture, is_glyph) and
   the current clip region, otherwise open a new one.  Returns NULL when the
   batch or clip array is full.  */
static metal_batch_t *
ensure_batch (emacs_metal_context_t *ctx,
              id<MTLTexture> texture, bool is_glyph)
{
  metal_clip_region_t *clip = &ctx->clip_stack[ctx->clip_depth - 1];

  if (ctx->batch_count > 0)
    {
      metal_batch_t *b = &ctx->batches[ctx->batch_count - 1];
      if (b->texture == texture
          && b->is_glyph == is_glyph
          && batch_clip_matches (ctx, b, clip))
        return b;
    }

  if (ctx->batch_count >= METAL_MAX_BATCHES)
    return NULL;

  metal_batch_t *b = &ctx->batches[ctx->batch_count++];
  b->vertex_offset = ctx->vertex_count;
  b->vertex_count  = 0;
  b->texture       = texture;
  b->is_glyph      = is_glyph;
  if (!store_batch_clip (ctx, b, clip))
    {
      ctx->batch_count--;
      return NULL;
    }
  return b;
}

/* Reserve space for count vertices, ensure a compatible batch, and return a
   pointer to the first reserved vertex.  Returns NULL on overflow.  */
static metal_vertex_t *
emit_vertices (emacs_metal_context_t *ctx, int count,
               id<MTLTexture> texture, bool is_glyph)
{
  if (!ctx->frame_command_buffer)
    return NULL;

  if (ctx->vertex_count + count > METAL_MAX_VERTICES)
    {
      flush_render_batches (ctx, ctx->frame_command_buffer);
      if (count > METAL_MAX_VERTICES
          || ctx->vertex_count + count > METAL_MAX_VERTICES)
        return NULL;
    }

  metal_batch_t *b = ensure_batch (ctx, texture, is_glyph);
  if (!b)
    {
      flush_render_batches (ctx, ctx->frame_command_buffer);
      b = ensure_batch (ctx, texture, is_glyph);
    }
  if (!b)
    return NULL;

  metal_vertex_t *v = &ctx->vertices[ctx->vertex_count];
  ctx->vertex_count += count;
  b->vertex_count   += count;
  return v;
}

/* Fill a single vertex.  color is 0xAARRGGBB.  */
static void
set_vertex (metal_vertex_t *v,
            float x, float y, float u, float v_coord,
            uint32_t color, uint32_t texture_id)
{
  v->position[0] = x;
  v->position[1] = y;
  v->texcoord[0] = u;
  v->texcoord[1] = v_coord;
  v->color[0]    = (uint8_t)((color >> 16) & 0xFF); /* R */
  v->color[1]    = (uint8_t)((color >>  8) & 0xFF); /* G */
  v->color[2]    = (uint8_t)( color        & 0xFF); /* B */
  v->color[3]    = (uint8_t)((color >> 24) & 0xFF); /* A */
  v->texture_id  = texture_id;
}

static uint32_t
metal_opaque_if_no_alpha (uint32_t color)
{
  return (color & 0xFF000000u) ? color : (color | 0xFF000000u);
}

/* --- Glyph atlas --- */

/* Allocate a rectangle (required_w x required_h) in the glyph atlas using
   shelf packing.  Returns the page index, and stores the allocated position
   in *out_x, *out_y.  Returns -1 on failure.  */
static int
glyph_cache_get_page (emacs_metal_context_t *ctx,
                      int required_w, int required_h,
                      bool is_rgba,
                      int *out_x, int *out_y)
{
  struct emacs_metal_glyph_cache *gc = ctx->glyph_cache;

  /* Try to fit in the most-recently-used page of the matching type.  */
  for (int pi = gc->page_count - 1; pi >= 0; pi--)
    {
      glyph_atlas_page_t *p = &gc->pages[pi];
      if (p->is_rgba != is_rgba)
        continue;

      /* Try current shelf.  */
      if (p->cursor_x + required_w <= GLYPH_ATLAS_SIZE
          && p->shelf_y + METAL_MAX (p->shelf_height, required_h)
             <= GLYPH_ATLAS_SIZE)
        {
          if (required_h > p->shelf_height)
            p->shelf_height = required_h;
          *out_x = p->cursor_x;
          *out_y = p->shelf_y;
          p->cursor_x += required_w;
          return pi;
        }

      /* Try starting a new shelf on this page.  */
      int new_shelf_y = p->shelf_y + p->shelf_height;
      if (required_w <= GLYPH_ATLAS_SIZE
          && new_shelf_y + required_h <= GLYPH_ATLAS_SIZE)
        {
          p->shelf_y = new_shelf_y;
          p->shelf_height = required_h;
          p->cursor_x = required_w;
          *out_x = 0;
          *out_y = new_shelf_y;
          return pi;
        }

      /* This page is full — don't search further.  */
      break;
    }

  /* Need a new page.  Evict oldest if at max.  */
  if (gc->page_count >= GLYPH_ATLAS_MAX_PAGES)
    {
      /* Evict page 0 (oldest): shift pages down, invalidate cache entries
         referencing page 0, and adjust page indices for remaining entries.  */
      gc->pages[0].texture = nil;
      for (int i = 1; i < gc->page_count; i++)
        gc->pages[i - 1] = gc->pages[i];
      gc->page_count--;

      /* Invalidate entries on evicted page and adjust page indices.  */
      for (int i = 0; i < GLYPH_CACHE_SIZE; i++)
        {
          if (gc->entries[i].font == NULL)
            continue;
          if (gc->entries[i].atlas_page == 0)
            {
              gc->entries[i].font = NULL;
              gc->entry_count--;
            }
          else
            gc->entries[i].atlas_page--;
        }
    }

  /* Allocate a new atlas page texture.  */
  MTLPixelFormat fmt = is_rgba ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatR8Unorm;
  MTLTextureDescriptor *desc
    = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:fmt
                                     width:GLYPH_ATLAS_SIZE
                                    height:GLYPH_ATLAS_SIZE
                                 mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModeShared;

  id<MTLTexture> texture = [shared_device newTextureWithDescriptor:desc];
  if (!texture)
    {
      NSLog (@"Metal: failed to create glyph atlas page");
      return -1;
    }

  int page_idx = gc->page_count;
  gc->pages[page_idx].texture = texture;
  gc->pages[page_idx].shelf_y = 0;
  gc->pages[page_idx].shelf_height = required_h;
  gc->pages[page_idx].cursor_x = required_w;
  gc->pages[page_idx].is_rgba = is_rgba;
  gc->page_count++;

  *out_x = 0;
  *out_y = 0;
  return page_idx;
}

/* FNV-1a hash for glyph cache lookup.  */
static uint32_t
glyph_cache_hash (CTFontRef font, uint16_t glyph_id, uint8_t subpixel)
{
  uint64_t h = 14695981039346656037ULL;
  h ^= (uintptr_t)font;  h *= 1099511628211ULL;
  h ^= glyph_id;          h *= 1099511628211ULL;
  h ^= subpixel;          h *= 1099511628211ULL;
  return (uint32_t)(h & (GLYPH_CACHE_SIZE - 1));
}

/* Look up a cached glyph entry.  Returns NULL on miss.  */
static glyph_cache_entry_t *
glyph_cache_lookup (emacs_metal_context_t *ctx,
                    CTFontRef font, uint16_t glyph_id, uint8_t subpixel)
{
  struct emacs_metal_glyph_cache *gc = ctx->glyph_cache;
  uint32_t idx = glyph_cache_hash (font, glyph_id, subpixel);

  for (int probe = 0; probe < 16; probe++)
    {
      uint32_t slot = (idx + probe) & (GLYPH_CACHE_SIZE - 1);
      glyph_cache_entry_t *e = &gc->entries[slot];
      if (e->font == NULL)
        return NULL;
      if (e->font == font && e->glyph_id == glyph_id
          && e->subpixel == subpixel)
        return e;
    }

  return NULL;
}

/* Rasterize a glyph via CoreText and upload to the atlas.  Returns the
   new cache entry, or NULL on failure.  */
static glyph_cache_entry_t *
glyph_cache_rasterize (emacs_metal_context_t *ctx,
                       CTFontRef font, uint16_t glyph_id, uint8_t subpixel)
{
  struct emacs_metal_glyph_cache *gc = ctx->glyph_cache;

  /* If the cache is nearly full, clear everything and start fresh.  */
  if (gc->entry_count >= GLYPH_CACHE_SIZE - 64)
    {
      memset (gc->entries, 0, sizeof (gc->entries));
      gc->entry_count = 0;
      /* Reset all atlas pages too.  */
      for (int i = 0; i < gc->page_count; i++)
        gc->pages[i].texture = nil;
      gc->page_count = 0;
    }

  /* Get glyph bounding box (in points, relative to pen position).  */
  CGGlyph cg_glyph = (CGGlyph)glyph_id;
  CGRect bbox;
  CTFontGetBoundingRectsForGlyphs (font, kCTFontOrientationHorizontal,
                                   &cg_glyph, &bbox, 1);

  CGSize advance_size;
  CTFontGetAdvancesForGlyphs (font, kCTFontOrientationHorizontal,
                              &cg_glyph, &advance_size, 1);

  int s = ctx->scale;

  /* Compute the glyph's pixel bounding box (relative to pen position).
     bbox.origin is the offset from pen to the bottom-left of the glyph
     in CG coordinates (y-up).  bbox.origin.y < 0 means descender.  */
  float px_left = floorf (bbox.origin.x * s);
  float px_bottom = floorf (bbox.origin.y * s);
  float px_right = ceilf ((bbox.origin.x + bbox.size.width) * s);
  float px_top = ceilf ((bbox.origin.y + bbox.size.height) * s);

  /* Bitmap dimensions: exact pixel bbox + 2px padding.  */
  int gw = (int)(px_right - px_left) + 2;
  int gh = (int)(px_top - px_bottom) + 2;

  if (gw <= 0) gw = 1;
  if (gh <= 0) gh = 1;
  if (gw > GLYPH_ATLAS_SIZE || gh > GLYPH_ATLAS_SIZE)
    return NULL;

  /* Detect color (emoji) fonts.  */
  CTFontSymbolicTraits traits = CTFontGetSymbolicTraits (font);
  bool is_color = (traits & kCTFontTraitColorGlyphs) != 0;

  /* Allocate space in the atlas.  */
  int atlas_x, atlas_y;
  int page = glyph_cache_get_page (ctx, gw, gh, is_color, &atlas_x, &atlas_y);
  if (page < 0)
    return NULL;

  /* Pen position in bitmap pixel coordinates.
     Place the pen so the glyph's bounding box starts at pixel (1, 1).
     CG origin is bottom-left (y-up).  */
  float pen_px_x = 1.0f - px_left
    + ((float) subpixel / (float) SUBPIXEL_POSITIONS);
  float pen_px_y = 1.0f - px_bottom;

  /* Pen position in points (after CTM scaling by s).  */
  CGFloat pen_pt_x = (CGFloat)pen_px_x / s;
  CGFloat pen_pt_y = (CGFloat)pen_px_y / s;

  uint8_t *pixels;
  CGContextRef cg_ctx;

  if (is_color)
    {
      /* RGBA bitmap for color emoji.  */
      size_t bpr = (size_t)gw * 4;
      pixels = glyph_scratch_pixels (ctx, (size_t)gh * bpr);
      if (!pixels)
        return NULL;

      CGColorSpaceRef cs = CGColorSpaceCreateWithName (kCGColorSpaceSRGB);
      cg_ctx = CGBitmapContextCreate (pixels, gw, gh, 8, bpr, cs,
                                      kCGImageAlphaPremultipliedFirst
                                      | kCGBitmapByteOrder32Host);
      CGColorSpaceRelease (cs);
      if (!cg_ctx)
        return NULL;

      CGContextScaleCTM (cg_ctx, s, s);
      CGPoint draw_point = CGPointMake (pen_pt_x, pen_pt_y);
      CTFontDrawGlyphs (font, &cg_glyph, &draw_point, 1, cg_ctx);
      CGContextRelease (cg_ctx);

      MTLRegion region = MTLRegionMake2D (atlas_x, atlas_y, gw, gh);
      [gc->pages[page].texture replaceRegion:region
                                 mipmapLevel:0
                                   withBytes:pixels
                                 bytesPerRow:(NSUInteger)(gw * 4)];
    }
  else
    {
      /* Alpha-only bitmap for monochrome glyphs.  */
      pixels = glyph_scratch_pixels (ctx, (size_t)gw * (size_t)gh);
      if (!pixels)
        return NULL;

      cg_ctx = CGBitmapContextCreate (pixels, gw, gh, 8, gw,
                                      NULL, (CGBitmapInfo) kCGImageAlphaOnly);
      if (!cg_ctx)
        return NULL;

      CGContextSetGrayFillColor (cg_ctx, 1.0, 1.0);
      CGContextScaleCTM (cg_ctx, s, s);
      CGPoint draw_point = CGPointMake (pen_pt_x, pen_pt_y);
      CTFontDrawGlyphs (font, &cg_glyph, &draw_point, 1, cg_ctx);
      CGContextRelease (cg_ctx);

      MTLRegion region = MTLRegionMake2D (atlas_x, atlas_y, gw, gh);
      [gc->pages[page].texture replaceRegion:region
                                 mipmapLevel:0
                                   withBytes:pixels
                                 bytesPerRow:(NSUInteger)gw];
    }

  /* Insert into the hash table using open addressing.  */
  uint32_t idx = glyph_cache_hash (font, glyph_id, subpixel);
  glyph_cache_entry_t *entry = NULL;
  for (int probe = 0; probe < GLYPH_CACHE_SIZE; probe++)
    {
      uint32_t slot = (idx + probe) & (GLYPH_CACHE_SIZE - 1);
      if (gc->entries[slot].font == NULL)
        {
          entry = &gc->entries[slot];
          break;
        }
    }

  if (!entry)
    return NULL;

  entry->font = font;
  entry->glyph_id = glyph_id;
  entry->subpixel = subpixel;
  entry->atlas_page = (uint16_t)page;
  entry->atlas_x = (uint16_t)atlas_x;
  entry->atlas_y = (uint16_t)atlas_y;
  entry->atlas_w = (uint16_t)gw;
  entry->atlas_h = (uint16_t)gh;
  /* Bearing values in pixels: offset from pen position to quad edges.
     bearing_x = px_left - 1 (left edge of quad relative to pen x)
     bearing_y = px_bottom - 1 (bottom edge relative to pen, CG y-up)
     In Metal (y-down), the quad top edge is:
       baseline_y - (px_top + 1) = baseline_y - (gh + bearing_y)
     because gh = px_top - px_bottom + 2 and bearing_y = px_bottom - 1
     so gh + bearing_y = px_top - px_bottom + 2 + px_bottom - 1 = px_top + 1. */
  entry->bearing_x = px_left - 1.0f;
  entry->bearing_y = px_bottom - 1.0f;
  entry->advance = (float)advance_size.width * s;
  entry->is_color = is_color;
  gc->entry_count++;

  return entry;
}

/* Draw an array of glyphs at given positions with the specified font and
   color.  */
void
emacs_metal_draw_glyphs (emacs_metal_context_t *ctx,
                         const CGGlyph *glyphs,
                         const CGPoint *positions,
                         int count,
                         void *font_ptr,
                         uint32_t color,
                         float origin_x,
                         float baseline_y)
{
  if (!ctx->in_frame || count <= 0)
    return;

  CTFontRef font = (CTFontRef)font_ptr;
  int s = ctx->scale;
  uint32_t c = metal_opaque_if_no_alpha (color);
  float atlas_size_inv = 1.0f / (float)GLYPH_ATLAS_SIZE;

  for (int i = 0; i < count; i++)
    {
      float x_pos = (origin_x + positions[i].x) * s;
      float y_pos = baseline_y * s;

      /* Compute subpixel quantization.  */
      float frac = x_pos - floorf (x_pos);
      uint8_t subpixel
        = (uint8_t)(frac * SUBPIXEL_POSITIONS) % SUBPIXEL_POSITIONS;

      /* Look up or rasterize the glyph.  */
      glyph_cache_entry_t *entry
        = glyph_cache_lookup (ctx, font, glyphs[i], subpixel);
      if (!entry)
        entry = glyph_cache_rasterize (ctx, font, glyphs[i], subpixel);
      if (!entry)
        continue;

      /* Get the atlas page texture for this glyph.  */
      id<MTLTexture> atlas_tex
        = ctx->glyph_cache->pages[entry->atlas_page].texture;
      if (!atlas_tex)
        continue;

      /* Compute quad corners in pixel coordinates.  */
      float gx = floorf (x_pos) + entry->bearing_x;
      float gy = y_pos - (entry->atlas_h + entry->bearing_y);
      float gx1 = gx + entry->atlas_w;
      float gy1 = gy + entry->atlas_h;

      /* Compute UV coordinates in the atlas.  */
      float u0 = (float)entry->atlas_x * atlas_size_inv;
      float v0 = (float)entry->atlas_y * atlas_size_inv;
      float u1 = (float)(entry->atlas_x + entry->atlas_w) * atlas_size_inv;
      float v1 = (float)(entry->atlas_y + entry->atlas_h) * atlas_size_inv;

      /* Emit 6 vertices (two triangles) for the glyph quad.
         texture_id = 1: alpha-tinted (monochrome); 2: direct RGBA (color emoji).  */
      uint32_t tid = entry->is_color ? 2 : 1;
      /* For color emoji, pass white so the fragment shader uses the texture
         color directly (tex * color = tex * 1).  */
      uint32_t vc = entry->is_color ? 0xFFFFFFFFu : c;
      metal_vertex_t *v = emit_vertices (ctx, 6, atlas_tex, true);
      if (!v) return;

      set_vertex (&v[0], gx,  gy,  u0, v0, vc, tid);
      set_vertex (&v[1], gx1, gy,  u1, v0, vc, tid);
      set_vertex (&v[2], gx,  gy1, u0, v1, vc, tid);
      set_vertex (&v[3], gx1, gy,  u1, v0, vc, tid);
      set_vertex (&v[4], gx1, gy1, u1, v1, vc, tid);
      set_vertex (&v[5], gx,  gy1, u0, v1, vc, tid);
    }
}

/* --- Drawing primitives --- */

void
emacs_metal_fill_rect (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h,
                       uint32_t color)
{
  if (!ctx->in_frame || w <= 0 || h <= 0)
    return;

  int s = ctx->scale;
  float x0 = (float)(x * s), y0 = (float)(y * s);
  float x1 = (float)((x + w) * s), y1 = (float)((y + h) * s);
  uint32_t c = metal_opaque_if_no_alpha (color);

  metal_vertex_t *v = emit_vertices (ctx, 6, nil, false);
  if (!v) return;

  set_vertex (&v[0], x0, y0, 0, 0, c, 0);
  set_vertex (&v[1], x1, y0, 0, 0, c, 0);
  set_vertex (&v[2], x0, y1, 0, 0, c, 0);
  set_vertex (&v[3], x1, y0, 0, 0, c, 0);
  set_vertex (&v[4], x1, y1, 0, 0, c, 0);
  set_vertex (&v[5], x0, y1, 0, 0, c, 0);
}

void
emacs_metal_draw_rect (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h,
                       uint32_t color)
{
  if (!ctx->in_frame || w <= 0 || h <= 0)
    return;

  emacs_metal_fill_rect (ctx, x, y, w, 1, color);           /* top    */
  emacs_metal_fill_rect (ctx, x, y + h - 1, w, 1, color);   /* bottom */
  emacs_metal_fill_rect (ctx, x, y, 1, h, color);            /* left   */
  emacs_metal_fill_rect (ctx, x + w - 1, y, 1, h, color);   /* right  */
}

void
emacs_metal_draw_line (emacs_metal_context_t *ctx,
                       int x1, int y1, int x2, int y2,
                       uint32_t color)
{
  if (!ctx->in_frame)
    return;

  int dx = x2 - x1;
  int dy = y2 - y1;

  if (dy == 0)
    {
      /* Horizontal line.  */
      int lx = METAL_MIN (x1, x2);
      int len = dx < 0 ? -dx : dx;
      emacs_metal_fill_rect (ctx, lx, y1, len, 1, color);
    }
  else if (dx == 0)
    {
      /* Vertical line.  */
      int ly = METAL_MIN (y1, y2);
      int len = dy < 0 ? -dy : dy;
      emacs_metal_fill_rect (ctx, x1, ly, 1, len, color);
    }
  else
    {
      /* Diagonal: emit a 1-px-wide quad along the line direction using
         perpendicular normals (half-pixel outset on each side).  */
      int s = ctx->scale;
      float ax = (float)(x1 * s), ay = (float)(y1 * s);
      float bx = (float)(x2 * s), by = (float)(y2 * s);

      float ldx = bx - ax, ldy = by - ay;
      float len = sqrtf (ldx * ldx + ldy * ldy);
      if (len == 0.0f) return;

      /* Unit perpendicular scaled to 0.5 px.  */
      float nx = (-ldy / len) * 0.5f;
      float ny = ( ldx / len) * 0.5f;

      uint32_t c = metal_opaque_if_no_alpha (color);

      metal_vertex_t *v = emit_vertices (ctx, 6, nil, false);
      if (!v) return;

      /* Four corners of the 1-px-wide quad.  */
      float p0x = ax + nx, p0y = ay + ny; /* A left  */
      float p1x = ax - nx, p1y = ay - ny; /* A right */
      float p2x = bx + nx, p2y = by + ny; /* B left  */
      float p3x = bx - nx, p3y = by - ny; /* B right */

      set_vertex (&v[0], p0x, p0y, 0, 0, c, 0);
      set_vertex (&v[1], p2x, p2y, 0, 0, c, 0);
      set_vertex (&v[2], p1x, p1y, 0, 0, c, 0);
      set_vertex (&v[3], p2x, p2y, 0, 0, c, 0);
      set_vertex (&v[4], p3x, p3y, 0, 0, c, 0);
      set_vertex (&v[5], p1x, p1y, 0, 0, c, 0);
    }
}

void
emacs_metal_push_clip (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h)
{
  if (!ctx || ctx->clip_depth >= METAL_MAX_CLIP_STACK)
    return;

  int s = ctx->scale;
  metal_clip_region_t *parent = &ctx->clip_stack[ctx->clip_depth - 1];
  metal_clip_region_t *child = &ctx->clip_stack[ctx->clip_depth];

  /* New rect in physical pixels.  */
  metal_clip_rect_t clip = {
    .x = x * s,
    .y = y * s,
    .w = w * s,
    .h = h * s
  };

  child->count = 0;
  for (int i = 0; i < parent->count; i++)
    {
      metal_clip_rect_t rect = intersect_clip_rects (parent->rects[i], clip);
      if (rect.w > 0 && rect.h > 0)
        child->rects[child->count++] = rect;
    }

  if (child->count == 0)
    child->rects[child->count++] = (metal_clip_rect_t){ .x = 0, .y = 0,
                                                        .w = 0, .h = 0 };
  ctx->clip_depth++;
}

void
emacs_metal_pop_clip (emacs_metal_context_t *ctx)
{
  if (ctx && ctx->clip_depth > 1)
    ctx->clip_depth--;
}

void
emacs_metal_set_clip_rect (emacs_metal_context_t *ctx,
                           int x, int y, int w, int h)
{
  if (!ctx)
    return;

  int s = ctx->scale;
  int nx = x * s;
  int ny = y * s;
  int nw = w * s;
  int nh = h * s;
  int fw = ctx->width * s;
  int fh = ctx->height * s;

  int ix = METAL_MAX (0, nx);
  int iy = METAL_MAX (0, ny);
  int ix2 = METAL_MIN (fw, nx + nw);
  int iy2 = METAL_MIN (fh, ny + nh);

  ctx->clip_depth = 1;
  ctx->clip_stack[0].count = 1;
  ctx->clip_stack[0].rects[0] = (metal_clip_rect_t){
    .x = ix, .y = iy,
    .w = METAL_MAX (0, ix2 - ix),
    .h = METAL_MAX (0, iy2 - iy)
  };
}

void
emacs_metal_set_clip_rects (emacs_metal_context_t *ctx,
                            const CGRect *rects, int count)
{
  if (!ctx)
    return;

  if (!rects || count <= 0)
    {
      emacs_metal_set_clip_rect (ctx, 0, 0, 0, 0);
      return;
    }

  if (count > METAL_MAX_ACTIVE_CLIP_RECTS)
    {
      set_clip_to_cg_rect_union (ctx, rects, count);
      return;
    }

  int s = ctx->scale;
  metal_clip_rect_t frame_clip = {
    .x = 0, .y = 0,
    .w = ctx->width * s,
    .h = ctx->height * s
  };
  metal_clip_region_t *clip = &ctx->clip_stack[0];

  ctx->clip_depth = 1;
  clip->count = 0;

  for (int i = 0; i < count; i++)
    {
      CGRect rect = CGRectStandardize (rects[i]);
      int x = floor (CGRectGetMinX (rect)) * s;
      int y = floor (CGRectGetMinY (rect)) * s;
      int x2 = ceil (CGRectGetMaxX (rect)) * s;
      int y2 = ceil (CGRectGetMaxY (rect)) * s;
      metal_clip_rect_t candidate = {
        .x = x, .y = y,
        .w = METAL_MAX (0, x2 - x),
        .h = METAL_MAX (0, y2 - y)
      };

      candidate = intersect_clip_rects (frame_clip, candidate);
      if (candidate.w > 0 && candidate.h > 0)
        {
          for (int j = 0; j < clip->count; j++)
            {
              metal_clip_rect_t intersection =
                intersect_clip_rects (clip->rects[j], candidate);
              if (intersection.w > 0 && intersection.h > 0)
                {
                  set_clip_to_cg_rect_union (ctx, rects, count);
                  return;
                }
            }

          clip->rects[clip->count++] = candidate;
        }
    }

  if (clip->count == 0)
    clip->rects[clip->count++] = (metal_clip_rect_t){ .x = 0, .y = 0,
                                                      .w = 0, .h = 0 };
}

void
emacs_metal_reset_clip (emacs_metal_context_t *ctx)
{
  if (!ctx)
    return;

  ctx->clip_depth = 1;
  ctx->clip_stack[0].count = 1;
  ctx->clip_stack[0].rects[0] = (metal_clip_rect_t){
    .x = 0, .y = 0,
    .w = ctx->width * ctx->scale,
    .h = ctx->height * ctx->scale
  };
}

void
emacs_metal_scroll (emacs_metal_context_t *ctx,
                    int x, int y, int w, int h,
                    int dx, int dy)
{
  if (!ctx->in_frame || (dx == 0 && dy == 0))
    return;

  int s = ctx->scale;
  int sx = x * s, sy = y * s, sw = w * s, sh = h * s;
  int sdx = dx * s, sdy = dy * s;

  /* Flush pending draws before blit.  */
  id<MTLCommandBuffer> cmd = ctx->frame_command_buffer;
  if (!cmd)
    return;
  flush_render_batches (ctx, cmd);

  /* Ensure staging texture is large enough.  */
  if (!ctx->scroll_staging
      || ctx->scroll_staging_w < sw
      || ctx->scroll_staging_h < sh)
    {
      MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ctx->backbuffer.pixelFormat
                                                          width:sw height:sh
                                                      mipmapped:NO];
      desc.storageMode = MTLStorageModePrivate;
      desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
      ctx->scroll_staging = [shared_device newTextureWithDescriptor:desc];
      ctx->scroll_staging_w = sw;
      ctx->scroll_staging_h = sh;
    }

  id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
  /* Copy source region to staging.  */
  [blit copyFromTexture:ctx->backbuffer
            sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake (sx, sy, 0)
             sourceSize:MTLSizeMake (sw, sh, 1)
              toTexture:ctx->scroll_staging
       destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake (0, 0, 0)];
  /* Copy staging to destination.  */
  [blit copyFromTexture:ctx->scroll_staging
            sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake (0, 0, 0)
             sourceSize:MTLSizeMake (sw, sh, 1)
              toTexture:ctx->backbuffer
       destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake (sx + sdx, sy + sdy, 0)];
  [blit endEncoding];
}

/* --- Image texture upload and drawing --- */

void *
emacs_metal_upload_cg_image (emacs_metal_context_t *ctx,
                             void *cg_image_ptr,
                             int width, int height,
                             void *fill_color)
{
  CGImageRef cg_image = (CGImageRef)cg_image_ptr;
  if (!cg_image || width <= 0 || height <= 0)
    return NULL;

  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                      width:width
                                                     height:height
                                                  mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModeShared;

  id<MTLTexture> texture = [shared_device newTextureWithDescriptor:desc];
  if (!texture)
    return NULL;

  size_t bpr = width * 4;
  uint8_t *pixels = calloc (height, bpr);
  if (!pixels)
    return NULL;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName (kCGColorSpaceSRGB);
  CGContextRef cg = CGBitmapContextCreate (pixels, width, height, 8, bpr, cs,
                                           kCGImageAlphaPremultipliedFirst
                                           | kCGBitmapByteOrder32Host);
  CGColorSpaceRelease (cs);
  if (cg)
    {
      /* For image masks (e.g. fringe bitmaps), the fill color determines
         what color masked pixels take.  Set it before drawing so the
         foreground color is applied, matching the CoreGraphics path.  */
      if (fill_color)
        CGContextSetFillColorWithColor (cg, (CGColorRef)fill_color);
      CGContextDrawImage (cg, CGRectMake (0, 0, width, height), cg_image);
      CGContextRelease (cg);
    }

  [texture replaceRegion:MTLRegionMake2D (0, 0, width, height)
             mipmapLevel:0
               withBytes:pixels
             bytesPerRow:bpr];
  free (pixels);

  return (__bridge_retained void *)texture;
}

void *
emacs_metal_get_cached_cg_image (emacs_metal_context_t *ctx,
                                 void *cg_image_ptr,
                                 int width, int height,
                                 void *fill_color_ptr)
{
  CGImageRef cg_image = (CGImageRef)cg_image_ptr;
  CGColorRef fill_color = (CGColorRef)fill_color_ptr;
  if (!ctx || !cg_image || width <= 0 || height <= 0)
    return NULL;

  uint64_t now = ++ctx->image_cache_clock;
  metal_image_cache_entry_t *victim = NULL;

  for (int i = 0; i < METAL_IMAGE_CACHE_SIZE; i++)
    {
      metal_image_cache_entry_t *entry = &ctx->image_cache[i];

      if (entry->image == cg_image
          && entry->width == width
          && entry->height == height
          && cg_color_key_equal (entry->fill_color, fill_color))
        {
          entry->last_used = now;
          return (__bridge void *)entry->texture;
        }

      if (!entry->image)
        victim = entry;
      else if (!victim || entry->last_used < victim->last_used)
        victim = entry;
    }

  void *texture_ptr = emacs_metal_upload_cg_image (ctx, cg_image_ptr,
                                                   width, height,
                                                   fill_color_ptr);
  if (!texture_ptr)
    return NULL;

  clear_image_cache_entry (victim);
  victim->image = CGImageRetain (cg_image);
  if (fill_color)
    victim->fill_color = CGColorRetain (fill_color);
  victim->width = width;
  victim->height = height;
  victim->texture = (__bridge_transfer id<MTLTexture>)texture_ptr;
  victim->last_used = now;

  return (__bridge void *)victim->texture;
}

void
emacs_metal_draw_image_texture (emacs_metal_context_t *ctx,
                                void *texture_ptr,
                                int src_x, int src_y, int src_w, int src_h,
                                int dst_x, int dst_y, int dst_w, int dst_h)
{
  if (!ctx->in_frame || !texture_ptr)
    return;

  id<MTLTexture> texture = (__bridge id<MTLTexture>)texture_ptr;
  int s = ctx->scale;
  float x0 = dst_x * s, y0 = dst_y * s;
  float x1 = (dst_x + dst_w) * s, y1 = (dst_y + dst_h) * s;

  int tw = (int)texture.width, th = (int)texture.height;
  float u0 = (float)src_x / tw, v0 = (float)src_y / th;
  float u1 = (float)(src_x + src_w) / tw, v1 = (float)(src_y + src_h) / th;

  uint32_t white = 0xFFFFFFFF;
  metal_vertex_t *v = emit_vertices (ctx, 6, texture, false);
  if (!v) return;

  set_vertex (&v[0], x0, y0, u0, v0, white, 2);
  set_vertex (&v[1], x1, y0, u1, v0, white, 2);
  set_vertex (&v[2], x0, y1, u0, v1, white, 2);
  set_vertex (&v[3], x1, y0, u1, v0, white, 2);
  set_vertex (&v[4], x1, y1, u1, v1, white, 2);
  set_vertex (&v[5], x0, y1, u0, v1, white, 2);
}

void
emacs_metal_destroy_texture (void *texture_ptr)
{
  if (texture_ptr)
    {
      /* Transfer ownership to ARC so it releases the texture.  */
      (void)(__bridge_transfer id<MTLTexture>)texture_ptr;
    }
}

#endif /* USE_METAL_RENDERING */

#include <config.h>

#ifdef USE_METAL_RENDERING

#include "macmetal.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

/* Shared Metal state, initialized once on first context creation.  */
static id<MTLDevice> shared_device;
static id<MTLLibrary> shared_library;
static id<MTLRenderPipelineState> shared_solid_pipeline;
static id<MTLRenderPipelineState> shared_textured_pipeline;

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

#define METAL_MAX_VERTICES (65536)
#define METAL_MAX_CLIP_STACK (32)
#define METAL_VERTEX_BUFFER_COUNT (2)
#define METAL_MAX_BATCHES (4096)

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
    int vertex_offset;
    int vertex_count;
    metal_clip_rect_t scissor;
    id<MTLTexture> texture;
    bool is_glyph;
} metal_batch_t;

struct emacs_metal_context
{
  id<MTLCommandQueue> command_queue;
  CAMetalLayer *layer;
  id<MTLTexture> backbuffer;

  id<MTLBuffer> vertex_buffers[METAL_VERTEX_BUFFER_COUNT];
  int current_buffer;
  metal_vertex_t *vertices;
  int vertex_count;

  metal_batch_t batches[METAL_MAX_BATCHES];
  int batch_count;
  id<MTLTexture> current_texture;
  bool current_is_glyph;

  metal_clip_rect_t clip_stack[METAL_MAX_CLIP_STACK];
  int clip_depth;

  int width, height, scale;
  bool in_frame;

  dispatch_semaphore_t buffer_semaphore;
};

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

  /* Solid pipeline — no blending.  */
  {
    MTLRenderPipelineDescriptor *desc
      = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertex_fn;
    desc.fragmentFunction = fragment_solid_fn;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    desc.colorAttachments[0].blendingEnabled = NO;

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

  return ctx;
}

void
emacs_metal_context_resize (emacs_metal_context_t *ctx, int width, int height)
{
  if (ctx->width == width && ctx->height == height)
    return;

  id<MTLTexture> old_backbuffer = ctx->backbuffer;
  int old_width = ctx->width * ctx->scale;
  int old_height = ctx->height * ctx->scale;

  ctx->width = width;
  ctx->height = height;

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
  ctx->command_queue = nil;
  ctx->layer = nil;

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
  ctx->current_texture = nil;
  ctx->current_is_glyph = false;

  /* Default clip to full frame in pixels.  */
  ctx->clip_depth = 1;
  ctx->clip_stack[0] = (metal_clip_rect_t){
    .x = 0, .y = 0,
    .w = ctx->width * ctx->scale,
    .h = ctx->height * ctx->scale
  };

  ctx->in_frame = true;
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
      return;
    }

  id<MTLCommandBuffer> cmd = [ctx->command_queue commandBuffer];

  /* Render all batches into the backbuffer.  */
  if (ctx->batch_count > 0)
    {
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

      for (int i = 0; i < ctx->batch_count; i++)
        {
          metal_batch_t *batch = &ctx->batches[i];

          /* Set scissor rect.  */
          MTLScissorRect scissor = {
            .x = (NSUInteger)batch->scissor.x,
            .y = (NSUInteger)batch->scissor.y,
            .width = (NSUInteger)batch->scissor.w,
            .height = (NSUInteger)batch->scissor.h
          };
          [encoder setScissorRect:scissor];

          /* Select pipeline state.  */
          if (batch->texture)
            [encoder setRenderPipelineState:shared_textured_pipeline];
          else
            [encoder setRenderPipelineState:shared_solid_pipeline];

          /* Set vertex buffer and uniforms.  */
          [encoder setVertexBuffer:ctx->vertex_buffers[ctx->current_buffer]
                            offset:0
                           atIndex:0];
          [encoder setVertexBytes:viewport_size
                           length:sizeof (viewport_size)
                          atIndex:1];

          /* Set texture if needed.  */
          if (batch->texture)
            [encoder setFragmentTexture:batch->texture atIndex:0];

          [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:(NSUInteger)batch->vertex_offset
                      vertexCount:(NSUInteger)batch->vertex_count];
        }

      [encoder endEncoding];
    }

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
}

/* Drawing stubs — to be implemented in Task 3.  */

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

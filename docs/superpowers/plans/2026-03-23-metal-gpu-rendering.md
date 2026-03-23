# Metal GPU Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Core Graphics CPU rendering with a full Metal GPU pipeline for the Emacs Mac port.

**Architecture:** A new Objective-C module (`macmetal.m/.h`) exposes a C API for Metal rendering. All drawing in `macterm.c` and `macfont.m` is redirected through this API. A glyph atlas caches rasterized glyphs as GPU textures. Drawing is batched into vertex buffers and flushed once per frame via `CAMetalLayer`.

**Tech Stack:** Metal, MetalKit, Core Text (shaping only), Objective-C, C

**Spec:** `docs/superpowers/specs/2026-03-23-metal-gpu-rendering-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `src/macmetal.h` | C API header — opaque types, all public functions |
| `src/macmetal.m` | Metal renderer — context lifecycle, glyph atlas, vertex batching, shaders, presentation |

### Modified Files
| File | Changes |
|------|---------|
| `configure.ac` | `--with-metal-rendering` flag, `USE_METAL_RENDERING` define, Metal framework linking |
| `src/Makefile.in` | Add `macmetal.o` to build, Objective-C compilation rule |
| `src/macterm.h` | Add `metal_ctx` to `mac_output` (line ~302), add `FRAME_METAL_CTX` macro |
| `src/macterm.c` | Wrap all drawing primitives (lines 260-384) and glyph string functions (lines 1234-2580) with `#ifdef USE_METAL_RENDERING`, redirect to `emacs_metal_*` calls |
| `src/macfont.m` | Wrap `macfont_draw` (line 2881) to call `emacs_metal_draw_glyphs` under Metal |
| `src/macappkit.h` | Conditional `EmacsBacking` interface removal, `CAMetalLayer` on `EmacsView` |
| `src/macappkit.m` | Replace `EmacsBacking` with Metal presentation, `EmacsView` layer setup, scroll via Metal blit, remove GCD drawing queue under Metal |
| `src/dispextern.h` | Add `metal_texture` field to `struct image` (near line 3287) |
| `src/image.c` | Upload images as `MTLTexture`, cache on image struct |

---

## Task 1: Build System — Configure Flag and Makefile

**Files:**
- Modify: `configure.ac:7594-7602`
- Modify: `src/Makefile.in:327,465,719`

This task adds the `--with-metal-rendering` configure option and the build rules for `macmetal.o`. No rendering code yet — just infrastructure.

- [ ] **Step 1: Add configure option**

In `configure.ac`, after the existing `--with-mac-metal` block (line ~7594), add:

```m4
AC_ARG_WITH([metal-rendering],
  [AS_HELP_STRING([--with-metal-rendering],
    [use Metal for all rendering (macOS 14+)])])

if test "$with_metal_rendering" = yes; then
  if test "$opsys" != darwin; then
    AC_MSG_ERROR([--with-metal-rendering requires macOS])
  fi
  AC_CHECK_HEADER([Metal/Metal.h], [],
    [AC_MSG_ERROR([Metal/Metal.h not found])])
  AC_DEFINE(USE_METAL_RENDERING, 1,
    [Define to 1 if using Metal for all rendering.])
  LIBS_METAL="-framework Metal -framework MetalKit -framework QuartzCore"
  LIBS="$LIBS $LIBS_METAL"
fi
```

- [ ] **Step 2: Add macmetal.o to Makefile.in**

In `src/Makefile.in`, add `macmetal.o` to the mac object list (near line 327 where `MAC_OBJC_OBJ` is defined or where mac objects are listed). Ensure the `.m.o` suffix rule (line ~465) covers it.

- [ ] **Step 3: Create stub macmetal.h and macmetal.m**

Create `src/macmetal.h`:
```c
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
```

Create `src/macmetal.m`:
```objc
#include <config.h>

#ifdef USE_METAL_RENDERING

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

/* Shared Metal state — initialized once, shared across all frames. */
static id<MTLDevice> shared_device;
static id<MTLLibrary> shared_library;
static id<MTLRenderPipelineState> shared_solid_pipeline;
static id<MTLRenderPipelineState> shared_textured_pipeline;

struct emacs_metal_context
{
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
  /* One-time shared initialization */
  if (!shared_device)
    {
      shared_device = MTLCreateSystemDefaultDevice ();
      if (!shared_device)
        {
          NSLog (@"Metal GPU not available. Build without "
                 "--with-metal-rendering to use Core Graphics.");
          return NULL;
        }
      if (!create_pipelines ())  /* sets shared_library, shared_*_pipeline */
        return NULL;
    }

  emacs_metal_context_t *ctx = calloc (1, sizeof *ctx);
  if (!ctx)
    return NULL;

  ctx->command_queue = [shared_device newCommandQueue];
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
```

- [ ] **Step 4: Verify it builds**

Run:
```bash
cd /Users/janne/Projects/emacs-mac/.claude/worktrees/metal-gpu
./autogen.sh
./configure --with-metal-rendering --with-native-compilation --enable-mac-app=yes --enable-mac-self-contained 'CFLAGS=-O2 -mcpu=native -fobjc-arc'
make -j$(sysctl -n hw.ncpu) 2>&1 | tail -20
```

Expected: Build succeeds. `macmetal.o` compiled. Binary launches (Metal code is all stubs).

- [ ] **Step 5: Commit**

```bash
git add configure.ac src/Makefile.in src/macmetal.h src/macmetal.m
git commit -m "Add --with-metal-rendering build infrastructure with stub module"
```

---

## Task 2: Metal Context — Shaders, Pipeline State, Backbuffer

**Files:**
- Modify: `src/macmetal.m`
- Modify: `src/macmetal.h`

This task implements the core Metal setup: shader compilation, render pipeline state objects, retained backbuffer texture, and the frame begin/end lifecycle. After this, the context is ready to accept draw calls.

- [ ] **Step 1: Add MSL shader source**

In `macmetal.m`, add the embedded shader source as a string constant:

```objc
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
```

The vertex shader converts pixel coordinates to normalized device coordinates. `fragment_solid` handles rectangles/lines. `fragment_textured` handles glyphs (alpha-tinted from atlas, texture_id==1) and images (direct RGBA, texture_id>=2).

- [ ] **Step 2: Add vertex struct and batch state to context**

Update `emacs_metal_context` in `macmetal.m`:

```objc
#define METAL_MAX_VERTICES (65536)
#define METAL_MAX_CLIP_STACK (32)
#define METAL_VERTEX_BUFFER_COUNT (2)

typedef struct {
    float position[2];
    float texcoord[2];
    uint8_t color[4];
    uint32_t texture_id;
} metal_vertex_t;

typedef struct {
    int x, y, w, h;
} metal_clip_rect_t;

/* Draw batch — one per texture/clip change */
typedef struct {
    int vertex_offset;
    int vertex_count;
    metal_clip_rect_t scissor;
    id<MTLTexture> texture;     /* nil for solid */
    bool is_glyph;              /* true = alpha-tinted glyph atlas */
} metal_batch_t;

#define METAL_MAX_BATCHES (4096)

struct emacs_metal_context
{
  /* Per-context state (device, library, pipelines are shared statics) */
  id<MTLCommandQueue> command_queue;

  /* Presentation */
  CAMetalLayer *layer;
  id<MTLTexture> backbuffer;

  /* Vertex batching */
  id<MTLBuffer> vertex_buffers[METAL_VERTEX_BUFFER_COUNT];
  int current_buffer;
  metal_vertex_t *vertices;     /* mapped pointer to current buffer */
  int vertex_count;

  /* Batch tracking */
  metal_batch_t batches[METAL_MAX_BATCHES];
  int batch_count;
  id<MTLTexture> current_texture;
  bool current_is_glyph;

  /* Clip stack */
  metal_clip_rect_t clip_stack[METAL_MAX_CLIP_STACK];
  int clip_depth;

  /* Frame state */
  int width, height, scale;
  bool in_frame;

  /* Synchronization */
  dispatch_semaphore_t buffer_semaphore;
};
```

- [ ] **Step 3: Implement shader compilation and pipeline creation**

Add a helper function that populates the shared statics (called once from first `context_create`):

```objc
static bool
create_pipelines (void)
{
  NSError *error = nil;
  shared_library = [shared_device newLibraryWithSource:metal_shader_source
                                               options:nil
                                                 error:&error];
  if (!shared_library)
    {
      NSLog (@"Metal shader compilation failed: %@", error);
      return false;
    }

  id<MTLFunction> vertex_fn = [shared_library newFunctionWithName:@"vertex_main"];
  id<MTLFunction> frag_solid = [shared_library newFunctionWithName:@"fragment_solid"];
  id<MTLFunction> frag_textured = [shared_library newFunctionWithName:@"fragment_textured"];

  MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = vertex_fn;
  desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;

  /* Solid pipeline — no blending */
  desc.fragmentFunction = frag_solid;
  desc.colorAttachments[0].blendingEnabled = NO;
  shared_solid_pipeline = [shared_device newRenderPipelineStateWithDescriptor:desc
                                                                       error:&error];
  if (!shared_solid_pipeline)
    {
      NSLog (@"Solid pipeline creation failed: %@", error);
      return false;
    }

  /* Textured pipeline — alpha blending for glyph rendering */
  desc.fragmentFunction = frag_textured;
  desc.colorAttachments[0].blendingEnabled = YES;
  desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  shared_textured_pipeline = [shared_device newRenderPipelineStateWithDescriptor:desc
                                                                          error:&error];
  if (!shared_textured_pipeline)
    {
      NSLog (@"Textured pipeline creation failed: %@", error);
      return false;
    }

  return true;
}
```

- [ ] **Step 4: Implement backbuffer and vertex buffer allocation**

```objc
static bool
create_backbuffer (emacs_metal_context_t *ctx)
{
  int pw = ctx->width * ctx->scale;
  int ph = ctx->height * ctx->scale;

  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                      width:pw
                                                     height:ph
                                                  mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModePrivate;

  ctx->backbuffer = [ctx->device newTextureWithDescriptor:desc];
  return ctx->backbuffer != nil;
}

static bool
create_vertex_buffers (emacs_metal_context_t *ctx)
{
  NSUInteger size = METAL_MAX_VERTICES * sizeof (metal_vertex_t);
  for (int i = 0; i < METAL_VERTEX_BUFFER_COUNT; i++)
    {
      ctx->vertex_buffers[i] =
        [ctx->device newBufferWithLength:size
                                 options:MTLResourceStorageModeShared];
      if (!ctx->vertex_buffers[i])
        return false;
    }
  ctx->buffer_semaphore = dispatch_semaphore_create (METAL_VERTEX_BUFFER_COUNT);
  return true;
}
```

Update `emacs_metal_context_create` to call these, and add `emacs_metal_context_resize` to reallocate the backbuffer (with old-content blit).

After creating the backbuffer, clear it to avoid garbage on first frame:

```objc
id<MTLCommandBuffer> cmd = [ctx->command_queue commandBuffer];
MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
pass.colorAttachments[0].texture = ctx->backbuffer;
pass.colorAttachments[0].loadAction = MTLLoadActionClear;
pass.colorAttachments[0].clearColor = MTLClearColorMake (1, 1, 1, 1);
pass.colorAttachments[0].storeAction = MTLStoreActionStore;
id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
[enc endEncoding];
[cmd commit];
[cmd waitUntilCompleted];
```

Also in `emacs_metal_context_resize`, blit old backbuffer content to the new one before releasing the old texture.

- [ ] **Step 5: Implement frame_begin and frame_end**

```objc
void
emacs_metal_frame_begin (emacs_metal_context_t *ctx)
{
  if (ctx->in_frame)
    return;

  dispatch_semaphore_wait (ctx->buffer_semaphore, DISPATCH_TIME_FOREVER);

  ctx->current_buffer = (ctx->current_buffer + 1) % METAL_VERTEX_BUFFER_COUNT;
  ctx->vertices = [ctx->vertex_buffers[ctx->current_buffer] contents];
  ctx->vertex_count = 0;
  ctx->batch_count = 0;
  ctx->current_texture = nil;
  ctx->current_is_glyph = false;
  ctx->clip_depth = 0;

  /* Default clip = full frame */
  ctx->clip_stack[0] = (metal_clip_rect_t){0, 0,
                                            ctx->width * ctx->scale,
                                            ctx->height * ctx->scale};
  ctx->clip_depth = 1;

  ctx->in_frame = true;
}

void
emacs_metal_frame_end (emacs_metal_context_t *ctx)
{
  if (!ctx->in_frame)
    return;

  id<CAMetalDrawable> drawable = [ctx->layer nextDrawable];
  if (!drawable)
    {
      ctx->in_frame = false;
      dispatch_semaphore_signal (ctx->buffer_semaphore);
      return;
    }

  id<MTLCommandBuffer> cmd = [ctx->command_queue commandBuffer];

  /* 1. Render batched draws into backbuffer */
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
  pass.colorAttachments[0].texture = ctx->backbuffer;
  pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc =
    [cmd renderCommandEncoderWithDescriptor:pass];

  float viewport_size[2] = {(float)(ctx->width * ctx->scale),
                             (float)(ctx->height * ctx->scale)};

  for (int i = 0; i < ctx->batch_count; i++)
    {
      metal_batch_t *b = &ctx->batches[i];

      MTLScissorRect scissor = {
        .x = (NSUInteger)b->scissor.x,
        .y = (NSUInteger)b->scissor.y,
        .width = (NSUInteger)b->scissor.w,
        .height = (NSUInteger)b->scissor.h
      };
      [enc setScissorRect:scissor];

      if (b->texture)
        {
          [enc setRenderPipelineState:shared_textured_pipeline];
          [enc setFragmentTexture:b->texture atIndex:0];
        }
      else
        {
          [enc setRenderPipelineState:shared_solid_pipeline];
        }

      [enc setVertexBuffer:ctx->vertex_buffers[ctx->current_buffer]
                    offset:b->vertex_offset * sizeof (metal_vertex_t)
                   atIndex:0];
      [enc setVertexBytes:viewport_size length:sizeof (viewport_size)
                  atIndex:1];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:b->vertex_count];
    }

  [enc endEncoding];

  /* 2. Blit backbuffer to drawable (long-form to handle size mismatch during resize) */
  id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
  NSUInteger copy_w = MIN (ctx->backbuffer.width, drawable.texture.width);
  NSUInteger copy_h = MIN (ctx->backbuffer.height, drawable.texture.height);
  [blit copyFromTexture:ctx->backbuffer
            sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake (0, 0, 0)
             sourceSize:MTLSizeMake (copy_w, copy_h, 1)
              toTexture:drawable.texture
       destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake (0, 0, 0)];
  [blit endEncoding];

  /* 3. Present and signal semaphore */
  [cmd presentDrawable:drawable];

  dispatch_semaphore_t sema = ctx->buffer_semaphore;
  [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
    dispatch_semaphore_signal (sema);
  }];

  [cmd commit];
  ctx->in_frame = false;
}
```

- [ ] **Step 6: Verify it builds and the Metal context initializes**

Rebuild with `--with-metal-rendering`. The context is not yet wired to anything visible, but there should be no build errors and no Metal validation errors on startup. You can add a temporary `NSLog` in `emacs_metal_context_create` to confirm it runs.

- [ ] **Step 7: Commit**

```bash
git add src/macmetal.h src/macmetal.m
git commit -m "Implement Metal context: shaders, pipeline state, backbuffer, frame lifecycle"
```

---

## Task 3: Vertex Batching — Fill Rect, Draw Rect, Draw Line, Clip

**Files:**
- Modify: `src/macmetal.m`

This task implements the drawing primitives and clip stack. After this, the renderer can draw solid rectangles, outlines, and lines into batches.

- [ ] **Step 1: Implement batch management helpers**

```objc
static metal_batch_t *
ensure_batch (emacs_metal_context_t *ctx, id<MTLTexture> texture, bool is_glyph)
{
  /* Reuse current batch if texture and clip match */
  if (ctx->batch_count > 0)
    {
      metal_batch_t *b = &ctx->batches[ctx->batch_count - 1];
      metal_clip_rect_t clip = ctx->clip_stack[ctx->clip_depth - 1];
      if (b->texture == texture
          && b->is_glyph == is_glyph
          && b->scissor.x == clip.x && b->scissor.y == clip.y
          && b->scissor.w == clip.w && b->scissor.h == clip.h)
        return b;
    }

  /* Start new batch */
  if (ctx->batch_count >= METAL_MAX_BATCHES)
    return NULL;

  metal_batch_t *b = &ctx->batches[ctx->batch_count++];
  b->vertex_offset = ctx->vertex_count;
  b->vertex_count = 0;
  b->texture = texture;
  b->is_glyph = is_glyph;
  b->scissor = ctx->clip_stack[ctx->clip_depth - 1];
  return b;
}

static metal_vertex_t *
emit_vertices (emacs_metal_context_t *ctx, int count, id<MTLTexture> texture,
               bool is_glyph)
{
  if (ctx->vertex_count + count > METAL_MAX_VERTICES)
    return NULL;

  metal_batch_t *b = ensure_batch (ctx, texture, is_glyph);
  if (!b)
    return NULL;

  metal_vertex_t *v = &ctx->vertices[ctx->vertex_count];
  ctx->vertex_count += count;
  b->vertex_count += count;
  return v;
}

static void
set_vertex (metal_vertex_t *v, float x, float y, float u, float v_coord,
            uint32_t color, uint32_t texture_id)
{
  v->position[0] = x;
  v->position[1] = y;
  v->texcoord[0] = u;
  v->texcoord[1] = v_coord;
  v->color[0] = (color >> 16) & 0xFF;  /* R */
  v->color[1] = (color >> 8) & 0xFF;   /* G */
  v->color[2] = color & 0xFF;          /* B */
  v->color[3] = (color >> 24) & 0xFF;  /* A, default 0xFF */
  v->texture_id = texture_id;
}
```

- [ ] **Step 2: Implement fill_rect**

```objc
void
emacs_metal_fill_rect (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h,
                       uint32_t color)
{
  if (!ctx->in_frame || w <= 0 || h <= 0)
    return;

  int s = ctx->scale;
  float x0 = x * s, y0 = y * s;
  float x1 = (x + w) * s, y1 = (y + h) * s;
  /* Emacs Mac port colors are 0x00RRGGBB — force alpha to 0xFF */
  uint32_t c = color | 0xFF000000;

  metal_vertex_t *v = emit_vertices (ctx, 6, nil, false);
  if (!v)
    return;

  /* Two triangles forming a quad */
  set_vertex (&v[0], x0, y0, 0, 0, c, 0);
  set_vertex (&v[1], x1, y0, 0, 0, c, 0);
  set_vertex (&v[2], x0, y1, 0, 0, c, 0);
  set_vertex (&v[3], x1, y0, 0, 0, c, 0);
  set_vertex (&v[4], x1, y1, 0, 0, c, 0);
  set_vertex (&v[5], x0, y1, 0, 0, c, 0);
}
```

- [ ] **Step 3: Implement draw_rect (outline)**

```objc
void
emacs_metal_draw_rect (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h,
                       uint32_t color)
{
  /* Draw as 4 thin filled rects (1px lines) */
  int s = ctx->scale;
  emacs_metal_fill_rect (ctx, x, y, w, 1);       /* top */
  emacs_metal_fill_rect (ctx, x, y + h - 1, w, 1); /* bottom */
  emacs_metal_fill_rect (ctx, x, y, 1, h);       /* left */
  emacs_metal_fill_rect (ctx, x + w - 1, y, 1, h); /* right */
}
```

Wait — `draw_rect` needs a color parameter. Fix the calls to pass `color` through. Actually, `draw_rect` already takes `color`, and `fill_rect` is the implementation. Let me correct:

```objc
void
emacs_metal_draw_rect (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h,
                       uint32_t color)
{
  emacs_metal_fill_rect (ctx, x, y, w, 1, color);
  emacs_metal_fill_rect (ctx, x, y + h - 1, w, 1, color);
  emacs_metal_fill_rect (ctx, x, y, 1, h, color);
  emacs_metal_fill_rect (ctx, x + w - 1, y, 1, h, color);
}
```

- [ ] **Step 4: Implement draw_line**

```objc
void
emacs_metal_draw_line (emacs_metal_context_t *ctx,
                       int x1, int y1, int x2, int y2,
                       uint32_t color)
{
  /* Horizontal or vertical lines as thin rects */
  if (y1 == y2)
    emacs_metal_fill_rect (ctx, x1, y1, x2 - x1, 1, color);
  else if (x1 == x2)
    emacs_metal_fill_rect (ctx, x1, y1, 1, y2 - y1, color);
  else
    {
      /* Diagonal — emit as a 1px-wide quad along the line.
         Rare in Emacs; simple approximation is fine. */
      int s = ctx->scale;
      float fx1 = x1 * s, fy1 = y1 * s, fx2 = x2 * s, fy2 = y2 * s;
      uint32_t c = color | 0xFF000000;
      float dx = fx2 - fx1, dy = fy2 - fy1;
      float len = sqrtf (dx * dx + dy * dy);
      float nx = -dy / len * 0.5f, ny = dx / len * 0.5f;

      metal_vertex_t *v = emit_vertices (ctx, 6, nil, false);
      if (!v) return;
      set_vertex (&v[0], fx1 + nx, fy1 + ny, 0, 0, c, 0);
      set_vertex (&v[1], fx1 - nx, fy1 - ny, 0, 0, c, 0);
      set_vertex (&v[2], fx2 + nx, fy2 + ny, 0, 0, c, 0);
      set_vertex (&v[3], fx1 - nx, fy1 - ny, 0, 0, c, 0);
      set_vertex (&v[4], fx2 - nx, fy2 - ny, 0, 0, c, 0);
      set_vertex (&v[5], fx2 + nx, fy2 + ny, 0, 0, c, 0);
    }
}
```

- [ ] **Step 5: Implement clip stack**

```objc
void
emacs_metal_push_clip (emacs_metal_context_t *ctx,
                       int x, int y, int w, int h)
{
  if (ctx->clip_depth >= METAL_MAX_CLIP_STACK)
    return;

  int s = ctx->scale;
  metal_clip_rect_t parent = ctx->clip_stack[ctx->clip_depth - 1];

  /* Intersect with parent clip */
  int cx = MAX (x * s, parent.x);
  int cy = MAX (y * s, parent.y);
  int cx2 = MIN ((x + w) * s, parent.x + parent.w);
  int cy2 = MIN ((y + h) * s, parent.y + parent.h);

  ctx->clip_stack[ctx->clip_depth++] = (metal_clip_rect_t){
    cx, cy, MAX (0, cx2 - cx), MAX (0, cy2 - cy)
  };
}

void
emacs_metal_pop_clip (emacs_metal_context_t *ctx)
{
  if (ctx->clip_depth > 1)
    ctx->clip_depth--;
}
```

- [ ] **Step 6: Verify build**

Rebuild. All primitives compile but aren't wired to macterm.c yet.

- [ ] **Step 7: Commit**

```bash
git add src/macmetal.m
git commit -m "Implement Metal vertex batching, fill_rect, draw_rect, draw_line, clip stack"
```

---

## Task 4: Glyph Atlas — Rasterization and Caching

**Files:**
- Modify: `src/macmetal.h`
- Modify: `src/macmetal.m`

This task implements the glyph atlas: shelf-packed texture, Core Text rasterization on cache miss, and the `emacs_metal_draw_glyphs` function.

- [ ] **Step 1: Add glyph atlas data structures**

In `macmetal.m`:

```objc
#import <CoreText/CoreText.h>

#define GLYPH_ATLAS_SIZE (2048)
#define GLYPH_ATLAS_MAX_PAGES (8)
#define GLYPH_CACHE_SIZE (16384)
#define SUBPIXEL_POSITIONS (4)

typedef struct {
    CTFontRef font;
    uint16_t glyph_id;
    uint8_t subpixel;        /* 0-3: quarter-pixel x offset */
    /* Atlas location */
    uint16_t atlas_page;
    uint16_t atlas_x, atlas_y;
    uint16_t atlas_w, atlas_h;
    /* Metrics (in pixels at scale) */
    float bearing_x, bearing_y;
    float advance;
} glyph_cache_entry_t;

typedef struct {
    id<MTLTexture> texture;
    int shelf_y;             /* current shelf top */
    int shelf_height;        /* current shelf row height */
    int cursor_x;            /* next glyph x position in shelf */
} glyph_atlas_page_t;

struct emacs_metal_glyph_cache {
    glyph_atlas_page_t pages[GLYPH_ATLAS_MAX_PAGES];
    int page_count;
    glyph_cache_entry_t entries[GLYPH_CACHE_SIZE];
    int entry_count;
};
```

Add `struct emacs_metal_glyph_cache *glyph_cache` to `emacs_metal_context`.

- [ ] **Step 2: Implement atlas page allocation**

```objc
static glyph_atlas_page_t *
glyph_cache_get_page (emacs_metal_context_t *ctx, int required_w, int required_h)
{
  struct emacs_metal_glyph_cache *gc = ctx->glyph_cache;

  /* Try current page */
  if (gc->page_count > 0)
    {
      glyph_atlas_page_t *page = &gc->pages[gc->page_count - 1];
      if (page->cursor_x + required_w <= GLYPH_ATLAS_SIZE)
        {
          if (required_h > page->shelf_height)
            page->shelf_height = required_h;
          return page;
        }
      /* Next shelf */
      page->shelf_y += page->shelf_height;
      page->cursor_x = 0;
      page->shelf_height = required_h;
      if (page->shelf_y + required_h <= GLYPH_ATLAS_SIZE)
        return page;
    }

  /* Allocate new page */
  if (gc->page_count >= GLYPH_ATLAS_MAX_PAGES)
    {
      /* Evict oldest page (LRU) */
      gc->pages[0].texture = nil;
      memmove (&gc->pages[0], &gc->pages[1],
               (GLYPH_ATLAS_MAX_PAGES - 1) * sizeof (glyph_atlas_page_t));
      gc->page_count--;
      /* Remove entries referencing evicted page */
      int write = 0;
      for (int i = 0; i < gc->entry_count; i++)
        if (gc->entries[i].atlas_page > 0)
          {
            gc->entries[i].atlas_page--;
            gc->entries[write++] = gc->entries[i];
          }
      gc->entry_count = write;
    }

  glyph_atlas_page_t *page = &gc->pages[gc->page_count++];
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                      width:GLYPH_ATLAS_SIZE
                                                     height:GLYPH_ATLAS_SIZE
                                                  mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModeShared;
  page->texture = [ctx->device newTextureWithDescriptor:desc];
  page->shelf_y = 0;
  page->shelf_height = required_h;
  page->cursor_x = 0;
  return page;
}
```

- [ ] **Step 3: Implement glyph rasterization and cache lookup**

```objc
static uint32_t
glyph_cache_hash (CTFontRef font, uint16_t glyph_id, uint8_t subpixel)
{
  /* FNV-1a inspired hash */
  uint64_t h = 14695981039346656037ULL;
  h ^= (uintptr_t)font;  h *= 1099511628211ULL;
  h ^= glyph_id;          h *= 1099511628211ULL;
  h ^= subpixel;          h *= 1099511628211ULL;
  return (uint32_t)(h & (GLYPH_CACHE_SIZE - 1));  /* GLYPH_CACHE_SIZE must be power of 2 */
}

static glyph_cache_entry_t *
glyph_cache_lookup (emacs_metal_context_t *ctx, CTFontRef font,
                    uint16_t glyph_id, uint8_t subpixel)
{
  struct emacs_metal_glyph_cache *gc = ctx->glyph_cache;
  uint32_t idx = glyph_cache_hash (font, glyph_id, subpixel);

  /* Open-addressing linear probe */
  for (int i = 0; i < 16; i++)
    {
      glyph_cache_entry_t *e = &gc->entries[(idx + i) & (GLYPH_CACHE_SIZE - 1)];
      if (e->font == NULL)
        return NULL;  /* empty slot — miss */
      if (e->font == font && e->glyph_id == glyph_id
          && e->subpixel == subpixel)
        return e;
    }

  return NULL;  /* probe limit — miss */
}

static glyph_cache_entry_t *
glyph_cache_rasterize (emacs_metal_context_t *ctx, CTFontRef font,
                       uint16_t glyph_id, uint8_t subpixel)
{
  struct emacs_metal_glyph_cache *gc = ctx->glyph_cache;
  int s = ctx->scale;
  CGGlyph cg_glyph = glyph_id;

  /* Get glyph bounding box */
  CGRect bbox;
  CTFontGetBoundingRectsForGlyphs (font, kCTFontOrientationDefault,
                                   &cg_glyph, &bbox, 1);

  int gw = (int)ceil (bbox.size.width * s) + 2;
  int gh = (int)ceil (bbox.size.height * s) + 2;
  if (gw <= 0 || gh <= 0)
    gw = gh = 1;

  /* Rasterize into CPU bitmap (alpha-only — NULL color space required) */
  uint8_t *pixels = calloc (gw * gh, 1);
  CGContextRef cg = CGBitmapContextCreate (pixels, gw, gh, 8, gw, NULL,
                                           kCGImageAlphaOnly);

  float ox = -bbox.origin.x * s + 1.0f + (float)subpixel * 0.25f;
  float oy = -bbox.origin.y * s + 1.0f;

  CGContextSetFont (cg, CTFontCopyGraphicsFont (font, NULL));
  CGContextSetFontSize (cg, CTFontGetSize (font) * s);
  CGContextSetGrayFillColor (cg, 1.0, 1.0);

  CGPoint pos = CGPointMake (ox, oy);
  CTFontDrawGlyphs (font, &cg_glyph, &pos, 1, cg);
  CGContextRelease (cg);

  /* Upload to atlas */
  glyph_atlas_page_t *page = glyph_cache_get_page (ctx, gw, gh);
  if (!page)
    {
      free (pixels);
      return NULL;
    }

  MTLRegion region = MTLRegionMake2D (page->cursor_x, page->shelf_y, gw, gh);
  [page->texture replaceRegion:region
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:gw];
  free (pixels);

  /* Store cache entry */
  if (gc->entry_count >= GLYPH_CACHE_SIZE)
    gc->entry_count = 0;  /* wrap — brutal but simple */

  glyph_cache_entry_t *entry = &gc->entries[gc->entry_count++];
  entry->font = font;
  entry->glyph_id = glyph_id;
  entry->subpixel = subpixel;
  entry->atlas_page = page - gc->pages;
  entry->atlas_x = page->cursor_x;
  entry->atlas_y = page->shelf_y;
  entry->atlas_w = gw;
  entry->atlas_h = gh;
  entry->bearing_x = bbox.origin.x * s;
  entry->bearing_y = bbox.origin.y * s;

  CGSize advance;
  CTFontGetAdvancesForGlyphs (font, kCTFontOrientationDefault,
                              &cg_glyph, &advance, 1);
  entry->advance = advance.width * s;

  page->cursor_x += gw;
  return entry;
}
```

- [ ] **Step 4: Implement emacs_metal_draw_glyphs**

Add to `macmetal.h`:
```c
/* Glyph rendering — font is a CTFontRef cast to void* for C API */
extern void emacs_metal_draw_glyphs (emacs_metal_context_t *ctx,
                                     uint16_t *glyphs,
                                     float *positions,
                                     int count,
                                     void *font,
                                     uint32_t color,
                                     float baseline_y);
```

Implement in `macmetal.m`:
```objc
void
emacs_metal_draw_glyphs (emacs_metal_context_t *ctx,
                         uint16_t *glyphs, float *positions,
                         int count, void *font_ptr,
                         uint32_t color, float baseline_y)
{
  if (!ctx->in_frame || count <= 0)
    return;

  CTFontRef font = (CTFontRef)font_ptr;
  int s = ctx->scale;
  uint32_t c = color | 0xFF000000;
  float by = baseline_y * s;

  for (int i = 0; i < count; i++)
    {
      float gx = positions[i * 2] * s;
      uint8_t subpixel = (uint8_t)((gx - floorf (gx)) * SUBPIXEL_POSITIONS)
                         % SUBPIXEL_POSITIONS;

      glyph_cache_entry_t *entry = glyph_cache_lookup (ctx, font,
                                                        glyphs[i], subpixel);
      if (!entry)
        entry = glyph_cache_rasterize (ctx, font, glyphs[i], subpixel);
      if (!entry)
        continue;

      glyph_atlas_page_t *page = &ctx->glyph_cache->pages[entry->atlas_page];

      float x0 = floorf (gx) + entry->bearing_x;
      float y0 = by - entry->bearing_y - entry->atlas_h;
      float x1 = x0 + entry->atlas_w;
      float y1 = y0 + entry->atlas_h;

      float u0 = (float)entry->atlas_x / GLYPH_ATLAS_SIZE;
      float v0 = (float)entry->atlas_y / GLYPH_ATLAS_SIZE;
      float u1 = (float)(entry->atlas_x + entry->atlas_w) / GLYPH_ATLAS_SIZE;
      float v1 = (float)(entry->atlas_y + entry->atlas_h) / GLYPH_ATLAS_SIZE;

      metal_vertex_t *v = emit_vertices (ctx, 6, page->texture, true);
      if (!v)
        return;

      set_vertex (&v[0], x0, y0, u0, v0, c, 1);
      set_vertex (&v[1], x1, y0, u1, v0, c, 1);
      set_vertex (&v[2], x0, y1, u0, v1, c, 1);
      set_vertex (&v[3], x1, y0, u1, v0, c, 1);
      set_vertex (&v[4], x1, y1, u1, v1, c, 1);
      set_vertex (&v[5], x0, y1, u0, v1, c, 1);
    }
}
```

- [ ] **Step 5: Initialize glyph cache in context_create**

Add to `emacs_metal_context_create`:
```objc
ctx->glyph_cache = calloc (1, sizeof (struct emacs_metal_glyph_cache));
```
And free in `emacs_metal_context_destroy`.

- [ ] **Step 6: Verify build**

Rebuild. Glyph atlas code compiles. Not yet wired to macfont.m.

- [ ] **Step 7: Commit**

```bash
git add src/macmetal.h src/macmetal.m
git commit -m "Implement glyph atlas with shelf packing, CT rasterization, and subpixel support"
```

---

## Task 5: Scrolling via Metal Blit

**Files:**
- Modify: `src/macmetal.m`

This task implements GPU-side scrolling by copying a region within the retained backbuffer.

- [ ] **Step 1: Implement emacs_metal_scroll with batch flush**

Add a helper to flush pending render batches:

```objc
static void
flush_render_batches (emacs_metal_context_t *ctx,
                      id<MTLCommandBuffer> cmd)
{
  if (ctx->batch_count == 0)
    return;

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
  pass.colorAttachments[0].texture = ctx->backbuffer;
  pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc =
    [cmd renderCommandEncoderWithDescriptor:pass];

  float viewport_size[2] = {(float)(ctx->width * ctx->scale),
                             (float)(ctx->height * ctx->scale)};

  for (int i = 0; i < ctx->batch_count; i++)
    {
      metal_batch_t *b = &ctx->batches[i];
      MTLScissorRect scissor = {
        .x = (NSUInteger)b->scissor.x,
        .y = (NSUInteger)b->scissor.y,
        .width = (NSUInteger)b->scissor.w,
        .height = (NSUInteger)b->scissor.h
      };
      [enc setScissorRect:scissor];

      if (b->texture)
        {
          [enc setRenderPipelineState:shared_textured_pipeline];
          [enc setFragmentTexture:b->texture atIndex:0];
        }
      else
        [enc setRenderPipelineState:shared_solid_pipeline];

      [enc setVertexBuffer:ctx->vertex_buffers[ctx->current_buffer]
                    offset:b->vertex_offset * sizeof (metal_vertex_t)
                   atIndex:0];
      [enc setVertexBytes:viewport_size length:sizeof (viewport_size)
                  atIndex:1];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:b->vertex_count];
    }

  [enc endEncoding];
  ctx->batch_count = 0;
  ctx->vertex_count = 0;
}
```

Now implement scroll:

```objc
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

  /* Flush pending draws before blit */
  id<MTLCommandBuffer> cmd = [ctx->command_queue commandBuffer];
  flush_render_batches (ctx, cmd);

  /* Blit region within backbuffer via temp texture */
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ctx->backbuffer.pixelFormat
                                                      width:sw height:sh
                                                  mipmapped:NO];
  desc.storageMode = MTLStorageModePrivate;
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> temp = [ctx->device newTextureWithDescriptor:desc];

  id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
  /* Copy source region to temp */
  [blit copyFromTexture:ctx->backbuffer
            sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake (sx, sy, 0)
             sourceSize:MTLSizeMake (sw, sh, 1)
              toTexture:temp
       destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake (0, 0, 0)];
  /* Copy temp to destination */
  [blit copyFromTexture:temp
            sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake (0, 0, 0)
             sourceSize:MTLSizeMake (sw, sh, 1)
              toTexture:ctx->backbuffer
       destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake (sx + sdx, sy + sdy, 0)];
  [blit endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];
}
```

Note: We use a temp texture because Metal doesn't allow overlapping src/dst in a single blit. The `waitUntilCompleted` is needed to ensure the blit finishes before subsequent vertex buffer writes — without it, new draws could overwrite vertices the GPU is still reading from the flushed batches.

The temp texture should be pre-allocated in the context (as `scroll_staging_texture`) and resized lazily to avoid per-scroll allocation. Add a `id<MTLTexture> scroll_staging` field to `emacs_metal_context` and reallocate only when the scroll region exceeds its current size.

- [ ] **Step 2: Refactor frame_end to use flush_render_batches**

Update `emacs_metal_frame_end` to call `flush_render_batches` instead of duplicating the encoding logic. Then just do the backbuffer→drawable blit and present.

- [ ] **Step 3: Verify build**

- [ ] **Step 4: Commit**

```bash
git add src/macmetal.m
git commit -m "Implement Metal GPU scrolling via blit with batch flush"
```

---

## Task 6: Wire macterm.h — Frame Struct and Macros

**Files:**
- Modify: `src/macterm.h:181-307,760-768`

This task adds the Metal context to the frame struct and defines the accessor macros. No behavior change yet — just data structure preparation.

- [ ] **Step 1: Add metal_ctx to mac_output**

In `src/macterm.h`, inside `struct mac_output` (around line 302 near `cg_context`):

```c
#ifdef USE_METAL_RENDERING
  struct emacs_metal_context *metal_ctx;
#else
  CGContextRef cg_context;
#endif
```

- [ ] **Step 2: Add FRAME_METAL_CTX macro**

Near the other FRAME macros (around line 313):

```c
#ifdef USE_METAL_RENDERING
#define FRAME_METAL_CTX(f) (FRAME_MAC_OUTPUT (f)->metal_ctx)
#endif
```

- [ ] **Step 3: Guard MAC_BEGIN_DRAW_TO_FRAME**

Wrap the existing `MAC_BEGIN_DRAW_TO_FRAME` / `MAC_END_DRAW_TO_FRAME` macros (lines ~760-768) with `#ifndef USE_METAL_RENDERING`:

```c
#ifndef USE_METAL_RENDERING
/* existing MAC_BEGIN_DRAW_TO_FRAME and MAC_END_DRAW_TO_FRAME macros */
#endif
```

- [ ] **Step 4: Include macmetal.h**

Add `#include "macmetal.h"` in `macterm.h` (inside `#ifdef USE_METAL_RENDERING`).

- [ ] **Step 5: Verify build**

Rebuild. Should compile — nothing uses `FRAME_METAL_CTX` yet, and `MAC_BEGIN_DRAW_TO_FRAME` is still available when Metal is off.

- [ ] **Step 6: Commit**

```bash
git add src/macterm.h
git commit -m "Add Metal context to mac_output struct and FRAME_METAL_CTX macro"
```

---

## Task 7: Wire macterm.c — Drawing Primitives

**Files:**
- Modify: `src/macterm.c:260-384,681-809`

This task redirects the low-level drawing functions in macterm.c to the Metal API. This is the bulk of the integration.

- [ ] **Step 1: Wire mac_fill_rectangle (line ~260)**

```c
static void
mac_fill_rectangle (struct frame *f, GC gc, int x, int y,
                    unsigned int width, unsigned int height)
{
#ifdef USE_METAL_RENDERING
  emacs_metal_fill_rect (FRAME_METAL_CTX (f), x, y, width, height,
                         gc->xgcv.foreground);
#else
  /* existing CG code */
#endif
}
```

- [ ] **Step 2: Wire mac_draw_rectangle (line ~273)**

Same pattern — wrap existing code, add Metal path calling `emacs_metal_draw_rect`.

- [ ] **Step 3: Wire mac_fill_trapezoid_for_relief (line ~284)**

Decompose the trapezoid into two triangles and emit via `emacs_metal_fill_rect` or add a new `emacs_metal_fill_trapezoid` function in `macmetal.m` that takes the four corner points. The existing code uses `CGContextBeginPath / CGContextAddLines / CGContextFillPath` — the Metal equivalent emits 6 vertices (two triangles) directly.

Add to `macmetal.h`:
```c
extern void emacs_metal_fill_trapezoid (emacs_metal_context_t *ctx,
                                        float x1, float y1,
                                        float x2, float y2,
                                        float x3, float y3,
                                        float x4, float y4,
                                        uint32_t color);
```

- [ ] **Step 4: Wire mac_draw_horizontal_wave (line ~355)**

The wave is drawn as a series of line segments. Under Metal, emit a quad strip. Add to `macmetal.h`:
```c
extern void emacs_metal_draw_wave (emacs_metal_context_t *ctx,
                                   int x, int y, int width, int height,
                                   uint32_t color);
```

Implement as a series of small filled rectangles (2px segments alternating up/down), matching the existing CG appearance.

- [ ] **Step 5: Wire mac_erase_rectangle (line ~123)**

This function handles stippled backgrounds and alpha-transparent fills. Under Metal, render as a solid fill with the background color (stipple patterns simplified to solid):

```c
#ifdef USE_METAL_RENDERING
  emacs_metal_fill_rect (FRAME_METAL_CTX (f), x, y, width, height,
                         gc->xgcv.background);
#else
  /* existing CG code with stipple/alpha handling */
#endif
```

- [ ] **Step 6: Wire mac_draw_cg_image (line ~177)**

This is used by fringe bitmaps AND image drawing. Under Metal, it needs to upload the CGImage and draw it. Add to `macmetal.h`:

```c
extern void emacs_metal_draw_cg_image (emacs_metal_context_t *ctx,
                                       void *cg_image,
                                       int src_x, int src_y,
                                       int src_w, int src_h,
                                       int dst_x, int dst_y,
                                       int dst_w, int dst_h,
                                       bool overlay);
```

Under Metal, this uploads the CGImage to a cached texture and draws as a textured quad. The `overlay` flag controls blend mode (premultiplied alpha when true, opaque when false).

- [ ] **Step 7: Wire mac_invert_rectangle (line ~387)**

Used for visual bell. Add a new Metal function:

```c
extern void emacs_metal_invert_rect (emacs_metal_context_t *ctx,
                                     int x, int y, int w, int h);
```

Implement by reading back the backbuffer region, inverting in a fragment shader, or by drawing a white rect with `kCGBlendModeDifference` equivalent (Metal blend factor: `MTLBlendFactorOneMinusDestinationColor` for both source and destination).

- [ ] **Step 8: Wire mac_erase_corners_for_relief (line ~320)**

This draws small erased corners for 3D box borders. Under Metal, approximate with small `fill_rect` calls at the corner positions (the CG version uses `CGContextAddArc` for tiny 1-2px arcs — rectangles are visually equivalent at that size).

- [ ] **Step 9: Wire mac_reset_clip_rectangles**

Called after many drawing operations (e.g., fringe drawing at line ~953). Under Metal, this resets the clip stack to the full-frame default:

```c
#ifdef USE_METAL_RENDERING
  /* Reset clip to full frame */
  while (FRAME_METAL_CTX (f)->clip_depth > 1)
    emacs_metal_pop_clip (FRAME_METAL_CTX (f));
#endif
```

- [ ] **Step 10: Wire mac_update_begin / mac_update_end (lines ~681, ~794)**

In `mac_update_begin`:
```c
#ifdef USE_METAL_RENDERING
  emacs_metal_frame_begin (FRAME_METAL_CTX (f));
#else
  /* existing code */
#endif
```

In `mac_update_end`:
```c
#ifdef USE_METAL_RENDERING
  emacs_metal_frame_end (FRAME_METAL_CTX (f));
#else
  /* existing code */
#endif
```

- [ ] **Step 11: Wire mac_scroll_area**

`mac_scroll_area` in macterm.c calls into macappkit.m. Under Metal, call `emacs_metal_scroll` directly:

```c
#ifdef USE_METAL_RENDERING
  emacs_metal_scroll (FRAME_METAL_CTX (f), x, y, width, height, dx, dy);
#else
  /* existing macappkit scroll call */
#endif
```

- [ ] **Step 12: Wire clipping in mac_begin_cg_clip / mac_end_cg_clip equivalents**

Find all call sites of `mac_begin_cg_clip` and `mac_end_cg_clip` in macterm.c and macappkit.m. Under Metal, replace with `emacs_metal_push_clip` / `emacs_metal_pop_clip`.

- [ ] **Step 13: Audit all remaining MAC_BEGIN_DRAW_TO_FRAME uses**

Search macterm.c for any remaining `MAC_BEGIN_DRAW_TO_FRAME` calls not yet handled. Each one needs a `#ifdef USE_METAL_RENDERING` Metal equivalent. The guarding of the macro itself (Task 6) will cause compile errors for any missed call sites — use this as a check.

- [ ] **Step 14: Verify build**

Rebuild with `--with-metal-rendering`. All drawing primitives now route through Metal.

- [ ] **Step 15: Commit**

```bash
git add src/macterm.c src/macmetal.h src/macmetal.m
git commit -m "Wire macterm.c drawing primitives to Metal API"
```

---

## Task 8: Wire macfont.m — Glyph Drawing

**Files:**
- Modify: `src/macfont.m:2881-3160`

This task redirects `macfont_draw` to use `emacs_metal_draw_glyphs`.

- [ ] **Step 1: Wrap macfont_draw**

In `macfont_draw` (line ~2881), the function currently:
1. Extracts glyphs from `s->char2b`
2. Computes positions/advances
3. Calls `MAC_BEGIN_DRAW_TO_FRAME`
4. Calls `CTFontDrawGlyphs` or `CGContextShowGlyphsAtPositions`
5. Calls `MAC_END_DRAW_TO_FRAME`

Under Metal, replace steps 3-5:

```objc
#ifdef USE_METAL_RENDERING
  {
    /* Build glyph ID and position arrays */
    uint16_t glyph_ids[len];
    float positions[len * 2];

    for (i = 0; i < len; i++)
      {
        glyph_ids[i] = s->char2b[from + i];
        positions[i * 2] = x + s->left_overhang + /* per-glyph x offset */;
        positions[i * 2 + 1] = 0;  /* y offset from baseline */
      }

    emacs_metal_draw_glyphs (FRAME_METAL_CTX (s->f),
                              glyph_ids, positions, len,
                              (void *)macfont_get_ct_font (s->font),
                              s->xgcv.foreground,
                              s->ybase);
  }
#else
  /* existing MAC_BEGIN_DRAW_TO_FRAME + CG/CT drawing code */
#endif
```

The exact position calculation needs to match the existing code that computes `advance_delta` and `positions[]` array. Read the existing code carefully — the Metal path must produce the same glyph positions.

- [ ] **Step 2: Handle background fill**

Before the glyph drawing, the existing code fills the background. Under Metal:

```objc
#ifdef USE_METAL_RENDERING
  if (s->background_filled_p == false)
    emacs_metal_fill_rect (FRAME_METAL_CTX (s->f),
                           s->x, s->y, s->background_width, s->height,
                           s->xgcv.background);
#endif
```

- [ ] **Step 3: Handle synthetic bold (overstrike)**

The existing code draws glyphs twice with a 1px offset for synthetic bold. Under Metal, call `emacs_metal_draw_glyphs` twice with offset positions.

- [ ] **Step 4: Verify build**

Rebuild. `macfont_draw` now routes through Metal.

- [ ] **Step 5: Commit**

```bash
git add src/macfont.m
git commit -m "Wire macfont_draw to Metal glyph rendering"
```

---

## Task 9: Wire macappkit.m — View Layer and Presentation

**Files:**
- Modify: `src/macappkit.m:5730-6420`
- Modify: `src/macappkit.h:777-857`

This task replaces the `EmacsBacking` / IOSurface path with `CAMetalLayer` presentation. This is where the rendering becomes visible.

- [ ] **Step 1: Modify EmacsView layer setup**

In `macappkit.m`, find where `EmacsView` sets up its backing layer. Under Metal:

```objc
#ifdef USE_METAL_RENDERING
- (CALayer *)makeBackingLayer
{
  CAMetalLayer *layer = [CAMetalLayer layer];
  layer.device = MTLCreateSystemDefaultDevice ();
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
  layer.framebufferOnly = YES;
  layer.contentsScale = self.window.backingScaleFactor;
  return layer;
}
#endif
```

- [ ] **Step 2: Create Metal context on frame creation**

Find where `EmacsBacking` is initialized (in the EmacsView or EmacsFrameController init path). Under Metal, create the `emacs_metal_context_t` instead:

```objc
#ifdef USE_METAL_RENDERING
  struct frame *f = /* get frame pointer */;
  NSRect frame_rect = self.bounds;
  int scale = (int)self.window.backingScaleFactor;
  FRAME_METAL_CTX (f) = emacs_metal_context_create (
    (__bridge void *)self,
    NSWidth (frame_rect), NSHeight (frame_rect), scale);
#endif
```

`emacs_metal_context_create` receives the view, gets its `CAMetalLayer` via `[(NSView *)view layer]`, and stores it directly. No separate `set_layer` call needed.

- [ ] **Step 3: Guard EmacsBacking**

Wrap the entire `@implementation EmacsBacking` block (lines ~5730-5940) and its `@interface` in `macappkit.h` (lines ~777-830) with `#ifndef USE_METAL_RENDERING`.

- [ ] **Step 4: Guard lockFocusOnBacking / unlockFocusOnBacking**

Wrap calls to `lockFocusOnBacking` (line ~6393) and `unlockFocusOnBacking` (line ~6419) with `#ifndef USE_METAL_RENDERING`. Under Metal these are no-ops.

- [ ] **Step 5: Guard GCD drawing queue functions**

Wrap `set_global_focus_view_frame` (line ~7656), `unset_global_focus_view_frame` (line ~7717), `mac_draw_queue_sync` (line ~7695), `mac_draw_queue_dispatch_async` (line ~7706), `mac_begin_cg_clip` (line ~7746), `mac_end_cg_clip` (line ~7794), and `mac_draw_to_frame` (line ~7814) with `#ifndef USE_METAL_RENDERING`.

- [ ] **Step 6: Handle resize with presentsWithTransaction**

Find `setFrameSize:` or `viewDidChangeBackingProperties:` in EmacsView. Under Metal:

```objc
#ifdef USE_METAL_RENDERING
  if (FRAME_METAL_CTX (f))
    {
      int scale = (int)self.window.backingScaleFactor;
      CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
      metalLayer.contentsScale = scale;
      metalLayer.drawableSize =
        CGSizeMake (NSWidth (self.bounds) * scale,
                    NSHeight (self.bounds) * scale);
      emacs_metal_context_resize (FRAME_METAL_CTX (f),
                                   NSWidth (self.bounds),
                                   NSHeight (self.bounds));
    }
#endif
```

Also find the live resize begin/end hooks (typically `viewWillStartLiveResize` / `viewDidEndLiveResize`). Under Metal:

```objc
#ifdef USE_METAL_RENDERING
- (void)viewWillStartLiveResize
{
  [super viewWillStartLiveResize];
  ((CAMetalLayer *)self.layer).presentsWithTransaction = YES;
}

- (void)viewDidEndLiveResize
{
  [super viewDidEndLiveResize];
  ((CAMetalLayer *)self.layer).presentsWithTransaction = NO;
}
#endif
```

Without `presentsWithTransaction`, resize will visibly tear because the window server and Metal present at different times.

- [ ] **Step 7: Handle frame destruction**

Find where `EmacsBacking` is deallocated. Under Metal, call `emacs_metal_context_destroy`.

- [ ] **Step 8: Verify build and test**

Rebuild. Launch Emacs. At this point the Metal path should be active — the frame should display something (even if imperfect). Verify:
- Window appears and is not just black
- Text is visible (even if positioning is off)
- Resizing doesn't crash

This is the first "something on screen" milestone.

- [ ] **Step 9: Commit**

```bash
git add src/macappkit.m src/macappkit.h src/macmetal.h src/macmetal.m
git commit -m "Wire EmacsView to CAMetalLayer and Metal context for presentation"
```

---

## Task 10: Wire Remaining Glyph String Types

**Files:**
- Modify: `src/macterm.c:1234-2580`

This task wraps the remaining glyph string drawing functions: background, composite glyphs, glyphless glyphs, image glyphs, stretch glyphs, box borders.

- [ ] **Step 1: Wire mac_draw_glyph_string_background (line ~1234)**

Under Metal, replace `mac_fill_rectangle` call (already wired in Task 7) — verify it's using the Metal path correctly.

- [ ] **Step 2: Wire mac_draw_composite_glyph_string_foreground (line ~1323)**

This calls `font->driver->draw()` per component. Since `macfont_draw` is already Metal-ified (Task 8), this should work automatically. Verify by reading the code path.

- [ ] **Step 3: Wire mac_draw_glyphless_glyph_string_foreground (line ~1414)**

This draws hex code boxes. It uses `mac_fill_rectangle` and `mac_draw_rectangle` (already wired) plus small text via the font driver (already wired). Verify the code path.

- [ ] **Step 4: Wire mac_draw_image_foreground (line ~1878)**

For now, skip actual image rendering (just draw a placeholder rectangle). Image Metal textures will be added in Task 11.

```c
#ifdef USE_METAL_RENDERING
  /* TODO: Draw image via Metal texture */
  emacs_metal_fill_rect (FRAME_METAL_CTX (s->f),
                         x, y, s->img->width, s->img->height,
                         s->xgcv.foreground);
#else
  /* existing CG image drawing */
#endif
```

- [ ] **Step 5: Wire mac_draw_stretch_glyph_string (line ~2120)**

Uses `mac_fill_rectangle` — already wired. Verify.

- [ ] **Step 6: Wire mac_draw_glyph_string_box (line ~1809)**

Uses `mac_fill_rectangle` and `mac_draw_rectangle` — already wired. Verify.

- [ ] **Step 7: Wire cursor drawing (lines ~3574-3750)**

`mac_draw_hollow_cursor` uses `mac_draw_rectangle`. `mac_draw_bar_cursor` uses `mac_fill_rectangle`. Both already wired. Verify.

- [ ] **Step 8: Verify visually**

Launch Emacs with Metal. At this point:
- Text should render correctly
- Cursor should be visible
- Backgrounds should fill correctly
- Images show as colored rectangles (placeholder)

Fix any positioning issues by comparing with the CG path.

- [ ] **Step 9: Commit**

```bash
git add src/macterm.c
git commit -m "Wire remaining glyph string types to Metal rendering"
```

---

## Task 11: Image Rendering via Metal Textures

**Files:**
- Modify: `src/dispextern.h:3287`
- Modify: `src/macterm.c:1878-1932`
- Modify: `src/image.c` (image deallocation)
- Modify: `src/macmetal.h`
- Modify: `src/macmetal.m`

- [ ] **Step 1: Add metal_texture field to image struct**

In `src/dispextern.h`, near `cg_image` (line ~3287):

```c
#ifdef USE_METAL_RENDERING
  void *metal_texture;   /* id<MTLTexture>, opaque for C */
#endif
```

- [ ] **Step 2: Add image upload function to macmetal API**

In `macmetal.h`:
```c
extern void *emacs_metal_upload_cg_image (emacs_metal_context_t *ctx,
                                          void *cg_image,
                                          int width, int height);
extern void emacs_metal_draw_image (emacs_metal_context_t *ctx,
                                    void *texture,
                                    int src_x, int src_y,
                                    int src_w, int src_h,
                                    int dst_x, int dst_y,
                                    int dst_w, int dst_h);
extern void emacs_metal_destroy_texture (void *texture);
```

- [ ] **Step 3: Implement image upload in macmetal.m**

```objc
void *
emacs_metal_upload_cg_image (emacs_metal_context_t *ctx,
                             void *cg_image_ptr,
                             int width, int height)
{
  CGImageRef cg_image = (CGImageRef)cg_image_ptr;

  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                      width:width
                                                     height:height
                                                  mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModeShared;

  id<MTLTexture> texture = [ctx->device newTextureWithDescriptor:desc];
  if (!texture)
    return NULL;

  /* Render CGImage into pixel buffer */
  size_t bpr = width * 4;
  uint8_t *pixels = calloc (height, bpr);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName (kCGColorSpaceSRGB);
  CGContextRef cg = CGBitmapContextCreate (pixels, width, height, 8, bpr, cs,
                                           kCGImageAlphaPremultipliedFirst
                                           | kCGBitmapByteOrder32Host);
  CGColorSpaceRelease (cs);
  CGContextDrawImage (cg, CGRectMake (0, 0, width, height), cg_image);
  CGContextRelease (cg);

  [texture replaceRegion:MTLRegionMake2D (0, 0, width, height)
             mipmapLevel:0
               withBytes:pixels
             bytesPerRow:bpr];
  free (pixels);

  return (__bridge_retained void *)texture;
}
```

- [ ] **Step 4: Implement emacs_metal_draw_image**

```objc
void
emacs_metal_draw_image (emacs_metal_context_t *ctx,
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
```

- [ ] **Step 5: Wire mac_draw_image_foreground**

In `macterm.c` at `mac_draw_image_foreground` (line ~1878), replace the Task 10 placeholder:

```c
#ifdef USE_METAL_RENDERING
  if (!s->img->metal_texture && s->img->cg_image)
    s->img->metal_texture =
      emacs_metal_upload_cg_image (FRAME_METAL_CTX (s->f),
                                   s->img->cg_image,
                                   s->img->width, s->img->height);
  if (s->img->metal_texture)
    emacs_metal_draw_image (FRAME_METAL_CTX (s->f),
                            s->img->metal_texture,
                            s->slice.x, s->slice.y,
                            s->slice.width, s->slice.height,
                            x, y, s->slice.width, s->slice.height);
#else
  /* existing CG code */
#endif
```

- [ ] **Step 6: Free metal_texture on image deallocation**

In `image.c`, find where `cg_image` is released (search for `CGImageRelease`). Add:
```c
#ifdef USE_METAL_RENDERING
  if (img->metal_texture)
    emacs_metal_destroy_texture (img->metal_texture);
  img->metal_texture = NULL;
#endif
```

- [ ] **Step 7: Verify build and test with images**

Open a file with inline images (e.g., an org file with images, or `M-x image-dired`). Images should display.

- [ ] **Step 8: Commit**

```bash
git add src/dispextern.h src/macterm.c src/image.c src/macmetal.h src/macmetal.m
git commit -m "Implement Metal image rendering with CGImage upload and texture caching"
```

---

## Task 12: Fringe Bitmaps

**Files:**
- Modify: `src/macterm.c` (fringe drawing function)
- Modify: `src/macmetal.m`

Fringe bitmaps in this codebase are stored as `CGImageRef` and drawn via `mac_draw_cg_image` (line ~177 in macterm.c, called at line ~948 for fringes). Since we already wired `mac_draw_cg_image` in Task 7 Step 6 (which calls `emacs_metal_draw_cg_image`), fringes should already work.

- [ ] **Step 1: Verify fringes display correctly**

Open a file with line wrapping to see continuation fringes. Check that truncation arrows appear. If `mac_draw_cg_image` was wired correctly in Task 7, fringes should render.

- [ ] **Step 2: Add fringe image caching if needed**

If fringe rendering is slow (because each fringe bitmap is re-uploaded per draw), add a per-bitmap-index cache array in the context. The bitmap indices are small integers (0-30 or so). Cache the `MTLTexture` by index and reuse on subsequent draws.

- [ ] **Step 3: Verify fringe bitmaps are correctly tinted**

Fringes use the foreground color of the fringe face. Verify that `mac_draw_cg_image` with the `overlay` flag passes the correct color to the textured shader for tinting.

- [ ] **Step 4: Commit**

```bash
git add src/macterm.c src/macmetal.m
git commit -m "Verify and optimize Metal fringe bitmap rendering"
```

---

## Task 13: Color Emoji Support

**Files:**
- Modify: `src/macmetal.m` (glyph atlas)

- [ ] **Step 1: Detect color fonts**

In `glyph_cache_rasterize`, check if the font is a color font:

```objc
CTFontSymbolicTraits traits = CTFontGetSymbolicTraits (font);
bool is_color = (traits & kCTFontTraitColorGlyphs) != 0;
```

- [ ] **Step 2: Rasterize color glyphs as RGBA**

If `is_color`, create the bitmap as RGBA instead of alpha-only:
- Use `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host` instead of `kCGImageAlphaOnly`
- Upload to an RGBA atlas page (`MTLPixelFormatBGRA8Unorm`) instead of `R8Unorm`

- [ ] **Step 3: Handle in fragment shader**

The existing `fragment_textured` shader already handles this via `texture_id`: when `texture_id == 1` it alpha-tints (monochrome glyphs), when `texture_id >= 2` it uses direct RGBA. Use `texture_id = 2` for color emoji atlas pages.

- [ ] **Step 4: Test with emoji**

Type some emoji in a buffer. They should render in color.

- [ ] **Step 5: Commit**

```bash
git add src/macmetal.m
git commit -m "Add color emoji support to glyph atlas"
```

---

## Task 14: Visual Polish and Bug Fixes

**Files:**
- Modify: various, as needed

This is an integration testing task. Work through common Emacs workflows and fix rendering issues.

- [ ] **Step 1: Test basic editing**

Open a source file. Type, delete, undo. Verify text renders correctly, cursor moves properly, and no visual artifacts appear.

- [ ] **Step 2: Test scrolling**

Scroll through a large file with `C-v`, `M-v`, mouse wheel, and scroll bar. Check for tearing, missing content, or corruption.

- [ ] **Step 3: Test multiple windows**

Split windows (`C-x 2`, `C-x 3`). Each window should render independently. Mode lines and fringes should be correct.

- [ ] **Step 4: Test multiple frames**

Open a new frame (`C-x 5 2`). Each frame should have its own Metal context and render independently.

- [ ] **Step 5: Test mode line, header line, tab bar**

Verify these display elements render with correct faces and decorations.

- [ ] **Step 6: Test minibuffer and echo area**

Type `M-x`, completion prompts, and messages. Verify rendering.

- [ ] **Step 7: Test live resize**

Drag the window edges. Content should resize smoothly without flicker or corruption.

- [ ] **Step 8: Test theme switching**

`M-x load-theme` — switch between light and dark themes. All faces should update.

- [ ] **Step 9: Fix issues found**

Address any rendering bugs discovered. Common issues:
- Y-coordinate flipping (Metal is top-down, CG is bottom-up)
- Off-by-one in glyph positioning
- Missing clip rects causing overdraw
- Wrong color byte order (BGRA vs RGBA)

- [ ] **Step 10: Commit fixes**

```bash
git add -u
git commit -m "Fix rendering issues found during visual testing"
```

---

## Checkpoint

After Task 15, the Metal rendering path should be functionally complete for:
- Text rendering (all glyph types, color emoji)
- Rectangles, lines, relief, wave underlines
- Images
- Fringe bitmaps
- Scrolling
- Multiple windows and frames
- Resize

Remaining work is performance optimization and edge cases.

---

## Task 15: Performance Profiling and Optimization

**Files:**
- Modify: `src/macmetal.m`

- [ ] **Step 1: Add frame timing**

Add optional timing to `frame_end`:

```objc
#ifdef METAL_DEBUG
  static CFAbsoluteTime last_time;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent ();
  if (last_time > 0)
    NSLog (@"Metal frame: %.1fms, %d batches, %d vertices",
           (now - last_time) * 1000.0,
           ctx->batch_count, ctx->vertex_count);
  last_time = now;
#endif
```

- [ ] **Step 2: Profile with Instruments**

Run Emacs under Instruments (Metal System Trace) to identify:
- Draw call count per frame
- Vertex buffer utilization
- GPU vs CPU time split
- Glyph atlas hit rate

- [ ] **Step 3: Optimize batch count**

If too many batch breaks occur, consider:
- Texture array for multiple atlas pages (bind all at once)
- Sorting draws by texture before encoding

- [ ] **Step 4: Commit optimizations**

```bash
git add src/macmetal.m
git commit -m "Add performance instrumentation and optimize hot paths"
```

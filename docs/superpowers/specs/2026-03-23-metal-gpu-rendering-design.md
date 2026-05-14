# Metal GPU Rendering for Emacs Mac Port

## Motivation

Performance — replace Core Graphics CPU rendering with a full Metal GPU pipeline to reduce CPU load, enable batched draw calls, and free the main thread for Lisp execution.

## Scope

Full pipeline replacement: all drawing (text, rectangles, images, relief, fringe, scrolling) goes through Metal. Mutually exclusive with CG drawing via `--with-metal-rendering` configure flag. Target macOS 14+ (Sonoma).

## Background: Why emacs-mac's existing Metal support was limited

YAMAMOTO's `--with-mac-metal` (2018) only used Metal for IOSurface pixel copies (buffer swaps, scrolling blits). All actual drawing remained Core Graphics. It was disabled by default in 2021 because:

1. The perceived CPU savings came from lower frame rate, not actual efficiency
2. GPU<->CPU synchronization (IOSurface lock/unlock around Metal blits) negated any advantage
3. M1 Macs achieved 60fps with CG alone

Our approach is fundamentally different: Metal draws everything directly — no IOSurface, no CG, no synchronization bottleneck.

## Architecture

### Core Module

New files:
- `src/macmetal.h` — C API header
- `src/macmetal.m` — Metal renderer implementation (context, glyph atlas, batching, shaders)
- Shaders embedded as MSL string constants in `macmetal.m`. Compiled once at startup during `emacs_metal_context_create` via `[device newLibraryWithSource:options:error:]` (~50-200ms one-time cost). The compiled `MTLLibrary` is shared across all Emacs frames. Move to precompiled `.metallib` if startup cost becomes a concern

Key opaque types:
```c
typedef struct emacs_metal_context emacs_metal_context_t;
typedef struct emacs_metal_glyph_cache emacs_metal_glyph_cache_t;
```

### C API

```c
// Lifecycle — one context per Emacs frame (window)
emacs_metal_context_t *emacs_metal_context_create(NSView *view, int w, int h, int scale);
void emacs_metal_context_resize(emacs_metal_context_t *ctx, int w, int h);
void emacs_metal_context_destroy(emacs_metal_context_t *ctx);

// Frame begin/end
void emacs_metal_frame_begin(emacs_metal_context_t *ctx);
void emacs_metal_frame_end(emacs_metal_context_t *ctx);

// Drawing primitives
void emacs_metal_fill_rect(emacs_metal_context_t *ctx, int x, int y, int w, int h, uint32_t color);
void emacs_metal_draw_rect(emacs_metal_context_t *ctx, int x, int y, int w, int h, uint32_t color);
void emacs_metal_draw_line(emacs_metal_context_t *ctx, int x1, int y1, int x2, int y2, uint32_t color);

// Glyph rendering
void emacs_metal_draw_glyphs(emacs_metal_context_t *ctx, uint16_t *glyphs, float *positions,
                              int count, CTFontRef font, uint32_t color, float baseline_y);

// Images
void emacs_metal_draw_image(emacs_metal_context_t *ctx, id<MTLTexture> texture,
                             int src_x, int src_y, int src_w, int src_h,
                             int dst_x, int dst_y, int dst_w, int dst_h);

// Clipping
void emacs_metal_push_clip(emacs_metal_context_t *ctx, int x, int y, int w, int h);
void emacs_metal_pop_clip(emacs_metal_context_t *ctx);

// Scrolling (GPU texture copy)
void emacs_metal_scroll(emacs_metal_context_t *ctx, int x, int y, int w, int h, int dx, int dy);
```

## Glyph Atlas & Text Rendering

Core Text handles all shaping and layout (glyph IDs, advances, positions). Metal handles rendering via a glyph atlas.

### Atlas strategy

- Large `MTLTexture` (2048x2048), shelf-packed
- Cache key: `(CTFontRef, glyph_id, scale_factor)`
- Cache miss: rasterize single glyph via `CTFontDrawGlyphs` into a `CGBitmapContext`, upload to atlas via `MTLTexture.replaceRegion`
- Render: emit a textured quad with atlas UV coordinates
- Multiple pages if atlas fills (allocate new 2048x2048)
- Eviction: per-page LRU — when a page fills, evict the least-recently-used page entirely and reuse it. Full multi-page clear as last resort. A visible re-rasterization stutter is possible on page eviction but limited to one page worth of glyphs (~7000 at 12pt@2x)

### Subpixel positioning

Quantize to 4 subpixel positions (1/4 pixel). Rasterize 4 variants per glyph. Smooth text without exploding the atlas.

### Color emoji / SVG glyphs

- Detected via `CTFontGetSymbolicTraits`
- Rasterized as RGBA (not alpha-only) into separate atlas region
- Shader uniform selects between alpha-tinted (monochrome) and direct RGBA sampling

### What stays the same in macfont.m

- `encode_char`, `text_extents`, `shape` — unchanged
- Only `macfont_draw()` changes: calls `emacs_metal_draw_glyphs()` instead of CG/CT functions

## Rendering Pipeline & Batching

### Shaders

Two shader programs:
1. **Solid shader** — vertex color only (rectangles, lines, relief, fringes)
2. **Textured shader** — samples from atlas or image texture (glyphs, images)

Shared vertex format:
```metal
struct Vertex {
    float2 position;
    float2 texcoord;
    uchar4 color;
    uint   texture_id;  // 0 = solid, 1 = glyph atlas page 0, 2 = page 1, etc.
};
```

Image textures are bound per-draw-call (batch break on image texture change). For image-heavy buffers (eww, org-mode with inline images), this means more draw calls — acceptable since text-heavy frames (the common case) remain fully batched. Small frequently-used images (fringe bitmaps) are packed into a dedicated fringe atlas to avoid per-image batch breaks.

### Per-frame flow

```
frame_begin()
  — clear command buffer, reset vertex buffer write position
  — set viewport to frame size

[all drawing calls from macterm.c]
  — each call appends quads to vertex buffer
  — batch breaks on: clip rect change, texture source change, buffer full

frame_end()
  — encode batched draw calls into MTLRenderCommandEncoder
  — blit retained backbuffer to drawable
  — commit command buffer, present drawable
```

### Buffering

Double-buffered vertex buffers (rotate per frame) with a `dispatch_semaphore` to prevent CPU from overwriting a buffer the GPU is still reading. Triple buffering is unnecessary — Emacs redraws are event-driven (not a continuous render loop), so the CPU rarely races the GPU.

## Window/View Integration

### Presentation path

```
EmacsView
  └── CAMetalLayer (replaces IOSurface/EmacsBacking)
       └── MTLTexture (drawable) ← blit from retained backbuffer
```

### Retained backbuffer

Emacs does partial redraws — only changed regions are redrawn. Each `CAMetalLayer` drawable is a fresh texture, so we maintain a persistent `MTLTexture` as the backbuffer:

- All drawing targets the retained backbuffer
- At `frame_end`, blit the full backbuffer to the drawable
- Partial updates only touch changed regions of the backbuffer

### EmacsView changes

- `makeBackingLayer` returns `CAMetalLayer`
- `layer.pixelFormat = .bgra8Unorm_srgb` (Emacs uses sRGB colors internally; this avoids manual gamma conversion in shaders)
- `layer.framebufferOnly = YES` (applies to drawable textures only — the retained backbuffer is a separate non-framebuffer-only texture)
- `layer.contentsScale = backingScaleFactor`
- `EmacsBacking` removed under `USE_METAL_RENDERING` — its responsibilities are replaced:
  - Double buffering → retained backbuffer + CAMetalLayer drawables
  - Front/back swap → blit backbuffer to drawable at `frame_end`
  - Dirty rect tracking → abandoned; full backbuffer blit on every `frame_end`. On Apple Silicon at 2x Retina (e.g., 2560x1600 = ~16MB), a single GPU blit is ~0.1ms — negligible. Dirty-region optimization deferred unless profiling shows otherwise

### Resize

- Reallocate retained backbuffer at new size
- Blit old content to new backbuffer
- `presentsWithTransaction = YES` during live resize

### Focus lifecycle under Metal

The current CG path uses `MAC_BEGIN_DRAW_TO_FRAME` / `MAC_END_DRAW_TO_FRAME` to bracket each individual drawing operation. Under GCD, these dispatch blocks onto `global_focus_drawing_queue`. Under Metal:

- `lockFocusOnBacking` / `unlockFocusOnBacking` become no-ops — there is no CG context to lock
- `MAC_BEGIN_DRAW_TO_FRAME` / `MAC_END_DRAW_TO_FRAME` are removed entirely under `USE_METAL_RENDERING`
- Drawing calls go directly to `emacs_metal_*` functions which append to the vertex buffer (no dispatch, no locking)
- The only synchronization points are `frame_begin` (acquire vertex buffer) and `frame_end` (encode + commit + present)
- `mac_within_gui` / `block_input()` / `unblock_input()` continue to work as before for event handling — they don't interact with Metal command buffer submission

### Scroll and blit encoder interaction

`emacs_metal_scroll` needs a blit command encoder, but rendering uses a render command encoder. Within a single command buffer, switching encoder types requires ending one and starting another. Scroll is therefore a batch break:

1. Flush and encode all pending render vertices into a render command encoder
2. End the render command encoder
3. Encode the blit operation (copy region within retained backbuffer)
4. Start a new render command encoder for subsequent drawing

This is correct because Emacs always calls `mac_scroll_area` between complete drawing sequences, not mid-glyph-string.

## Scrolling, Images & Decorations

### Scrolling

Single `MTLBlitCommandEncoder` operation on the retained backbuffer:
```
copy region (x,y,w,h) from backbuffer to (x+dx, y+dy)
```
Entirely GPU-side. No IOSurface locking.

### Images

- First display: `CGImageRef` → pixel data → `MTLTexture`, cached on image struct
- Render as textured quad via textured shader
- Transforms (scaling, rotation) via vertex positions / UV coords

### Fringe bitmaps

- Upload 1-bit bitmaps as small `MTLTexture` (or packed fringe atlas)
- Render as textured quads, tinted with foreground color in shader

### Relief rectangles

- Decompose trapezoids into triangle pairs
- Emit as solid-colored vertices

### Wave underlines

- Pre-generate wave pattern as triangle strip, tile horizontally

### Cursor

- Block/bar/hbar/hollow: all covered by existing `fill_rect` / `draw_rect` primitives

### Composite and glyphless glyphs

- `COMPOSITE_GLYPH`: drawn via `mac_draw_composite_glyph_string_foreground`, which calls `font->driver->draw()` per component — same Metal path as regular glyphs
- `GLYPHLESS_GLYPH`: drawn via `mac_draw_glyphless_glyph_string_foreground`, which renders hex codes as small text + box outline — uses `fill_rect` + `draw_glyphs`, both already Metal-ified

### Stipple / pattern fills

The existing code supports stippled backgrounds via `s->stippled_p`. On macOS this is rarely used (no X11 stipple patterns). Under Metal, stippled fills are rendered as solid fills with the stipple's foreground color. If true stipple support is needed later, it can be implemented as a repeating texture pattern.

### Xwidget compositing

Xwidgets (`XWIDGET_GLYPH`) render as `NSView` subviews of `EmacsView`. When `EmacsView`'s backing layer becomes `CAMetalLayer`, xwidget subviews are composited on top by AppKit's normal view compositing. No special Metal handling needed — AppKit handles the layer tree. Verify during implementation that z-ordering is correct.

## Integration Points

### Files modified

| File | Change |
|------|--------|
| `macterm.c` | All drawing functions rewritten to call `emacs_metal_*` API |
| `macfont.m` | `macfont_draw()` calls `emacs_metal_draw_glyphs()` |
| `macappkit.m` | `EmacsView` gets `CAMetalLayer`; `EmacsBacking` removed |
| `macappkit.h` | `mac_output`: remove `cg_context`, add `metal_ctx` |
| `macterm.h` | Update `mac_output` struct |
| `image.c` / `macterm.c` | Image rendering via `MTLTexture` |
| `configure.ac` | `--with-metal-rendering` flag |
| `Makefile.in` | Add `macmetal.o`, link Metal frameworks |

### Files added

| File | Purpose |
|------|---------|
| `src/macmetal.h` | C API header |
| `src/macmetal.m` | Metal renderer implementation |

### Key macro replacements

| Current (CG) | Metal replacement |
|---|---|
| `MAC_BEGIN_DRAW_TO_FRAME(f, gc, rect, context)` | `emacs_metal_frame_begin()` (once in `mac_update_begin`) |
| `CGContextFillRect(context, rect)` | `emacs_metal_fill_rect(ctx, ...)` |
| `CGContextShowGlyphsAtPositions(...)` | `emacs_metal_draw_glyphs(ctx, ...)` |
| `[backing swapBuffers]` | `emacs_metal_frame_end(ctx)` |

### Unchanged

- `xdisp.c`, `dispnew.c` — display engine untouched
- `macfont.m` shaping/layout code — only `macfont_draw` changes
- All Lisp-level APIs
- GCD drawing queue removed (Metal command buffers are inherently async)

## Build System

### Configure

```
--with-metal-rendering    Use Metal for all rendering (macOS 14+)
```

- Verify macOS 14+ SDK: `__MAC_OS_X_VERSION_MAX_ALLOWED >= 140000`
- Detect Metal: `AC_CHECK_HEADER([Metal/Metal.h])`
- Define `USE_METAL_RENDERING=1`
- Link: `-framework Metal -framework MetalKit -framework QuartzCore`
- Supersedes `HAVE_MAC_METAL`

### Conditional compilation

```c
#ifdef USE_METAL_RENDERING
  emacs_metal_fill_rect(FRAME_METAL_CTX(f), x, y, w, h, gc->xgcv.foreground);
#else
  /* existing CG code */
#endif
```

## Risk Assessment

### Partial redraw correctness
Emacs assumes previous frame content persists. The retained backbuffer handles this. Remove `cg_context` from `mac_output` under `USE_METAL_RENDERING` so missed call sites fail to compile.

### Glyph atlas memory pressure
2048x2048 atlas holds ~7000 glyphs at 12pt@2x. Multiple atlas pages for overflow. Full eviction as escape valve. Counter exposed via Lisp for debugging.

### Drawing order / clipping correctness
Batch breaks on clip rect changes enforce ordering. Within a clip region, Emacs draws back-to-front naturally.

### Thread safety
Remove GCD drawing queue under `USE_METAL_RENDERING`. All vertex buffer accumulation on main thread. GPU execution async via command buffer commit.

### Live resize flicker
Reallocate backbuffer, blit old content. `presentsWithTransaction = YES` during live resize.

### Performance regression on trivial frames
Metal setup overhead (command buffer, render encoder, drawable acquisition) should be minimal on Apple Silicon. Measure early. Target is large/complex frames.

### Metal device creation failure
`MTLCreateSystemDefaultDevice()` returns nil in VMs without GPU passthrough. Since `--with-metal-rendering` is a compile-time flag with no CG fallback, this is a hard failure at startup. Emit a clear error message: "Metal GPU not available. Build without --with-metal-rendering to use Core Graphics." This is acceptable — the flag is opt-in and targets macOS 14+ on real hardware.

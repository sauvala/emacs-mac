# emacs-mac Performance Findings

This note captures potential performance work for the emacs-mac fork. It
assumes upstream Emacs will handle incremental garbage collection, so the focus
here is mac-port-specific interactive latency: scrolling, typing, redisplay,
large-buffer navigation, image rendering, and GUI event responsiveness.

## Priority Recommendations

### 1. Finish and harden the Metal renderer

The current Metal path is promising, but still has avoidable costs.

- `src/macmetal.m:484` creates a fresh `MTLBuffer` with `newBufferWithBytes` in
  `flush_render_batches`, even though the context already owns reusable vertex
  buffers. This adds allocation and copy overhead on a hot path.
- `src/macmetal.m:563` presents by blitting the persistent backbuffer into the
  drawable each frame. That is simple and preserves scroll state, but it makes
  every presentation pay a full texture copy.

Recommended work:

- Use the existing reusable vertex-buffer ring directly in render encoders.
- Move from double buffering to triple buffering if GPU/CPU synchronization
  shows stalls.
- Render directly to the drawable where possible.
- Keep the persistent backbuffer only where it materially helps scroll
  preservation.
- Add Metal counters for batches, vertices, texture uploads, flushes, blits,
  and command-buffer latency.

### 2. Make glyph rendering more cache-aware

The Metal glyph atlas rasterizes one glyph at a time through CoreText and uses a
coarse cache policy.

- `src/macmetal.m:862` rasterizes individual glyphs on cache miss.
- `src/macmetal.m:867` clears the entire glyph cache and all atlas pages when
  the entry table is nearly full.
- `src/macmetal.m:931` and `src/macmetal.m:961` allocate temporary pixel buffers
  per missed glyph.
- `src/macmetal.m:982` uploads each missed glyph separately with
  `replaceRegion`.

Recommended work:

- Add reusable scratch buffers for glyph rasterization.
- Batch atlas uploads where practical.
- Replace whole-cache reset with LRU or clock eviction.
- Track font-generation invalidation instead of relying only on font pointer
  identity.
- Prewarm ASCII and common glyphs for active font faces.
- Consider separate atlases by scale and font class to reduce churn.

### 3. Reduce per-glyph-string allocation and metric work

`macfont_draw` does per-call allocation and repeated metric lookup in a hot text
rendering path.

- `src/macfont.m:2918` allocates glyph arrays per draw call.
- `src/macfont.m:2924` allocates positions per draw call.
- `src/macfont.m:2931` calls `macfont_glyph_extents` inside the per-glyph loop.
- `src/macfont.m:2952` builds another stack array for Metal x positions.

Recommended work:

- Introduce a per-frame or per-thread scratch arena for glyph and position
  arrays.
- Use stack storage for short glyph strings and scratch storage for longer
  runs.
- Cache glyph advances/extents by font, glyph, antialias mode, and scale.
- Avoid building duplicate intermediate arrays when the Metal path can consume
  the existing glyph/position data.

### 4. Avoid transient image texture uploads

Ordinary image glyphs have a Metal texture cache, but some image drawing paths
still upload and destroy textures per call.

- `src/macterm.c:2078` caches `s->img->metal_texture` for regular image glyphs.
- `src/macterm.c:265` uploads a `CGImageRef` to a Metal texture in
  `mac_draw_cg_image`.
- `src/macterm.c:275` destroys that texture immediately after drawing.
- `src/macmetal.m:1340` converts each `CGImageRef` through a temporary bitmap
  before upload.

Recommended work:

- Add a small texture cache for transient `CGImageRef` users.
- Include scale, mask/fill color, and transform flags in the cache key.
- Keep special handling for image masks such as fringe bitmaps.
- Track texture upload counts and bytes per frame.

### 5. Improve Metal clipping fidelity and batching

The Metal path currently converts multi-rect clipping into one union scissor.

- `src/macterm.c:134` reads clip rectangles from the GC.
- `src/macterm.c:140` starts with the first rect and unions the rest.
- `src/macterm.c:150` sets a single Metal clip rectangle.

This can overdraw significantly when damage is fragmented across rows, windows,
fringes, or modelines.

Recommended work:

- Preserve multi-rect clipping through the Metal batching layer.
- Emit repeated scissored batches for complex clip regions.
- Group batches by compatible pipeline, texture, and clip state.
- Measure overdraw by comparing union area against original clip area.

## Larger Refactors

### Dirty-region driven rendering

Emacs redisplay already knows much of the damage information. The mac port could
carry that information deeper into the renderer.

Recommended work:

- Add a mac-port damage accumulator with precise dirty rectangles.
- Combine adjacent text-row damage.
- Skip full-frame presentation work where possible.
- Avoid redrawing stable margins, fringes, and modelines.
- Feed damage into both Core Graphics and Metal paths where reasonable.

### Row/run-level text batching

Instead of drawing each glyph string through many small calls, translate each
redisplay row into compact render commands:

- background rectangles
- glyph runs
- underline, wave, strike-through, and box primitives
- images
- cursor and fringe primitives

This is a larger architectural change, but it better matches GPU rendering and
could also make Core Graphics drawing more coherent.

### Event-loop latency instrumentation and simplification

GUI/Lisp thread synchronization and select emulation are complex and likely
contribute to perceived latency.

- `src/macappkit.m:16820` defines the GUI/Lisp semaphores.
- `src/macappkit.m:16926` synchronously transfers work to the GUI thread.
- `src/macappkit.m:17168` implements `mac_select`.
- `src/macappkit.m:17254` runs the GUI event loop while coordinating with Lisp
  select handling.

Recommended instrumentation:

- Time spent waiting in `mac_select`.
- Time from input event arrival to command dispatch.
- Time from buffer modification to frame presentation.
- Number of GUI/Lisp semaphore round trips per frame.
- Number of run-loop wakeups that do not produce useful work.

After measuring, consider replacing parts of the socketpair/select choreography
with a tighter dispatch/run-loop integration on modern macOS, while preserving
legacy behavior only where needed.

### Modern macOS baseline cleanup

If the fork can raise its minimum supported macOS version, old compatibility
branches can be removed or isolated. That could simplify drawing, run-loop
handling, toolbar validation behavior, layer-backed assumptions, and future
Metal work.

## Benchmark Harness

Before major changes, add repeatable benchmarks that exercise mac-port-specific
paths:

- Scroll a huge source file.
- Render long mixed-script lines.
- Render emoji-heavy buffers.
- Show many inline images.
- Stress modeline, fringe, cursor, and highlight updates.
- Measure typing latency under LSP, Flymake, and syntax-highlighting load.
- Compare Core Graphics and Metal builds under identical workloads.

Useful counters:

- frame time
- redisplay time
- draw time
- present time
- glyph cache hit/miss rate
- texture upload count and bytes
- batch count
- vertex count
- clip union overdraw ratio
- event-to-present latency

## Suggested Order

1. Add instrumentation and benchmark scenarios.
2. Remove obvious Metal allocation and copy costs.
3. Improve glyph cache allocation, eviction, and upload behavior.
4. Reduce `macfont_draw` allocation and repeated metric work.
5. Add transient image texture caching.
6. Improve clipping and dirty-region propagation.
7. Revisit event-loop architecture based on latency traces.

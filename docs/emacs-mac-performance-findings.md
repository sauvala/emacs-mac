# emacs-mac Performance Findings

This note captures potential performance work for the emacs-mac fork. It
assumes upstream Emacs will handle incremental garbage collection, so the focus
here is mac-port-specific interactive latency: scrolling, typing, redisplay,
large-buffer navigation, image rendering, and GUI event responsiveness.

## Current Status

The first wave of Metal renderer performance work is now in the `nemesis`
history.  The plan checklist in `docs/superpowers/plans/2026-03-23-metal-gpu-rendering.md`
is stale; use this section as the current summary.

Completed:

- `cb6b83789ad` — optimized Metal batch vertex buffers so batch flushing uses
  the existing reusable vertex-buffer ring instead of allocating a fresh
  `MTLBuffer` on each flush.
- `43bb05cfdeb` — added reusable glyph raster scratch storage, avoiding
  temporary pixel-buffer allocation on each glyph cache miss.
- `2f3537a38e6` — avoided heap allocation for short `macfont_draw` glyph runs.
- `c97e99adb33` — let the Metal path consume Mac glyph run positions directly,
  avoiding a duplicate intermediate position array.
- `0ef92d7e80e` — added a small transient `CGImageRef` texture cache for image
  paths that do not have a persistent `struct image` texture.
- `ff922ca35cc` — exposed Metal clip union overdraw statistics.
- `09d84b4d84d` — preserved multi-rect clipping through Metal batching instead
  of always collapsing to one union scissor.
- `6f888f45119` — added AppKit `mac_select` latency statistics.
- `29000c3cf02` — exposed Metal renderer counters for frames, flushes, batches,
  vertices, blits, texture uploads, and command-buffer timing.
- `445d8a98e2f` — added the mac performance benchmark harness.
- `944ea879dc2` — replaced whole glyph-cache reset under entry-table pressure
  with incremental entry eviction.
- Added Metal glyph cache hit/miss counters to `mac-metal-render-stats`, with
  source-invariant tests.

Still open:

- Decide whether the retained backbuffer should keep doing a full drawable blit
  every frame, or whether some paths can render directly to the drawable.
- Investigate triple buffering only if the new command-buffer timing counters
  show CPU/GPU stalls.
- Batch glyph atlas uploads where practical.
- Track font-generation invalidation instead of relying only on `CTFontRef`
  pointer identity in the glyph cache key.
- Consider ASCII/common-glyph prewarming for active font faces.
- Consider separate glyph atlases by scale and font class if churn remains high.
- Cache glyph advances/extents by font, glyph, antialias mode, and scale if
  profiling still shows repeated metric work in `macfont_draw`.
- Add dirty-region driven rendering and row/run-level batching as larger
  follow-up refactors.
- Use the new event-loop latency stats to decide whether the
  socketpair/select/run-loop choreography needs simplification.

## Priority Recommendations

### 1. Finish and harden the Metal renderer

The current Metal path is promising, and some of the original hot-path costs
have been removed.

Done:

- `cb6b83789ad` removed the fresh `MTLBuffer` allocation/copy from
  `flush_render_batches`; draws now encode from the context-owned vertex-buffer
  ring.
- `29000c3cf02` added counters for batches, vertices, texture uploads, flushes,
  blits, and command-buffer latency.

Remaining work:

- Move from double buffering to triple buffering if GPU/CPU synchronization
  shows stalls.
- Render directly to the drawable where possible.
- Keep the persistent backbuffer only where it materially helps scroll
  preservation.

### 2. Make glyph rendering more cache-aware

The Metal glyph atlas rasterizes one glyph at a time through CoreText and uses a
coarse cache policy, but the worst allocation and eviction behavior has been
improved.

Done:

- `43bb05cfdeb` added reusable scratch buffers for glyph rasterization.
- `944ea879dc2` replaced whole-cache reset with incremental cache-entry
  eviction.
- Added glyph cache hit/miss counters to `mac-metal-render-stats`.

Remaining work:

- Batch atlas uploads where practical.
- Track font-generation invalidation instead of relying only on font pointer
  identity.
- Prewarm ASCII and common glyphs for active font faces.
- Consider separate atlases by scale and font class to reduce churn.

### 3. Reduce per-glyph-string allocation and metric work

`macfont_draw` does per-call allocation and repeated metric lookup in a hot text
rendering path.

Done:

- `2f3537a38e6` added stack storage for short glyph strings.
- `c97e99adb33` avoided building duplicate Metal x-position arrays by consuming
  existing glyph position data.

Remaining work:

- Introduce a per-frame or per-thread scratch arena for glyph and position
  arrays for longer runs if profiling shows those allocations still matter.
- Cache glyph advances/extents by font, glyph, antialias mode, and scale.

### 4. Avoid transient image texture uploads

Ordinary image glyphs have a Metal texture cache, but some image drawing paths
used to upload and destroy textures per call.

Done:

- `0ef92d7e80e` added a small texture cache for transient `CGImageRef` users.
- The cache key includes the image pointer, dimensions, and mask/fill color.
- `29000c3cf02` tracks texture upload counts and bytes per frame.

Remaining work:

- Include transform flags in the transient texture cache key if a transformed
  path starts sharing cached textures incorrectly.
- Keep special handling for image masks such as fringe bitmaps.

### 5. Improve Metal clipping fidelity and batching

The Metal path originally converted multi-rect clipping into one union scissor.

Done:

- `ff922ca35cc` added exact-vs-union overdraw counters.
- `09d84b4d84d` preserved multi-rect clipping through the Metal batching layer
  and replays compatible batches through each active scissor.

Remaining work:

- Use the overdraw counters to decide whether further dirty-region propagation
  is worth the complexity.
- Continue grouping batches by compatible pipeline, texture, and clip state as
  new drawing paths are added.

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

Done:

- `6f888f45119` added AppKit select latency statistics.

Remaining instrumentation:

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

`445d8a98e2f` added a repeatable benchmark harness.  Keep extending it with
scenarios that exercise mac-port-specific paths:

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
- texture upload count and bytes (`29000c3cf02`)
- batch count (`29000c3cf02`)
- vertex count (`29000c3cf02`)
- clip union overdraw ratio (`ff922ca35cc`)
- event-to-present latency

## Suggested Order

1. Run the benchmark harness across Core Graphics and Metal builds to establish
   post-optimization baselines.
2. Use command-buffer timing to decide whether triple buffering or direct
   drawable rendering is worth pursuing.
3. Improve glyph atlas behavior: batched uploads, font-generation invalidation,
   optional prewarming, and scale/font-class atlas separation.
4. Profile `macfont_draw` again before adding metric caches or longer-run
   scratch arenas.
5. Investigate dirty-region driven rendering and row/run-level batching.
6. Revisit event-loop architecture based on latency traces.

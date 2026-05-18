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
- Added split Metal blit counters for presentation vs scroll-preservation
  copies while preserving aggregate blit counters.
- Added Metal `nextDrawable` wait counters so renderer statistics can separate
  layer drawable acquisition time from command-buffer execution time.
- Added experimental Metal layer pacing controls for display synchronization
  and maximum drawable count.  They are intended for measurement, not yet as
  user-facing tuning policy.
- Added a `backbuffer_dirty` guard so Metal update cycles that do not change
  the retained backbuffer skip drawable acquisition and the full presentation
  blit.
- Added a bounded direct scroll-copy path for Metal axis-aligned scrolls.  It
  splits the copy into ordered non-overlapping chunks to avoid the staging
  texture when the chunk count is small.
- Added a first coalesced/asynchronous Metal presentation path.  Changed frames
  still flush drawing into the retained backbuffer synchronously, but
  backbuffer-to-drawable presentation now runs from a scheduled main-queue task
  with coalescing and final-present rescheduling counters.
- A 2026-05-18 benchmark run showed that the first main-queue presentation
  prototype is not the right final shape: it coalesces presentations, but
  `nextDrawable` still blocks the main event loop from the scheduled task and
  text-heavy elapsed times regress.
- `6f888f45119` — added AppKit `mac_select` latency statistics.
- `29000c3cf02` — exposed Metal renderer counters for frames, flushes, batches,
  vertices, blits, texture uploads, and command-buffer timing.
- `445d8a98e2f` — added the mac performance benchmark harness.
- Added a scheduled unattended GUI benchmark runner,
  `mac-performance-run-benchmarks-and-exit`, that starts after frame setup,
  writes result/progress files, and exits with a status code.
- `944ea879dc2` — replaced whole glyph-cache reset under entry-table pressure
  with incremental entry eviction.
- `8636b60dd34` — added Metal glyph cache hit/miss counters to
  `mac-metal-render-stats`, with source-invariant tests.

Still open:

- Decide whether the retained backbuffer should keep doing a full drawable blit
  after changed frames, or whether some paths can render directly to the
  drawable.  Partial dirty-rect copies to `CAMetalDrawable` are not safe by
  themselves because drawable contents are transient.
- Rework the coalesced/asynchronous Metal presentation prototype so drawable
  acquisition no longer runs as a blocking main-queue task.  The first
  main-queue version did not remove `CAMetalLayer nextDrawable` wait from the
  main event loop.
- Re-measure before spending more time on display-sync or maximum-drawable-count
  tuning; the 2026-05-17 benchmark runs did not show meaningful elapsed-time
  improvement from either knob before presentation coalescing.
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

- Rework and harden the coalesced/asynchronous presentation path so redisplay
  can update the retained backbuffer without the main event loop synchronously
  waiting for every layer drawable.  The first main-queue task prototype
  coalesces requests but still blocks the main queue during drawable acquisition.
- Render directly to the drawable where possible.
- Keep the persistent backbuffer only where it materially helps scroll
  preservation.

Recommended next implementation:

- The first implementation keeps drawing into the retained backbuffer
  synchronous.  `emacs_metal_frame_end`
  should still flush all pending batches before returning so Emacs redisplay
  state remains deterministic.
- Presentation is now split from frame drawing.  After a changed frame is
  flushed into the retained backbuffer, mark presentation pending and schedule
  one presentation task instead of immediately blocking in
  `emacs_metal_frame_end` on `CAMetalLayer nextDrawable`.
- The 2026-05-18 benchmark shows that scheduling the task on the main queue is
  insufficient; the next prototype should keep the same coalescing/final-present
  state machine but move drawable acquisition and presentation command
  submission off the main event loop if `CAMetalLayer` usage remains correct.
- Coalesce bursty redisplay.  If another redisplay cycle updates the retained
  backbuffer before the scheduled presentation task runs, keep one pending task
  and present only the newest retained backbuffer contents.
- If an update arrives while a presentation task is already acquiring a drawable
  or submitting a command buffer, mark that another present is needed and
  schedule one more task after the current presentation completes.  This keeps a
  final-present guarantee after redisplay bursts.
- Keep context lifetime explicit.  Context destruction must invalidate pending
  presentation work before freeing textures, the command queue, or the
  `CAMetalLayer` reference.
- Start with full backbuffer-to-drawable copies in the async task.  Direct
  drawable rendering and dirty-region presentation should remain separate
  follow-up experiments.
- Add counters for requested presentations, coalesced/skipped presentation
  requests, async presentation task runs, and final-present reschedules.  Compare
  these with `nextDrawable` wait time to confirm the main thread is no longer
  paying the full drawable wait on every changed redisplay cycle.

Success criteria for the first pass:

- Text-heavy benchmark scenarios should show a material elapsed-time reduction
  versus the 2026-05-17 Metal default baseline while preserving correct final
  frame contents.
- `nextDrawable` wait may still exist, but it should move out of the tight
  redisplay path enough that mixed-script, emoji, and modeline/fringe get closer
  to Core Graphics.
- No change should rely on disabling display synchronization or forcing
  `maximumDrawableCount` to 3, since those knobs were already measured and did
  not materially close the gap.

### 2. Make glyph rendering more cache-aware

The Metal glyph atlas rasterizes one glyph at a time through CoreText and uses a
coarse cache policy, but the worst allocation and eviction behavior has been
improved.

Done:

- `43bb05cfdeb` added reusable scratch buffers for glyph rasterization.
- `944ea879dc2` replaced whole-cache reset with incremental cache-entry
  eviction.
- `8636b60dd34` added glyph cache hit/miss counters to
  `mac-metal-render-stats`.

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

Current benchmark status:

- Isolated Core Graphics and Metal builds from `8636b60dd34` both complete with
  `--without-rsvg --without-xwidgets --without-mailutils
  --without-native-compilation`; the Metal build compiles `macmetal.o` and links
  successfully with `--with-metal-rendering`.
- The main checkout's current configured build is blocked before the changed
  mac files by a local missing `librsvg/rsvg.h` header.  Reconfigure without
  librsvg or reinstall librsvg before using that checkout for fresh baselines.
- Automated GUI startup should use
  `mac-performance-run-benchmarks-and-exit`, which schedules the benchmark with
  `run-with-timer` after frame setup.  A one-iteration smoke run completes and
  writes result/progress files; run full Core Graphics and Metal baselines with
  this entry point or interactively via `mac-performance-run-benchmarks`.
- A 120-iteration scheduled baseline run completed for the isolated Core
  Graphics and Metal builds on 2026-05-17.  Single-run elapsed seconds:

  | Scenario | Core Graphics | Metal |
  | --- | ---: | ---: |
  | scroll-source | 0.091 | 0.134 |
  | mixed-script | 0.048 | 0.170 |
  | emoji | 0.035 | 0.129 |
  | inline-images | 0.312 | 0.317 |
  | modeline-fringe | 0.121 | 1.007 |

- The initial Metal run did not show obvious command-buffer stalls in this
  small sample: max command-buffer time was about 0.84 ms outside
  modeline/fringe and about 2.04 ms in modeline/fringe.  The first suspicious
  signal was retained backbuffer traffic: modeline/fringe reported 357 blits
  and about 1.46 GB of blit bytes.
- A first safe reduction is now implemented: no-op Metal update cycles leave
  `backbuffer_dirty` clear and return before `nextDrawable`, avoiding a full
  retained-backbuffer presentation blit.  Changed frames still need the full
  backbuffer-to-drawable copy until a direct-drawable or retained-drawable design
  exists.
- A same-session 120-iteration rerun after rebuilding the Metal executable with
  split blit counters and no-op presentation suppression showed no elapsed-time
  improvement in the existing scenarios, because they all perform changed-frame
  redisplay:

  | Scenario | Core Graphics | Metal | Metal/CG |
  | --- | ---: | ---: | ---: |
  | scroll-source | 0.093 | 0.130 | 1.39x |
  | mixed-script | 0.045 | 0.170 | 3.77x |
  | emoji | 0.036 | 0.128 | 3.54x |
  | inline-images | 0.311 | 0.309 | 0.99x |
  | modeline-fringe | 0.122 | 1.008 | 8.25x |

- The split counters refine the retained-backbuffer diagnosis.  In
  `modeline-fringe`, the aggregate 357 blits and about 1.40 GiB of blit traffic
  split into 121 presentation blits / about 631 MiB and 236 scroll-preservation
  blits / about 765 MiB.  The next optimization target should therefore include
  scroll-preservation backbuffer copies, not just full-drawable presentation.
- A follow-up Metal rerun with bounded direct scroll-copy chunks cut
  `modeline-fringe` scroll-preservation traffic from about 765 MiB to about
  382.5 MiB and total blit traffic from about 1.40 GiB to about 1.01 GiB.  The
  elapsed time changed only from 1.008 s to 1.005 s in this single run, while
  scroll blit commands increased from 236 to 357.  This confirms byte traffic
  was reduced, but it does not yet prove an interactive latency win.
- The same Metal run does not make glyph-cache churn look urgent: reported
  glyph-cache misses were 1 in scroll-source and 0 in the other scenarios.
  Batched atlas uploads, ASCII prewarming, and atlas separation should wait for
  traces that show materially higher miss or upload pressure.
- A follow-up rebuild added `nextDrawable` timing counters.  The 2026-05-17
  text-heavy benchmark gap is dominated by drawable acquisition waits, not by
  command-buffer execution:

  | Scenario | Metal seconds | `nextDrawable` wait | Command-buffer wait |
  | --- | ---: | ---: | ---: |
  | scroll-source | 0.130 | 41.1 ms | 9.2 ms |
  | mixed-script | 0.171 | 114.4 ms | 9.7 ms |
  | emoji | 0.129 | 88.8 ms | 7.4 ms |
  | inline-images | 0.314 | 0.2 ms | 8.3 ms |
  | modeline-fringe | 1.009 | 694.6 ms | 98.8 ms |

- Disabling `CAMetalLayer` display synchronization did not materially improve
  elapsed time in the same 120-iteration run:

  | Scenario | Sync on | Sync off |
  | --- | ---: | ---: |
  | scroll-source | 0.130 | 0.134 |
  | mixed-script | 0.171 | 0.171 |
  | emoji | 0.129 | 0.129 |
  | inline-images | 0.314 | 0.307 |
  | modeline-fringe | 1.009 | 1.025 |

- Forcing `maximumDrawableCount` to 3 was also not enough to make Metal
  competitive with Core Graphics in text-heavy scenarios:

  | Scenario | Core Graphics | Metal default | Metal drawable count 3 |
  | --- | ---: | ---: | ---: |
  | scroll-source | 0.093 | 0.130 | 0.131 |
  | mixed-script | 0.045 | 0.171 | 0.170 |
  | emoji | 0.036 | 0.129 | 0.129 |
  | inline-images | 0.311 | 0.314 | 0.314 |
  | modeline-fringe | 0.122 | 1.009 | 1.006 |

- The likely high-impact path for text-heavy competitiveness is therefore not
  glyph-cache work, display-sync toggling, or simple triple buffering.  It is a
  presentation architecture change: update the retained backbuffer during
  redisplay, but coalesce or asynchronously perform drawable acquisition and
  presentation so benchmark-style tight redisplay loops do not synchronously
  wait for the display layer on every changed frame.  That needs careful
  lifetime handling for the frame/context and a final-present guarantee after a
  burst of updates.
- A 2026-05-18 120-iteration run of the first main-queue coalesced presentation
  prototype completed with `--with-metal-rendering --without-rsvg
  --without-xwidgets --without-mailutils --without-native-compilation`.  It
  reduced the number of presentation tasks relative to redisplay requests, but
  elapsed time regressed in text-heavy scenarios because `nextDrawable` still
  ran on the main event loop:

  | Scenario | 2026-05-17 Metal default | Main-queue coalesced prototype | Prototype/default |
  | --- | ---: | ---: | ---: |
  | scroll-source | 0.130 | 0.227 | 1.75x |
  | mixed-script | 0.171 | 0.320 | 1.87x |
  | emoji | 0.129 | 0.226 | 1.75x |
  | inline-images | 0.314 | 0.324 | 1.03x |
  | modeline-fringe | 1.009 | 1.904 | 1.89x |

  Presentation counters from the same run:

  | Scenario | Requests | Coalesced | Task runs | Final reschedules | `nextDrawable` wait |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | scroll-source | 16 | 1 | 16 | 1 | 86.2 ms |
  | mixed-script | 22 | 3 | 21 | 2 | 188.5 ms |
  | emoji | 16 | 1 | 16 | 1 | 131.7 ms |
  | inline-images | 16 | 1 | 15 | 0 | 0.2 ms |
  | modeline-fringe | 123 | 13 | 116 | 5 | 1282.6 ms |

  This is useful negative evidence: simply moving presentation out of
  `emacs_metal_frame_end` is not enough if the scheduled task still performs
  drawable acquisition on the main queue.  The coalescing state machine and
  counters are still useful, but the next experiment should move the blocking
  presentation work off the main event loop or otherwise make `nextDrawable`
  non-blocking from Emacs's perspective.
- Follow-up 2026-05-18 variant runs support that diagnosis.  Setting
  `maximumDrawableCount` to 3 did not materially change the prototype results,
  while disabling `displaySyncEnabled` made `nextDrawable` wait mostly
  disappear and reduced text-heavy elapsed time:

  | Scenario | Prototype default | `maximumDrawableCount = 3` | `displaySyncEnabled = nil` |
  | --- | ---: | ---: | ---: |
  | scroll-source | 0.227 | 0.226 | 0.126 |
  | mixed-script | 0.320 | 0.318 | 0.119 |
  | emoji | 0.226 | 0.210 | 0.108 |
  | inline-images | 0.324 | 0.324 | 0.338 |
  | modeline-fringe | 1.904 | 1.956 | 0.660 |

  With display sync disabled, cumulative `nextDrawable` wait fell from
  86.2/188.5/131.7/1282.6 ms to 9.1/12.1/13.7/2.2 ms for
  scroll-source/mixed-script/emoji/modeline-fringe respectively, but
  command-buffer completion time rose sharply.  That makes display sync
  disabling a diagnostic, not a policy fix: it confirms the main-queue
  prototype is blocked by display pacing, but it does not preserve the intended
  synchronized presentation behavior.

Useful counters:

- frame time
- redisplay time
- draw time
- present time
- `nextDrawable` wait time
- presentation request, coalesced request, task run, and final-reschedule counts
- glyph cache hit/miss rate
- texture upload count and bytes (`29000c3cf02`)
- batch count (`29000c3cf02`)
- vertex count (`29000c3cf02`)
- presentation vs scroll-preservation blit count and bytes
- clip union overdraw ratio (`ff922ca35cc`)
- event-to-present latency

## Suggested Order

1. Rework the coalesced presentation prototype so `nextDrawable` and the
   backbuffer-to-drawable presentation command do not block the main event loop,
   then rerun the 120-iteration benchmark and inspect the existing presentation
   coalescing counters alongside `nextDrawable` wait time.
2. Compare bounded direct scroll-copy chunks against the staging path with
   repeated runs and interactive traces.  Keep the chunked path only if the
   lower byte traffic does not regress command-buffer latency on real scrolls.
3. Investigate direct-drawable or dirty-region rendering for changed frames
   after coalesced presentation has been measured.
4. Add a targeted no-op redisplay/presentation benchmark if no-op update cycles
   become a suspected source of interactive latency.
5. Keep font-generation invalidation on the glyph-cache list, but defer
   prewarming, atlas separation, and batched uploads until traces show higher
   miss or upload pressure.
6. Profile `macfont_draw` again before adding metric caches or longer-run
   scratch arenas.
7. Investigate dirty-region driven rendering and row/run-level batching.
8. Revisit event-loop architecture based on latency traces.

# emacs-mac Snappiness Optimization Ideas

Date: 2026-05-30

This note lists practical and more ambitious ideas for making the mac port feel
faster: lower input latency, smoother scrolling, faster visible redisplay, less
main-thread work during process-heavy sessions, and quicker processing of large
data.  It intentionally does not cover incremental garbage collection, since
that work is already being handled upstream.

This is a companion to `docs/emacs-mac-performance-findings.md`, which focuses
mostly on the first Metal renderer benchmark work.  The ideas below look more
broadly at snappiness across rendering, event handling, subprocess output, data
parsing, fontification, file-system operations, and worker-process designs.

## What "snappy" should mean

Optimize for perceived latency before raw throughput:

- Keystroke-to-command latency stays low while subprocesses, LSP, timers, or
  font-lock are busy.
- Scroll input is handled at the user's input rate, with stale work dropped or
  coalesced.
- Visible frame updates are presented at most once per display refresh, but the
  newest state is always eventually shown.
- Large data processing, parsing, image decode, and directory scans make steady
  progress without monopolizing the main Lisp thread.
- Benchmarks report p50, p95, and max latency, not only total elapsed time.

## Current useful hooks and observations

- `test/src/mac-performance-benchmark.el` already exercises scrolling, mixed
  script text, emoji, inline images, and modeline/fringe churn.
- `src/macmetal.m` already separates retained-backbuffer drawing from
  presenter-queue drawable acquisition.  That is a strong foundation for
  coalesced presentation.
- `src/macmetal.h` exposes render, glyph-cache, blit, presentation, and
  `nextDrawable` counters.
- `src/macterm.c` exposes Metal clipping overdraw counters and routes glyph,
  image, rectangle, underline, and scroll operations into the mac renderer.
- `src/macappkit.m` has `mac_select` latency counters and a complex
  socketpair/run-loop/dispatch-source bridge between the Lisp and GUI threads.
- `src/process.c` reads at most `read-process-output-max` bytes per subprocess
  chunk, defaulting to 65536, and has a fast path for the default process
  filter.
- `src/json.c` has a C JSON parser.  In rope-backed buffers,
  `json-parse-buffer` currently linearizes the parsed region before parsing.
- `src/xdisp.c` already has `redisplay-skip-fontification-on-input`, currently
  defaulting to nil, which can avoid unnecessary fontification when Emacs is
  already behind incoming input.
- `src/macterm.c` repeatedly allocates/releases `CFDataRef` clip-rectangle
  storage even for the common one- or two-rectangle glyph clipping case.

## Small wins

### 1. Inline small clip rectangles in `GC`

`mac_set_clip_rectangles` converts one or two `NativeRectangle`s into a newly
allocated `CFDataRef` on every clip update.  Glyph drawing sets and resets clips
very often, so this is a good low-risk hot-path cleanup.

Proposed change:

- Add inline clip storage to `struct _XGC` for the common case, probably two
  `CGRect`s plus a count.
- Keep `CFDataRef` only for larger clip lists.
- Teach `mac_metal_apply_gc_clip`, `mac_begin_cg_clip`, GC copy, and GC free to
  read either inline or heap-backed clips.

Expected effect: less Core Foundation retain/release churn during text drawing,
fringe drawing, and modeline redraws.

First test: add clip set/reset counters and compare the existing
`modeline-fringe` benchmark before and after.

Initial implementation result: `GC` now keeps up to two clip rectangles inline
and exposes `mac-gc-clip-stats`.  Two local 120-iteration GUI runs on
2026-05-30 showed `heap=0` for every benchmark scenario, so the common text,
modeline, fringe, image, and scroll paths no longer allocate `CFDataRef` for
clip storage.  Text-heavy scenarios also skipped substantial redundant clip
sets, for example `scroll-source` skipped 1273 of 4619 set calls and
`modeline-fringe` skipped 1627 of 5828 set calls.  The timing samples were too
noisy to claim a wall-clock improvement without a controlled A/B run, but the
allocation-path result is clear.

### 2. Skip redundant clip and color state changes

Several glyph paths set a clip, draw a small run, then reset it.  Many
consecutive glyph strings on one row often reuse the same clip or colors.

Proposed change:

- Cache the currently applied renderer clip per frame/context.
- Do not call Metal/CG clip setup when the new clip equals the active clip.
- Do the same for solid foreground/background colors where the API currently
  rebuilds or reapplies state.

Expected effect: fewer tiny renderer calls and less state churn in rows with
many faces, cursor highlights, overlays, or composition boundaries.

First test: add counters for clip changes requested, clip changes applied, and
identical clips skipped.

### 3. Make input-aware fontification easier to enable

`redisplay-skip-fontification-on-input` is exactly the kind of tradeoff that
helps perceived smoothness when scrolling or typing outruns redisplay.

Proposed change:

- Add a mac-port experiment or user-facing preset that enables it for GUI frames.
- Consider dynamic behavior: enable during high-frequency wheel/trackpad input,
  then return to precise behavior after a short idle interval.
- Make benchmark scenarios compare default behavior, always-on behavior, and
  scroll-burst-only behavior.

Expected effect: smoother scroll bursts in large source buffers and tree-sitter
buffers by deferring fontification that would be invalidated by the next input.

Risk: transiently less accurate font-lock during fast motion.  That is usually
acceptable if the final idle frame is correct.

### 4. Add keystroke, scroll, and input-to-present tracing

The existing benchmark reports elapsed scenario time.  For snappiness, add
event-latency traces:

- native event timestamp to Emacs input event creation
- input event read to command dispatch
- command start/end
- command end to redisplay start
- redisplay start/end
- frame draw end to presented drawable or layer update
- number of run-loop wakeups that produced no useful Emacs work

Use low-overhead counters in normal builds and optional `os_signpost` events in
debug/performance builds so Instruments can show where p95 latency comes from.

Expected effect: this prevents optimizing the wrong part of a frame.  The prior
Metal work already showed that total `nextDrawable` wait was not the same as
main-thread latency after presentation moved to a presenter queue.

Command-loop/input and native synthetic GUI event injection are complementary:

- Start with command-loop/input benchmarking in
  `test/src/mac-performance-benchmark.el`.  A keyboard macro can run through
  the normal command loop while `pre-command-hook` and `post-command-hook`
  record per-command dispatch latency.  This is low risk, works in batch tests,
  and answers whether command dispatch, hooks, redisplay triggering, or buffer
  modification dominates a typing workload.
- Add native synthetic GUI event injection later, probably behind a mac-only
  testing helper in `src/macappkit.m`, when the command-loop numbers show that
  the native event path needs isolation.  AppKit-level key and scroll injection
  can measure event timestamp to Emacs event creation, focus/window handling,
  input queue wakeups, and run-loop latency.  It is more invasive and more
  brittle than command-loop benchmarking because it depends on the selected
  frame, active window, keyboard layout, and AppKit event routing.

Recommended sequencing: keep both in the plan, but implement command-loop
instrumentation first and treat native synthetic GUI event injection as the
next layer once there is a stable baseline.  The command-loop benchmark gives a
cheap regression signal; the native injection benchmark explains the macOS
event ingress path when that becomes the suspected bottleneck.

Initial local benchmark result: a 120-iteration GUI run on 2026-05-30 added a
`command-loop-input` scenario using `execute-kbd-macro`.  Simple self-insert
dispatch measured `command-loop-command` at p50 0.002 ms, p95 0.003 ms, and max
0.037 ms, with the whole macro at 1.027 ms and the final forced redisplay at
3.453 ms.  That suggests the simple command-loop dispatch path is not the first
suspect for current snappiness work; rendering, redisplay, process drains, and
native event ingress are more useful places to investigate next.

### 5. Add benchmark scenarios for real interactive workloads

Extend `mac-performance-benchmark.el` with workloads that match common "Emacs
feels slow" reports:

- command-loop typing in a large source buffer
- native synthetic key and scroll events into a focused GUI frame
- repeated typing in a large tree-sitter source buffer
- typing while an LSP/jsonrpc server sends diagnostics
- large `*compilation*` or shell process output
- `completion-at-point` with a large candidate set
- Dired opening a very large local directory
- repeated frame resize and Split View resize
- scrolling with many overlays, Flymake diagnostics, hl-line, and display
  properties
- minibuffer completion while process output arrives in another buffer

Expected effect: better prioritization.  Rendering-only benchmarks will miss
process-filter and fontification stalls.

### 6. Make render statistics thread-safe

`src/macmetal.m` now updates render statistics from the main thread, presenter
queue, and Metal completion handlers.  Make counters atomic or per-context with
explicit aggregation.

Expected effect: trustworthy diagnostics.  This probably will not make Emacs
feel faster directly, but it protects later decisions from misleading numbers.

### 7. Tune subprocess chunking adaptively

`read-process-output-max` defaults to 64 KiB.  That is safe, but LSP, terminals,
compilation, and grep-like processes have different needs.

Proposed change:

- Keep small chunks for filters that run expensive Lisp.
- Use larger chunks for default insertion filters and known throughput-heavy
  buffers.
- Add a per-process latency/throughput counter: bytes read, decode time, filter
  time, insert time, and time spent before checking keyboard input again.
- Add a budget so one busy process cannot run filters forever before returning
  to input.

Expected effect: less UI starvation during large output bursts without hurting
bulk process throughput.

### 8. Avoid full JSON rope linearization

In rope-backed buffers, `json-parse-buffer` copies the parsed region into one
linear buffer before parsing.  For large JSON buffers that is extra allocation
and memory bandwidth.

Proposed change:

- Let the JSON parser consume a sequence of rope spans, similar to how it
  already handles a primary and secondary buffer segment around the gap.
- Keep the current linear fallback for simplicity if too many spans are needed.
- Add a direct parser path for process-owned byte buffers if jsonrpc adopts a
  process-buffer ring.

Expected effect: faster JSON parsing for large buffers and less memory pressure
in rope builds.

### 9. Prewarm the obvious glyphs during idle

After a frame's default font and scale are known, prewarm ASCII and common UI
glyphs in the active faces during idle time.

Expected effect: fewer first-scroll or first-command glyph atlas misses.

Risk: previous benchmark notes showed glyph misses were not urgent in the
existing scenarios, so this should be gated by counters and kept idle-only.

### 10. Coalesce stale mouse motion and scroll work more aggressively

Mouse movement is already coarse by default, but trackpad scroll can still
create more work than the user can see.

Proposed change:

- Keep only the newest scroll delta inside a short frame budget when redisplay
  is already behind.
- Preserve semantic events, but drop intermediate pure motion events that have
  been superseded.
- During kinetic scrolling, draw the latest target position instead of every
  intermediate state.

Expected effect: lower p95 scroll latency on busy buffers.

## Medium-sized changes

### 1. Input-priority scheduling inside the command loop

Add explicit "latency checkpoints" in long-running internal loops:

- process output draining
- redisplay/fontification loops
- tree-sitter parse/font-lock loops
- large search/replace loops
- directory scanning

At checkpoints, if GUI input is pending and the current operation is
interruptible, yield back to command/input handling or reduce the remaining
work budget.

Expected effect: keypresses and scroll events feel responsive even when Emacs
is doing useful background work.

Risk: some code assumes a large operation runs to completion.  Start with
places that already tolerate partial work, such as fontification and process
output.

### 2. Time-budgeted process filters

Subprocess filters can run arbitrary Lisp while input waits.  Add optional
cooperative budgeting:

- A process can have a per-drain time budget.
- If the budget expires and more output is available, leave the process
  readable and return to the input loop.
- Resume draining after command handling or redisplay.

Expected effect: LSP, shell, compilation, and terminal buffers stop stealing
long uninterrupted slices from interactive editing.

### 3. Fast path for default process insertion

The default process filter already avoids allocating a Lisp string.  Extend the
same idea:

- Batch multiple adjacent chunks before one buffer modification notification
  when no user filter observes the intermediate state.
- Avoid forcing mode-line updates per chunk when a later chunk arrives
  immediately.
- Preserve marker behavior, narrowing, and hooks for compatibility.

Expected effect: faster `*compilation*`, shell output, and subprocess-heavy
sessions.

### 4. Background image decode and preparation

Inline images and PDF/image document previews can decode or transform on the
critical path.

Proposed change:

- Decode images on a worker thread or helper process into immutable pixel
  buffers.
- Upload Metal textures or create CGImage objects only when the frame actually
  needs them.
- Cache transformed variants by source image, scale, mask, foreground,
  background, and transform flags.

Expected effect: smoother scrolling through image-heavy buffers.

### 5. macOS bulk directory reads

Dired and completion can spend time on many file attributes.  On macOS,
`getattrlistbulk` can fetch directory entries and common attributes in batches.

Proposed change:

- Add a Darwin-specific fast path for local directory scans.
- Use it for `directory-files-and-attributes` and Dired-like operations when
  the requested attribute set fits.
- Fall back to existing portable stat loops for remote, special, or unsupported
  paths.

Expected effect: faster Dired, project file listing, and completion in very
large directories.

### 6. Faster UTF-8, newline, and ASCII scans

Several hot paths count bytes, characters, newlines, or ASCII-ness with scalar
loops.  These show up in file reading, JSON parsing, process decoding, search,
and buffer line calculations.

Proposed change:

- Add portable vectorized helpers where possible, with Darwin/clang SIMD
  specializations guarded cleanly.
- Replace repeated byte-at-a-time scans in JSON, coding, and newline counting
  paths when profiling confirms them.
- Keep scalar fallbacks simple and identical.

Expected effect: faster large data ingestion and parsing.

### 7. Font fallback and metric generation caches

The mac font path already caches some glyphs and metrics, but mixed-script,
emoji, and fallback-heavy buffers are still suspicious.

Proposed change:

- Add counters around `macfont_encode_char`, `macfont_text_extents`,
  `macfont_draw`, Core Text glyph lookup, and fallback lookup.
- Cache fallback decisions by fontset, script/range, variation selector, and
  frame scale.
- Cache glyph advance/extents by font generation, glyph, antialias mode, and
  scale.

Expected effect: smoother mixed-script and emoji-heavy redisplay.

### 8. mac_select wakeup cleanup

`mac_select` is necessarily complex, but it now has enough counters to
investigate wasted wakeups.

Proposed change:

- Use the existing run-loop wakeup counters to identify wakeups without events,
  display work, or process readiness.
- Try a modern macOS-only path that uses a tighter `CFRunLoopSource`,
  dispatch source, or kqueue integration instead of socketpair round trips.
- Keep old behavior behind compatibility guards.

Expected effect: lower idle CPU and lower tail latency around GUI input.

### 9. Adaptive frame pacing

The presenter queue should know when Emacs is producing frames faster than the
display can show them.

Proposed change:

- Keep one pending present per frame/context.
- Coalesce dirty work until the next display interval when input is still
  flowing.
- Present immediately after idle or when a command finishes and no newer frame
  is pending.
- Track final-present guarantees explicitly.

Expected effect: smoother perceived responsiveness during fast scroll and
typing bursts, with fewer wasted presents.

## Larger changes

### 1. Dirty-region and tile-based rendering

The current renderer still tends to operate around full-frame backbuffer state.
A bigger renderer change would make Emacs behave more like a terminal emulator
or browser compositor.

Proposed design:

- Track dirty rectangles from redisplay rows, fringes, mode lines, cursor,
  overlays, and images.
- Merge them into stable tiles or row bands.
- Render only dirty tiles into a retained texture.
- Present only the newest retained state, coalescing updates that arrive before
  the display can show them.

Expected effect: less work for cursor movement, modeline changes, small edits,
and overlay churn.

Risk: damage tracking bugs are visually obvious.  This needs strong screenshot
tests and a debug mode that flashes dirty regions.

### 2. Row command caching

Instead of translating every redisplay result into immediate drawing calls,
build compact render commands per glyph row:

- background rectangles
- glyph runs
- decorations
- images
- cursor/fringe primitives
- clipping metadata

Cache row commands by buffer modification tick, overlay/face generation, window
geometry, font generation, scale, and scroll offset.  If a row is still valid,
the renderer replays commands without recomputing glyph drawing state.

Expected effect: faster repeated redisplay of stable visible text, especially
when only point, cursor, or modeline changes.

### 3. Background tree-sitter parsing and fontification snapshots

Tree-sitter and font-lock are visible sources of perceived latency in modern
Emacs use.  The safe design is to compute off-main and apply only if the buffer
has not changed incompatibly.

Proposed design:

- Main thread creates immutable text snapshots or compact changed ranges.
- Worker process or C worker thread updates tree-sitter parse state and
  computes face spans.
- Main thread applies spans only when the buffer modification tick and parse
  generation still match.
- If input arrives, visible-range work takes priority over background ranges.

Expected effect: typing remains responsive in large source files even when
syntax highlighting is expensive.

Risk: applying stale fontification would be bad, so generation checks must be
strict.  Start with inactive or non-visible ranges before visible text.

### 4. Worker-process pool for pure or snapshot-based tasks

Emacs Lisp threads do not remove the main global-lock bottleneck for arbitrary
Lisp work.  A persistent worker-process pool is safer and more scalable.

Good candidates:

- JSON/LSP message parsing
- tree-sitter parse and query execution on snapshots
- native compilation and byte compilation scheduling
- project file indexing
- directory attribute scans
- image decode and thumbnailing
- grep/consult-style result parsing
- expensive completion candidate preparation

Protocol sketch:

- Main Emacs sends immutable snapshots, file descriptors, or shared-memory
  buffers to workers.
- Workers return compact results plus the source generation they used.
- Main thread applies results only if generations still match.
- Cancellation is cheap: mark older generation results stale.

Expected effect: large background work stops competing directly with typing and
redisplay.

### 5. Shared-memory subprocess and JSON pipeline

For LSP and other JSON-heavy protocols, avoid repeatedly copying data through
process buffers and Lisp strings before parsing.

Proposed design:

- Process reader appends bytes into a ring buffer.
- JSON tokenizer/parser consumes bytes directly from that ring.
- Parsed messages enter Lisp as already-structured objects.
- For huge payloads, strings can reference immutable byte storage until they
  need to become ordinary Lisp strings.

Expected effect: lower latency and allocation pressure for LSP diagnostics,
completion, semantic tokens, and workspace events.

Risk: this is a large semantic boundary.  Keep it opt-in for jsonrpc-like
clients before generalizing process filters.

### 6. Overlay and face-merge acceleration

Modern configurations use many overlays: Flymake/Flycheck diagnostics, LSP
semantic highlighting, hl-line, selection, completion previews, inlay hints,
VC annotations, and org visibility.  Redisplay often pays to merge many small
intervals.

Proposed design:

- Add generation counters for overlay sets and face-merge inputs.
- Cache face results for common overlay stacks.
- Add an interval index optimized for "next visible face change in this row".
- Make visible-region overlay queries avoid scanning irrelevant overlays.

Expected effect: faster redisplay in heavily annotated buffers.

### 7. Lazy file visiting with mmap-backed or rope-backed text

For very large files, opening the file can do too much decoding and copying
upfront.

Proposed design:

- Map large local files as immutable byte pieces.
- Decode visible chunks first.
- Build line and character indexes lazily in the background.
- Materialize editable buffer pieces only when the user modifies them.

Expected effect: much faster open and first display for huge logs and generated
files.

Risk: this touches deep buffer invariants.  It is a major project, but it fits
the goal of perceived speed better than optimizing only normal-size buffers.

### 8. Speculative visible-range redisplay

When the user scrolls, Emacs can predict the next visible range from recent
scroll velocity.

Proposed design:

- During idle or while presenter queue is waiting, prepare glyph rows just past
  the current viewport in the likely scroll direction.
- Throw away predictions if buffer/window generation changes.
- Keep this bounded so it never delays real input.

Expected effect: fewer visible stalls during smooth scrolling.

Risk: wasted work if predictions are wrong.  It must be strictly best-effort.

## Most promising order

1. Add latency instrumentation and benchmark scenarios for command-loop input,
   typing, scroll, process output, jsonrpc, Dired, resize, and overlay-heavy
   buffers; add native synthetic GUI event injection after the command-loop
   baseline is stable.
2. Implement inline small clip rectangles and redundant clip-state skipping.
3. Make Metal render stats thread-safe, then re-baseline presenter-queue Metal
   and Core Graphics across repeated runs.
4. Add input-aware fontification experiments using
   `redisplay-skip-fontification-on-input`.
5. Add process-output latency counters and an adaptive process drain budget.
6. Avoid JSON rope linearization and add JSON/process throughput benchmarks.
7. Investigate `mac_select` useless wakeups with the new counters.
8. Prototype worker-process parsing for jsonrpc or tree-sitter, where stale
   result cancellation is straightforward.
9. Prototype row command caching or dirty-region/tile rendering after the
   measurement suite can catch visual and latency regressions.

## Ideas to avoid for now

- Do not spend more time on simple `displaySyncEnabled` or
  `maximumDrawableCount` toggles as a primary fix.  Earlier Metal notes show
  those knobs are diagnostics, not a complete policy.
- Do not prewarm every glyph or every font.  Prewarm only active faces and only
  when counters show cache misses matter.
- Do not move arbitrary Lisp execution onto threads.  Use worker processes or
  pure C worker threads with immutable inputs.
- Do not optimize only total benchmark elapsed time.  A change that improves
  throughput but worsens p95 input latency can make Emacs feel slower.
- Do not include incremental GC in this plan; assume upstream owns that work.

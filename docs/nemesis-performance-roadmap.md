# Nemesis performance roadmap

Created 2026-09-25 from a measured review of `nemesis` at `879656dd5c9`, after
the persistent AppKit event loop became the only loop.  It complements the
older [findings](emacs-mac-performance-findings.md) and
[idea bank](emacs-mac-snappiness-optimization-ideas.md) documents, which focus
on the Metal renderer.  Fork-local work only; nothing here goes to GNU Emacs.

## Baseline

Measured with [`test/manual/redisplay-bench/perf.el`](../test/manual/redisplay-bench/perf.el).
Setup: development bundle, `emacs -Q`, 200x60 frame, `src/xdisp.c` in `c-mode`.
Each value is `(fn)` plus `(redisplay t)`, single runs.

| Scenario | Default GC (800 KB) | 16 MB threshold | No font-lock |
|---|---|---|---|
| Typing, median / p90 | 4.6 / 12.1 ms | 4.5 / 5.2 ms | 0.9 ms |
| Page scroll into unfontified text, median / p90 | 16.0 / 28.9 ms, 144 GCs per 150 scrolls | 9.4 / 17.5 ms, 7 GCs | 1.4 ms |
| Scroll by one line, median | 1.2 ms | 1.2 ms | 1.1 ms |
| `redraw-frame`, median | 16.7 ms | 16.7 ms | 16.7 ms |

Profile findings (from `sample` on the Lisp thread):

- **GC:** about 40-45% of the Lisp thread's time with the default threshold.
  One collection takes 7-10 ms even in `-Q`.
- **Fontification:** most of the remaining time.  It is dominated by C
  primitives (regexp matching, syntax scanning, text properties), not
  bytecode dispatch.  Native-compiling cc-mode, font-lock and jit-lock
  changed typing latency by only about 3%.
- **Metal drawing:** under 10% of the Lisp thread's time.
- **Regexp cache:** `regex_compile` reached through `compile_pattern` took
  about 3% of typing time; the 20-entry cache thrashes.
- **Idle:** 0.1% CPU and no idle wakeups.  `emacs -Q` starts to its first
  redisplay in 0.43 s.

## Items

Status: `todo`, `in progress`, `done`, `user` (the user handles it outside
this list) or `skip`.

| # | Item | Impact | Effort | Status |
|---|---|---|---|---|
| 1 | GC threshold defaults and idle collection | high | S | skip (user runs gcmh) |
| 2 | Remove the vsync wait when a garbaged frame is redrawn | medium-high | S-M | done (`0bf652222bb`, `3be53d16eb8`) |
| 3 | Merge deferred trackpad scroll events | medium | S | done (`b4724e11c83`) |
| 4 | Native-compile preloaded Lisp again; prune stale ABI directories | low-medium | S | user (manual clean and recompile) |
| 5 | Drop global `-fobjc-arc` and the removed `--enable-mac-persistent-loop` from the configure line | correctness | XS | done (main tree reconfigured 2026-09-25, not yet rebuilt) |
| 6 | Enlarge the regexp cache and hash its lookups | low-medium | XS-S | done (`e365131854d`) |
| 7 | Default `redisplay-skip-fontification-on-input` to t | medium | XS | done (`7d18d47b0fc`) |
| 8 | Benchmark harness on `nemesis` and event-to-screen latency measurement | enabler | S-M | done |
| 9 | Copy only changed regions when presenting | medium (GPU bandwidth, power) | M | todo |
| 10 | Cherry-pick the measured wins from `codex/responsive-coding-bb3c` | medium | M | todo |
| 11 | Profile-guided optimization (PGO) and ThinLTO build | 5-15% CPU | M | todo |
| 12 | Concurrent GC (GNU `feature/igc`, MPS) | high | XL | skip (upstream work; revisit when it merges) |
| 13 | Take fontification off the redisplay path | high | L | todo (long term) |
| 14 | Fix the macOS 27 hit test that sends every mouse and scroll event through AppKit | medium | S-M | done (awaiting the user's trackpad check) |
| 15 | Cheaper menu-bar fills: skip `substitute-command-keys` for plain help strings | low-medium | XS | done |

### 1. GC defaults and idle collection (skipped)

The 800 KB default made almost every fontifying page scroll collect.  The user
already runs gcmh, which covers this.  If it is ever built in: raise the
default threshold for the mac build, and collect after about 1 s of idle or on
focus loss when more than half the threshold has been consed.

### 2. Vsync wait on garbaged-frame redraw

`mac_update_end` in `src/macterm.c` holds the clear that `redraw_frame` does,
through `emacs_metal_frame_end_held`.  Before committing, the held frame calls
`emacs_metal_wait_for_presentation_copy`, which waits for the presenter task.
The presenter blocks in `nextDrawable` until vsync.  So resizes, face and theme
changes, `text-scale` and `redraw-display` each cost the Lisp thread about one
frame.

Fix direction: never wait for drawable acquisition.  When a held frame overlaps
a pending presentation, snapshot the presentable backbuffer on the GPU into a
separate texture, in command-queue order, and present from it.

Keep two things unchanged: a held clear must never reach the screen alone, and
live-resize synchronous presentation (ticket 18) must behave as before.

### 3. Merge deferred scroll events

`mac_loop_send_event` merges consecutive deferred mouse-moved events but queues
every scroll-wheel event on its own.  While Lisp is busy, momentum scrolling
therefore builds a backlog.

Merge compatible precise-delta scroll events by summing their deltas.
Compatible means same window, same modifiers, and the same "changed" phase or
momentum phase.  Never merge across the start or end of a gesture.

### 4. Native compilation of preloaded Lisp

Incremental builds change the native ABI hash while the `.elc` files stay up to
date, so the preloaded `.eln` files are never regenerated.  On 2026-09-25,
`native-lisp/32_0_50-c5eab433/preloaded/` held only `mac-win.eln`, so `simple`,
`subr`, `jit-lock`, `font-lock` and the other preloaded files ran as bytecode.
Fix by cleaning and recompiling.

Possible follow-up: a Makefile check that fails `make install` when
`preloaded/` is nearly empty.  Stale ABI directories (12 in the bundle,
76 MB) and old `src/emacs-32.0.50.N` dumps (1.8 GB) can be removed.

### 5. Configure line

The local `config.status` records
`CFLAGS=-O2 -mcpu=native -fobjc-arc` and `--enable-mac-persistent-loop`.
With ARC applied globally, `macappkit.m` and `macfont.m`, which are written for
manual retain/release, are compiled under ARC.  AGENTS.md scopes ARC to
`macmetal.o` only.  Reconfigure without both flags.

### 6. Regexp cache

`REGEXP_CACHE_SIZE` is 20, and cc-mode's working set is larger.  Raise it to
around 128 and check a cheap hash before the full comparison in
`compile_pattern`, so the longer list does not cost more than it saves.

### 7. Skip fontification on pending input

`redisplay-skip-fontification-on-input` is an upstream variable that defaults
to nil.  Setting it to t gives most of the largest measured win of the old
responsive-coding branch (`bbe583ccc4f`, "Defer jit-lock while input is
pending") without new code.

### 8. Harness and latency measurement

The GUI benchmark harness (`test/src/mac-performance-benchmark.el`) exists only
on `nemesis-gpu`.  Bring it to `nemesis` and add the scenarios from the
baseline above: fontified page scroll, cc-mode typing, `redraw-frame`, and GC
counts.

Also add end-to-end latency.  Record the key event's timestamp
(`NSEvent.timestamp`), and use the drawable's `addPresentedHandler`
presented time to histogram event-to-screen latency.  This is needed before
tuning `maximumDrawableCount`, direct presentation or item 9.

The harness is noisy.  At 30 iterations, run-to-run spread reaches 40-90% of
the median.  Use 120 iterations, alternate the two builds round-robin, and
compare minimums; differences under about 2% are not signal.

Result (2026-09-25):

- `nemesis` already had an older copy of the harness; it now has the
  `nemesis-gpu` version plus `c-page-scroll`, `c-typing` and
  `c-full-redraw` on `src/xdisp.c` in `c-mode` (each step timed with its
  redisplay as the latency bucket `step`, with GC counts and GC time).
  `MAC_BENCH_SCENARIOS` selects scenarios.
- `mac-metal-input-latency` returns key-to-screen latencies: the GUI
  thread notes each key-down's `NSEvent.timestamp`, the next frame
  scheduled for presentation claims it, and the drawable's presented
  handler records `presentedTime` minus that timestamp.  The harness
  posts 120 Control-O keys, 60 ms apart, that insert into xdisp.c.
  First reading at 60 keys: min 25 ms, median 35 ms, p95 58 ms, max
  98 ms, none unpresented.
- The harness runs in a timer, where `current-idle-time` is non-nil, so
  `set_frame_menubar` fills the whole menu bar on every redisplay after
  a window or buffer change instead of deferring it.  That made
  `c-full-redraw` 12 ms with a GC per step; `perf.el`, run from
  `--eval` before the command loop, measures 1.9 ms.  Idle timers that
  change windows pay the same cost in real use.  See item 15.

### 9. Changed-region presentation

Each presentation copies the whole backbuffer to the drawable, roughly
30-60 MB on Retina, even for a one-character change.  Track changed
rectangles per frame.  Drawables rotate among three, so copy the union of the
last three frames' changes.

### 10. Responsive-coding branch

`codex/responsive-coding-bb3c` (95 commits, last touched 2026-07-16) holds
measured wins:

- deferring jit-lock while input is pending (`bbe583ccc4f`), largely covered
  by item 7
- bounded JSON-RPC and Eglot batches (batch size 8 or 16)
- jit-lock deferred-scan batching

Cherry-pick these and measure again.  Leave the async font-lock worker-process
machinery out unless it is re-justified.

### 11. PGO and ThinLTO

Use a two-stage build:

1. Build with `-fprofile-instr-generate`.
2. Run training with the item 8 harness and a test subset.
3. Merge the profiles with `llvm-profdata merge`.
4. Rebuild with `-fprofile-instr-use` and `-flto=thin`.

Expected to help the bytecode interpreter, `display_line`, GC marking and
regexp matching.  Measure with item 8.

### 12. Concurrent GC (skipped)

GNU's MPS branch is being worked on upstream.  When it reaches master, the
weekly sync brings it in.  The mac port then needs an audit of Lisp objects
held in Objective-C instance variables, blocks, CF collections and GCD queues,
and of the GUI thread's try-lock access to Lisp.

### 13. Fontification off the redisplay path

This is how Zed and Neovim stay fast: they parse and highlight on a background
thread and only apply results on the main thread.  A contained version for
Emacs: run tree-sitter parsing (C only, no Lisp) on a worker thread over a
snapshot of the buffer text, and apply faces on the Lisp thread for the visible
range.

### Results so far (2026-09-25)

- **Item 2:** `redraw-frame` plus `(redisplay t)` went from a median of
  16.7 ms to 2.0 ms (p90 17.1 to 2.2 ms), in a round-robin A/B against a build
  with the same configuration; all other scenarios are unchanged.  A held
  frame now snapshots the presentable backbuffer on the GPU instead of waiting
  for the presenter's `nextDrawable`.
  - A second commit fixes a pre-existing bug: internal-border drawing done
    outside an update presented a cleared frame (blank frames recorded 5/0/0
    before, 0 in four runs after).
  - Metal invariants 26/26 pass, `check.sh` passes, and the resize and
    fullscreen scenarios show no long gaps.
  - Follow-up: the snapshot texture (one backbuffer's worth) stays allocated
    after first use.
  - The user tried a test build with items 2, 3, 6 and 7 on 2026-09-25 and
    reported it working.

- **Item 6:** fontifying all of `src/xdisp.c` with cc-mode (`font-lock-ensure`,
  best of 3, three alternating rounds against a baseline differing only in
  `search.c`) went from 4.04-4.19 s to 3.64-3.72 s, about 10% faster.
  Cycling 60 distinct regexps is about 27% faster.  Search, regex, rx,
  syntax, replace, isearch, subr and cc-mode tests pass.
- **Item 3:** the `busy-scroll` scenario merges 20 changed events into one
  (-60 px) and 15 momentum-changed events into one (-30 px), with the total
  preserved and gesture start and end events delivered unmerged and in order.
  `idle-scroll` shows no merging.  The existing scenarios are unchanged; the
  `busy-native` and `stress-requests` gaps of about 0.6 s predate this change
  (see the 2026-09-24 evidence).  The user tried it in the same
  test build and reported it working.

### 14. macOS 27 hit test (found while doing item 3)

`mac_loop_event_emacs_bound_p` converts the event location with
`[frameView.superview convertPoint:...]`.  On macOS 27 the window's frame view
(`NSThemeFrame`) has no superview, so the point becomes (0,0).  The hit test
then lands on the frame view, not the content view.

As a result, every mouse and scroll event goes through AppKit and then the
`EmacsMainView` callback deferral, instead of Emacs's own event path.

Fix direction: pass `event.locationInWindow` straight to `hitTest:` when
there is no superview.  Caveat found with a trial fix: deferred momentum
scroll events replayed through `-[NSWindow sendEvent:]` did not reach Lisp,
with or without item 3's merging.  That has to be solved in the same change.

Result (2026-09-25): the hit test now uses the window point when the frame
view has no superview.  A scroll event that finds Lisp busy still goes to
AppKit at once, and `-[EmacsMainView scrollWheel:]` defers and merges it,
which is the path that already worked; the unused deferral of scroll
NSEvents by `mac_loop_send_event` is gone.

- The wrong hit test also broke `help-echo` from mouse movement, idle or
  busy: a `HELP_EVENT` stored from a view callback only sets `do_help`,
  which only `handleOneNSEvent` acts on.  The new `idle-mouse` and
  `busy-mouse` scenarios (move over text with `help-echo`, then click;
  new `move X Y` test action) failed `help-shown` before and pass after.
- The full scripted matrix passes, `busy-scroll` and `idle-scroll`
  included.  The `busy-native`/`stress-requests` (about 0.6 s) and
  close (about 0.1 s) GUI gaps are as before.
- Real trackpad scrolling, momentum included, still needs the user's
  check.

### 15. Menu-bar fill cost (found while doing item 8)

A deep menu-bar fill parses every menu item, and `parse_menu_item` passes
each item's help string to `substitute-command-keys`, which creates a
buffer per call: 364 calls and about 1.6 MB of allocation per fill with
`emacs -Q`.  Fills happen from the idle timer, on menu open (D3), and on
every redisplay after a window or buffer change while Lisp is idle (in
timers, for example).  Most help strings contain no backslash, grave
accent or apostrophe, the only characters that the function changes.

Result (2026-09-25): `substitute-command-keys` returns such a string
unchanged without a buffer, as its docstring already promised.  In the
`menu-fill-cost` scenario (100 forced fills, three runs each, same build
configuration) a plain fill went from 8.5 to 3.7 ms, one with 200
buffers and six major modes from 14.4 to 7.0 ms, and GCs from 57 to 38.
A redraw in a timer went from 13 to 7 ms.  The help, help-fns,
help-mode, doc and bytecomp tests pass.  This changes an upstream Lisp
file; it is fork-local.

## Not worth doing yet

- **Metal micro-optimizations** (instanced quads, atlas splitting,
  prewarming): drawing is under 10% of the Lisp thread's time.
- **The rope buffer as a speed lever:** buffer text access did not appear in
  any profile.
- **`displaySyncEnabled` and `maximumDrawableCount` tweaks:** already measured
  with no throughput gain.  Revisit only with item 8's latency numbers.

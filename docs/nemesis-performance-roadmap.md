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
| 4 | Native-compile preloaded Lisp again; prune stale ABI directories | low-medium | S | done in the tree (2026-09-25 rebuild); `/Applications` left to the user |
| 5 | Drop global `-fobjc-arc` and the removed `--enable-mac-persistent-loop` from the configure line | correctness | XS | done (main tree rebuilt 2026-09-25 with `mac/pgo-build.sh`) |
| 6 | Enlarge the regexp cache and hash its lookups | low-medium | XS-S | done (`e365131854d`) |
| 7 | Default `redisplay-skip-fontification-on-input` to t | medium | XS | done (`7d18d47b0fc`) |
| 8 | Benchmark harness on `nemesis` and event-to-screen latency measurement | enabler | S-M | done |
| 9 | Copy only changed regions when presenting | low (measured) | M | skip (0.7 ms GPU per present; needs undocumented drawable reuse) |
| 10 | Cherry-pick the measured wins from `codex/responsive-coding-bb3c` | medium | M | done |
| 11 | Profile-guided optimization (PGO) and ThinLTO build | 15-27% CPU (measured) | M | done (`mac/pgo-build.sh`; opt-in) |
| 12 | Concurrent GC (GNU `feature/igc`, MPS) | high | XL | skip (upstream work; revisit when it merges) |
| 13 | Take fontification off the redisplay path | low (measured) | L | planned in stages: all design decisions made 2026-09-26, stage 1 next (see section) |
| 14 | Fix the macOS 27 hit test that sends every mouse and scroll event through AppKit | medium | S-M | done, accepted |
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

Skipped (2026-09-25) after measuring: in a maximized window on the built-in
Retina display (M2), the presentation command buffer's GPU time
(`GPUEndTime - GPUStartTime`) was 0.57-0.74 ms (p95), 3.2 ms at most, over
the `c-typing` scenario.  That runs asynchronously to Lisp and rarely
moves a frame across a refresh.  Copying less would also rely on a
drawable keeping its previous contents, which Core Animation does not
promise.  Revisit only if power measurements point here.

Follow-up from item 2, done the same day: the snapshot texture that a
held frame copies into is now purgeable while no presentation copies
from it or is redirected to it, so the system can reclaim its memory
(one backbuffer's worth); it is made non-purgeable before the next
snapshot.  `redraw-frame` stays at 1.9-2.0 ms.

### 10. Responsive-coding branch

`codex/responsive-coding-bb3c` (95 commits, last touched 2026-07-16) holds
measured wins:

- deferring jit-lock while input is pending (`bbe583ccc4f`), largely covered
  by item 7
- bounded JSON-RPC and Eglot batches (batch size 8 or 16)
- jit-lock deferred-scan batching

Cherry-pick these and measure again.  Leave the async font-lock worker-process
machinery out unless it is re-justified.

Result (2026-09-25): picked with `-x`, in order, the JSON-RPC chain
(`3cf64efda33` through `e92f835442a`, 8 commits), the Eglot semantic-token
chain (`11d1eedb27e`, `c961eb3d08a`, `89966f0a50a`) and the whole jit-lock
chain (`bbe583ccc4f` through `55393d47590`, 10 commits; the later ones build
on `bbe583ccc4f`'s `jit-lock-defer-on-input`, which complements item 7).  No
async font-lock or tree-sitter commits.  The benchmark-harness and findings
hunks of three commits were dropped in favor of the `nemesis` harness, which
lacks their `coding-*`, `jsonrpc-*`, `eglot-*` and `treesit-*` scenarios.

- jsonrpc 22/22, jit-lock 14/14, cc-mode and font-lock tests pass.  Eglot's
  five rust-analyzer tests fail with and without the picks (environment).
- These changes act under input pressure, which the `nemesis` harness does
  not create; `c-typing`, `c-page-scroll` and key latency are unchanged.
- They edit upstream Lisp files (`jsonrpc.el`, `eglot.el`, `jit-lock.el`),
  so the weekly GNU sync may conflict there.

### 11. PGO and ThinLTO

Use a two-stage build:

1. Build with `-fprofile-instr-generate`.
2. Run training with the item 8 harness and a test subset.
3. Merge the profiles with `llvm-profdata merge`.
4. Rebuild with `-fprofile-instr-use` and `-flto=thin`.

Expected to help the bytecode interpreter, `display_line`, GC marking and
regexp matching.  Measure with item 8.

Result (2026-09-25): `mac/pgo-build.sh` does the four steps; its outputs go
to `mac/pgo/` (ignored).  Training runs the GUI harness at 40 iterations,
`perf.el` and batch fontification, and needs a GUI session.  Measured
against a plain `-O2` build of the same commit and configuration
(`--with-metal-rendering --enable-mac-app=yes --without-native-compilation`),
three round-robin rounds, best of rounds:

| Measurement | `-O2` | PGO + ThinLTO | Change |
|---|---|---|---|
| Fontify xdisp.c, batch | 3.96 s | 2.91 s | -26.6% |
| `perf.el` typing, median | 2.92 ms | 2.34 ms | -19.8% |
| `perf.el` page scroll, median | 1.50 ms | 1.20 ms | -20.3% |
| `perf.el` redraw, median | 1.65 ms | 1.27 ms | -22.7% |
| `perf.el` next-line, median | 0.56 ms | 0.51 ms | -8.3% |
| Harness `c-typing` step p50 | 2.97 ms | 2.38 ms | -20.0% |
| Harness `c-page-scroll` total | 0.89 s | 0.74 s | -16.8% |

The training overlaps those workloads, so held-out ones were checked
too: fontifying a 400 KB Python file (`test_typing.py`) 0.75 to 0.52 s (-31%), `sort-lines`
on 200,000 lines 0.545 to 0.478 s (-12%); byte-compiling `org-agenda.el`
and `json-parse-string` on 7.6 MB were unchanged.  The full test suite
gives the same results on both builds (the failures are rust-analyzer,
tramp and vc environment issues, and two stale source invariants that
failed before this session and have since been updated).  The profile covers only C; native-compiled Lisp
is unaffected, and a profile goes stale as the C sources change (clang
ignores functions whose shape changed).  Not made the default build.

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

#### Measurements (2026-09-25)

These ran on the installed PGO build (`ba7e776ed83`) with a 16 MB
`gc-cons-threshold`, grammars from `~/.emacs.d/tree-sitter`, and
tree-sitter 0.27.  The user's configuration uses `treesit-auto` for every
language with an installed grammar, so this item concerns tree-sitter modes.
C files still open in cc-mode because no C grammar is installed.

| Case | python-ts, 240 KB | typescript-ts, 800 KB | python-ts, 45-50 KB |
|---|---|---|---|
| Full parse (opening the file) | 16.6 ms | 44 ms | - |
| Reparse after a one-character edit | 0.16 ms | 1.0 ms | - |
| Reparse after typing `"` (the tree changes to the end of the buffer) | 6.7 ms | 3.3 ms | 1.4-2.2 ms |
| Query and faces for 60 lines | 1.3 ms | 1.6 ms | 0.4-1.0 ms |
| GUI keystroke, including redisplay | 1.0 ms | 1.9 ms | - |
| GUI page scroll | 2.6 ms | 2.5 ms | - |

The first three rows are parsing, the only work a C worker thread could
take over.  Querying and applying faces must stay on the Lisp thread, and
cost about 1 ms per screen.  An ordinary edit's parse is already under
1 ms.  A worker saves time only on edits that invalidate much of the tree,
such as quotes, brackets and comment starters, in files over about
200 KB, and on the first parse when a file is opened.

cc-mode is the largest fontification cost: about 3.7 ms per keystroke in
`src/xdisp.c` (typing takes 4.6 ms, 0.9 ms without font-lock).  It is Lisp,
so no C worker can help it.  `codex/responsive-coding-bb3c` ran font-lock
in helper Emacs processes instead, which took 95 commits and nearly
3,000 changed lines.  Item 10 took only the budgeting and deferral
commits from that branch.

Measuring note: `jit-lock-defer-on-input` (item 10) defers fontification
whenever input is pending, and a scripted GUI loop always has input
pending.  Bind it to nil in a benchmark, or the benchmark times
unfontified redisplay.

#### Design (decided 2026-09-25 by Claude, per the user's standing instruction to adopt recommendations; not reviewed by the user)

1. **Scope.** Only a buffer's primary tree-sitter parser, and only when it
   has no included ranges and no embedded parsers.  Everything else parses
   synchronously, as it does today.  Queries, `treesit-font-lock-rules`
   and face application stay on the Lisp thread.
2. **Budgeted parse.** `treesit_ensure_parsed` calls
   `ts_parser_parse_with_options` with a progress callback that halts the
   parse after a budget, `treesit-sync-parse-budget` (default 3 ms).
   Ordinary edits finish within the budget, so behaviour is unchanged for
   them.
3. **Handoff.** When the parse halts, copy the parsed region's bytes (both
   sides of the gap, the accessible region only) into a snapshot, and
   resume the parse on a serial GCD queue.  Tree-sitter resumes a halted
   parse when it is called again with the same arguments (see
   `ts_parser_reset` in `api.h`).  The snapshot has the same content as the
   buffer at the halt, so the byte offsets stay valid.  Until the parse
   completes, only the worker uses the `TSParser`.
4. **While the parse is pending.** `treesit--pre-redisplay` and
   `treesit-font-lock-fontify-region` do not wait.  They leave the regions
   they are asked to fontify marked for `jit-lock`'s deferral, so the old
   faces stay visible and are not cleared.  Every other caller that needs
   the tree, such as indentation, navigation, `treesit-node-at` or
   `syntax-propertize`, waits for the worker.  That wait is never longer
   than today's synchronous parse.
5. **Completion.** The worker posts a wakeup to the Lisp thread, as the
   persistent loop does for other GUI-thread results.  The Lisp thread
   installs the tree, bumps the timestamp and runs the after-change
   notifiers with the changed ranges, which marks those regions for
   refontification.  Edits made during the parse are queued as
   `TSInputEdit`s; they are applied to the new tree with `ts_tree_edit`,
   and a normal budgeted reparse follows.  A change of narrowing, a
   language change or a parser deletion during the parse makes the Lisp
   thread wait for the worker first.
6. **Tests.** A batch ERT test forces a budget of 0 and checks that the
   finished tree equals a synchronous parse after interleaved edits.  A
   GUI scenario types `"` into the 800 KB TypeScript file and checks
   keystroke latency and that the string face appears afterwards.  Run the
   scenario under `MallocScribble=1`.

**Decision: not implemented now.**  The saving is 2-7 ms on a small class
of edits in large files, plus the first parse on opening a file.  Ordinary
keystrokes already take 1-2 ms in total.  The change would add
cross-thread ownership to `src/treesit.c`, which GNU master changed in 74
commits over the last six months together with `lisp/treesit.el`.  Every
weekly sync would have to re-verify the threading invariants.  Revisit
if any of these happens:
- a tree-sitter mode keystroke measures over 8 ms, one frame at 120 Hz;
- the user reports lag in large files;
- upstream adds a similar asynchronous parse.

The design above is the starting point for that work.

The harness `test/manual/redisplay-bench/ts-perf.el` later measured
worse quote cases.  Typing `"` at the start of a line reparses in
4-5 ms at 50-100 KB, 9 ms in `codegen.py`, and 63 ms in an 800 KB
docstring-heavy Python file.  See
`.wayfinder/research/ts-latency-baseline.md`.

The user later asked for this to be split into stages; the plan is the
wayfinder map `.wayfinder/issues/treesit-budgeted-parse.md` (2026-09-25).

All of the map's design decisions were made on 2026-09-26, so the deferral
no longer holds:
- stage 1 times every parse without changing behaviour;
- stage 2 budgets reparses and continues them in idle slices on the Lisp
  thread;
- a worker thread is built only if stage 2's stats pass the gate recorded
  on the map.

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
- On the PGO build `busy-scroll` later failed `newest-timestamp`: its
  calibration of the busy loop took about the 0.1 s before the gesture,
  and the Lisp after it let `read_socket` take the first deferred
  events, splitting the merge.  The scenario now calibrates before
  posting the gesture and passes 5 of 5 runs.
- Accepted 2026-09-25: the user checked real trackpad scrolling,
  momentum included, both idle and while Lisp was busy.

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

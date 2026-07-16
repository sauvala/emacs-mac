# Native Multiple Cursors Handoff

## Objective and scope

Continue the experimental native multiple-cursor implementation for Janne's
personal `emacs-mac` fork.  Preserve the central design: supported commands
have explicit native policies and operate as one staged transaction; unknown
or unsafe commands fail before editing.  Do not replace this with arbitrary
command-loop replay at every cursor.

This work is only for the personal fork.  Do **not** spend time on upstream
preparation, upstream naming/API review, patch-series cleanup, or a GNU Emacs
submission.  Small internal refactors are appropriate when they directly
enable a planned feature or remove measured overhead.

## Repository state

- Persistent worktree:
  `/Users/janne/Projects/emacs-mac/.worktrees/native-multiple-cursors`
- Branch: `codex/native-multiple-cursors`
- Remote tracking branch: `fork/codex/native-multiple-cursors`
- Latest completed commit at handoff: `ee8038954d2`
  (`Preserve nested electric option references`)
- Expected starting state: clean and synchronized with the fork branch.
- Publish with:

  ```bash
  git push fork HEAD:codex/native-multiple-cursors
  ```

Use this worktree rather than the main checkout.  Commit every logical slice
and push regularly so progress remains recoverable.  Preserve unrelated user
changes if the worktree is unexpectedly dirty.

The original design and checkpoint plan remain useful architectural context:

- `docs/superpowers/specs/2026-07-13-native-multiple-cursors-design.md`
- `docs/superpowers/plans/2026-07-13-native-multiple-cursors.md`

They describe the initial checkpoint, much of which is now complete.  This
handoff is authoritative for the remaining personal-fork work and supersedes
the original plan's upstream-facing follow-up.

## What is implemented

The branch contains the complete initial checkpoint plus several compatibility
slices:

- buffer-local marker-backed cursor sessions and public creation/management
  commands;
- explicit command-policy dispatch with fail-closed unknown commands;
- staged logical movement, including ordinary logical arrow and word commands;
- a C primitive for normalized disjoint replacements, owned by one Lisp
  transaction;
- transactional typing, character deletion, grapheme-aware forward Delete,
  ordinary Backspace, and all four
  `backward-delete-char-untabify` modes;
- transactional kill, copy, and yank;
- transactional raw and bounded stock-relative electric `newline`/RET paths;
- immutable redisplay snapshots, native Mac caret painting, active secondary
  selections, and overlay fallback on non-native displays;
- threshold-free scalability benchmarks, manual fixtures, user/Elisp
  documentation, NEWS, and source-invariant coverage.

The relevant commits, in order, can be listed with:

```bash
git log --oneline --reverse fork/nemesis..HEAD
```

The latest compatibility and Return commits are:

- `b7a63ee16a5` ordinary logical arrow movement;
- `3259fdfc48e` grapheme-aware character deletion;
- `a94c3e698fa` untabifying/hungry Backspace;
- `1b1a379c519` guarded transactional raw RET;
- `494d2b3c3e0` and `70befe0bf7a` hook-context and rollback hardening;
- `af85064513f` bounded stock-relative electric RET;
- `0787be52ba8` single after-change/composition signaling in rope buffers;
- `c70182d7d19` through `ee8038954d2` exact guarded-option, mark, binding,
  alias, and dead-buffer restoration.

At handoff, the combined Lisp/C ERT command passed **212/213** tests on the
non-rope build; the one guarded rope test skipped because
`buffer-enable-rope` was unavailable.  Source invariants passed **25/25**.
Treat those counts as useful references, not permanent assertions; new tests
should increase them.

## Architectural invariants to preserve

1. Lisp owns the session, command classification, cursor snapshots, planning,
   and the single transaction boundary.
2. `multi-cursor--apply-edits` receives already validated, normalized,
   disjoint edits.  The C primitive does not open its own change group.
3. A supported edit is one logical command, one atomic application, and one
   undo unit.  Preflight every cursor before the first durable change.
4. Modification hooks, quit, buffer/restriction changes, cursor-session
   mutation, and guarded-option mutation must either succeed for the whole set
   or restore the original text and cursor state.
5. Do not invoke arbitrary interactive commands once per cursor.  Add a
   command-specific planner/handler with an explicit safety contract.
6. Preserve ordinary Emacs behavior only where it is proven.  Reject other
   contexts explicitly and document the limitation.
7. Redisplay consumes immutable, generation-checked snapshots.  Do not expose
   mutable Lisp cursor records to redisplay.
8. Existing user-visible limitations are contracts until a tested slice
   removes them.

Important implementation details and traps:

- `multi-cursor--apply-edit-transaction` is the common atomic owner and restores
  detached cursor markers on failure.  Change-group cancellation inhibits
  modification hooks so a hook that caused failure cannot re-enter rollback.
- For each edit, the C batch primitive checks the entry buffer and accessible
  bounds immediately after `prepare_to_modify_buffer` returns and again after
  `signal_after_change` returns.  It deliberately retains already completed
  higher edits when called without the Lisp transaction.  Both gap and rope
  replacement paths honor the `run_mod_hooks` argument.
- Edit merging intentionally has different behavior for plain deletions and
  replacement-safe untabify/electric edits.  A boundary no-op that shares the
  start of a replacement is carried as a passive state so neither cursor is
  lost.
- Forward Delete follows Emacs composition/grapheme boundaries.
- Ordinary vertical arrows keep independent goal columns; visual-line and
  visual-order movement remain rejected because they need live glyph geometry
  per cursor.
- The native edit primitive inserts with non-inheriting replacement semantics.
  Ordinary `newline` uses `insert_and_inherit`, so both RET paths reject all
  insertion or replaced-whitespace boundaries containing relevant text
  properties.  Checks widen temporarily because properties just outside
  narrowing can be inherited.
- Raw RET remains the fast path when electric indentation is disabled.
  Bounded electric RET supports only the stock `indent-relative` case at the
  physical end of complete accessible lines.  It computes every trailing-space
  deletion and target indentation without invoking syntax, electric, or
  indentation callbacks, then applies the disjoint set once.
- Electric planning snapshots guarded binding locality, values, defaults, and
  recursive mutable references.  Hook-time mutation, equal-object replacement,
  alias changes, buffer switching, restriction changes, or session mutation
  fail atomically and restore the original identities where the source buffer
  remains live; process-wide defaults are restored even if a hook kills it.
- Both RET paths continue to reject auto-fill, abbrevs, hard newlines, left
  margins, input translation, overwrite mode, prefixes, active selections,
  minibuffers, custom insertion hooks, and adjacent text properties.
- Computer Use verification on 2026-07-17 confirmed transactional broadcast
  insertion in the branch GUI.  The captured frame showed duplicated,
  fragmented, and stale glyphs, but subsequent controls produced the same
  corruption with no secondary cursors, a no-op native callback, and the Lisp
  overlay fallback.  This Core Graphics build therefore has a general
  source-build or Computer Use capture problem; the recording is not evidence
  that the native cursor painter is broken.  Native painting still needs visual
  verification through a trustworthy display or capture path.
- Commit `2e674c0fddf` adds a deterministic GUI fixture with 1, 3, 30, and 300
  cursor presets, forced redisplay, movement, insertion, scrolling, removal,
  resize, screenshot hooks, and machine-readable state.
- Commit `d827416a2f4` distinguishes an intentional pending nil clear from no
  cursor-decoration transaction.  Unrelated redisplay re-resolves the current
  generation, matrix teardown preserves pending nil and non-nil generations,
  split-window replacement is transaction-safe, and confirmed window death
  releases snapshot ownership.
- The mode currently paints only the selected window when several windows show
  the same buffer.
- Undo/redo commands remain unsupported while a session is active even though
  each supported edit produces one undo unit.

## Remaining plan, in priority order

### 1. Establish a trustworthy native Mac painter baseline

Visual correctness remains a release gate and takes priority over TAB,
compatibility expansion, and performance optimization.  The available capture
is not a painter-specific reproducer: identical corruption occurs without
multiple cursors and outside the native callback.  First reproduce on a known
good ordinary source-built frame or establish a trustworthy capture path.  Do
not change `mac_draw_window_cursor_decorations` merely to improve a corrupted
Computer Use recording.

#### 1.1 Deterministic GUI regression fixture (complete)

`test/manual/multi-cursor-tests.el` now provides distinctive deterministic
content, 1/3/30/300 cursor presets, automated insertion, movement, removal,
scrolling, forced redisplay and resize steps, synchronous capture hooks, and
machine-readable text/pixel-mask/geometry/counter state.  It was committed
separately as `Add deterministic multiple cursor GUI fixture` (`2e674c0fddf`).

The remaining acceptance work is to run this fixture through a trustworthy
graphical path and compare pixels outside the expected cursor masks.

#### 1.2 Bisect the native rendering stages

Add temporary internal switches or build variants that exercise these stages
independently:

1. force the Lisp overlay fallback by reporting no native capability;
2. install the native callback but make it a no-op;
3. paint cursor rectangles only;
4. restore underlying glyphs when old cursors disappear;
5. redraw contrasting glyphs inside filled box cursors.

Temporary no-op-native and overlay-fallback controls were run, but the same
whole-frame corruption remained even with zero cursors.  Those Computer Use
captures are inconclusive and all temporary bisection edits were reverted.
Repeat the stage matrix only after an ordinary no-cursor control renders
cleanly.  If the overlay fallback is then clean, the snapshot and editing
layers are exonerated.  If rectangles-only is clean, one of the direct
`draw_glyphs` paths is responsible.

Run the same matrix with Metal and Core Graphics and with box, hollow, bar, and
horizontal-bar cursors.  A Metal-only failure points to clip/scissor or command
ordering; a failure in both backends points to glyph geometry, cache
publication, or direct `draw_glyphs` use; a filled-box-only failure points to
contrast rendering.

#### 1.3 Scope renderer state correctly

The Metal painter currently changes the frame-wide clip with
`emacs_metal_set_clip_rect` and later resets it.  Replace this with scoped
clip-state handling: save or push the current clip, intersect it with the
window text area and cursor rectangle, draw, and restore or pop the original
clip.  Never reset renderer state owned by another drawing operation.  Assert
that every cursor rectangle and clip is contained by the target window's text
area.

Commit this behavior separately as `Scope Metal clipping for secondary
cursors`.

#### 1.4 Restore old cursor cells through ordinary redisplay

`damage_window_cursor_decorations` currently invokes the backend with
`on=false`; the Mac callback then calls `draw_glyphs` directly before the
ordinary window update.  Replace that restoration path with precise row or
rectangle damage and let normal redisplay repaint the underlying text.  Paint
new secondary cursors only after the completed row update, and never repaint
geometry resolved from an old glyph matrix when cache publication fails.

Commit this behavior separately as `Restore old secondary cursor cells through
redisplay`.

#### 1.5 Reintroduce filled-box contrast conservatively

After rectangle painting and cursor removal are clean, redraw one contrasting
glyph at a time under a local clip.  Remove the process-global
`mac_cursor_decoration_span_*` state if possible.  Test wide glyphs, combining
characters, bidi text, tabs, images, and overlapping glyph rows.  Reintroduce
adjacent-glyph batching only after the graphical checks pass.

Commit this behavior separately as `Restore contrasting secondary cursor
glyphs safely`.

#### 1.6 Add permanent graphical acceptance coverage

The source-pattern invariants are useful but did not detect this failure.  Add
GUI checks proving that:

- add, move, remove, scroll, resize, split, and refocus leave no trails;
- forced redisplay is visually idempotent;
- disabling the session restores pixels identical to the no-cursor frame;
- split windows clip independently;
- every cursor shape is correct;
- the 1,000-cursor fixture completes without corruption.

Keep the combined ERT suite and source invariants as mandatory gates.  Test
both Metal and Core Graphics where the build supports them.

Only after correctness is established should painter batching be restored and
measured.  Record Mac painter counters for 1, 10, 100, and 1,000 cursors, and
run the graphical regression fixture after every optimization.

This task is complete only when broadcast edits remain one undo unit, displayed
and accessible buffer contents agree, no pixels outside expected cursor cells
change, and the 3-, 30-, and 300-cursor fixtures pass movement, removal,
scrolling, resizing, splitting, and refocus tests without trails.

### 2. Add a narrowly proven TAB path

Audit actual bindings in Fundamental, Text, Emacs Lisp, and C modes before
editing.  `indent-for-tab-command` may indent a region, call arbitrary
mode-specific indentation, insert whitespace, perform completion, widen, or
rigidly indent a following expression; C mode can bind TAB to another command.

Start only with the provable literal `insert-tab` branch, if it remains useful:

- no prefix, active region, abbrev expansion, completion, or arbitrary
  indentation callback;
- model `indent-tabs-mode`, `tab-width`, current column, and the exact inserted
  tabs/spaces per cursor;
- preflight and apply once;
- reject all other command identities and branches atomically;
- test both tabs and spaces, different columns, narrowing, fields/read-only
  text, undo/history, mutation rollback, and real key resolution.

Do not claim general TAB support until mode indentation and completion have
separate explicit contracts.

### 3. Broaden editing commands and define session undo behavior

After Return/TAB foundations, audit commonly used commands and add only
bounded native handlers.  Likely candidates include `open-line`,
`newline-and-indent`, word deletion, case conversion, transpose operations,
and comment commands, but prioritize by usefulness and implementation risk.

Separately design undo/redo during an active session.  Decide and test how a
transaction restores cursor positions, selections, direction, goal columns,
and yank metadata.  Do not merely allow ordinary `undo` while cursor records
silently drift.  Preserve one undo unit per broadcast edit and test undo/redo
across overlapping selections, killed cursors, narrowing, and failed hooks.

### 4. Run and record GUI performance baselines

The headless harness exists at
`test/benchmarks/multi-cursor-benchmarks.el`.  Run it from a graphical Mac frame
so native painter counters are populated, and compare against
`multiple-cursors.el` when that package is available on `load-path`.

Capture reproducible results for 1, 10, 100, and 1,000 cursors across editing,
movement, normalization, and redisplay.  Record median/p95 time, allocation,
GC, undo growth, hook counts, and Mac painter counters.  Keep machine-specific
results clearly labeled; do not turn them into universal timing thresholds.

Use measurements to identify the next optimization instead of assuming the
native path is faster.

### 5. Improve multi-window painting and painter allocations

Extend presentation beyond the selected window so every live window showing
the buffer receives correct cursor decorations.  Preserve generation/window
validation and cleanup when windows, frames, or buffers disappear.

Profile and then reduce allocation in snapshot publication, glyph resolution,
decoration vectors, and Mac painter batching.  Add source invariants and GUI
tests for clipping, scrolling, window splits, indirect visibility, frame
activation, stale snapshots, and 1,000-cursor redisplay.  Commit measured
optimizations separately from behavior changes.

### 6. Compatibility and stabilization pass

Exercise the feature in Fundamental, Text, Emacs Lisp, and C modes; narrowed
buffers; TTY/overlay fallback; Mac GUI; read-only and propertized text; large
buffers; and buffers displayed in multiple windows.  Revisit fail-closed
messages and documentation for every newly supported or deliberately rejected
command.

Run the manual fixture in `test/manual/multi-cursor-tests.el`, fix any concrete
personal-fork issues found, and keep commits small.  There is no upstream
preparation phase.

## Verification commands

Build first if `src/emacs` does not include the branch changes:

```bash
make -j2 src/emacs
```

Run the combined native multiple-cursor suite:

```bash
src/emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L lisp -L test/lisp -L test/src \
  -l test/lisp/multi-cursor-tests.el \
  -l test/src/multicursor-tests.el \
  -f ert-run-tests-batch-and-exit
```

Run source invariants after Lisp/C/redisplay changes:

```bash
src/emacs -Q --batch \
  -L test/misc/multi-cursor-tests \
  -l test/misc/multi-cursor-tests/source-invariants.el \
  -f ert-run-tests-batch-and-exit
```

Run a focused selector during each red/green slice, for example:

```bash
src/emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el \
  --eval '(ert-run-tests-batch-and-exit "multi-cursor-edit-newline")'
```

Validate documentation and whitespace when relevant:

```bash
/opt/homebrew/opt/texinfo/bin/makeinfo --force --enable-encoding \
  -I doc/emacs doc/emacs/emacs.texi -o /private/tmp/emacs-native-mc.info
git diff --check
git status --short --branch
```

For Lisp edits, also run `check-parens` and `checkdoc-file` against
`lisp/multi-cursor.el`.  Some pre-existing checkdoc warnings about
`command-history` and `goal-column` may remain; do not introduce new warnings.

The benchmark file documents its batch and GUI invocation forms.  Native Mac
painter statistics require a running graphical Mac frame rather than batch
mode.

## Working style for the next agent

Keep implementation subagent-driven when collaboration slots are available:
delegate bounded production, test, and review work, then review the shared
diff and run the decisive verification commands from the primary agent.

1. Inspect the clean branch and the relevant ordinary Emacs command before
   changing policy registration.
2. Write a focused test matrix and obtain a meaningful failing test.
3. Implement the smallest semantically honest handler.
4. Have a separate agent review edge cases when subagents are available.
5. Run focused tests, the full combined suite, source invariants when relevant,
   documentation checks, and `git diff --check`.
6. Commit that logical slice with a concise message and push it immediately.
7. Update this handoff if the remaining plan or a durable invariant changes.

Do not bundle an unverified compatibility expansion with performance or
redisplay changes.  Do not add an upstream-preparation task.

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
- Latest completed commit before the current TAB slice: `8d0eebf8081`
  (`Support undo during multiple-cursor sessions`)
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
- active-session undo/redo with exact cursor-state restoration and stale-history
  rejection;
- bounded `indent-for-tab-command` support whenever every cursor takes Emacs's
  literal `insert-tab` branch;
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
- `8d0eebf8081` active-session transactional undo and redo.

After the undo slice, the combined Lisp/C ERT command passed **222/222** tests
on the rope-enabled build. Source invariants passed **31/31**. The TAB slice
adds its own focused regression matrix; rerun the combined counts rather than
assuming these reference numbers remain current.
Treat those counts as useful references, not permanent assertions; new tests
should increase them.

### 2026-07-19 daily-editing checkpoint

The prioritized daily-editing expansion is complete.  The branch now also
contains transactional syntax-aware `kill-word` and `backward-kill-word`, a
bounded literal `open-line`, literal and bounded stock Emacs Lisp TAB paths,
bounded stock Emacs Lisp `newline-and-indent`, and transactional `yank-pop`.
The completed commits before the yank-pop slice are:

- `376e6332b5e` word killing;
- `047a3beec59` open line;
- `832d7980d9b` Emacs Lisp TAB indentation;
- `fe523655a02` newline and indent.

`yank-pop` is deliberately bounded to the immediately preceding native yank
or yank-pop.  It records the exact merged ranges, restriction, modification
tick, cursor object identities, and orientation; rotates the ordinary kill
ring once; applies all replacements in one transaction; defers external
selection publication until commit; and fails closed after text, narrowing,
or cursor-topology drift.  Failed transactions restore the kill-ring pointer
and remain retryable.  Custom `yank-handler` behavior remains unsupported.

At this checkpoint the complete Lisp ERT suite passes **274/274**, native
redisplay source invariants pass **31/31**, byte compilation reports no new
yank/newline errors, and `git diff --check` is clean.  The remaining sections
below are a longer-term backlog rather than unfinished work in this
daily-editing slice; TAB, open-line, newline-and-indent, word killing,
session undo/redo, and bounded yank-pop should not be reimplemented.

### 2026-07-27 command-classification checkpoint

A coverage audit measured how many ordinary editing commands actually reach
a handler during a session.  Of a 45-command sample of common commands, only
**5** were supported; **40** failed closed.  Most of the gap was not missing
handlers but missing *classification*: commands which never edit at a cursor
position — `other-window`, `switch-to-buffer`, `mwheel-scroll`,
`scroll-other-window`, `describe-function`, `find-file` — signalled
"not multiple-cursor safe" merely because nothing had registered them.
The design already called for these to be `run-once`; that step had never
been completed.  The same sample now reports **20** supported.

Completed in this checkpoint:

- `9be799d9fa9` collects the run-once set in
  `multi-cursor--run-once-commands`, grouped by why each group is safe:
  cursor-set management, prefix accumulation, scrolling and display, window
  and frame management, buffer and file commands, help, and evaluation.
  Entries which are not preloaded are skipped.  `multi-cursor-count` became
  interactive so the documented accessibility report is bindable.
- `c58c6c924c8` extends the vetted movement set with
  `back-to-indentation`, plain `beginning-of-line`/`end-of-line`,
  balanced-expression motion, paragraph and sentence motion, and defun
  motion.
- `884118c1f15` corrects `doc/emacs/mark.texi`, which had drifted far enough
  to state the opposite of the shipped behavior.

Two durable facts were established while doing this:

- `multi-cursor-add-at-point` **cannot** become a command.  It rejects the
  primary position by contract, so calling it without an argument always
  signals.  It is a Lisp entry point; `multi-cursor-add-above` and
  `multi-cursor-add-below` are the interactive equivalents.  Its docstring
  now says so, and a test pins it.
- Two mechanical traps govern adding movement commands.  Some take no
  argument at all (`back-to-indentation`), so `multi-cursor--invoke-movement`
  now calls argumentless commands without one.  Expression motion reports an
  unreachable target with `scan-error`, not beginning/end-of-buffer, so that
  condition is local for `multi-cursor--scan-motion-commands` only and still
  aborts the broadcast from any other command.

`beginning-of-buffer` and `end-of-buffer` were deliberately left out: they
push the mark, which is buffer-global state the movement staging does not
model per cursor.  Deciding their semantics (collapse-to-one versus
primary-only) is open work.

At this checkpoint the combined Lisp/C suite passes **303/303**, source
invariants **31/31**, `makeinfo` reports no `mark.texi` diagnostics,
`check-parens` passes, `checkdoc` reports **13** warnings both before and
after the change (no new ones), and `git diff --check` is clean.

### 2026-07-27 package comparison: acceptance requirement 2 fails for editing

`multiple-cursors.el` was cloned and put on `load-path`, and the full
benchmark matrix ran against it for the first time.  The result splits
cleanly, and it is not the result the design assumed.

Ratios are medians over 12 cells each: ascii, combining, and bidi content,
10 KiB and 1 MiB buffers, and clustered/even/coincident/overlapping
distributions.  The ratio is package median over native median, so above
1.0 means native is faster:

| operation | 2 cursors | 10 | 100 | 1000 |
| --------- | --------- | -- | --- | ---- |
| insert    | 0.18x     | 0.23x | 0.25x | 0.37x |
| delete    | 0.16x     | 0.20x | 0.23x | 0.37x |
| horizontal motion | 2.91x | 2.69x | 2.66x | 3.73x |
| vertical motion   | 2.23x | 2.23x | 2.29x | 3.41x |

p95 ratios track the medians closely, so this is not tail noise.

**Movement passes and editing fails.**  Native movement is 2.2-3.7x faster
and its margin *grows* with cursor count, which is the scaling advantage the
batch design predicted.  Native editing is 2.7-6x *slower* than the package
at every count from 2 to 1000.

Fitting the editing curves between 100 and 1000 cursors, native costs
0.069 ms per cursor against the package's 0.025 ms — about 2.7x more
per-cursor work.  The gap narrows as the count rises (0.16x to 0.37x), so
native does scale better and would cross over somewhere well above 1000
cursors, but no tested configuration reaches it.  This is a per-cursor cost
problem in the batch-edit path, not a fixed setup cost that could be
amortized away.

Allocation is consistent with that on small buffers: at 100 cursors in a
10 KiB buffer native allocates about 2x the package (95502 against 46938
units, and the same ratio for bidi and combining content).  At 1 MiB the
fixture's own allocation dominates and the ratio falls to 1.04x, so
allocation alone does not explain the time gap — do not treat it as the
diagnosis.  Both providers produce identical before/after change hook
counts, and native's undo list is *tighter* (201 entries against 298).

Two fairness notes, neither of which explains a 2.7x per-cursor gap:

- The benchmark drives the package through
  `mc/execute-command-for-all-cursors` without enabling
  `multiple-cursors-mode`, so it skips that mode's `post-command-hook`
  dispatch.  That overhead is per command, not per cursor.
- The package wraps each cursor in `ignore-errors` and offers no atomicity,
  no preflight, and no single-undo-unit guarantee.  Native buys real
  correctness properties with that time.  Acceptance requirement 2 as
  written is nonetheless unconditional on latency, and it fails.

What to do with this:

1. Do not publish a comparative editing-performance claim.  The movement
   claim is real and can be stated with these numbers.
2. Profile the batch-edit path before optimizing it.  The suspects are
   per-cursor allocation in edit-record and edit-state construction,
   marker detach/reattach, and position remapping — but this has not been
   profiled yet, and the 2x allocation figure is the only direct evidence.
3. Treat absolute latency as a separate usability question from the ratio.
   At 100 cursors native insert is about 6 ms per keystroke, which is
   usable; at 1000 cursors it is about 70 ms, which is not.

Raw results are reproducible with the command in section 4; the package was
cloned from `https://github.com/magnars/multiple-cursors.el`.

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
bounded native handlers.  `open-line`, `newline-and-indent`, and word
deletion are done.  The remaining high-value candidates, in rough order of
usefulness against implementation risk:

1. ~~`set-mark-command` and `exchange-point-and-mark`~~ — done in
   `bbf75ff7337` and `20154206f8c`.  Both are bounded to the branches which
   act on the current position; every prefixed branch is rejected because it
   navigates the buffer-global mark ring.  The primary keeps stock behavior
   through `push-mark-command`, so exactly one mark-ring push happens per
   command and secondary marks never reach the ring.  Note the invariant
   found while doing it: an active flag without a mark is not a
   representable cursor state, so activation must skip markless cursors.
2. `kill-line` and `kill-whole-line`.  Very common, and expressible as a
   batch edit over per-cursor line bounds.  Now the top priority.
3. Case conversion (`upcase-word`, `downcase-word`, `capitalize-word`) and
   `delete-horizontal-space`/`just-one-space`.  Pure text transforms with
   no mode-specific callbacks.
4. `comment-dwim` and `comment-line` only after auditing how much
   mode-specific machinery `comment-region` reaches; likely expensive.
5. `beginning-of-buffer`/`end-of-buffer`, which need a decision about
   `push-mark` before they can be classified at all.

Transpose operations are deliberately ranked last: they move text across
cursor boundaries and do not fit the disjoint-replacement model cleanly.

Active-session undo/redo now restores cursor positions, selections, direction,
goal columns, and yank metadata one session generation at a time. Remaining
undo work is compatibility hardening: exercise narrowing changes, more command
types, long sessions, and interactive command-loop use without weakening the
stale-history boundary.

#### Open question: the cost of per-mode indentation

Before writing a fourth indentation shadow plan, settle whether the current
strategy scales.  Today roughly 900 lines buy RET and TAB *in Emacs Lisp
mode only*:

| region                        | lines |
| ----------------------------- | ----- |
| electric newline guards       | ~500  |
| Emacs Lisp indent shadow plan | ~236  |
| newline-and-indent shadow     | ~185  |

Most of that is not indentation logic; it is
`multi-cursor--electric-newline-reference-state` and its validators
recursively snapshotting cons cells, char-tables, extra slots, parents, and
vectors to detect whether a hook mutated a guarded option.  Extending this
to C, Python, or any tree-sitter mode means reimplementing that mode's
indentation engine per mode, at a similar cost each time.

The invariant "never invoke an arbitrary interactive command once per
cursor" is correct and must stay — it is what makes edits transactional and
keeps cost linear.  But it constrains how edits are *applied*, not how a
target column is *computed*.  Worth prototyping: run the mode's real
`indent-line-function` in a shadow context (an indirect buffer, or a temp
buffer carrying enough syntactic context) purely to compute each cursor's
target indentation, then apply the whole set through the existing
transaction.  That would keep atomicity, one undo unit, and linear scaling
while making indentation mode-generic.

If the prototype fails, record why, and treat per-mode indentation as
permanently bounded rather than continuing to add shadow plans by default.

### 4. Run and record GUI performance baselines

The headless harness exists at
`test/benchmarks/multi-cursor-benchmarks.el`.  Run it from a graphical Mac frame
so native painter counters are populated, and compare against
`multiple-cursors.el` when that package is available on `load-path`.

**The package comparison has now been run, and acceptance requirement 2
fails for editing.**  See the checkpoint below.

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

# Native Multiple Cursors Implementation Plan

> **Execution note:** Implement this plan task by task. Run the focused test after every red/green step and commit each completed task before moving on.

**Goal:** Add an Emacs-native multiple-cursor editing model with buffer-local cursor state, explicit command policies, atomic multi-location edits, and redisplay support that uses the normal terminal backend abstraction.

**Architecture:** Lisp owns cursor sessions, command classification, and per-command state. A small C editing primitive applies already-normalized disjoint replacements inside its Lisp caller's change group. Redisplay exposes secondary cursor decorations through the redisplay interface; each graphical backend may paint them natively, while selection ranges initially remain overlays. Tasks 1-10 deliver the first usable checkpoint; Task 11 then adds the first plain kill/yank compatibility checkpoint.

**Scope boundary:** Electric indentation, abbrev expansion, auto-fill, syntax-aware indentation, distributed yank/yank-pop, per-damage redisplay optimization, and non-Mac native painters are follow-up plans after the core model is stable.

**Primary files:** `lisp/multi-cursor.el`, `src/multicursor.c`, `src/xdisp.c`, `src/dispnew.c`, `src/macterm.c`, focused ERT tests under `test/lisp` and `test/src`, plus manual and benchmark fixtures.

**Test convention:** Every numbered task starts by adding the named test and
running its focused command to observe a failure caused by the missing behavior.
After implementation, rerun the identical command; expected output is all named
tests passing with process status 0. Any broader regression command must also
finish with status 0 before the task's commit.

---

## Task 1: Cursor records and session lifecycle

**Files:**

- Create: `lisp/multi-cursor.el`
- Create: `test/lisp/multi-cursor-tests.el`

### Step 1: Write failing lifecycle tests

Add ERT tests for these invariants:

- enabling `multi-cursor-mode` creates a buffer-local session;
- cursor records use markers and survive text inserted before them;
- disabling the mode clears markers and all session state;
- duplicate point/mark pairs collapse to one cursor;
- cursor state never leaks to another buffer;
- kill, revert, major-mode change, and wholesale content replacement end the
  session; and
- enabling the native mode while Magnar Sveen's `multiple-cursors-mode` is
  active signals without disturbing either implementation.

Representative test:

```elisp
(ert-deftest multi-cursor-lifecycle-markers-track-edits ()
  (with-temp-buffer
    (insert "alpha beta")
    (goto-char 7)
    (multi-cursor-mode 1)
    (multi-cursor--add-cursor 7 nil nil)
    (goto-char 1)
    (insert "X")
    (should (= (marker-position
                (multi-cursor--cursor-point
                 (car multi-cursor--cursors)))
               8))))
```

Run:

```bash
src/emacs -Q --batch -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el \
  -f ert-run-tests-batch-and-exit
```

Expected: failure because `multi-cursor.el` and its lifecycle API do not exist.

### Step 2: Implement the smallest lifecycle model

Use the `multi-cursor-` namespace so this feature can coexist with the external `multiple-cursors` package.

```elisp
(require 'cl-lib)

(defgroup multi-cursor nil
  "Edit a buffer through multiple native cursors."
  :group 'editing)

(cl-defstruct (multi-cursor--cursor
               (:constructor multi-cursor--cursor-create))
  id point mark mark-active direction goal-column last-yank)

(defvar-local multi-cursor--cursors nil)
(defvar-local multi-cursor--next-id 0)

(define-minor-mode multi-cursor-mode
  "Edit the current buffer using multiple cursors."
  :lighter " MC"
  (unless multi-cursor-mode
    (multi-cursor--clear)))
```

Implement `multi-cursor--add-cursor`, `multi-cursor--clear`, and a normalization helper that owns and releases every marker it creates. Install buffer-local cleanup hooks for kill, revert, and major-mode change. Keep loading the external package harmless; check for a conflict only when either mode is active in the current buffer.

### Step 3: Verify and commit

Run the focused ERT command, then:

```bash
git diff --check
git add lisp/multi-cursor.el test/lisp/multi-cursor-tests.el
git commit -m "Add multiple cursor session lifecycle"
```

## Task 2: Public cursor API and normalization

**Files:**

- Modify: `lisp/multi-cursor.el`
- Modify: `test/lisp/multi-cursor-tests.el`

### Step 1: Test the supported API

Add tests for:

- `multi-cursor-add-selection` accepts point/mark orientation and optional
  active state;
- `multi-cursor-add-at-point`, `multi-cursor-remove-at-point`, and
  `multi-cursor-remove-all` have deterministic point-local behavior;
- `multi-cursor-selections` returns immutable integer snapshots, not internal
  marker objects;
- `multi-cursor-count` includes the ordinary primary cursor;
- normalization sorts by point, removes exact duplicates, and retains
  overlapping active selections until an editing handler can merge them;
- the primary point is not stored as a secondary cursor.

The public snapshot should have stable fields:

```elisp
(:id ID :point POS :mark MARK :mark-active ACTIVE :direction DIRECTION)
```

### Step 2: Implement and document the API

Implement the exact public API from the design: `multi-cursor-add-selection`, `multi-cursor-add-at-point`, `multi-cursor-remove-at-point`, `multi-cursor-remove-all`, `multi-cursor-count`, and `multi-cursor-selections`. Add autoload cookies to interactive commands. Signal `user-error` before mutating state for invalid positions, cross-buffer markers, the cursor ceiling, or a duplicate primary cursor. Overlapping active selections remain representable and are merged only when an editing command derives replacement ranges. Keep an internal `multi-cursor--normalized-cursors` function used by commands and the future C boundary.

### Step 3: Verify and commit

```bash
src/emacs -Q --batch -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el -f ert-run-tests-batch-and-exit
git diff --check
git add lisp/multi-cursor.el test/lisp/multi-cursor-tests.el
git commit -m "Define native multiple cursor API"
```

## Task 3: Cursor creation commands

**Files:**

- Modify: `lisp/multi-cursor.el`
- Modify: `test/lisp/multi-cursor-tests.el`

### Step 1: Test user-facing creation

Cover every first-checkpoint creation and navigation command:

- `multi-cursor-edit-lines` creates one cursor per selected logical line at the
  same logical column and exercises the `eol`, `skip`, `pad`, and `error`
  short-line policies;
- `multi-cursor-add-above` and `multi-cursor-add-below` preserve logical column;
- `multi-cursor-select-next-occurrence`,
  `multi-cursor-select-previous-occurrence`, and
  `multi-cursor-select-all-occurrences` add literal matches;
- repeated occurrence commands skip an already-selected occurrence;
- case folding follows `case-fold-search`;
- a missing region falls back to the symbol at point and otherwise signals
  before changing the session;
- `multi-cursor-add-at-mouse` validates the event but installs no default
  mouse binding;
- `multi-cursor-cycle-forward` and `multi-cursor-cycle-backward` exchange the
  real primary state with a secondary cursor and report its ordinal; and
- `multi-cursor-count` and the mode-line lighter include the primary cursor.

### Step 2: Implement creation separately from execution

Creation commands should only populate normalized cursor records and enable `multi-cursor-mode`. They must not replay editing commands. Store selection direction so point and mark orientation remain meaningful. Enforce `multi-cursor-max-cursors`, accessible-buffer bounds, and `case-fold-search`. After a narrowing command, remove inaccessible secondaries and report the reduced count without widening.

### Step 3: Verify and commit

```bash
src/emacs -Q --batch -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el -f ert-run-tests-batch-and-exit
git add lisp/multi-cursor.el test/lisp/multi-cursor-tests.el
git commit -m "Add multiple cursor creation commands"
```

## Task 4: Explicit command-policy registry

**Files:**

- Modify: `lisp/multi-cursor.el`
- Modify: `lisp/simple.el`
- Modify: `lisp/delsel.el`
- Modify: `test/lisp/multi-cursor-tests.el`

### Step 1: Test classification before execution

Create test commands with counters and edits. Use `ert-play-keys` for the
command-loop integration cases rather than calling the dispatcher directly.
Assert that:

- `run-once` commands execute exactly once at the primary point;
- `broadcast-movement` commands run for every cursor;
- `batch-edit` commands call their registered handler once;
- `custom-handler` receives the command, captured raw prefix, keys/event,
  record flag, and `special`; command-specific handlers capture any other
  interactive input once;
- `unsupported` and unregistered commands signal `user-error` before any edit;
- recursive command execution does not re-enter the dispatcher;
- exactly one pre-command and one post-command hook run on success, error, and
  quit;
- raw prefixes nil, an integer, `-`, `(4)`, and `(16)` reach the handler
  unchanged;
- `this-command`, `real-this-command`, `last-command-event`, supplied keys,
  command history, and `last-command` retain normal outer-command values;
- disabled commands, autoloaded commands, keyboard macros, and special events
  retain their existing paths; and
- with `delete-selection-mode`, the primary region is not deleted before the
  batch handler replaces all selections.

### Step 2: Add registry and dispatcher seam

```elisp
(defconst multi-cursor--valid-policies
  '(broadcast-movement batch-edit run-once custom-handler unsupported))

(defvar multi-cursor--command-policies (make-hash-table :test #'eq))

(defun multi-cursor-register-command (command policy &optional handler)
  "Register COMMAND with POLICY and optional HANDLER."
  (unless (memq policy multi-cursor--valid-policies)
    (error "Invalid multiple-cursor policy: %S" policy))
  (when (and (memq policy '(batch-edit custom-handler))
             (not (functionp handler)))
    (error "Policy %S requires a handler" policy))
  (puthash command (cons policy handler) multi-cursor--command-policies))

(defun multi-cursor--command-execute (command record-flag keys special)
  "Dispatch COMMAND using its registered multiple-cursor policy."
  (let ((entry (gethash command multi-cursor--command-policies)))
    (unless entry
      (user-error "%S is not multiple-cursor safe" command))
    (multi-cursor--dispatch-policy
     (car entry) (cdr entry) command record-flag keys special)))
```

Add one narrow hook in `command-execute`, specifically in the non-keyboard-macro function branch after prefix transfer, disabled-command handling, and autoload resolution, immediately around the existing `call-interactively`. When `multi-cursor-mode` is active and the dispatcher is not already running, delegate to `multi-cursor--command-execute`; otherwise preserve the existing call path byte-for-byte.

Because `delete-selection-pre-hook` runs before `command-execute`, it cannot
depend on a dynamic binding established by the dispatcher. Instead, make it
query a small side-effect-free predicate in `multi-cursor.el` using
`this-command`'s already-registered policy. It defers primary deletion only
for a batch/custom edit policy that promises to handle every selection. The
real-command-loop test must prove the primary text remains untouched until the
handler begins.

Do not infer policy from command names or properties. Register the initial supported command set explicitly.

### Step 3: Run regression tests and commit

```bash
src/emacs -Q --batch -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el -f ert-run-tests-batch-and-exit
make -C test TEST_BACKTRACE_LINE_LENGTH=0 \
  SELECTOR='(or (test-match "command-execute") (test-match "delete-selection"))' check
git diff --check
git add lisp/multi-cursor.el lisp/simple.el lisp/delsel.el \
  test/lisp/multi-cursor-tests.el
git commit -m "Dispatch commands by multiple cursor policy"
```

## Task 5: Broadcast movement with per-cursor state

**Files:**

- Modify: `lisp/multi-cursor.el`
- Modify: `test/lisp/multi-cursor-tests.el`

### Step 1: Test movement semantics

Test horizontal and logical-line movement, active selections, goal columns, beginning/end of buffer, and partial failure. Expected `beginning-of-buffer` and `end-of-buffer` conditions clamp only that cursor and allow the broadcast to continue; every other error restores all cursor snapshots and the primary point/mark. Visual-line movement remains unsupported until a later window-geometry handler exists.

### Step 2: Implement install/run/capture

For each normalized cursor, install its point, mark, `mark-active`, and `temporary-goal-column`; invoke only a vetted pure-movement allowlist; capture the result back into markers; then restore the primary state. Wrap the loop in `unwind-protect`. Redisplay and command hooks remain inhibited until the whole broadcast completes. A third-party command cannot acquire `broadcast-movement` policy unless it accepts the documented no-edit/no-prompt/no-buffer-switch contract.

### Step 3: Verify and commit

```bash
src/emacs -Q --batch -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el -f ert-run-tests-batch-and-exit
git add lisp/multi-cursor.el test/lisp/multi-cursor-tests.el
git commit -m "Broadcast movement across native cursors"
```

## Task 6: Disjoint-edit primitive

**Files:**

- Create: `src/multicursor.c`
- Modify: `src/Makefile.in`
- Modify: `src/emacs.c`
- Modify: `src/lisp.h`
- Create: `test/src/multicursor-tests.el`

### Step 1: Write C-boundary tests

Test `multi-cursor--apply-edits` with a vector of `[BEG END STRING]` operations:

- insertions and replacements apply in descending buffer order;
- returned positions correspond to the end of each inserted string in input order;
- overlapping or unsorted-normalization failures signal before modification;
- read-only text, field constraints, and modification hooks preserve normal Emacs behavior;
- multibyte strings and text properties work; and
- validation of every edit completes before the first modification;
- a smaller-position insertion correctly shifts the returned final position
  of an already-applied higher-position edit; and
- validation and application loops check for quit at bounded intervals.

Rollback after a modification hook signals is tested in Task 7, where the
single transaction owner is introduced.

### Step 2: Wire a minimal primitive

Create `multicursor.c` with `syms_of_multicursor`, add `multicursor.o` to `base_obj`, declare the initializer in `lisp.h`, and call it from `syms_of_emacs` near other editing primitives.

The core shape is:

```c
struct mc_edit
{
  ptrdiff_t beg, end;
  Lisp_Object string;
  ptrdiff_t input_index;
};

DEFUN ("multi-cursor--apply-edits", Fmulti_cursor_apply_edits,
       Smulti_cursor_apply_edits, 1, 1, 0,
       doc: /* Apply prevalidated, normalized, disjoint EDITS.  */)
  (Lisp_Object edits)
{
  /* Decode and validate every edit first.  Apply from the greatest
     buffer position downward, using ordinary delete/insert machinery.
     Adjust results by all lower-position deltas and return final point
     positions in caller order.  */
}
```

This primitive does not start or accept a change group. Its Lisp caller owns the sole transaction boundary. Do not bypass normal low-level buffer modification functions, change hooks, undo recording, text properties, or bounded `maybe_quit` checks.

### Step 3: Build, test, and commit

```bash
make -j2 src/emacs
src/emacs -Q --batch -L test/src \
  -l test/src/multicursor-tests.el -f ert-run-tests-batch-and-exit
git diff --check
git add src/multicursor.c src/Makefile.in src/emacs.c src/lisp.h \
  test/src/multicursor-tests.el
git commit -m "Add disjoint buffer edit primitive"
```

## Task 7: Transactional insertion, replacement, and deletion

**Files:**

- Modify: `lisp/multi-cursor.el`
- Modify: `test/lisp/multi-cursor-tests.el`

### Step 1: Test editing as one command

Cover `self-insert-command`, `delete-char`, `delete-backward-char`, active-region replacement, mixed empty/non-empty selections, undo/redo, read-only failures, quit during validation and during a large active batch, and modification-hook errors on the first, middle, and final edits. Include marker gravity at selection endpoints, narrowing and exact `point-min`/`point-max` edits, adjacent selections, overlapping derived deletion ranges, and different-sized descending edits. One invocation must create one undo boundary and never leave a partially edited buffer. Specify and test the first checkpoint's deliberate undo policy: each broadcast self-insert is one undo unit; consecutive characters are not amalgamated until a later compatibility slice adds one outer `undo-auto-amalgamate` call per broadcast command.

### Step 2: Build normalized edit vectors

Snapshot all primary and secondary states first. Convert the command into a vector of disjoint replacements, merging touching active replacement selections and overlapping/adjacent derived deletion ranges according to the design's oldest-ID/primary-survival rules. Preflight grapheme boundaries, fields, narrowing, and read-only constraints in the command-specific handler. Detach cursor markers while applying the vector and map returned positions back to the primary and secondary cursor records.

```elisp
(let ((handle (prepare-change-group)))
  (unwind-protect
      (progn
        (activate-change-group handle)
        (setq positions (multi-cursor--apply-edits edits))
        (accept-change-group handle)
        (setq handle nil))
    (when handle
      (cancel-change-group handle))))
```

The Lisp wrapper is the only transaction owner. The C primitive neither starts nor accepts a change group. This is safe because handlers call low-level buffer changes rather than replaying `self-insert-command` or deletion commands that amalgamate undo internally.

### Step 3: Verify and commit

```bash
make -j2 src/emacs
src/emacs -Q --batch -L lisp -L test/lisp -L test/src \
  -l test/lisp/multi-cursor-tests.el \
  -l test/src/multicursor-tests.el \
  -f ert-run-tests-batch-and-exit
git add lisp/multi-cursor.el test/lisp/multi-cursor-tests.el
git commit -m "Apply transactional multiple cursor edits"
```

## Task 8: Generic redisplay decoration contract

**Files:**

- Modify: `src/window.h`
- Modify: `src/window.c`
- Modify: `src/dispextern.h`
- Modify: `src/xdisp.c`
- Modify: `src/dispnew.c`
- Create: `test/misc/multi-cursor-tests/source-invariants.el`

### Step 1: Add source-invariant tests

Assert that the redisplay interface has a secondary-decoration callback, `update_window` invokes it after the primary cursor is positioned, and no backend is required to mutate `w->phys_cursor` for a secondary cursor.

### Step 2: Define a backend-neutral descriptor

```c
struct cursor_decoration
{
  struct glyph_row *row;
  int x, y, height;
  enum text_cursor_kinds kind;
  bool on;
};
```

Expose one immutable, sorted Lisp snapshot on the selected window during redisplay. Resolve all visible positions in a single scan of existing glyph rows using the same bidi, display-string, invisible-text, composition, image, EOL, and clipping rules as the primary cursor; never call `pos-visible-in-window-p` once per cursor. Store old and new resolved decoration caches in non-Lisp window state and add this optional redisplay-interface callback:

```c
void (*draw_window_cursor_decorations)
  (struct window *, const struct cursor_decoration *, ptrdiff_t);
```

Before row scrolling or reuse, erase old decorations by redrawing their underlying glyphs/rows. For the correctness-first implementation, mark decorated windows as ineligible for scrolling reuse. After ordinary glyph and overlapping-row repair, call the painter once and draw the primary cursor last. Exposure and mouse-face repair must repaint intersecting decorations. An absent callback selects the Lisp face-overlay fallback, not a crash. Limit the first implementation to the selected window showing the active session buffer.

### Step 3: Verify and commit

```bash
src/emacs -Q --batch -L test/misc/multi-cursor-tests \
  -l test/misc/multi-cursor-tests/source-invariants.el \
  -f ert-run-tests-batch-and-exit
make -j2 src/emacs
git diff --check
git add src/window.h src/window.c src/dispextern.h src/xdisp.c src/dispnew.c \
  test/misc/multi-cursor-tests/source-invariants.el
git commit -m "Expose secondary cursor redisplay decorations"
```

## Task 9: Native Mac cursor painter

**Files:**

- Modify: `src/macterm.c`
- Modify: `test/misc/multi-cursor-tests/source-invariants.el`
- Create: `test/manual/multi-cursor-tests.el`

### Step 1: Test structural integration

Check that the Mac redisplay interface installs the callback, the painter uses existing cursor color/shape helpers, and it does not assign to `w->phys_cursor` or schedule one draw per cursor through GCD.

### Step 2: Implement stateless batch painting

Paint all decorations in one backend call using the current graphics context. Match the primary cursor's bar/box/hollow-box rules, clipping, HiDPI scale, and fringe/window bounds. Keep primary cursor blinking and overwrite bookkeeping unchanged.

The manual fixture should create hundreds of cursors in a large buffer and provide commands to toggle bar/box cursor types, scroll, resize, switch windows, and test active/inactive frame colors.

### Step 3: Verify and commit

```bash
src/emacs -Q --batch -L test/misc/multi-cursor-tests \
  -l test/misc/multi-cursor-tests/source-invariants.el \
  -f ert-run-tests-batch-and-exit
make -j2 src/emacs
git diff --check
git add src/macterm.c test/misc/multi-cursor-tests/source-invariants.el \
  test/manual/multi-cursor-tests.el
git commit -m "Draw native multiple cursors on Mac"
```

## Task 10: Selection rendering and session exit

**Files:**

- Modify: `lisp/multi-cursor.el`
- Modify: `test/lisp/multi-cursor-tests.el`

### Step 1: Test presentation lifecycle

Assert one overlay per active secondary selection, no overlay for an inactive mark, overlay movement after edits, a face-overlay caret fallback when the current terminal has no native decoration callback, cleanup on mode disable/buffer kill, and the two-stage `keyboard-quit` contract: first deactivate all selections, then exit the session without changing text.

### Step 2: Implement overlays as the first selection renderer

Use dedicated caret and region faces, with the region face inheriting from `region`; set overlay evaporation and selected-window restrictions; rebuild only when cursor snapshots change. Native secondary carets and fallback caret overlays are mutually exclusive. Register `keyboard-quit` with a custom run-once handler implementing the two-stage exit contract.

### Step 3: Verify and commit

```bash
src/emacs -Q --batch -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el -f ert-run-tests-batch-and-exit
git add lisp/multi-cursor.el test/lisp/multi-cursor-tests.el
git commit -m "Render and exit multiple cursor sessions"
```

## Task 11: Plain kill and yank integration

**Files:**

- Modify: `lisp/multi-cursor.el`
- Modify: `test/lisp/multi-cursor-tests.el`

### Step 1: Specify first-checkpoint clipboard semantics

Test that `kill-region`, `kill-line`, and `kill-word` compute every range before editing; concatenate killed text in buffer order using the command's normal separator; update the kill ring once; and edit atomically. Cover failures before editing, during the buffer transaction, and while updating Lisp kill-ring state. Test that `yank` snapshots `current-kill` once—including interprogram-paste effects—and inserts the same string at every cursor while preserving primary mark direction and ordinary `this-command`/`last-command` conventions.

This checkpoint deliberately does not distribute different kill-ring entries and does not implement `yank-pop`; both require the later per-cursor last-yank protocol.

### Step 2: Add custom handlers

Register kill commands with explicit custom handlers and `yank` with a batch-edit handler. Stage all killed text before changing the buffer, snapshot and restore Lisp kill-ring variables on a recoverable failure, and invoke external clipboard export only after the buffer transaction succeeds. Document that an external clipboard callback's side effects cannot be rolled back. Capture `current-kill` and any interprogram-paste mutation once before yank editing. Register `yank-pop` as unsupported until the distributed-yank follow-up.

### Step 3: Verify and commit

```bash
src/emacs -Q --batch -L lisp -L test/lisp \
  -l test/lisp/multi-cursor-tests.el -f ert-run-tests-batch-and-exit
git add lisp/multi-cursor.el test/lisp/multi-cursor-tests.el
git commit -m "Integrate kill and yank with multiple cursors"
```

## Task 12: Documentation, benchmarks, and checkpoint validation

**Files:**

- Modify: `doc/emacs/killing.texi`
- Modify: `doc/emacs/emacs.texi`
- Create: `doc/lispref/multiple-cursors.texi`
- Modify: `doc/lispref/elisp.texi`
- Modify: `etc/NEWS`
- Modify: `README.md`
- Create: `test/benchmarks/multi-cursor-benchmarks.el`
- Modify: `test/manual/multi-cursor-tests.el`

### Step 1: Document the contract

Add a user-manual section near regions and rectangles covering creation, cycling, two-stage C-g, kill/yank, TTY/accessibility behavior, package migration names, and limitations. Add an Elisp reference node for ownership, immutable snapshots, and command-policy registration. Document unsupported-command behavior, undo atomicity, selected-window rendering, backend fallback, and deliberately deferred behaviors. Add a NEWS entry scoped to the experimental native facility and a concise README note only after the checkpoint has passed its tests.

### Step 2: Add reproducible benchmarks

Benchmark 1, 2, 10, 100, and 1,000 cursors in 10 KiB, 1 MiB, and 100 MiB buffers for insertion, deletion, horizontal and vertical movement, session normalization, and a redisplay-forcing edit. Compare native cursors with ordinary single-cursor Emacs and `multiple-cursors.el` when the package is available. Include clustered and evenly spaced positions plus ASCII, combining-character, and bidi-heavy text. Report median and p95 elapsed time, garbage collections, bytes consed, undo growth, hook counts, and redisplay/Metal statistics. Keep fixture generation outside the measured form.

Run:

```bash
src/emacs -Q --batch -L lisp -L test/benchmarks \
  -l test/benchmarks/multi-cursor-benchmarks.el \
  --eval '(multi-cursor-benchmark-batch)'
```

Expected: a table for every cursor count and operation, with no errors or missing cases. The checkpoint is not declared faster unless the 100- and 1,000-cursor median and p95 results beat the package under the same configuration. Save baseline numbers in the commit message or an adjacent results comment, not as a claimed cross-machine threshold.

### Step 3: Run the checkpoint suite

```bash
make -j2 src/emacs
src/emacs -Q --batch -L lisp -L test/lisp -L test/src \
  -l test/lisp/multi-cursor-tests.el \
  -l test/src/multicursor-tests.el \
  -f ert-run-tests-batch-and-exit
src/emacs -Q --batch -L test/misc/multi-cursor-tests \
  -l test/misc/multi-cursor-tests/source-invariants.el \
  -f ert-run-tests-batch-and-exit
make -C test check-maybe
git diff --check
```

Manually run `test/manual/multi-cursor-tests.el` in the Mac app and verify cursor shapes, scrolling, clipping, frame activation, undo, quit, and a 1,000-cursor edit.

### Step 4: Commit and publish the checkpoint

```bash
git add doc/emacs/killing.texi doc/emacs/emacs.texi \
  doc/lispref/multiple-cursors.texi doc/lispref/elisp.texi \
  etc/NEWS README.md test/benchmarks/multi-cursor-benchmarks.el \
  test/manual/multi-cursor-tests.el
git commit -m "Document and benchmark native multiple cursors"
git status --short --branch
git log --oneline --decorate fork/nemesis..HEAD
git push -u fork HEAD:codex/native-multiple-cursors
```

## Follow-up implementation plans

After this checkpoint is measured and reviewed, write separate plans in this order:

1. electric-pair, electric-indent, abbrev, and auto-fill integration;
2. syntax-aware indentation and commands whose effects depend on preceding cursor edits;
3. distributed kill/yank and richer clipboard policies;
4. redisplay damage tracking and scaling optimization from benchmark evidence;
5. native painters for other graphical backends and terminal fallback behavior;
6. upstream-facing API review, naming review, and user customization surface.

Each follow-up must keep command behavior explicit. Do not fall back to replaying arbitrary commands at every cursor.

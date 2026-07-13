# Native Multiple Cursors Design

## Status

Approved architecture for implementation on branch
`codex/native-multiple-cursors`, based on `fork/nemesis`.

## Goal

Add a built-in, VS Code-like multiple-cursor editing mode whose supported
operations are faster, more predictable, and more tightly integrated with
Emacs than replaying ordinary interactive commands at overlay-based fake
cursors.

The feature is named `multi-cursor-mode`.  The `multi-cursor-` namespace
avoids conflicts with Magnar Sveen's `multiple-cursors` package and its
`multiple-cursors-mode` and `mc/` APIs.

## Design principles

1. The existing Emacs point and mark remain the primary cursor.
2. One user command has one command-loop envelope and one logical result.
3. Supported editing commands operate on a normalized cursor set as a batch.
4. Unsupported commands fail before changing text.
5. Secondary carets are native redisplay decorations, not cursor overlays.
6. Existing Emacs buffer-change, font-lock, narrowing, read-only, and undo
   contracts remain authoritative.
7. The initial feature is intentionally bounded; compatibility is extended by
   explicit command handlers rather than optimistic interactive replay.
8. Performance claims are accepted only after comparison with
   `multiple-cursors.el` using repeatable benchmarks.

## User-visible scope

### First usable checkpoint

The first usable checkpoint provides:

- a buffer-local `multi-cursor-mode`;
- programmatic cursor addition and removal;
- cursor addition above and below the primary cursor;
- cursor creation on each line covered by a region;
- selection of the next, previous, and all literal occurrences;
- an opt-in mouse command for adding or removing a cursor;
- independent active selections and selection direction;
- character, word, beginning/end-of-line, and logical-line movement;
- plain character insertion;
- forward and backward deletion;
- replacement of active selections;
- one logical undo result for a broadcast edit;
- atomic rollback for unexpected errors, quitting, and read-only failures;
- native secondary-caret rendering in the Mac port; and
- cursor count plus next/previous cursor cycling for accessibility.

### Compatibility checkpoints

Later checkpoints on the same branch add, in order:

1. plain broadcast yank and multi-selection kill;
2. newline and open-line behavior;
3. electric pair, electric indent, abbrev, and auto-fill compatibility;
4. mode-specific indentation handlers;
5. distributed kill/yank payloads and `yank-pop`;
6. optimized redisplay damage; and
7. additional display backends when the generic interface has proven stable.

### Non-goals

The initial implementation does not provide:

- cross-buffer cursor sets;
- independent cursor sets per window;
- arbitrary interactive command replay;
- simultaneous isearch, query-replace, completion sessions, snippets, or
  recursive minibuffers at every cursor;
- keyboard-macro execution at every cursor;
- aliases for `multiple-cursors-mode` or any `mc/` symbol;
- persistence across revert or major-mode changes; or
- secondary OS accessibility, IME, or system carets.

## User interaction

The feature exposes these commands:

- `multi-cursor-mode`
- `multi-cursor-add-at-point`
- `multi-cursor-remove-at-point`
- `multi-cursor-remove-all`
- `multi-cursor-add-above`
- `multi-cursor-add-below`
- `multi-cursor-edit-lines`
- `multi-cursor-select-next-occurrence`
- `multi-cursor-select-previous-occurrence`
- `multi-cursor-select-all-occurrences`
- `multi-cursor-add-at-mouse`
- `multi-cursor-cycle-forward`
- `multi-cursor-cycle-backward`
- `multi-cursor-count`

No global bindings are installed.  Emacs already assigns important meanings
to common Meta- and Control-mouse combinations, so mouse integration is
explicitly opt-in.

Within `multi-cursor-mode`, `C-g` first deactivates active selections while
retaining the cursor set.  A subsequent `C-g` exits the mode and removes the
secondary cursors.  Return remains a newline command; it does not exit the
mode.

The mode line reports the total cursor count.  Cycling commands make a
secondary cursor primary and report messages such as "Cursor 3 of 12" so a
screen-reader user can inspect every cursor through the real Emacs point.

## State model

### Ownership

The cursor session is buffer-local.  Only one buffer can participate in a
session, and every secondary cursor marker must refer to that buffer.

The primary cursor is the ordinary buffer point, mark, and `mark-active`
state.  Secondary cursors are represented by internal records containing:

- a stable numeric identifier;
- a point marker;
- an optional mark marker;
- an independent active-selection flag;
- selection direction;
- an independent goal column for repeated vertical motion; and
- optional bounds describing the last yank at that cursor.

The public API does not expose mutable cursor records.  Functions that report
selections return integer snapshots.

### Window behavior

The initial feature renders secondary carets and regions only in the selected
window displaying the session buffer.  Selecting another window that displays
the same buffer moves the presentation to that window and adopts that
window's ordinary point as the primary cursor.  Other windows never acquire
an active or system caret from the cursor set.

### Lifecycle

Disabling the mode detaches every secondary marker and removes all visual
state.  Killing or reverting the buffer, changing major mode, or replacing
the buffer contents ends the session.  Narrowing retains cursors inside the
accessible portion and removes inaccessible secondary cursors after the
narrowing command, reporting the reduced count.

If Magnar Sveen's `multiple-cursors-mode` is active in the buffer, enabling
`multi-cursor-mode` signals a user error.  Loading the package without
activating its mode is harmless.

## Cursor normalization

The cursor set is normalized before every broadcast command and after every
movement:

1. A secondary cursor identical to the primary cursor is removed.
2. Secondary cursors with identical point, mark, active state, and direction
   collapse to the oldest stable cursor ID.
3. Coincident zero-width carets result in one operation, not repeated text.
4. Active selections are represented as half-open ranges while retaining
   point/mark direction separately.
5. Overlapping or touching replacement ranges are merged before editing.
6. When a merge includes the primary selection, the merged result remains
   primary; otherwise the oldest stable ID survives.
7. After replacement, the surviving cursor is placed at the end of the text
   inserted for the merged range and its selection becomes inactive.

Movement commands do not merge non-identical active selections merely because
their ranges overlap.  They normalize only exact duplicate cursor states after
movement.

## Command-loop integration

The existing editor command loop remains responsible for input, remapping,
prefix arguments, command history, top-level hooks, error reporting, and
redisplay.

The integration point is `command-execute`, immediately before its ordinary
`call-interactively` path.  The control flow is:

```text
read and remap key sequence
  -> pre-command-hook once
  -> ordinary undo-boundary preparation
  -> command-execute consumes the prefix once
  -> multi-cursor dispatcher or normal call-interactively
  -> post-command-hook once
  -> mark finalization once
  -> redisplay once
```

The dispatcher receives the remapped command, captured prefix, key sequence,
last input event, and current cursor set.  It never calls `command-execute`
recursively and never runs top-level pre/post-command hooks for secondary
cursors.

## Command policies

Every command used while the mode is active has one of these policies:

- `broadcast-movement`: invoke a point/mark movement operation for every
  cursor while preserving independent cursor state;
- `batch-edit`: compute and apply a set of edits transactionally;
- `run-once`: execute the ordinary command at the primary cursor without
  ending the session;
- `custom-handler`: call a registered multi-cursor implementation; or
- `unsupported`: signal a user error before the command changes text.

Unknown commands use the `unsupported` policy.  Core explicitly marks common
display, scrolling, recentering, saving, and cursor-management commands as
`run-once`.  This avoids both silent primary-only edits and the package's
persistent interactive allowlist prompt.

A documented registration function lets another built-in feature or package
associate a command with a policy and optional custom handler.  Registration
changes command behavior globally, while the handler receives the active
cursor session explicitly.

Isearch, completion UIs, query-replace, keyboard macros, buffer-switching
commands, and recursive editing are initially unsupported.  Their own state
machines can gain explicit cursor-set integration later.

## Movement semantics

Movement handlers operate sequentially on saved cursor records because they
do not edit buffer text.  Each handler installs one cursor's point, mark,
mark-active state, and goal column, calls a noninteractive movement operation,
then saves the resulting state.

Expected `beginning-of-buffer` and `end-of-buffer` conditions are local to the
cursor: that cursor remains at the boundary while other cursors move.
Unexpected errors abort the command and restore the entire cursor snapshot.

Logical-line movement is included in the first checkpoint.  Visual-line
movement through wrapped, bidi-reordered, image, or variable-pitch display is
deferred until redisplay can provide an efficient multi-position geometry API.

## Batch editing

### Motivation

Ordinary Emacs markers form an unordered linked list, and each insertion or
deletion walks that list.  Replaying N editing commands while N cursor markers
remain attached can therefore produce quadratic cursor-maintenance work.

### Edit representation

Every batch-edit handler builds immutable edit records containing:

- original half-open start and end positions;
- replacement text and its text properties;
- the surviving cursor ID;
- the desired final point and selection state relative to the replacement;
  and
- the command-specific metadata needed for undo or kill/yank behavior.

The edit set is sorted by original position and validated before the first
modification.  Duplicate carets and overlapping replacement ranges are
normalized as described above.

### Execution

During execution:

1. The complete cursor and undo state is snapshotted.
2. Every cursor-owned marker is detached and retained as integer char/byte
   positions.
3. Preflight checks narrowing, read-only text and properties, replacement
   validity, and handler-specific constraints for every edit.
4. Edits are applied from the end of the buffer toward the beginning.
5. Normal low-level buffer modification functions record undo and notify
   buffer-change hooks for the actual disjoint changes.
6. Cursor positions are reconstructed from original positions and accumulated
   edit deltas.
7. Cursor markers are reattached once and the primary state is restored to
   ordinary point and mark.

The batch engine does not pretend disjoint edits are one contiguous change.
`before-change-functions` and `after-change-functions` receive correct ranges
for each changed span.  Font-lock, syntax caches, modification ticks, file
locking, and buffer-modified state therefore continue to use normal Emacs
change notification.

### Initial handlers

The first handlers cover:

- plain character insertion without overwrite, abbrev, auto-fill, or electric
  behavior;
- replacement of active selections by inserted text;
- forward and backward character deletion using Emacs grapheme boundaries;
- forward and backward word deletion; and
- deletion of active selections.

At a buffer boundary, an empty deletion is a no-op for that cursor.  A
read-only failure anywhere aborts the complete batch.

Self-insertion compatibility features are added through dedicated handlers;
the implementation does not call `self-insert-command` once per cursor.

## Undo, errors, and quitting

One broadcast editing command produces one logical undo result.  Consecutive
plain self-insert batches may use Emacs's normal command-level amalgamation,
but amalgamation runs once per broadcast command, never inside an active
per-cursor replay loop.

The implementation cannot wrap repeated `self-insert-command` or
`delete-char` calls in `atomic-change-group`, because those commands manipulate
undo amalgamation in ways prohibited by the change-group contract.  The batch
engine uses lower-level modification and undo APIs and owns its transaction
boundary directly.

Before editing, the transaction records sufficient buffer-undo and cursor
state to restore the original text and cursor set.  On an unexpected error,
read-only violation, or quit:

1. all text changes from the batch are reversed;
2. the original primary and secondary cursor state is restored;
3. the transaction leaves no partial undo unit; and
4. the original condition is re-signaled so the normal command loop reports
   it.

Long cursor loops call the normal quit check at bounded intervals so `C-g`
remains responsive.

The transaction guarantees only buffer and cursor state.  Custom handlers that
cause external effects, modify other buffers, start processes, or mutate
global state must perform their own preflight and compensation or declare the
command unsupported.

## Kill and yank

The first kill/yank compatibility checkpoint broadcasts one snapshotted
kill-ring string at every cursor.  Reading or rotating the kill ring happens
once per command.

The later distributed-kill checkpoint uses one ordinary kill-ring entry whose
plain text is the selected strings joined by newlines in buffer order.  A
private yank-handler payload retains the original vector of strings.  When the
payload count matches the active cursor count, yank distributes one element
per cursor in buffer order; otherwise the plain string is broadcast at every
cursor.  External clipboard text always has a valid broadcast fallback.

`yank-pop` rotates the ordinary kill-ring pointer once, removes every previous
multi-cursor yank span, and applies the new broadcast or distributed payload as
one transaction.

## Public Lisp API

The supported programmatic API includes:

```elisp
(multi-cursor-add-selection beg end &optional active)
(multi-cursor-add-at-point)
(multi-cursor-remove-at-point)
(multi-cursor-remove-all)
(multi-cursor-count)
(multi-cursor-selections)
(multi-cursor-register-command command policy &optional handler)
```

`multi-cursor-selections` returns immutable integer snapshots in buffer order.
It never returns the internal marker objects.

The principal customization variables and faces are:

- `multi-cursor-max-cursors`, default 1000;
- `multi-cursor-edit-lines-short-lines`, with values `eol`, `skip`, `pad`, or
  `error` and default `eol`;
- `multi-cursor-face`;
- `multi-cursor-region-face`; and
- `multi-cursor-mode-hook`.

Occurrence commands use the active primary region.  Without one, they use the
symbol at point and signal a user error when no symbol exists.  Matching is
literal within the accessible portion, honors `case-fold-search`, skips
overlaps and duplicate selections, and does not wrap implicitly.

## Redisplay architecture

### Generic ownership

Secondary carets are generic window cursor decorations.  Lisp supplies a
snapshot of buffer positions and styles for the selected window.  Generic
redisplay owns position resolution, old/new damage, scrolling, exposure, and
redraw order.  A terminal backend is only a stateless painter of already
resolved cursor geometry.

The implementation does not convert `w->cursor`, `w->phys_cursor`, or the OS
system caret into arrays.  Those remain the single primary cursor.

### Position resolution

`xdisp.c` resolves the sorted secondary positions while producing or scanning
the visible glyph rows.  It shares the primary cursor's rules for:

- bidi-reordered and continued lines;
- display strings and cursor properties;
- invisible text and ellipses;
- composed and multicolumn characters;
- empty rows, newline glyphs, and narrowed `ZV`;
- images and fringe positions; and
- horizontal and vertical clipping.

Resolution is one pass over visible rows plus the sorted visible cursor list.
It does not call `pos-visible-in-window-p` or construct a display iterator once
per cursor.

### Damage and drawing

`dispnew.c` stores the resolved decorations from the completed update and:

1. erases old decorations before row scrolling or reuse;
2. updates ordinary glyph rows and overlapping-glyph repairs;
3. draws visible secondary decorations;
4. repairs decorations affected by exposure or mouse-face drawing; and
5. draws the primary cursor last.

The first correctness-oriented implementation may disable scrolling reuse for
a window with active cursor decorations.  A later optimization compares old
and new resolved geometry, erases only removed or moved decorations, and
re-enables row-copy scrolling after proving ghost-free behavior.

### Backend contract

A new redisplay-interface callback receives a batch of resolved, immutable
cursor-decoration structures.  Each structure contains glyph-row position,
pixel geometry, cursor kind, width, and resolved color.  The callback never
changes `w->phys_cursor`, activates a system caret, or performs marker lookup.

The Mac backend is implemented first for Core Graphics and Metal rendering.
It supports box, hollow, bar, and horizontal-bar secondary carets by extracting
stateless geometry and drawing helpers from the current primary-cursor code.
Secondary carets do not blink by default.

Backends without the callback use a face-overlay fallback.  TTY frames use
inverse-video or `multi-cursor-face`; a text terminal retains only one hardware
cursor.

### Selections

Secondary active selections initially use the same window-restricted face
overlay mechanism as Emacs's primary region.  This preserves mature behavior
for font-lock, bidi text, invisible text, and TTY display.  The overlays belong
only to presentation; command execution reads the cursor records.

Benchmarks separately measure selection-overlay cost.  Native selection spans
will be designed only if overlays are a demonstrated bottleneck.

## Integration with existing Emacs features

- Command remapping happens before dispatch, so major and minor mode maps
  remain authoritative.
- Top-level pre/post-command hooks run once per user command.
- Buffer-change hooks run for each actual disjoint edit span.
- Font-lock and syntax invalidation observe ordinary buffer changes.
- Narrowing and read-only properties are preflight requirements, not bypassed.
- Delete-selection behavior is handled by the batch edit.  Because
  `delete-selection-pre-hook` runs before `command-execute`, that hook gains an
  explicit multi-cursor guard that defers deletion when the upcoming command
  has a batch-edit policy.  The dispatcher then replaces every active
  selection, including the primary one, in the same transaction.
- Prefix arguments and input events are captured once and passed to every
  applicable handler.
- The primary point remains the only accessibility and IME caret.
- Third-party integration uses explicit command policies and handlers, not
  inspection of cursor overlays.

Mode-specific electric, abbrev, auto-fill, and indentation behavior is not
claimed until its dedicated compatibility tests pass.  Commands without a
policy fail without modifying text.

## Performance requirements

Benchmarks compare the native implementation with both single-cursor Emacs and
the current `multiple-cursors.el` package.

The benchmark matrix includes:

- 1, 2, 10, 100, and 1000 cursors;
- 10 KiB, 1 MiB, and 100 MiB buffers;
- clustered, evenly distributed, coincident, and overlapping selections;
- insert, delete, horizontal and logical-line movement, yank, newline, and
  indentation;
- ASCII, combining-character, and bidi-heavy text;
- undo enabled and disabled;
- no hooks, ordinary font-lock hooks, and electric/auto-fill configurations;
- redisplay inhibited and enabled; and
- Core Graphics and Metal rendering.

Measurements include median and 95th-percentile command latency, allocation
and GC, marker-update time, undo-list growth, buffer-change hook count,
redisplay time, rows redrawn, Metal frame/presentation statistics, and quit
latency.

Acceptance requirements are:

1. With no active cursor session, the dispatcher and redisplay additions show
   no statistically significant regression beyond benchmark noise.
2. For supported operations at 100 and 1000 cursors, median and p95 latency are
   lower than `multiple-cursors.el` under the same configuration.
3. Cursor-management time does not exhibit the package's cursor-marker
   quadratic growth when increasing from 100 to 1000 cursors.
4. One undo operation restores the complete last broadcast edit.
5. Error and quit tests leave byte-identical buffer contents and identical
   cursor snapshots.
6. Scrolling, exposure, resize, and repeated identical wrapped lines produce
   no cursor ghosting.

If an acceptance requirement fails, the corresponding optimization or
compatibility claim is not documented as complete.

## Testing strategy

### Lisp behavior tests

`test/lisp/multi-cursor-tests.el` covers:

- lifecycle, cursor addition/removal, normalization, and maximum count;
- buffer and selected-window ownership;
- occurrence and edit-lines commands;
- independent selection direction and region replacement;
- movement, goal columns, and boundary behavior;
- insertion, deletion, narrowing, read-only text, and multibyte graphemes;
- command policy and remapping behavior;
- prefix, event, `this-command`, and `last-command` state;
- exactly one top-level pre/post-command hook invocation;
- undo, rollback, quitting, and cleanup;
- kill/yank behavior when implemented; and
- package namespace and active-mode conflict handling.

Command-loop tests use `ert-simulate-command` where the surrounding command
state matters.

### C batch-edit tests

`test/src/multicursor-tests.el` exercises the lower-level batch primitive:

- sorted and unsorted edit input;
- duplicate and overlapping ranges;
- char/byte position reconstruction for multibyte text;
- marker detachment and reattachment;
- correct change notifications;
- undo-disabled buffers;
- rollback after an injected failure; and
- quit checks in large batches.

### Redisplay tests

Generic and Mac-specific tests cover:

- empty buffer, EOL, no-final-newline, and narrowed `ZV`;
- tabs, wide characters, combining characters, ligatures, and compositions;
- mixed LTR/R2L wrapped lines;
- invisible and display-string text;
- images, fringe positions, and horizontal scrolling;
- exposure, resize, row scrolling/reuse, and overlapping glyph repair;
- identical wrapped rows followed by insert, delete, and undo;
- primary-cursor blinking while secondary carets remain stable;
- Core Graphics and Metal paths; and
- TTY fallback without requiring a graphical display.

Source-invariant tests guard the separation between generic cursor-decoration
state and the single primary `phys_cursor`.

### Verification levels

Every logical commit runs the narrow tests introduced or affected by that
commit plus `git diff --check`.  Milestone commits additionally run the full
multi-cursor test files, relevant command/undo/marker tests, syntax-only
Objective-C compilation for Mac renderer changes, and interactive GUI smoke
tests where rendering is involved.

## Documentation

The implementation updates:

- `etc/NEWS` with the new mode and supported command scope;
- the Emacs manual near regions and rectangles with user commands, exit
  behavior, kill/yank semantics, and limitations;
- the Elisp reference manual with the cursor-set API, ownership, command-policy
  registration, and immutable snapshots; and
- `README.md` only when the first usable checkpoint is complete and verified
  in the emacs-mac fork.

Migration documentation maps common package commands to their native
equivalents without defining aliases.  Existing `multiple-cursors.el`
configurations continue to work unchanged until users explicitly migrate.

## Delivery and commit strategy

Implementation proceeds through small, recoverable commits:

1. Add cursor records, lifecycle, normalization, and Lisp API.
2. Add cursor creation and occurrence-selection commands.
3. Add command policies and movement broadcasting.
4. Add transactional insertion and selection replacement.
5. Add transactional deletion and grapheme handling.
6. Add undo, rollback, quitting, and read-only guarantees.
7. Add generic redisplay cursor decorations.
8. Add the native Mac cursor-decoration painter.
9. Add plain kill/yank support.
10. Add newline and electric editing compatibility.
11. Add indentation compatibility.
12. Add user and Lisp documentation plus repeatable benchmarks.
13. Optimize redisplay damage and expand backend support when measurements
    justify the work.

Each commit contains its tests and passes the relevant verification before the
next slice begins.  The branch is pushed to `fork` at meaningful milestones so
work is recoverable outside the local worktree.

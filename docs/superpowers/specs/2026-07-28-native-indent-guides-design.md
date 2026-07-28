# Native indentation guides

Design for a C implementation of indentation guides in the emacs-mac port,
replacing the Elisp `indent-bars` package with display-engine support.

Branch: `codex/native-indent-guides`, based on `nemesis`.

## Motivation

`indent-bars` produces excellent results but pays for them in Elisp. Its bars
are `display` and `face` text properties applied through a font-lock
`fontify-region` override, using per-window stipple bitmaps whose horizontal
rotation must be recomputed whenever a window's geometry changes, plus a
debounced timer and face remapping to move the current-depth highlight. Every
one of those mechanisms exists to work around the fact that Elisp cannot
participate in redisplay directly.

Implementing guides as a display feature removes the workarounds rather than
optimizing them. There is no text-property churn, no font-lock involvement, no
stipple remapping, and no timer. Emacs already treats one feature of this exact
shape natively — `display-fill-column-indicator` produces its glyph in
`display_line` and `extend_face_to_end_of_line` — and this design follows that
precedent.

## Scope

Full feature parity with `indent-bars` as configured in practice:

- Bars at each indentation stop, with per-depth face cycling.
- Bars continued through blank lines from surrounding context.
- Current-depth highlighting that follows point.
- Tree-sitter scope awareness.

Not in v1, and documented as such:

- Right-to-left rows.
- Pattern styles (dashed, zigzag). The drawing API accepts a pattern spec from
  the start so these can be added without changing the glyph format.

## Decisions

| Question | Decision |
| --- | --- |
| Rendering | New `INDENT_GUIDE_GLYPH` glyph type produced in `xdisp.c` |
| Depth data | Live scan per visible row, with a memo for blank runs |
| Tree-sitter | Lisp publishes a scope range; redisplay only reads it |
| Appearance | Solid bars in v1; pattern-capable backend API |
| Configuration | `display-indent-guides-*`, following the fill-column-indicator precedent |

### Why a glyph type rather than post-drawing pixels

The considered alternative was drawing vertical rules after each row, hooked
where `draw_row_fringe_bitmaps` is called. That is simpler, pixel-perfect, and
makes tabs trivial, but it is GUI-only and puts invalidation in our hands: every
row-background draw has to be sequenced so it cannot erase bars, and moving the
current-depth highlight requires explicitly forcing row redraws.

A glyph type makes guides first-class display objects. Horizontal scrolling,
clipping, expose handling, scroll-by-copy, and row diffing all work without
special cases. A changed highlight changes glyph contents, so once rows are
rebuilt, ordinary matrix diffing redraws exactly the affected rows and nothing
else — we never hand-manage invalidation, only decide when rows must be rebuilt
(see "Current depth"). It is also the shape an upstream submission would take,
which matters on a branch that tracks GNU master.

The cost is real and accepted: `dispextern.h` and eight backend draw switches
change, and tabs in indentation must be split.

## Architecture

All display logic lives in one new section of `xdisp.c`. The core is a single
post-pass over each completed glyph row:

```c
static void maybe_display_indent_guides (struct it *it, struct glyph_row *row);
```

called at the end of `display_line`. The row is built normally and then
decorated. Nothing threads through the character-production loop, so the change
to existing `xdisp.c` code is one call site.

### Components

- **Stop computation** — from a row's line start, derive bar columns and depth
  indices. A pure function of buffer text plus spacing and offset.
- **Row decoration** — map columns to glyph positions, overwrite spaces, split
  tab stretch glyphs. A separate path appends guides to otherwise-empty rows.
- **Style resolution** — depth index and current-scope state to a face id via
  `merge_faces`, as `fill_column_indicator` does.
- **Backend draw** — fill a thin rect inside the glyph cell.
- **Lisp layer** (`lisp/indent-guides.el`) — the minor mode, the per-mode
  spacing guess, and the scope hook.

### Files

| File | Change |
| --- | --- |
| `src/dispextern.h` | `INDENT_GUIDE_GLYPH` enum value, glyph union sub-struct |
| `src/xdisp.c` | Guide computation, row pass, glyph-string case, variables, faces |
| `src/macterm.c` | `mac_draw_indent_guide_glyph_string` |
| `src/xterm.c`, `w32term.c`, `nsterm.m`, `pgtkterm.c`, `haikuterm.c`, `androidterm.c` | One draw case each, via a shared fallback |
| `lisp/indent-guides.el` | New: minor mode, spacing guess, tree-sitter scope |
| `etc/NEWS`, `doc/emacs/display.texi` | Documentation |

`term.c` and `dispnew.c` are untouched: on a text terminal the row pass emits a
`CHAR_GLYPH` carrying the configured guide character, not an
`INDENT_GUIDE_GLYPH`.

## Data flow

### Entry and bail-out

The pass returns immediately when:

- the buffer has `display-indent-guides` nil,
- the row is a continuation line — bars belong to the logical line's first
  screen row, matching `indent-bars` behaviour,
- `row->reversed_p` is set (R2L, out of scope for v1).

### Depth

Matching `indent-bars--depth` exactly. For leading-whitespace width `len` in
columns:

```
depth = len > offset ? 1 + (len - offset - 1) / spacing : 0
```

and stop `d` (1-based) sits at column `offset + (d - 1) * spacing`. The scan
expands tabs by `tab-width` and stops at the first non-whitespace character.

### Blank lines

A whitespace-only line takes the maximum of the indentation depths of the
nearest non-blank lines above and below, skipping intervening blank lines. This
is the rule `indent-bars--context-indentation` uses.

The blank-run memo caches that result for an entire run of blank lines, so a
long gap is scanned once per redisplay pass rather than once per row. It holds
no state across redisplay passes, so there is nothing to invalidate.

### Column to glyph

The pass walks the row's `TEXT_AREA` glyphs accumulating columns. Horizontal
scrolling falls out naturally: stops scrolled off the left find no glyph and are
skipped.

- A space glyph is overwritten in place.
- A tab is a stretch glyph spanning several columns and is split into
  stretch + guide + stretch, shifting the remaining glyphs. This is the
  fiddliest part of the implementation and gets dedicated tests.
- A blank row has no whitespace glyphs at all and takes a separate append path
  modeled on `append_space_for_newline`.

Guide glyphs carry the `charpos` and `object` of the whitespace they replace, so
clicking in indentation still sets point correctly. When a tab is split, all
three pieces keep the tab's position.

### Current depth

Computed in C at the start of `redisplay_window`, from the indentation of
point's line. No timer and no debounce, unlike the Elisp implementation.

The cost is explicit: as with `display-line-numbers` when the current line's
number uses a distinct face, enabling this must `GIVE_UP` in
`try_cursor_movement` (`src/xdisp.c:20722`) and `try_window_id`
(`src/xdisp.c:23551`), so moving point redisplays the window's rows. This is
still far cheaper than the Elisp path, which re-fontifies and remaps faces on a
timer, but the variable's documentation states it.

### Scope and string suppression

One buffer-local interface serves both tree-sitter scope awareness and
`indent-bars-no-descend-string` behaviour: Lisp publishes a vector of ranges plus
a depth cap in `display-indent-guides-scope`, and the row pass does integer
comparisons against it.

This is why neither `treesit` nor `syntax-ppss` ever runs inside redisplay.
Parsing is expensive and can signal; row building is the wrong place for either.
The interface is provider-agnostic, so anything that can compute ranges can feed
it.

## Rendering

### Glyph payload

The glyph union has 32 bits available, used as:

```c
struct
{
  unsigned depth   : 8;
  unsigned width   : 8;
  unsigned pad     : 8;
  unsigned pattern : 8;
} indent_guide;
```

Width and pad are resolved to pixels at row-build time, so a glyph is
self-describing at draw time even if a buffer variable changed in between. The
face comes from the glyph's existing `face_id` field.

### Backend

`mac_draw_indent_guide_glyph_string` sits next to
`mac_draw_stretch_glyph_string` (`src/macterm.c:2696`) and reuses its background
handling, so region and `hl-line` backgrounds show through correctly. The bar
itself is filled via `mac_fill_rectangle` (`src/macterm.c:665`); using that
primitive rather than raw Core Graphics is what keeps the feature working under
both the Core Graphics and Metal paths on this branch.

The fill entry point takes a pattern argument that v1 always passes as solid.
Because a native implementation can derive pattern phase from the row's y offset
in the window, dashed styles would come out continuous across lines without the
per-window stipple rotation `indent-bars` needs.

`draw_phys_cursor_glyph` needs a case so a block cursor sitting on indentation
renders sensibly over a guide glyph.

## Configuration

Buffer-local variables, following the `display-fill-column-indicator` naming
precedent:

| Variable | Default | Meaning |
| --- | --- | --- |
| `display-indent-guides` | `nil` | Enable guides in this buffer |
| `display-indent-guides-spacing` | mode guess | Columns between stops |
| `display-indent-guides-offset` | `0` | Column of the first stop |
| `display-indent-guides-width` | `0.25` | Bar width as a fraction of char width |
| `display-indent-guides-pad` | `0.1` | Bar offset within the cell |
| `display-indent-guides-max-depth` | `16` | Cap on drawn stops |
| `display-indent-guides-blank-lines` | `t` | Continue bars through blank lines |
| `display-indent-guides-highlight-current` | `nil` | Highlight the enclosing depth |
| `display-indent-guides-character` | `?│` | Text-terminal rendering |
| `display-indent-guides-scope` | `nil` | Range vector published by Lisp |

Faces: `indent-guide-1` through `indent-guide-8`, cycled by depth, plus
`indent-guide-current`.

`lisp/indent-guides.el` provides `indent-guides-mode`, the per-mode spacing
guess (as `indent-bars--guess-spacing` does), and the tree-sitter scope hook.

### Migration from indent-bars

No compatibility shim. The existing configuration translates directly:

| indent-bars | Native |
| --- | --- |
| `indent-bars-width-frac 0.25` | `display-indent-guides-width 0.25` |
| `indent-bars-pad-frac 0.1` | `display-indent-guides-pad 0.1` |
| `indent-bars-pattern "."` | default (solid) |
| `indent-bars-display-on-blank-lines t` | `display-indent-guides-blank-lines t` |
| `indent-bars-color-by-depth '(:regexp "outline-\\([0-9]+\\)")` | customize `indent-guide-N` faces |
| `indent-bars-treesit-support t` | `indent-guides-mode` with treesit available |

## Robustness

No C path may signal during redisplay.

- Every value read from a Lisp variable is type-checked and clamped: spacing at
  least 1, width no wider than the cell, depth capped. Anything invalid degrades
  to drawing no guides.
- Tab splitting checks remaining room in the row's glyph area and skips guides
  rather than overflowing it.
- Guides never overwrite a non-space glyph; enforced by both a runtime check and
  an `eassert`.
- No new Lisp objects are stored in glyphs, so pdumper is unaffected.

## Verification

The depth, blank-line, and tab logic is deterministic in text-terminal character
mode, so it is covered by batch tests on a text-terminal frame. That is where the
parts most likely to be wrong actually live.

GUI drawing is verified manually against a screenshot checklist: bar width and
padding, depth colours, current-depth highlight, region and `hl-line`
backgrounds behind bars, horizontal scrolling, tab-indented buffers, and cursor
on indentation.

Acceptance is a benchmark against `indent-bars` on a large indented file:
scroll a fixed number of screens and compare total redisplay time. The measured
result is recorded here once available.

## Implementation phases

1. Glyph type, mac drawing, solid bars on space-only indentation.
2. Tabs, horizontal scrolling, text-terminal character mode.
3. Depth faces, current-depth highlight, redisplay optimization give-ups.
4. Blank lines and the blank-run memo.
5. Lisp layer: minor mode, spacing guess, tree-sitter scope, string suppression.
6. Documentation, NEWS, benchmark.

# Native Indentation Guides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement indentation guides natively in the Emacs display engine as a
new `INDENT_GUIDE_GLYPH` glyph type, replacing the Elisp `indent-bars` package.

**Architecture:** A post-pass over each completed glyph row in `display_line`
decorates leading whitespace with guide glyphs. Bar positions come from a live
scan of the line's indentation; blank lines take context from their neighbours.
Tree-sitter scope and string suppression arrive through a buffer-local range
vector that Lisp publishes, so no parsing happens inside redisplay.

**Tech Stack:** C (Emacs display engine: `src/xdisp.c`, `src/dispextern.h`,
`src/macterm.c` and the other GUI backends), Emacs Lisp (`lisp/indent-guides.el`),
ERT for tests.

**Design doc:** `docs/superpowers/specs/2026-07-28-native-indent-guides-design.md`

---

## Ordering note

The design doc lists six phases with the glyph type first. This plan deliberately
front-loads the *pure logic* (Tasks 1-3) instead, because that logic is
unit-testable in batch Emacs while glyph decoration is not. Emacs does not run
redisplay in batch mode, and `dump-glyph-matrix` writes to stderr rather than
returning a value, so glyph rows cannot be asserted on from ERT.

The testing strategy that follows from this:

- **Tasks 1-3** (depth formula, blank-line context, scope suppression) get real
  batch ERT tests through an internal Lisp entry point. This is where the
  algorithmic complexity lives and where bugs are most likely.
- **Tasks 5-7** (decoration, tabs, blank rows) get interactive regression tests
  asserting that guides never disturb buffer positions — `posn-at-x-y` must
  return the same point with guides on and off. This is the invariant most
  likely to break when tab glyphs are split.
- **All tasks** are additionally validated by building with
  `--enable-checking=yes,glyphs`, which turns the `eassert` calls into real
  glyph-matrix corruption detection.
- **Visual correctness** is a manual screenshot checklist in Task 10.

## File structure

| File | Responsibility |
| --- | --- |
| `src/dispextern.h` | `INDENT_GUIDE_GLYPH` enum value, glyph union sub-struct, `struct it` memo fields |
| `src/xdisp.c` | All guide logic: scanning, stop computation, row decoration, glyph-string case, variables |
| `src/macterm.c` | Mac backend drawing |
| `src/xterm.c`, `w32term.c`, `nsterm.m`, `pgtkterm.c`, `haikuterm.c`, `androidterm.c` | One draw case each |
| `lisp/faces.el` | Guide face definitions |
| `lisp/indent-guides.el` | Minor mode, spacing guess, tree-sitter scope publisher |
| `test/src/xdisp-tests.el` | Batch logic tests and interactive position tests |
| `etc/NEWS`, `doc/emacs/display.texi` | Documentation |

## Build and test commands

Configure once, with checking enabled so `eassert` is live:

```bash
./autogen.sh
CFLAGS="-O0 -g3" ./configure --enable-mac-app=yes --enable-checking=yes,glyphs
make -j$(sysctl -n hw.ncpu)
```

Run the display tests:

```bash
make -C test src/xdisp-tests.log       # batch, logged
make -C test src/xdisp-tests           # interactive, needed for redisplay tests
```

---

### Task 1: Variables, faces, and the depth formula

**Files:**
- Modify: `src/xdisp.c` (new section before `display_line`, and `syms_of_xdisp`)
- Modify: `lisp/faces.el:2669` (after the `fill-column-indicator` face)
- Test: `test/src/xdisp-tests.el`

- [ ] **Step 1: Write the failing test**

Append to `test/src/xdisp-tests.el`:

```elisp
(defun xdisp-tests--guide-stops (text pos)
  "Return guide stops for the line containing POS in a buffer with TEXT."
  (with-temp-buffer
    (insert text)
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local tab-width 8)
    (internal--indent-guide-stops pos)))

(ert-deftest xdisp-tests--indent-guide-stops-none ()
  "A line with no indentation has no guides."
  (should (equal (xdisp-tests--guide-stops "foo\n" 1) nil)))

(ert-deftest xdisp-tests--indent-guide-stops-one ()
  "Four columns of indentation give one guide, at column 0."
  (should (equal (xdisp-tests--guide-stops "    foo\n" 1) '((0 . 1)))))

(ert-deftest xdisp-tests--indent-guide-stops-three ()
  "Twelve columns of indentation give three guides."
  (should (equal (xdisp-tests--guide-stops "            foo\n" 1)
                 '((0 . 1) (4 . 2) (8 . 3)))))

(ert-deftest xdisp-tests--indent-guide-stops-partial ()
  "Indentation that does not land on a stop still yields the passed stops."
  (should (equal (xdisp-tests--guide-stops "      foo\n" 1)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-stops-tabs ()
  "A tab expands by `tab-width' when measuring indentation."
  (should (equal (xdisp-tests--guide-stops "\tfoo\n" 1)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-stops-offset ()
  "`display-indent-guides-offset' shifts the first stop."
  (with-temp-buffer
    (insert "        foo\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 2)
    (should (equal (internal--indent-guide-stops 1) '((2 . 1) (6 . 2))))))

(ert-deftest xdisp-tests--indent-guide-stops-disabled ()
  "No guides when the feature is off in this buffer."
  (with-temp-buffer
    (insert "        foo\n")
    (setq-local display-indent-guides nil)
    (should (equal (internal--indent-guide-stops 1) nil))))

(ert-deftest xdisp-tests--indent-guide-stops-max-depth ()
  "`display-indent-guides-max-depth' caps the number of guides."
  (with-temp-buffer
    (insert (make-string 40 ?\s) "foo\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local display-indent-guides-max-depth 3)
    (should (equal (internal--indent-guide-stops 1)
                   '((0 . 1) (4 . 2) (8 . 3))))))

(ert-deftest xdisp-tests--indent-guide-stops-bad-spacing ()
  "A nonsensical spacing degrades to no guides rather than signalling."
  (with-temp-buffer
    (insert "        foo\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 0)
    (should (equal (internal--indent-guide-stops 1) nil))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make -C test src/xdisp-tests.log`

Expected: FAIL, `void-function internal--indent-guide-stops`.

- [ ] **Step 3: Add the faces**

In `lisp/faces.el`, immediately after the `fill-column-indicator` defface that
ends near line 2680, add:

```elisp
(defface indent-guide-1
  '((t :inherit shadow))
  "Face for indentation guides at depth 1, and every 8th depth after it."
  :version "32.1"
  :group 'basic-faces)

(defface indent-guide-2 '((t :inherit indent-guide-1))
  "Face for indentation guides at depth 2." :version "32.1" :group 'basic-faces)
(defface indent-guide-3 '((t :inherit indent-guide-1))
  "Face for indentation guides at depth 3." :version "32.1" :group 'basic-faces)
(defface indent-guide-4 '((t :inherit indent-guide-1))
  "Face for indentation guides at depth 4." :version "32.1" :group 'basic-faces)
(defface indent-guide-5 '((t :inherit indent-guide-1))
  "Face for indentation guides at depth 5." :version "32.1" :group 'basic-faces)
(defface indent-guide-6 '((t :inherit indent-guide-1))
  "Face for indentation guides at depth 6." :version "32.1" :group 'basic-faces)
(defface indent-guide-7 '((t :inherit indent-guide-1))
  "Face for indentation guides at depth 7." :version "32.1" :group 'basic-faces)
(defface indent-guide-8 '((t :inherit indent-guide-1))
  "Face for indentation guides at depth 8." :version "32.1" :group 'basic-faces)

(defface indent-guide-current
  '((t :inherit indent-guide-1 :weight bold))
  "Face for the indentation guide of the block containing point.
Used only when `display-indent-guides-highlight-current' is non-nil."
  :version "32.1"
  :group 'basic-faces)
```

- [ ] **Step 4: Add the C variables**

In `src/xdisp.c`, inside `syms_of_xdisp` next to the
`display-fill-column-indicator` block near line 40062, add:

```c
  DEFVAR_LISP ("display-indent-guides", Vdisplay_indent_guides,
    doc: /* Non-nil means display vertical guides in leading indentation.
Guides are drawn at every `display-indent-guides-spacing' columns, starting
at `display-indent-guides-offset'.  */);
  Vdisplay_indent_guides = Qnil;
  DEFSYM (Qdisplay_indent_guides, "display-indent-guides");
  Fmake_variable_buffer_local (Qdisplay_indent_guides);

  DEFVAR_LISP ("display-indent-guides-spacing", Vdisplay_indent_guides_spacing,
    doc: /* Number of columns between indentation guides.
The value should be a positive integer.  Any other value disables guides
in this buffer.  */);
  Vdisplay_indent_guides_spacing = make_fixnum (4);
  DEFSYM (Qdisplay_indent_guides_spacing, "display-indent-guides-spacing");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_spacing);

  DEFVAR_LISP ("display-indent-guides-offset", Vdisplay_indent_guides_offset,
    doc: /* Column of the first indentation guide.  */);
  Vdisplay_indent_guides_offset = make_fixnum (0);
  DEFSYM (Qdisplay_indent_guides_offset, "display-indent-guides-offset");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_offset);

  DEFVAR_LISP ("display-indent-guides-max-depth",
	       Vdisplay_indent_guides_max_depth,
    doc: /* Maximum number of indentation guides to draw on one line.  */);
  Vdisplay_indent_guides_max_depth = make_fixnum (16);
  DEFSYM (Qdisplay_indent_guides_max_depth, "display-indent-guides-max-depth");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_max_depth);
```

And register the test entry point, next to `defsubr (&Sdump_glyph_matrix);` at
line 39289:

```c
  defsubr (&Sinternal__indent_guide_stops);
```

- [ ] **Step 5: Implement the scan and stop computation**

In `src/xdisp.c`, add a new section immediately before `display_line` (which
starts at line 26702):

```c
/***********************************************************************
			  Indentation guides
 ***********************************************************************/

/* Hard cap on guides per line, independent of user configuration.  The
   glyph's depth field is 8 bits, and a row cannot usefully hold more.  */
#define INDENT_GUIDE_MAX_DEPTH 64

/* Configuration for indentation guides in the current buffer, read once
   per row and validated so that redisplay never has to check again.  */

struct indent_guide_config
{
  bool enabled;
  int spacing;
  int offset;
  int max_depth;
};

/* Fill CFG from the buffer-local variables.  Set CFG->enabled to false
   for any configuration we cannot use, so that a bad user value results
   in no guides rather than a signal inside redisplay.  */

static void
indent_guide_get_config (struct indent_guide_config *cfg)
{
  cfg->enabled = false;
  cfg->spacing = 0;
  cfg->offset = 0;
  cfg->max_depth = 0;

  if (NILP (Vdisplay_indent_guides))
    return;
  if (!FIXNUMP (Vdisplay_indent_guides_spacing)
      || !FIXNUMP (Vdisplay_indent_guides_offset)
      || !FIXNUMP (Vdisplay_indent_guides_max_depth))
    return;

  EMACS_INT spacing = XFIXNUM (Vdisplay_indent_guides_spacing);
  EMACS_INT offset = XFIXNUM (Vdisplay_indent_guides_offset);
  EMACS_INT max_depth = XFIXNUM (Vdisplay_indent_guides_max_depth);

  if (spacing < 1 || offset < 0 || max_depth < 1)
    return;
  if (spacing > INDENT_GUIDE_MAX_DEPTH * 64 || offset > INT_MAX / 2)
    return;

  cfg->enabled = true;
  cfg->spacing = min (spacing, INT_MAX / 2);
  cfg->offset = offset;
  cfg->max_depth = min (max_depth, INDENT_GUIDE_MAX_DEPTH);
}

/* Number of guides for leading whitespace LEN columns wide.  This is the
   same formula `indent-bars' uses, so that the two agree visually.  */

static int
indent_guide_depth (int len, const struct indent_guide_config *cfg)
{
  if (len > cfg->offset)
    return 1 + (len - cfg->offset - 1) / cfg->spacing;
  return 0;
}

/* Column of guide number DEPTH, counting from 1.  */

static int
indent_guide_column (int depth, const struct indent_guide_config *cfg)
{
  return cfg->offset + (depth - 1) * cfg->spacing;
}

/* Measure the leading whitespace of the line starting at buffer position
   BEG.  Store its width in columns in *WIDTH.  Return true if the line
   contains a non-whitespace character, false if it is blank (whitespace
   up to the newline, or up to ZV).  */

static bool
indent_guide_line_indentation (ptrdiff_t beg, int tab_width, int *width)
{
  ptrdiff_t pos = beg;
  ptrdiff_t pos_byte = CHAR_TO_BYTE (beg);
  int col = 0;

  while (pos < ZV)
    {
      int c = FETCH_BYTE (pos_byte);

      if (c == ' ')
	col++;
      else if (c == '\t')
	col += tab_width - (col % tab_width);
      else
	{
	  *width = col;
	  return c != '\n';
	}
      pos++;
      pos_byte++;
    }

  *width = col;
  return false;
}
```

`FETCH_BYTE` is safe here because both space and tab are ASCII, and any
multibyte lead byte compares unequal to both and ends the scan.

- [ ] **Step 6: Implement the test entry point**

Still in `src/xdisp.c`, after the functions from Step 5:

```c
DEFUN ("internal--indent-guide-stops", Finternal__indent_guide_stops,
       Sinternal__indent_guide_stops, 1, 1, 0,
       doc: /* Return the indentation guides for the line containing POS.
The value is a list of (COLUMN . DEPTH) pairs, in increasing column
order, or nil if this line has no guides.  This function exists for
testing the display code and should not be used in Lisp programs.  */)
  (Lisp_Object pos)
{
  CHECK_FIXNUM_COERCE_MARKER (pos);

  struct indent_guide_config cfg;
  indent_guide_get_config (&cfg);
  if (!cfg.enabled)
    return Qnil;

  ptrdiff_t charpos = clip_to_bounds (BEGV, XFIXNUM (pos), ZV);
  ptrdiff_t beg = find_newline (charpos, -1, 0, -1, -1, NULL, NULL, false);

  int tab_width = SANE_TAB_WIDTH (current_buffer);
  int width;
  indent_guide_line_indentation (beg, tab_width, &width);

  int depth = min (indent_guide_depth (width, &cfg), cfg.max_depth);
  Lisp_Object result = Qnil;
  for (int d = depth; d >= 1; d--)
    result = Fcons (Fcons (make_fixnum (indent_guide_column (d, &cfg)),
			   make_fixnum (d)),
		    result);
  return result;
}
```

- [ ] **Step 7: Build**

Run: `make -j$(sysctl -n hw.ncpu)`
Expected: builds clean, no warnings from the new code.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `make -C test src/xdisp-tests.log`
Expected: all nine `xdisp-tests--indent-guide-stops-*` tests PASS.

- [ ] **Step 9: Commit**

```bash
git add src/xdisp.c lisp/faces.el test/src/xdisp-tests.el
git commit -m "Add indentation guide configuration and depth computation"
```

---

### Task 2: Blank-line context and the blank-run memo

**Files:**
- Modify: `src/xdisp.c` (indentation guides section from Task 1)
- Modify: `src/dispextern.h` (`struct it` memo fields)
- Test: `test/src/xdisp-tests.el`

- [ ] **Step 1: Write the failing test**

Append to `test/src/xdisp-tests.el`:

```elisp
(defun xdisp-tests--guide-stops-blank (text pos)
  "Return guide stops for TEXT at POS with blank-line guides enabled."
  (with-temp-buffer
    (insert text)
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local display-indent-guides-blank-lines t)
    (setq-local tab-width 8)
    (internal--indent-guide-stops pos)))

(ert-deftest xdisp-tests--indent-guide-blank-between ()
  "A blank line between two indented lines takes the deeper context."
  ;; Line 2 is blank; neighbours are indented 4 and 8 columns.
  (should (equal (xdisp-tests--guide-stops-blank "    a\n\n        b\n" 7)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-blank-run ()
  "All lines of a blank run get the same context."
  (let ((text "        a\n\n\n\n    b\n"))
    ;; Positions 11, 12 and 13 are the three blank lines.
    (should (equal (xdisp-tests--guide-stops-blank text 11)
                   '((0 . 1) (4 . 2))))
    (should (equal (xdisp-tests--guide-stops-blank text 12)
                   '((0 . 1) (4 . 2))))
    (should (equal (xdisp-tests--guide-stops-blank text 13)
                   '((0 . 1) (4 . 2))))))

(ert-deftest xdisp-tests--indent-guide-blank-at-bob ()
  "A blank line with no previous non-blank line uses the following one."
  (should (equal (xdisp-tests--guide-stops-blank "\n        b\n" 1)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-blank-at-eob ()
  "A blank line with no following non-blank line uses the previous one."
  (should (equal (xdisp-tests--guide-stops-blank "        a\n\n" 11)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-blank-disabled ()
  "With blank-line guides off, a blank line has no guides."
  (with-temp-buffer
    (insert "        a\n\n        b\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local display-indent-guides-blank-lines nil)
    (should (equal (internal--indent-guide-stops 11) nil))))

(ert-deftest xdisp-tests--indent-guide-whitespace-only-line ()
  "A line of only whitespace counts as blank, not as indentation."
  ;; Line 2 holds two spaces; context from neighbours is 8 columns deep.
  (should (equal (xdisp-tests--guide-stops-blank "        a\n  \n        b\n" 11)
                 '((0 . 1) (4 . 2)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make -C test src/xdisp-tests.log`
Expected: FAIL — `display-indent-guides-blank-lines` is void, and blank lines
currently return nil.

- [ ] **Step 3: Add the variable and memo fields**

In `src/xdisp.c`, `syms_of_xdisp`, after the Task 1 variables:

```c
  DEFVAR_LISP ("display-indent-guides-blank-lines",
	       Vdisplay_indent_guides_blank_lines,
    doc: /* Non-nil means draw indentation guides on blank lines.
The guides drawn on a blank line are those of the deeper of the nearest
non-blank lines above and below it.  */);
  Vdisplay_indent_guides_blank_lines = Qt;
  DEFSYM (Qdisplay_indent_guides_blank_lines,
	  "display-indent-guides-blank-lines");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_blank_lines);
```

In `src/dispextern.h`, inside `struct it`, next to the other bookkeeping
fields, add:

```c
  /* Memo for indentation guides on runs of blank lines.  Valid when
     GUIDE_MEMO_BEG < GUIDE_MEMO_END; covers the buffer range of one run
     of blank lines, whose common guide depth is GUIDE_MEMO_DEPTH.  Reset
     for each redisplay of a window.  */
  ptrdiff_t guide_memo_beg, guide_memo_end;
  int guide_memo_depth;
```

- [ ] **Step 4: Implement the context computation**

In `src/xdisp.c`, add after `indent_guide_line_indentation`:

```c
/* Return the guide depth for the blank line whose first character is at
   BEG.  This is the greater of the depths of the nearest non-blank lines
   above and below, skipping intervening blank lines, which is the rule
   `indent-bars' uses.  Store the buffer range of the whole blank run in
   *RUN_BEG and *RUN_END so callers can memoize the answer.  */

static int
indent_guide_blank_context (ptrdiff_t beg, int tab_width,
			    const struct indent_guide_config *cfg,
			    ptrdiff_t *run_beg, ptrdiff_t *run_end)
{
  ptrdiff_t line_beg = beg;
  int width;
  int prev_depth = 0, next_depth = 0;

  /* Walk backwards to the nearest non-blank line.  */
  ptrdiff_t p = line_beg;
  while (p > BEGV)
    {
      ptrdiff_t prev = find_newline (p - 1, -1, 0, -1, -1, NULL, NULL, false);
      if (indent_guide_line_indentation (prev, tab_width, &width))
	{
	  prev_depth = indent_guide_depth (width, cfg);
	  break;
	}
      p = prev;
    }
  *run_beg = p;

  /* Walk forwards to the nearest non-blank line.  */
  p = line_beg;
  while (p < ZV)
    {
      ptrdiff_t next = find_newline (p, 1, 0, 1, 1, NULL, NULL, false);
      if (next >= ZV)
	{
	  p = ZV;
	  break;
	}
      if (indent_guide_line_indentation (next, tab_width, &width))
	{
	  next_depth = indent_guide_depth (width, cfg);
	  p = next;
	  break;
	}
      p = next;
    }
  *run_end = p;

  return max (prev_depth, next_depth);
}

/* Guide depth for the line starting at BEG.  IT may be NULL, in which
   case the blank-run memo is not used.  */

static int
indent_guide_line_depth (struct it *it, ptrdiff_t beg, int tab_width,
			 const struct indent_guide_config *cfg)
{
  int width;

  if (indent_guide_line_indentation (beg, tab_width, &width))
    return min (indent_guide_depth (width, cfg), cfg->max_depth);

  if (NILP (Vdisplay_indent_guides_blank_lines))
    return 0;

  if (it && it->guide_memo_beg < it->guide_memo_end
      && beg >= it->guide_memo_beg && beg < it->guide_memo_end)
    return it->guide_memo_depth;

  ptrdiff_t run_beg, run_end;
  int depth = min (indent_guide_blank_context (beg, tab_width, cfg,
					       &run_beg, &run_end),
		   cfg->max_depth);
  if (it)
    {
      it->guide_memo_beg = run_beg;
      it->guide_memo_end = run_end;
      it->guide_memo_depth = depth;
    }
  return depth;
}
```

- [ ] **Step 5: Route the test entry point through the new function**

In `Finternal__indent_guide_stops`, replace the two lines

```c
  int width;
  indent_guide_line_indentation (beg, tab_width, &width);

  int depth = min (indent_guide_depth (width, &cfg), cfg.max_depth);
```

with

```c
  int depth = indent_guide_line_depth (NULL, beg, tab_width, &cfg);
```

- [ ] **Step 6: Initialize the memo**

In `src/xdisp.c`, in `init_iterator`, next to the other `it->` field
initializations, add:

```c
  it->guide_memo_beg = it->guide_memo_end = 0;
  it->guide_memo_depth = 0;
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `make -j$(sysctl -n hw.ncpu) && make -C test src/xdisp-tests.log`
Expected: all Task 1 and Task 2 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add src/xdisp.c src/dispextern.h test/src/xdisp-tests.el
git commit -m "Compute indentation guide depth for blank lines"
```

---

### Task 3: Scope suppression

**Files:**
- Modify: `src/xdisp.c` (indentation guides section)
- Test: `test/src/xdisp-tests.el`

The scope value is a vector of the form `[DEPTH-CAP BEG END BEG END ...]`,
where `DEPTH-CAP` is the maximum depth to draw for lines inside any of the
following position ranges. This one structure serves both tree-sitter scope
limiting and `no-descend-string` behaviour. Lisp publishes it; C only reads it.

- [ ] **Step 1: Write the failing test**

Append to `test/src/xdisp-tests.el`:

```elisp
(ert-deftest xdisp-tests--indent-guide-scope-caps-depth ()
  "Lines inside a scope range are capped at the scope depth."
  (with-temp-buffer
    (insert "                a\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    ;; Without a scope, 16 columns give four guides.
    (should (equal (internal--indent-guide-stops 1)
                   '((0 . 1) (4 . 2) (8 . 3) (12 . 4))))
    ;; Cap depth at 2 for the whole buffer.
    (setq-local display-indent-guides-scope (vector 2 (point-min) (point-max)))
    (should (equal (internal--indent-guide-stops 1)
                   '((0 . 1) (4 . 2))))))

(ert-deftest xdisp-tests--indent-guide-scope-outside-range ()
  "Lines outside every scope range are not capped."
  (with-temp-buffer
    (insert "                a\n                b\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    ;; Cap applies only to the first line.
    (setq-local display-indent-guides-scope (vector 1 1 19))
    (should (equal (internal--indent-guide-stops 1) '((0 . 1))))
    (should (equal (internal--indent-guide-stops 20)
                   '((0 . 1) (4 . 2) (8 . 3) (12 . 4))))))

(ert-deftest xdisp-tests--indent-guide-scope-malformed ()
  "A malformed scope value is ignored rather than signalling."
  (with-temp-buffer
    (insert "                a\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (dolist (bad (list "not a vector" (vector) (vector 'x 1 2) (vector 2 1)))
      (setq-local display-indent-guides-scope bad)
      (should (equal (internal--indent-guide-stops 1)
                     '((0 . 1) (4 . 2) (8 . 3) (12 . 4)))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make -C test src/xdisp-tests.log`
Expected: FAIL — `display-indent-guides-scope` is void.

- [ ] **Step 3: Add the variable**

In `src/xdisp.c`, `syms_of_xdisp`, after the Task 2 variable:

```c
  DEFVAR_LISP ("display-indent-guides-scope", Vdisplay_indent_guides_scope,
    doc: /* Scope ranges limiting indentation guide depth, or nil.
The value is a vector [DEPTH BEG END BEG END ...].  Lines whose start
lies within any BEG..END range draw at most DEPTH guides.  This is how
`indent-guides-mode' applies tree-sitter scope and suppresses guides
inside multi-line strings; redisplay only reads this variable, and never
computes it.  A malformed value is ignored.  */);
  Vdisplay_indent_guides_scope = Qnil;
  DEFSYM (Qdisplay_indent_guides_scope, "display-indent-guides-scope");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_scope);
```

- [ ] **Step 4: Implement the cap lookup**

In `src/xdisp.c`, add after `indent_guide_line_depth`:

```c
/* Apply `display-indent-guides-scope' to DEPTH for a line starting at
   BEG.  A malformed value is ignored, because redisplay must not signal.  */

static int
indent_guide_apply_scope (int depth, ptrdiff_t beg)
{
  Lisp_Object scope = Vdisplay_indent_guides_scope;

  if (!VECTORP (scope))
    return depth;

  ptrdiff_t size = ASIZE (scope);
  if (size < 3 || (size % 2) == 0)
    return depth;

  Lisp_Object cap = AREF (scope, 0);
  if (!FIXNUMP (cap) || XFIXNUM (cap) < 0)
    return depth;

  for (ptrdiff_t i = 1; i + 1 < size; i += 2)
    {
      Lisp_Object lo = AREF (scope, i), hi = AREF (scope, i + 1);
      if (!FIXNUMP (lo) || !FIXNUMP (hi))
	return depth;
      if (beg >= XFIXNUM (lo) && beg < XFIXNUM (hi))
	return min (depth, (int) XFIXNUM (cap));
    }

  return depth;
}
```

- [ ] **Step 5: Apply the cap in the test entry point**

In `Finternal__indent_guide_stops`, replace

```c
  int depth = indent_guide_line_depth (NULL, beg, tab_width, &cfg);
```

with

```c
  int depth = indent_guide_line_depth (NULL, beg, tab_width, &cfg);
  depth = indent_guide_apply_scope (depth, beg);
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make -j$(sysctl -n hw.ncpu) && make -C test src/xdisp-tests.log`
Expected: all guide tests PASS.

- [ ] **Step 7: Commit**

```bash
git add src/xdisp.c test/src/xdisp-tests.el
git commit -m "Limit indentation guide depth by published scope ranges"
```

---

### Task 4: The `INDENT_GUIDE_GLYPH` glyph type

This task adds the glyph type and its drawing, with nothing yet producing it.
It is verified by building and by a smoke test that draws one guide glyph from
a temporary hook, removed at the end of the task.

**Files:**
- Modify: `src/dispextern.h:455` (enum), `src/dispextern.h:621` (union)
- Modify: `src/xdisp.c:32817` (glyph string build), `src/xdisp.c:35917` (cursor)
- Modify: `src/macterm.c:2696`, `src/macterm.c:2888`
- Modify: `src/xterm.c:11005`, `src/w32term.c:2778`, `src/nsterm.m:4846`, `src/pgtkterm.c:2601`, `src/haikuterm.c:1984`, `src/androidterm.c:4338`

- [ ] **Step 1: Add the enum value**

In `src/dispextern.h`, in `enum glyph_type`, after `XWIDGET_GLYPH` (line 458),
add a comma to the previous entry and then:

```c
  /* Glyph is a vertical indentation guide.  */
  INDENT_GUIDE_GLYPH
```

- [ ] **Step 2: Add the union sub-struct**

In `src/dispextern.h`, in the glyph union after the `stretch` sub-struct that
ends near line 631, add:

```c
    /* Sub-structure for type == INDENT_GUIDE_GLYPH.  All fields fit in
       the 32 bits shared with U.VAL, so guides compare in one step like
       every other glyph type.  */
    struct
    {
      /* Indentation depth this guide marks, counting from 1.  */
      unsigned depth : 8;
      /* Bar width in pixels.  */
      unsigned width : 8;
      /* Pixels between the left edge of the cell and the bar.  */
      unsigned pad : 8;
      /* Reserved for dashed and zigzag styles; always 0 in this version.  */
      unsigned pattern : 8;
    }
    indent_guide;
```

- [ ] **Step 3: Add the glyph-string build case**

In `src/xdisp.c`, in `BUILD_GLYPH_STRINGS_1`, after the `case STRETCH_GLYPH:`
block at line 32817, add:

```c
	    case INDENT_GUIDE_GLYPH:					\
	      BUILD_INDENT_GUIDE_GLYPH_STRING (START, END, HEAD, TAIL,	\
					       HL, X, LAST_X);		\
	      break;							\
```

and define the macro next to `BUILD_STRETCH_GLYPH_STRING` (line 32625):

```c
/* Build a glyph string for a run of indentation guide glyphs.  Guides in
   one run share a face, so they can be drawn together.  */

#define BUILD_INDENT_GUIDE_GLYPH_STRING(START, END, HEAD, TAIL, HL, X,	\
					LAST_X)				\
     do									\
       {								\
	 s = alloca (sizeof *s);					\
	 INIT_GLYPH_STRING (s, NULL, w, row, area, START, HL);		\
	 START = fill_indent_guide_glyph_string (s, face_id, START, END,	\
						 overlaps);		\
	 append_glyph_string (&HEAD, &TAIL, s);				\
	 s->x = (X);							\
       }								\
     while (false)
```

with the filler next to `fill_stretch_glyph_string`:

```c
/* Fill glyph string S from a run of indentation guide glyphs starting at
   START and ending before END in S->row->glyphs[S->area].  Return the
   index of the first glyph not consumed.  */

static int
fill_indent_guide_glyph_string (struct glyph_string *s, int face_id,
				int start, int end, int overlaps)
{
  struct glyph *glyph, *last;
  int voffset, face_id_of_run;

  eassert (s->first_glyph->type == INDENT_GUIDE_GLYPH);

  glyph = s->row->glyphs[s->area] + start;
  last = s->row->glyphs[s->area] + end;
  face_id_of_run = glyph->face_id;
  s->face = FACE_FROM_ID (s->f, face_id_of_run);
  s->font = s->face->font;
  s->width = glyph->pixel_width;
  s->nchars = 1;
  voffset = glyph->voffset;

  for (++glyph;
       (glyph < last
	&& glyph->type == INDENT_GUIDE_GLYPH
	&& glyph->voffset == voffset
	&& glyph->face_id == face_id_of_run);
       ++glyph)
    s->width += glyph->pixel_width;

  s->nglyphs = glyph - (s->row->glyphs[s->area] + start);
  s->y += voffset;

  if (overlaps)
    s->for_overlaps = overlaps;

  return glyph - s->row->glyphs[s->area];
}
```

- [ ] **Step 4: Implement mac drawing**

In `src/macterm.c`, immediately before `mac_draw_stretch_glyph_string` (line
2696), add:

```c
/* Draw a run of indentation guide glyphs.  The background is filled the
   same way a stretch glyph fills it, so that region and hl-line
   highlighting show through behind the bars.  PATTERN is reserved for
   dashed and zigzag styles and is 0 (solid) in this version.  */

static void
mac_draw_indent_guide_glyph_string (struct glyph_string *s)
{
  struct face *face = s->face;
  int i, x;

  eassert (s->first_glyph->type == INDENT_GUIDE_GLYPH);

  if (!s->background_filled_p && s->background_width > 0)
    {
      mac_clear_glyph_string_rect (s, s->x, s->y, s->background_width,
				   s->height);
      s->background_filled_p = true;
    }

  if (s->hl == DRAW_CURSOR)
    return;

  x = s->x;
  for (i = 0; i < s->nglyphs; i++)
    {
      struct glyph *g = s->first_glyph + i;
      int width = g->u.indent_guide.width;
      int pad = g->u.indent_guide.pad;

      if (width > 0 && pad + width <= g->pixel_width)
	mac_fill_rectangle (s->f, s->gc, x + pad, s->y, width, s->height);

      x += g->pixel_width;
    }

  (void) face;
}
```

`mac_clear_glyph_string_rect` is defined at `src/macterm.c:1768` and is what
the stretch and character paths already use to fill a glyph string's
background. Drawing the bar goes through `mac_fill_rectangle`
(`src/macterm.c:665`) rather than raw Core Graphics, so that the feature works
under both the Core Graphics and Metal paths on this branch.

- [ ] **Step 5: Add the mac dispatch case**

In `src/macterm.c`, in `mac_draw_glyph_string`, after the `case STRETCH_GLYPH:`
block at line 2888:

```c
    case INDENT_GUIDE_GLYPH:
      mac_draw_indent_guide_glyph_string (s);
      break;
```

- [ ] **Step 6: Add the other backends' cases**

In each of `src/xterm.c:11005`, `src/w32term.c:2778`, `src/nsterm.m:4846`,
`src/pgtkterm.c:2601`, `src/haikuterm.c:1984`, `src/androidterm.c:4338`, add a
case next to `case STRETCH_GLYPH:` that draws nothing but leaves the background
correct:

```c
    case INDENT_GUIDE_GLYPH:
      /* Indentation guides are drawn by the mac backend only; on other
	 window systems the glyph renders as its background, so text
	 layout is unaffected.  */
      break;
```

Extending guide drawing to those backends is straightforward — each needs the
equivalent of `mac_draw_indent_guide_glyph_string` — but is out of scope here.

- [ ] **Step 7: Handle the cursor**

In `src/xdisp.c`, in `draw_phys_cursor_glyph` (line 35917), the existing code
special-cases glyph types when deciding how to draw the cursor. Add
`INDENT_GUIDE_GLYPH` wherever `STRETCH_GLYPH` is tested for cursor drawing, so
a block cursor sitting on indentation draws over the whole cell:

```c
  if (glyph->type == STRETCH_GLYPH
      || glyph->type == INDENT_GUIDE_GLYPH)
```

- [ ] **Step 8: Build with checking enabled**

Run: `make -j$(sysctl -n hw.ncpu)`
Expected: builds clean. No switch-not-handled warnings from any backend, which
is the real check that every dispatch site was covered.

- [ ] **Step 9: Commit**

```bash
git add src/dispextern.h src/xdisp.c src/macterm.c src/xterm.c \
        src/w32term.c src/nsterm.m src/pgtkterm.c src/haikuterm.c \
        src/androidterm.c
git commit -m "Add INDENT_GUIDE_GLYPH glyph type and mac drawing"
```

---

### Task 5: Decorate rows with guides

**Files:**
- Modify: `src/xdisp.c` (guides section, and `display_line` at line 27735)
- Test: `test/src/xdisp-tests.el`

- [ ] **Step 1: Write the failing test**

The invariant to protect is that guides never disturb buffer positions. Append
to `test/src/xdisp-tests.el`:

```elisp
(defun xdisp-tests--positions-across-line (buffer-text)
  "Return the buffer positions `posn-at-x-y' reports across line 1.
Renders BUFFER-TEXT in a temporary window and samples every column."
  (let ((buf (generate-new-buffer " *guide-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert buffer-text)
          (set-window-buffer (selected-window) buf)
          (goto-char (point-min))
          (redisplay t)
          (let ((res nil)
                (h (line-pixel-height)))
            (dotimes (col 20)
              (push (posn-point
                     (posn-at-x-y (* col (frame-char-width)) (/ h 2)))
                    res))
            (nreverse res)))
      (kill-buffer buf))))

(ert-deftest xdisp-tests--indent-guides-preserve-positions ()
  "Enabling guides must not change where a column maps to in the buffer."
  (skip-unless (not noninteractive))
  (let* ((text "        foo\n        bar\n")
         (without (let ((display-indent-guides nil))
                    (xdisp-tests--positions-across-line text)))
         (with (let ((display-indent-guides t)
                     (display-indent-guides-spacing 4)
                     (display-indent-guides-offset 0))
                 (xdisp-tests--positions-across-line text))))
    (should (equal without with))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make -C test src/xdisp-tests`

Expected: at this point the test PASSES trivially, because nothing produces
guides yet. That is expected and fine — it is a regression test that must keep
passing through Tasks 5 to 7, and it starts green on purpose. Note the result
so a later failure is meaningful.

- [ ] **Step 3: Implement the decoration pass**

In `src/xdisp.c`, add after `indent_guide_apply_scope`:

```c
/* Depth of the block containing point in the window being redisplayed,
   or 0 for none.  Set once per window by redisplay_window; read while
   rows are built.  Redisplay is single-threaded, so a file-scope value
   is safe here.  */

static int indent_guide_current_depth;

/* Return the face to use for a guide at DEPTH.  BASE_FACE_ID is the face
   of the whitespace being replaced, so that guides inherit its
   background.  */

static int
indent_guide_face (struct window *w, int depth, int base_face_id)
{
  Lisp_Object face_name;

  if (!NILP (Vdisplay_indent_guides_highlight_current)
      && depth == indent_guide_current_depth)
    face_name = Qindent_guide_current;
  else
    face_name = indent_guide_face_names[(depth - 1) % 8];

  return merge_faces (w, face_name, 0, base_face_id);
}

/* Turn the glyph at ROW->glyphs[TEXT_AREA][I] into a guide glyph at
   DEPTH.  The glyph must be a space; its position and width are kept, so
   buffer positions and layout are unchanged.  */

static void
indent_guide_convert_glyph (struct window *w, struct glyph_row *row, int i,
			    int depth, int width, int pad)
{
  struct glyph *g = row->glyphs[TEXT_AREA] + i;

  eassert (g->type == CHAR_GLYPH && g->u.ch == ' ');

  g->face_id = indent_guide_face (w, depth, g->face_id);
  g->type = INDENT_GUIDE_GLYPH;
  g->u.val = 0;
  g->u.indent_guide.depth = min (depth, 255);
  g->u.indent_guide.width = min (width, 255);
  g->u.indent_guide.pad = min (pad, 255);
  g->u.indent_guide.pattern = 0;
}

/* Decorate ROW with indentation guides.  Called once per row, at the end
   of display_line, after all glyphs have been produced and before the
   cursor is placed.  */

static void
maybe_display_indent_guides (struct it *it, struct glyph_row *row)
{
  struct indent_guide_config cfg;

  /* Guides belong to the first screen line of a buffer line.  R2L rows
     are not supported in this version.  */
  if (row->continuation_lines_width > 0 || row->reversed_p)
    return;

  indent_guide_get_config (&cfg);
  if (!cfg.enabled)
    return;

  ptrdiff_t beg = MATRIX_ROW_START_CHARPOS (row);
  if (beg < BEGV || beg > ZV)
    return;

  int tab_width = SANE_TAB_WIDTH (current_buffer);
  int depth = indent_guide_line_depth (it, beg, tab_width, &cfg);
  depth = indent_guide_apply_scope (depth, beg);
  if (depth <= 0)
    return;

  int char_width = FRAME_COLUMN_WIDTH (it->f);
  int width = max (1, (int) (char_width * indent_guide_width_frac ()));
  int pad = (int) (char_width * indent_guide_pad_frac ());
  if (pad + width > char_width)
    pad = max (0, char_width - width);

  /* Walk the row's glyphs, tracking the column each one starts at, and
     convert the glyph covering each guide stop.  Stops scrolled off the
     left simply find no glyph and are skipped.  */
  int next_depth = 1;
  int col = it->hscroll_column_offset;

  for (int i = 0; i < row->used[TEXT_AREA] && next_depth <= depth; i++)
    {
      struct glyph *g = row->glyphs[TEXT_AREA] + i;

      if (g->type != CHAR_GLYPH || g->u.ch != ' ')
	break;

      while (next_depth <= depth
	     && indent_guide_column (next_depth, &cfg) < col)
	next_depth++;

      if (next_depth <= depth
	  && indent_guide_column (next_depth, &cfg) == col)
	{
	  indent_guide_convert_glyph (it->w, row, i, next_depth, width, pad);
	  next_depth++;
	}

      col++;
    }
}
```

`indent_guide_width_frac` and `indent_guide_pad_frac` read
`display-indent-guides-width` and `display-indent-guides-pad`, clamped:

```c
static double
indent_guide_frac (Lisp_Object value, double dflt)
{
  if (!NUMBERP (value))
    return dflt;
  double v = XFLOATINT (value);
  if (!(v >= 0.0) || v > 1.0)
    return dflt;
  return v;
}

static double
indent_guide_width_frac (void)
{
  return indent_guide_frac (Vdisplay_indent_guides_width, 0.25);
}

static double
indent_guide_pad_frac (void)
{
  return indent_guide_frac (Vdisplay_indent_guides_pad, 0.1);
}
```

`it->hscroll_column_offset` does not exist; use 0 for now and replace it in
Task 6, which handles horizontal scrolling together with tabs. Add a comment
saying so.

`indent_guide_face_names` is a static array initialized in `syms_of_xdisp`:

```c
static Lisp_Object indent_guide_face_names[8];
```

with, in `syms_of_xdisp`:

```c
  DEFSYM (Qindent_guide_1, "indent-guide-1");
  DEFSYM (Qindent_guide_2, "indent-guide-2");
  DEFSYM (Qindent_guide_3, "indent-guide-3");
  DEFSYM (Qindent_guide_4, "indent-guide-4");
  DEFSYM (Qindent_guide_5, "indent-guide-5");
  DEFSYM (Qindent_guide_6, "indent-guide-6");
  DEFSYM (Qindent_guide_7, "indent-guide-7");
  DEFSYM (Qindent_guide_8, "indent-guide-8");
  DEFSYM (Qindent_guide_current, "indent-guide-current");
  indent_guide_face_names[0] = Qindent_guide_1;
  indent_guide_face_names[1] = Qindent_guide_2;
  indent_guide_face_names[2] = Qindent_guide_3;
  indent_guide_face_names[3] = Qindent_guide_4;
  indent_guide_face_names[4] = Qindent_guide_5;
  indent_guide_face_names[5] = Qindent_guide_6;
  indent_guide_face_names[6] = Qindent_guide_7;
  indent_guide_face_names[7] = Qindent_guide_8;
  staticpro (&indent_guide_face_names[0]);
  staticpro (&indent_guide_face_names[1]);
  staticpro (&indent_guide_face_names[2]);
  staticpro (&indent_guide_face_names[3]);
  staticpro (&indent_guide_face_names[4]);
  staticpro (&indent_guide_face_names[5]);
  staticpro (&indent_guide_face_names[6]);
  staticpro (&indent_guide_face_names[7]);
```

- [ ] **Step 4: Add the remaining variables**

In `syms_of_xdisp`, after the Task 3 variable:

```c
  DEFVAR_LISP ("display-indent-guides-width", Vdisplay_indent_guides_width,
    doc: /* Width of an indentation guide, as a fraction of character width.
The value should be a number between 0 and 1.  */);
  Vdisplay_indent_guides_width = make_float (0.25);
  DEFSYM (Qdisplay_indent_guides_width, "display-indent-guides-width");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_width);

  DEFVAR_LISP ("display-indent-guides-pad", Vdisplay_indent_guides_pad,
    doc: /* Space left of an indentation guide, as a fraction of character width.
The value should be a number between 0 and 1.  */);
  Vdisplay_indent_guides_pad = make_float (0.1);
  DEFSYM (Qdisplay_indent_guides_pad, "display-indent-guides-pad");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_pad);

  DEFVAR_LISP ("display-indent-guides-highlight-current",
	       Vdisplay_indent_guides_highlight_current,
    doc: /* Non-nil means highlight the guide of the block containing point.
Enabling this disables two redisplay optimizations for windows showing
this buffer, so that moving point redraws the guides.  This is the same
cost `display-line-numbers' pays when the current line's number uses a
distinct face.  */);
  Vdisplay_indent_guides_highlight_current = Qnil;
  DEFSYM (Qdisplay_indent_guides_highlight_current,
	  "display-indent-guides-highlight-current");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_highlight_current);
```

- [ ] **Step 5: Call the pass from `display_line`**

In `src/xdisp.c`, in `display_line`, immediately before the comment
`/* Maybe set the cursor.  */` at line 27735, add:

```c
  /* Decorate leading whitespace with indentation guides.  This must
     happen before the cursor is placed, so that the cursor lands on the
     final glyphs.  */
  maybe_display_indent_guides (it, row);
```

- [ ] **Step 6: Verify it renders**

Run:

```bash
./src/emacs -Q -l /dev/stdin <<'EOF'
(with-current-buffer (get-buffer-create "*guides*")
  (insert "def f():\n    if x:\n        return 1\n    return 0\n")
  (setq-local display-indent-guides t)
  (setq-local display-indent-guides-spacing 4)
  (switch-to-buffer (current-buffer)))
EOF
```

Expected: vertical bars at columns 0 and 4 on the indented lines, roughly a
quarter of a character wide, offset slightly right of the cell edge.

- [ ] **Step 7: Run the position regression test**

Run: `make -C test src/xdisp-tests`
Expected: `xdisp-tests--indent-guides-preserve-positions` PASSES. If it fails,
guides are changing glyph widths or positions, which is a bug in
`indent_guide_convert_glyph`.

- [ ] **Step 8: Run the batch tests**

Run: `make -C test src/xdisp-tests.log`
Expected: all Task 1-3 tests still PASS.

- [ ] **Step 9: Commit**

```bash
git add src/xdisp.c test/src/xdisp-tests.el
git commit -m "Draw indentation guides in leading whitespace"
```

---

### Task 6: Tabs and horizontal scrolling

Indentation made of tabs produces a single stretch glyph spanning several
columns. A guide inside it requires splitting the glyph into
stretch + guide + stretch. This is the fiddliest part of the feature.

**Files:**
- Modify: `src/xdisp.c` (`maybe_display_indent_guides`)
- Test: `test/src/xdisp-tests.el`

- [ ] **Step 1: Write the failing test**

Append to `test/src/xdisp-tests.el`:

```elisp
(ert-deftest xdisp-tests--indent-guides-preserve-positions-tabs ()
  "Guides inside tab indentation must not change buffer positions."
  (skip-unless (not noninteractive))
  (let* ((text "\t\tfoo\n\t\tbar\n")
         (without (let ((display-indent-guides nil))
                    (xdisp-tests--positions-across-line text)))
         (with (let ((display-indent-guides t)
                     (display-indent-guides-spacing 4)
                     (display-indent-guides-offset 0))
                 (xdisp-tests--positions-across-line text))))
    (should (equal without with))))

(ert-deftest xdisp-tests--indent-guides-preserve-positions-hscroll ()
  "Guides must not change buffer positions in a horizontally scrolled window."
  (skip-unless (not noninteractive))
  (let* ((text (concat (make-string 40 ?\s) "foo\n"
                       (make-string 40 ?\s) "bar\n"))
         (sample
          (lambda (on)
            (let ((display-indent-guides on)
                  (display-indent-guides-spacing 4)
                  (display-indent-guides-offset 0))
              (let ((buf (generate-new-buffer " *guide-hscroll*")))
                (unwind-protect
                    (with-current-buffer buf
                      (insert text)
                      (set-window-buffer (selected-window) buf)
                      (goto-char (point-min))
                      (set-window-hscroll (selected-window) 10)
                      (redisplay t)
                      (let ((res nil) (h (line-pixel-height)))
                        (dotimes (col 20)
                          (push (posn-point
                                 (posn-at-x-y (* col (frame-char-width))
                                              (/ h 2)))
                                res))
                        (nreverse res)))
                  (kill-buffer buf)))))))
    (should (equal (funcall sample nil) (funcall sample t)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make -C test src/xdisp-tests`
Expected: the tab test FAILS or shows no guides at all, because
`maybe_display_indent_guides` stops at the first non-space glyph. The hscroll
test FAILS because Task 5 hardcoded the starting column to 0.

- [ ] **Step 3: Implement tab splitting**

Replace the glyph-walk loop in `maybe_display_indent_guides` with:

```c
  /* Determine the column the first glyph in the row starts at.  With
     horizontal scrolling, leading columns are off-screen and their
     stops must be skipped.  */
  int col = 0;
  if (row->used[TEXT_AREA] > 0)
    {
      struct glyph *first = row->glyphs[TEXT_AREA];
      ptrdiff_t first_pos = first->charpos;
      if (first_pos > beg)
	{
	  int off_width;
	  indent_guide_line_indentation_upto (beg, first_pos, tab_width,
					      &off_width);
	  col = off_width;
	}
    }

  int next_depth = 1;
  while (next_depth <= depth && indent_guide_column (next_depth, &cfg) < col)
    next_depth++;

  for (int i = 0; i < row->used[TEXT_AREA] && next_depth <= depth; i++)
    {
      struct glyph *g = row->glyphs[TEXT_AREA] + i;
      int glyph_cols;

      if (g->type == CHAR_GLYPH && g->u.ch == ' ')
	glyph_cols = 1;
      else if (g->type == STRETCH_GLYPH && g->charpos >= beg
	       && char_at_is_tab (g->charpos))
	glyph_cols = tab_width - (col % tab_width);
      else
	break;

      int stop_col = indent_guide_column (next_depth, &cfg);

      if (stop_col >= col && stop_col < col + glyph_cols)
	{
	  if (glyph_cols == 1)
	    indent_guide_convert_glyph (it->w, row, i, next_depth, width, pad);
	  else if (!indent_guide_split_tab (it, row, &i, col, stop_col,
					    glyph_cols, next_depth,
					    width, pad))
	    break;		/* No room in the row; draw no more guides.  */
	  next_depth++;
	}

      col += glyph_cols;
    }
```

Add the two helpers next to the others:

```c
/* True if the character at CHARPOS is a tab.  */

static bool
char_at_is_tab (ptrdiff_t charpos)
{
  if (charpos < BEGV || charpos >= ZV)
    return false;
  return FETCH_BYTE (CHAR_TO_BYTE (charpos)) == '\t';
}

/* Width in columns of the text from BEG to END, expanding tabs.  */

static void
indent_guide_line_indentation_upto (ptrdiff_t beg, ptrdiff_t end,
				    int tab_width, int *width)
{
  int col = 0;
  ptrdiff_t pos_byte = CHAR_TO_BYTE (beg);

  for (ptrdiff_t pos = beg; pos < end && pos < ZV; pos++, pos_byte++)
    {
      int c = FETCH_BYTE (pos_byte);
      if (c == '\t')
	col += tab_width - (col % tab_width);
      else
	col++;
    }
  *width = col;
}

/* Split the tab stretch glyph at *I in ROW so that a guide can be drawn
   at column STOP_COL.  The tab starts at column COL and spans
   GLYPH_COLS columns.  On success *I is left on the guide glyph and true
   is returned.  Return false without modifying ROW if the row has no
   room for the extra glyphs.  */

static bool
indent_guide_split_tab (struct it *it, struct glyph_row *row, int *i,
			int col, int stop_col, int glyph_cols,
			int depth, int width, int pad)
{
  struct glyph *area_start = row->glyphs[TEXT_AREA];
  int used = row->used[TEXT_AREA];
  struct glyph *area_end = row->glyphs[1 + TEXT_AREA];
  int capacity = area_end - area_start;
  struct glyph *tab = area_start + *i;

  int left_cols = stop_col - col;
  int right_cols = glyph_cols - left_cols - 1;
  int extra = (left_cols > 0) + (right_cols > 0);

  if (used + extra > capacity)
    return false;

  int char_width = FRAME_COLUMN_WIDTH (it->f);
  int total_width = tab->pixel_width;
  int left_width = (total_width * left_cols) / glyph_cols;
  int guide_width = char_width;
  int right_width = total_width - left_width - guide_width;

  if (right_width < 0)
    {
      guide_width = total_width - left_width;
      right_width = 0;
    }

  /* Make room after the tab glyph.  */
  memmove (tab + 1 + extra, tab + 1,
	   (used - *i - 1) * sizeof *tab);
  row->used[TEXT_AREA] = used + extra;

  struct glyph proto = *tab;
  int at = *i;

  if (left_cols > 0)
    {
      area_start[at] = proto;
      area_start[at].pixel_width = left_width;
      at++;
    }

  area_start[at] = proto;
  area_start[at].type = CHAR_GLYPH;
  area_start[at].u.ch = ' ';
  area_start[at].pixel_width = guide_width;
  indent_guide_convert_glyph (it->w, row, at, depth, width, pad);
  *i = at;

  if (right_cols > 0)
    {
      area_start[at + 1] = proto;
      area_start[at + 1].pixel_width = right_width;
    }

  return true;
}
```

All three pieces keep the tab's `charpos` and `object`, inherited from `proto`,
which is what keeps `posn-at-x-y` agreeing with the unguided rendering.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make -j$(sysctl -n hw.ncpu) && make -C test src/xdisp-tests`
Expected: both new tests and the Task 5 test PASS.

- [ ] **Step 5: Verify tabs render**

Run:

```bash
printf 'def f():\n\tif x:\n\t\treturn 1\n' > /tmp/guide-tabs.py
./src/emacs -Q /tmp/guide-tabs.py --eval '(progn (setq-local indent-tabs-mode t tab-width 4) (setq-local display-indent-guides t display-indent-guides-spacing 4))'
```

Expected: guides at the same columns as in the space-indented case.

- [ ] **Step 6: Run the batch tests**

Run: `make -C test src/xdisp-tests.log`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add src/xdisp.c test/src/xdisp-tests.el
git commit -m "Support tab indentation and hscroll in indentation guides"
```

---

### Task 7: Guides on blank rows

A blank line's row has no whitespace glyphs to convert, so guides must be
appended, together with the stretch glyphs that space them out.

**Files:**
- Modify: `src/xdisp.c` (`maybe_display_indent_guides`)
- Test: `test/src/xdisp-tests.el`

- [ ] **Step 1: Write the failing test**

Append to `test/src/xdisp-tests.el`:

```elisp
(ert-deftest xdisp-tests--indent-guides-blank-line-positions ()
  "Guides appended to a blank line must not change buffer positions."
  (skip-unless (not noninteractive))
  (let* ((text "        foo\n\n        bar\n")
         (sample
          (lambda (on)
            (let ((display-indent-guides on)
                  (display-indent-guides-spacing 4)
                  (display-indent-guides-offset 0)
                  (display-indent-guides-blank-lines t))
              (let ((buf (generate-new-buffer " *guide-blank*")))
                (unwind-protect
                    (with-current-buffer buf
                      (insert text)
                      (set-window-buffer (selected-window) buf)
                      (goto-char (point-min))
                      (redisplay t)
                      (let ((res nil) (h (line-pixel-height)))
                        (dotimes (col 20)
                          ;; Sample the second screen line, the blank one.
                          (push (posn-point
                                 (posn-at-x-y (* col (frame-char-width))
                                              (+ h (/ h 2))))
                                res))
                        (nreverse res)))
                  (kill-buffer buf)))))))
    (should (equal (funcall sample nil) (funcall sample t)))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make -C test src/xdisp-tests`
Expected: PASSES trivially — no guides are appended to blank rows yet. As in
Task 5, this is a regression test that must stay green once Step 3 lands.

- [ ] **Step 3: Implement the append path**

In `maybe_display_indent_guides`, after computing `depth` and before the glyph
walk, add:

```c
  /* A blank line has no whitespace glyphs to convert, so guides and the
     stretch glyphs spacing them are appended instead.  */
  if (row->used[TEXT_AREA] == 0
      || (row->used[TEXT_AREA] == 1
	  && row->glyphs[TEXT_AREA][0].charpos == beg
	  && row->glyphs[TEXT_AREA][0].type == CHAR_GLYPH
	  && row->glyphs[TEXT_AREA][0].u.ch == ' '))
    {
      indent_guide_append_to_blank_row (it, row, beg, &cfg, depth,
					width, pad);
      return;
    }
```

and the helper:

```c
/* Append DEPTH guides to blank ROW, whose line starts at BEG.  Guides are
   separated by stretch glyphs, all carrying BEG as their position so that
   clicking a blank line still puts point at its start.  */

static void
indent_guide_append_to_blank_row (struct it *it, struct glyph_row *row,
				  ptrdiff_t beg,
				  const struct indent_guide_config *cfg,
				  int depth, int width, int pad)
{
  struct glyph *area_start = row->glyphs[TEXT_AREA];
  struct glyph *area_end = row->glyphs[1 + TEXT_AREA];
  int capacity = area_end - area_start;
  int char_width = FRAME_COLUMN_WIDTH (it->f);

  struct glyph proto;
  memset (&proto, 0, sizeof proto);
  proto.charpos = beg;
  proto.object = Qnil;
  proto.face_id = it->base_face_id;
  proto.frame = it->f;
  proto.ascent = it->ascent;
  proto.descent = it->descent;
  proto.avoid_cursor_p = true;

  int at = 0;
  int col = 0;

  for (int d = 1; d <= depth; d++)
    {
      int stop_col = indent_guide_column (d, cfg);
      int gap = stop_col - col;

      if (at + (gap > 0) + 1 > capacity)
	break;

      if (gap > 0)
	{
	  area_start[at] = proto;
	  area_start[at].type = STRETCH_GLYPH;
	  area_start[at].pixel_width = gap * char_width;
	  area_start[at].u.stretch.height = it->ascent + it->descent;
	  area_start[at].u.stretch.ascent = it->ascent;
	  at++;
	}

      area_start[at] = proto;
      area_start[at].type = CHAR_GLYPH;
      area_start[at].u.ch = ' ';
      area_start[at].pixel_width = char_width;
      row->used[TEXT_AREA] = at + 1;
      indent_guide_convert_glyph (it->w, row, at, d, width, pad);
      at++;
      col = stop_col + 1;
    }

  row->used[TEXT_AREA] = at;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make -j$(sysctl -n hw.ncpu) && make -C test src/xdisp-tests`
Expected: all three position tests PASS.

- [ ] **Step 5: Verify blank lines render**

Run:

```bash
./src/emacs -Q -l /dev/stdin <<'EOF'
(with-current-buffer (get-buffer-create "*guides*")
  (insert "def f():\n    if x:\n\n\n        return 1\n")
  (setq-local display-indent-guides t)
  (setq-local display-indent-guides-spacing 4)
  (setq-local display-indent-guides-blank-lines t)
  (switch-to-buffer (current-buffer)))
EOF
```

Expected: the two blank lines carry guides at columns 0 and 4, matching the
deeper neighbouring line.

- [ ] **Step 6: Commit**

```bash
git add src/xdisp.c test/src/xdisp-tests.el
git commit -m "Draw indentation guides on blank lines"
```

---

### Task 8: Current-depth highlighting

**Files:**
- Modify: `src/xdisp.c` (`redisplay_window`, `try_cursor_movement` at line 20722, `try_window_id` at line 23551)
- Test: manual, plus the existing position tests must keep passing

- [ ] **Step 1: Compute the current depth**

In `src/xdisp.c`, in `redisplay_window`, after the buffer is set up and before
any row building, add:

```c
  /* Depth of the block containing point, for guide highlighting.  Read
     while rows are built; recomputed for each window.  */
  indent_guide_current_depth = 0;
  if (!NILP (Vdisplay_indent_guides)
      && !NILP (Vdisplay_indent_guides_highlight_current))
    {
      struct indent_guide_config cfg;
      indent_guide_get_config (&cfg);
      if (cfg.enabled)
	{
	  ptrdiff_t line_beg
	    = find_newline (PT, -1, 0, -1, -1, NULL, NULL, false);
	  int tab_width = SANE_TAB_WIDTH (current_buffer);
	  indent_guide_current_depth
	    = indent_guide_apply_scope
		(indent_guide_line_depth (NULL, line_beg, tab_width, &cfg),
		 line_beg);
	}
    }
```

- [ ] **Step 2: Disable the incompatible optimizations**

In `try_cursor_movement`, in the condition at line 20722 that already gives up
for `display-line-numbers` with a distinct current-line face, add a clause:

```c
      /* Highlighting the current indentation depth means moving point
	 changes which guides are highlighted, which this optimization
	 cannot express.  */
      && !(!NILP (Vdisplay_indent_guides)
	   && !NILP (Vdisplay_indent_guides_highlight_current))
```

In `try_window_id`, next to the `GIVE_UP (24)` at line 23551, add:

```c
  /* Give up when the current indentation depth is highlighted, for the
     same reason as the current line number's face.  */
  if (!NILP (Vdisplay_indent_guides)
      && !NILP (Vdisplay_indent_guides_highlight_current))
    GIVE_UP (25);
```

Check that 25 is not already used in this function; if it is, use the next
free number.

- [ ] **Step 3: Verify the highlight follows point**

Run:

```bash
./src/emacs -Q -l /dev/stdin <<'EOF'
(with-current-buffer (get-buffer-create "*guides*")
  (insert "def f():\n    if x:\n        return 1\n    return 0\n")
  (setq-local display-indent-guides t)
  (setq-local display-indent-guides-spacing 4)
  (setq-local display-indent-guides-highlight-current t)
  (switch-to-buffer (current-buffer)))
EOF
```

Expected: moving point between the `return 1` and `return 0` lines moves the
bold highlight between the depth-2 and depth-1 guides, with no lag and no
stale highlight left behind. A stale highlight means the optimization give-ups
in Step 2 are not taking effect.

- [ ] **Step 4: Run the full display test suite**

Run: `make -C test src/xdisp-tests && make -C test src/xdisp-tests.log`
Expected: all PASS. These tests run with highlighting off, so they confirm the
give-ups did not break the ordinary path.

- [ ] **Step 5: Commit**

```bash
git add src/xdisp.c
git commit -m "Highlight the indentation guide of the block containing point"
```

---

### Task 9: The Lisp layer

**Files:**
- Create: `lisp/indent-guides.el`
- Test: `test/lisp/indent-guides-tests.el`

- [ ] **Step 1: Write the failing test**

Create `test/lisp/indent-guides-tests.el`:

```elisp
;;; indent-guides-tests.el --- Tests for indent-guides  -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'indent-guides)

(ert-deftest indent-guides-tests--spacing-from-tab-width ()
  "A mode with no known indent variable falls back to `tab-width'."
  (with-temp-buffer
    (fundamental-mode)
    (setq-local tab-width 3)
    (should (equal (indent-guides--guess-spacing) 3))))

(ert-deftest indent-guides-tests--spacing-from-mode-variable ()
  "A mode's own indent variable wins over `tab-width'."
  (with-temp-buffer
    (emacs-lisp-mode)
    (setq-local lisp-body-indent 2)
    (setq-local tab-width 8)
    (should (equal (indent-guides--guess-spacing) 2))))

(ert-deftest indent-guides-tests--mode-enables-display ()
  "Enabling the mode turns on the display variable and sets spacing."
  (with-temp-buffer
    (fundamental-mode)
    (setq-local tab-width 4)
    (indent-guides-mode 1)
    (should display-indent-guides)
    (should (equal display-indent-guides-spacing 4))
    (indent-guides-mode -1)
    (should-not display-indent-guides)))

(ert-deftest indent-guides-tests--scope-vector-shape ()
  "The published scope value is a well-formed vector."
  (with-temp-buffer
    (insert "  a\n  b\n")
    (fundamental-mode)
    (indent-guides-mode 1)
    (let ((v (indent-guides--scope-vector 2 '((1 . 5)))))
      (should (vectorp v))
      (should (equal (length v) 3))
      (should (equal (aref v 0) 2))
      (should (equal (aref v 1) 1))
      (should (equal (aref v 2) 5)))))

(provide 'indent-guides-tests)
;;; indent-guides-tests.el ends here
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make -C test lisp/indent-guides-tests.log`
Expected: FAIL, cannot open load file `indent-guides`.

- [ ] **Step 3: Write the mode**

Create `lisp/indent-guides.el`:

```elisp
;;; indent-guides.el --- Indentation guides  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Keywords: convenience, faces

;; This file is part of GNU Emacs.

;;; Commentary:

;; Display vertical guides in leading indentation.  The guides themselves
;; are drawn by the display engine; this file only decides where guides
;; should stop (`display-indent-guides-spacing') and publishes the scope
;; ranges the display engine reads (`display-indent-guides-scope').
;;
;; Nothing here runs during redisplay.  Tree-sitter queries and syntax
;; parsing happen after commands, and their results are handed to the
;; display engine as plain integers.

;;; Code:

(defgroup indent-guides nil
  "Vertical guides in leading indentation."
  :group 'convenience
  :version "32.1")

(defcustom indent-guides-spacing-alist
  '((python-mode . python-indent-offset)
    (python-ts-mode . python-indent-offset)
    (c-mode . c-basic-offset)
    (c-ts-mode . c-ts-mode-indent-offset)
    (c++-mode . c-basic-offset)
    (c++-ts-mode . c-ts-mode-indent-offset)
    (emacs-lisp-mode . lisp-body-indent)
    (lisp-interaction-mode . lisp-body-indent)
    (js-mode . js-indent-level)
    (js-ts-mode . js-indent-level)
    (typescript-ts-mode . typescript-ts-mode-indent-offset)
    (ruby-mode . ruby-indent-level)
    (ruby-ts-mode . ruby-indent-level)
    (sh-mode . sh-basic-offset)
    (rust-ts-mode . rust-ts-mode-indent-offset)
    (go-ts-mode . go-ts-mode-indent-offset)
    (yaml-ts-mode . yaml-indent-offset))
  "Alist mapping major modes to the variable holding their indent width.
Used by `indent-guides-mode' to choose `display-indent-guides-spacing'.
Modes not listed fall back to `tab-width'."
  :type '(alist :key-type symbol :value-type symbol)
  :version "32.1")

(defcustom indent-guides-no-descend-string t
  "Non-nil means do not deepen guides inside multi-line strings."
  :type 'boolean
  :version "32.1")

(defcustom indent-guides-treesit-scope
  '((python-ts-mode function_definition class_definition if_statement
                    for_statement while_statement with_statement)
    (c-ts-mode compound_statement)
    (c++-ts-mode compound_statement)
    (js-ts-mode statement_block function_declaration)
    (rust-ts-mode block)
    (go-ts-mode block))
  "Alist mapping major modes to the tree-sitter node types that form a scope.
When the major mode has a tree-sitter parser and an entry here,
`indent-guides-mode' limits guide depth to the innermost such node
containing point."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :version "32.1")

(defun indent-guides--guess-spacing ()
  "Return the number of columns between guides for the current buffer."
  (let* ((var (alist-get major-mode indent-guides-spacing-alist))
         (val (and var (boundp var) (symbol-value var))))
    (if (and (integerp val) (> val 0))
        val
      tab-width)))

(defun indent-guides--scope-vector (depth ranges)
  "Build the value for `display-indent-guides-scope'.
DEPTH is the maximum guide depth inside RANGES, a list of (BEG . END)."
  (apply #'vector depth
         (apply #'append
                (mapcar (lambda (r) (list (car r) (cdr r))) ranges))))

(defun indent-guides--string-ranges ()
  "Return (BEG . END) ranges of multi-line strings around point.
Returns nil when point is not inside a string."
  (when indent-guides-no-descend-string
    (let ((state (syntax-ppss)))
      (when (nth 3 state)
        (let ((beg (nth 8 state)))
          (save-excursion
            (goto-char beg)
            (condition-case nil
                (progn (forward-sexp 1)
                       (list (cons beg (point))))
              (error (list (cons beg (point-max)))))))))))

(defun indent-guides--treesit-range ()
  "Return (BEG . END) of the innermost tree-sitter scope around point, or nil."
  (when (and (fboundp 'treesit-parser-list)
             (treesit-parser-list)
             (alist-get major-mode indent-guides-treesit-scope))
    (let* ((types (alist-get major-mode indent-guides-treesit-scope))
           (node (treesit-parent-until
                  (treesit-node-at (point))
                  (lambda (n) (memq (intern (treesit-node-type n)) types))
                  t)))
      (when node
        (cons (treesit-node-start node) (treesit-node-end node))))))

(defun indent-guides--depth-at (pos)
  "Return the guide depth of the line containing POS."
  (length (internal--indent-guide-stops pos)))

(defun indent-guides--update-scope ()
  "Recompute `display-indent-guides-scope' for the current buffer."
  (setq display-indent-guides-scope
        (let* ((strings (indent-guides--string-ranges))
               (ts (indent-guides--treesit-range)))
          (cond
           (strings
            ;; Inside a multi-line string: cap at the string's own depth.
            (indent-guides--scope-vector
             (indent-guides--depth-at (caar strings))
             strings))
           (ts
            (indent-guides--scope-vector
             (+ 1 (indent-guides--depth-at (car ts)))
             (list ts)))
           (t nil)))))

(defvar-local indent-guides--saved-spacing nil
  "Value of `display-indent-guides-spacing' before the mode was enabled.")

;;;###autoload
(define-minor-mode indent-guides-mode
  "Display vertical guides in leading indentation.

The guides are drawn by the display engine; this mode chooses the
column spacing for the current major mode and, when tree-sitter is
available, limits guide depth to the syntactic scope around point.

Customize the faces `indent-guide-1' through `indent-guide-8' to change
guide colors, and `indent-guide-current' for the highlighted depth."
  :lighter nil
  (if indent-guides-mode
      (progn
        (setq indent-guides--saved-spacing display-indent-guides-spacing)
        (setq display-indent-guides-spacing (indent-guides--guess-spacing))
        (setq display-indent-guides t)
        (add-hook 'post-command-hook #'indent-guides--update-scope nil t)
        (indent-guides--update-scope))
    (remove-hook 'post-command-hook #'indent-guides--update-scope t)
    (setq display-indent-guides nil)
    (setq display-indent-guides-scope nil)
    (when indent-guides--saved-spacing
      (setq display-indent-guides-spacing indent-guides--saved-spacing))))

;;;###autoload
(define-globalized-minor-mode global-indent-guides-mode
  indent-guides-mode
  (lambda () (when (derived-mode-p 'prog-mode) (indent-guides-mode 1))))

(provide 'indent-guides)
;;; indent-guides.el ends here
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make -C test lisp/indent-guides-tests.log`
Expected: all four tests PASS.

- [ ] **Step 5: Verify tree-sitter scope**

Requires a build with tree-sitter and a Python grammar installed:

```bash
./src/emacs -Q /path/to/some.py --eval '(progn (python-ts-mode) (indent-guides-mode 1) (setq-local display-indent-guides-highlight-current t))'
```

Expected: moving point between functions changes which guides are drawn, with
depth limited to the enclosing definition. If tree-sitter is unavailable, the
mode still works and `display-indent-guides-scope` stays nil.

- [ ] **Step 6: Commit**

```bash
git add lisp/indent-guides.el test/lisp/indent-guides-tests.el
git commit -m "Add indent-guides-mode"
```

---

### Task 10: Text-terminal guides

On a text terminal a guide cannot be a thin rule, so the row pass emits a
character glyph instead. `term.c` and `dispnew.c` need no changes.

**Files:**
- Modify: `src/xdisp.c` (`indent_guide_convert_glyph`, `syms_of_xdisp`)
- Test: `test/src/xdisp-tests.el`

- [ ] **Step 1: Write the failing test**

Append to `test/src/xdisp-tests.el`:

```elisp
(ert-deftest xdisp-tests--indent-guides-character-default ()
  "The text-terminal guide character defaults to a box-drawing bar."
  (should (equal display-indent-guides-character ?\N{BOX DRAWINGS LIGHT VERTICAL})))

(ert-deftest xdisp-tests--indent-guides-character-settable ()
  "The text-terminal guide character is buffer-local and settable."
  (with-temp-buffer
    (setq-local display-indent-guides-character ?|)
    (should (equal display-indent-guides-character ?|))
    (should (local-variable-p 'display-indent-guides-character))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make -C test src/xdisp-tests.log`
Expected: FAIL, `display-indent-guides-character` is void.

- [ ] **Step 3: Add the variable**

In `src/xdisp.c`, `syms_of_xdisp`, after the Task 5 variables:

```c
  DEFVAR_LISP ("display-indent-guides-character",
	       Vdisplay_indent_guides_character,
    doc: /* Character used to draw indentation guides on text terminals.
On graphical displays guides are drawn as thin vertical lines and this
variable has no effect.  */);
  Vdisplay_indent_guides_character
    = make_fixnum (0x2502);	/* BOX DRAWINGS LIGHT VERTICAL */
  DEFSYM (Qdisplay_indent_guides_character,
	  "display-indent-guides-character");
  Fmake_variable_buffer_local (Qdisplay_indent_guides_character);
```

- [ ] **Step 4: Emit a character glyph on text terminals**

In `src/xdisp.c`, change `indent_guide_convert_glyph` to take the frame into
account:

```c
static void
indent_guide_convert_glyph (struct window *w, struct glyph_row *row, int i,
			    int depth, int width, int pad)
{
  struct glyph *g = row->glyphs[TEXT_AREA] + i;
  struct frame *f = XFRAME (w->frame);

  eassert (g->type == CHAR_GLYPH && g->u.ch == ' ');

  g->face_id = indent_guide_face (w, depth, g->face_id);

  if (!FRAME_WINDOW_P (f))
    {
      /* Text terminals cannot draw a sub-character rule, so display a
	 character instead.  The glyph stays a CHAR_GLYPH, which keeps
	 term.c and dispnew.c out of this feature entirely.  */
      if (FIXNATP (Vdisplay_indent_guides_character))
	g->u.ch = XFIXNAT (Vdisplay_indent_guides_character);
      return;
    }

  g->type = INDENT_GUIDE_GLYPH;
  g->u.val = 0;
  g->u.indent_guide.depth = min (depth, 255);
  g->u.indent_guide.width = min (width, 255);
  g->u.indent_guide.pad = min (pad, 255);
  g->u.indent_guide.pattern = 0;
}
```

Note that `indent_guide_split_tab` and `indent_guide_append_to_blank_row` both
go through this function, so they gain text-terminal support with no change of
their own.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make -j$(sysctl -n hw.ncpu) && make -C test src/xdisp-tests.log`
Expected: both new tests PASS, and all earlier tests still PASS.

- [ ] **Step 6: Verify it renders in a terminal**

Run, in a terminal:

```bash
./src/emacs -nw -Q -l /dev/stdin <<'EOF'
(with-current-buffer (get-buffer-create "*guides*")
  (insert "def f():\n    if x:\n        return 1\n")
  (setq-local display-indent-guides t)
  (setq-local display-indent-guides-spacing 4)
  (switch-to-buffer (current-buffer)))
EOF
```

Expected: `│` characters at columns 0 and 4 of the indented lines.

- [ ] **Step 7: Commit**

```bash
git add src/xdisp.c test/src/xdisp-tests.el
git commit -m "Display indentation guides on text terminals"
```

---

### Task 11: Documentation, NEWS, and benchmark

**Files:**
- Modify: `etc/NEWS`
- Modify: `doc/emacs/display.texi:1533` (near the fill-column-indicator section)
- Modify: `docs/superpowers/specs/2026-07-28-native-indent-guides-design.md`

- [ ] **Step 1: Add the NEWS entry**

In `etc/NEWS`, under the new-features section for Emacs 32.1:

```
+++
** New minor mode 'indent-guides-mode'.
This mode displays vertical guides in leading indentation, drawn by the
display engine rather than by text properties.  Use
'global-indent-guides-mode' to enable it in all programming modes.  The
guides' appearance is controlled by 'display-indent-guides-width',
'display-indent-guides-pad', and the faces 'indent-guide-1' through
'indent-guide-8'.  Set 'display-indent-guides-highlight-current' to
highlight the guide of the block containing point, using the
'indent-guide-current' face; note that this disables some redisplay
optimizations, as highlighting the current line number does.  On text
terminals the guides are drawn using
'display-indent-guides-character'.  Guides are not displayed in
right-to-left paragraphs.
```

- [ ] **Step 2: Document in the manual**

In `doc/emacs/display.texi`, after the fill-column-indicator section that
begins at line 1533, add:

```texinfo
@node Indentation Guides
@section Indentation Guides
@cindex indentation guides
@cindex guides, indentation

@findex indent-guides-mode
@findex global-indent-guides-mode
  Indentation guides are thin vertical lines drawn in the leading
whitespace of indented lines, showing at a glance how deeply each line
is nested.  Type @kbd{M-x indent-guides-mode} to display them in the
current buffer, or @kbd{M-x global-indent-guides-mode} to display them
in every programming-language buffer.

@vindex display-indent-guides-spacing
@vindex display-indent-guides-offset
  Guides are drawn every @code{display-indent-guides-spacing} columns,
starting at column @code{display-indent-guides-offset}.
@code{indent-guides-mode} sets the spacing from the major mode's own
indentation width, falling back to @code{tab-width}.

@vindex display-indent-guides-width
@vindex display-indent-guides-pad
  @code{display-indent-guides-width} sets the width of a guide as a
fraction of the width of a character, and
@code{display-indent-guides-pad} sets how far the guide sits from the
left edge of its column.  Both default to small fractions, giving a
thin line rather than a full character.

@vindex display-indent-guides-blank-lines
  By default guides continue through blank lines, using the guides of
the deeper of the nearest non-blank lines above and below.  Set
@code{display-indent-guides-blank-lines} to @code{nil} to leave blank
lines empty.

@vindex display-indent-guides-highlight-current
@cindex indent-guide-current face
  If you set @code{display-indent-guides-highlight-current} to a
non-@code{nil} value, the guide of the block containing point is drawn
in the @code{indent-guide-current} face.  Note that this disables some
redisplay optimizations for windows showing the buffer, as highlighting
the current line's number does; see @ref{Display Custom}.

@cindex indent-guide-1 face
  Guides cycle through the faces @code{indent-guide-1} to
@code{indent-guide-8} by depth, so customizing those faces gives each
nesting level its own color.

  Indentation guides are not displayed in right-to-left paragraphs.
```

Add the new node to the `@menu` of the enclosing chapter and to the
`@detailmenu` in `doc/emacs/emacs.texi`, following how the neighbouring
display sections are listed.

- [ ] **Step 3: Write the benchmark**

Create `/tmp/guide-bench.el`:

```elisp
;;; Compare native indentation guides against indent-bars.
(defun guide-bench--scroll (n)
  "Scroll N screens, forcing a redisplay each time, and return elapsed time."
  (goto-char (point-min))
  (redisplay t)
  (let ((start (float-time)))
    (dotimes (_ n)
      (scroll-up)
      (redisplay t))
    (- (float-time) start)))

(defun guide-bench (file screens)
  (find-file file)
  (let ((plain (guide-bench--scroll screens)))
    (indent-guides-mode 1)
    (let ((native (guide-bench--scroll screens)))
      (indent-guides-mode -1)
      (indent-bars-mode 1)
      (let ((elisp (guide-bench--scroll screens)))
        (indent-bars-mode -1)
        (message "no guides: %.3fs  native: %.3fs  indent-bars: %.3fs"
                 plain native elisp)))))
```

- [ ] **Step 4: Run the benchmark**

Run, against a large deeply indented file:

```bash
./src/emacs -Q -l /tmp/guide-bench.el \
  --eval '(guide-bench "/path/to/large-indented-file.py" 200)'
```

Expected: the native timing is much closer to the no-guides baseline than
`indent-bars` is. Record the three numbers.

- [ ] **Step 5: Record the result in the design doc**

In `docs/superpowers/specs/2026-07-28-native-indent-guides-design.md`, replace
the sentence "The measured result is recorded here once available." in the
Verification section with the three measured timings, the file used, and the
machine.

- [ ] **Step 6: Commit**

```bash
git add etc/NEWS doc/emacs/display.texi \
        docs/superpowers/specs/2026-07-28-native-indent-guides-design.md
git commit -m "Document indentation guides and record benchmark results"
```

---

## Known deviations from the design doc

- Task ordering puts pure logic before rendering, for the testability reasons
  given at the top of this plan.
- Only the mac backend draws guides. The other GUI backends get a case that
  renders the glyph as background, so builds and layout are correct everywhere
  but bars appear only on the mac port. The design doc implies all backends;
  extending them is mechanical follow-up work, one function per backend
  mirroring `mac_draw_indent_guide_glyph_string`.

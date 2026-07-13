/* Batched editing support for multiple cursors.

Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */


#include <config.h>

#include <stdlib.h>

#include "lisp.h"
#include "buffer.h"


struct multi_cursor_edit
{
  ptrdiff_t beg;
  ptrdiff_t end;
  ptrdiff_t input_index;
};

static int
compare_edits_descending (const void *a, const void *b)
{
  const struct multi_cursor_edit *ea = a;
  const struct multi_cursor_edit *eb = b;

  if (ea->beg != eb->beg)
    return ea->beg > eb->beg ? -1 : 1;
  if (ea->end != eb->end)
    return ea->end > eb->end ? -1 : 1;
  if (ea->input_index != eb->input_index)
    return ea->input_index < eb->input_index ? -1 : 1;
  return 0;
}

DEFUN ("multi-cursor--apply-edits", Fmulti_cursor_apply_edits,
       Smulti_cursor_apply_edits, 1, 1, 0,
       doc: /* Apply the disjoint buffer replacements in EDITS.
EDITS is a vector whose elements have the form [BEG END STRING].
BEG and END are character positions in the accessible portion of the
current buffer.  Each edit replaces the text from BEG up to END with
STRING.  Empty ranges insert STRING.

The edits may be in any order, but their ranges must not overlap and no
two edits may start at the same position.  All shapes, positions, and
overlap relationships are validated before the buffer is modified.  The
edits are then applied from the greatest buffer position down, using the
normal buffer modification machinery.

Return a vector of the final end positions, in the same order as EDITS.
Changes at lower positions are reflected in returned positions for edits
at higher positions.  This primitive does not provide transaction rollback;
its Lisp caller should arrange that when atomic behavior is required.  */)
  (Lisp_Object edits)
{
  CHECK_VECTOR (edits);

  ptrdiff_t n = ASIZE (edits);
  Lisp_Object result = make_nil_vector (n);
  /* Keep private roots for the replacement strings.  Modification hooks
     can run arbitrary Lisp, including changing the caller's vector.  */
  Lisp_Object strings = make_nil_vector (n);
  struct multi_cursor_edit *sorted;
  USE_SAFE_ALLOCA;
  SAFE_NALLOCA (sorted, 1, n);

  /* Complete all structural validation before the first modification.  */
  for (ptrdiff_t i = 0; i < n; i++)
    {
      maybe_quit ();

      Lisp_Object edit = AREF (edits, i);
      CHECK_VECTOR (edit);
      if (ASIZE (edit) != 3)
	xsignal2 (Qwrong_length_argument, make_fixnum (ASIZE (edit)),
		  make_fixnum (3));

      Lisp_Object beg = AREF (edit, 0);
      Lisp_Object end = AREF (edit, 1);
      Lisp_Object string = AREF (edit, 2);
      CHECK_FIXNUM (beg);
      CHECK_FIXNUM (end);
      CHECK_STRING (string);
      ASET (strings, i, string);

      ptrdiff_t begpos = XFIXNUM (beg);
      ptrdiff_t endpos = XFIXNUM (end);
      if (begpos < BEGV || endpos < begpos || endpos > ZV)
	args_out_of_range_3 (edit, make_fixnum (BEGV), make_fixnum (ZV));

      sorted[i] = (struct multi_cursor_edit) {
	.beg = begpos,
	.end = endpos,
	.input_index = i,
      };
    }

  maybe_quit ();
  if (n > 1)
    qsort (sorted, n, sizeof *sorted, compare_edits_descending);
  maybe_quit ();

  for (ptrdiff_t i = 1; i < n; i++)
    {
      maybe_quit ();
      if (sorted[i].beg == sorted[i - 1].beg
	  || sorted[i].end > sorted[i - 1].beg)
	error ("Multiple-cursor edits overlap");
    }

  /* Calculate results from low positions upward.  At each edit,
     LOWER_DELTA is the net change caused by all lower edits.  */
  ptrdiff_t lower_delta = 0;
  for (ptrdiff_t i = n; i-- > 0; )
    {
      maybe_quit ();
      ptrdiff_t final_end;
      Lisp_Object string = AREF (strings, sorted[i].input_index);
      ptrdiff_t inserted = SCHARS (string);
      if (ckd_add (&final_end, sorted[i].beg, inserted)
	  || ckd_add (&final_end, final_end, lower_delta))
	buffer_overflow ();
      ASET (result, sorted[i].input_index, make_fixnum (final_end));

      ptrdiff_t delta = inserted - (sorted[i].end - sorted[i].beg);
      if (ckd_add (&lower_delta, lower_delta, delta))
	buffer_overflow ();
    }

  for (ptrdiff_t i = 0; i < n; i++)
    {
      maybe_quit ();
      Lisp_Object string = AREF (strings, sorted[i].input_index);
      if (sorted[i].beg != sorted[i].end || SCHARS (string) != 0)
	replace_range (sorted[i].beg, sorted[i].end, string,
		       true, false, false);
    }

  SAFE_FREE ();
  return result;
}


void
syms_of_multicursor (void)
{
  defsubr (&Smulti_cursor_apply_edits);
}

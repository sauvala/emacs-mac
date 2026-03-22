/* WrapMap — centralized visual line estimation for long wrapped lines.

Copyright (C) 2025 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

#include <config.h>
#include "lisp.h"
#include "buffer.h"
#include "window.h"
#include "frame.h"
#include "dispextern.h"
#include "wrapmap.h"

#ifdef USE_ROPE
#include "ropebuf.h"
#endif

bool
wrapmap_estimate_vline (struct window *w,
                        ptrdiff_t charpos, ptrdiff_t bytepos,
                        struct wrapmap_result *result)
{
  struct frame *f = XFRAME (w->frame);
  int avg_cw = FRAME_COLUMN_WIDTH (f);
  int win_w = window_body_width (w, true);

  if (avg_cw <= 0 || win_w <= 0)
    return false;

  ptrdiff_t chars_per_row = win_w / avg_cw;
  if (chars_per_row <= 0)
    return false;

#ifdef USE_ROPE
  if (current_buffer->text->rope)
    {
      RopePoint pt = rope_offset_to_point_emacs (bytepos);
      ptrdiff_t chars_into_line = (ptrdiff_t) pt.col;
      ptrdiff_t line_beg_charpos = charpos - chars_into_line;
      ptrdiff_t vline_idx = chars_into_line / chars_per_row;
      ptrdiff_t target_col = vline_idx * chars_per_row;

      result->vline_start_charpos = line_beg_charpos + target_col;
      result->vline_start_bytepos
        = rope_point_to_offset_emacs (pt.row, target_col);
      result->continuation_lines_width
        = (int) (vline_idx * (ptrdiff_t) win_w);
      result->vline_idx = vline_idx;
      result->chars_per_row = chars_per_row;
      return true;
    }
#endif

  {
    ptrdiff_t line_beg_byte;
    ptrdiff_t line_beg_charpos
      = find_newline_no_quit (charpos, bytepos, -1, &line_beg_byte);
    ptrdiff_t chars_into_line = charpos - line_beg_charpos;
    ptrdiff_t vline_idx = chars_into_line / chars_per_row;
    ptrdiff_t target_col = vline_idx * chars_per_row;
    ptrdiff_t vline_start = line_beg_charpos + target_col;

    result->vline_start_charpos = vline_start;
    result->vline_start_bytepos = CHAR_TO_BYTE (vline_start);
    result->continuation_lines_width
      = (int) (vline_idx * (ptrdiff_t) win_w);
    result->vline_idx = vline_idx;
    result->chars_per_row = chars_per_row;
    return true;
  }
}

bool
wrapmap_estimate_backward (struct window *w,
                           ptrdiff_t charpos, ptrdiff_t bytepos,
                           ptrdiff_t nlines,
                           struct wrapmap_result *result)
{
  struct frame *f = XFRAME (w->frame);
  int avg_cw = FRAME_COLUMN_WIDTH (f);
  int win_w = window_body_width (w, true);

  if (avg_cw <= 0 || win_w <= 0)
    return false;

  ptrdiff_t chars_per_row = win_w / avg_cw;
  if (chars_per_row <= 0)
    return false;

#ifdef USE_ROPE
  if (current_buffer->text->rope)
    {
      /* Rope path: precisely target the visual line nlines before
         the current position using O(log n) tree operations.  */
      RopePoint pt = rope_offset_to_point_emacs (bytepos);
      ptrdiff_t chars_into_line = (ptrdiff_t) pt.col;
      ptrdiff_t line_beg_charpos = charpos - chars_into_line;
      ptrdiff_t vline_idx = chars_into_line / chars_per_row;
      ptrdiff_t target_vline = vline_idx - nlines;

      if (target_vline < 0)
        {
          /* Not enough visual lines on the current logical line.
             Go back nlines * chars_per_row characters and
             re-estimate from there (same strategy as gap-buffer
             path).  */
          ptrdiff_t chars_back = nlines * chars_per_row;
          ptrdiff_t est_charpos = max (BEGV, charpos - chars_back);
          ptrdiff_t est_bytepos = CHAR_TO_BYTE (est_charpos);
          pt = rope_offset_to_point_emacs (est_bytepos);
          chars_into_line = (ptrdiff_t) pt.col;
          line_beg_charpos = est_charpos - chars_into_line;
          vline_idx = chars_into_line / chars_per_row;
          target_vline = vline_idx;
        }

      ptrdiff_t target_col = target_vline * chars_per_row;

      result->vline_start_charpos = line_beg_charpos + target_col;
      result->vline_start_bytepos
        = rope_point_to_offset_emacs (pt.row, target_col);
      result->continuation_lines_width
        = (int) (target_vline * (ptrdiff_t) win_w);
      result->vline_idx = target_vline;
      result->chars_per_row = chars_per_row;
      return true;
    }
#endif

  {
    /* Gap buffer path: go back nlines * chars_per_row characters
       and estimate the visual line at the resulting position.  */
    ptrdiff_t chars_back = nlines * chars_per_row;
    ptrdiff_t est_charpos = max (BEGV, charpos - chars_back);
    ptrdiff_t est_bytepos = CHAR_TO_BYTE (est_charpos);

    ptrdiff_t line_beg_byte;
    ptrdiff_t line_beg
      = find_newline_no_quit (est_charpos, est_bytepos,
                              -1, &line_beg_byte);
    ptrdiff_t chars_into_line = est_charpos - line_beg;
    ptrdiff_t vline_idx = chars_into_line / chars_per_row;
    ptrdiff_t target_col = vline_idx * chars_per_row;
    ptrdiff_t vline_start = line_beg + target_col;

    result->vline_start_charpos = vline_start;
    result->vline_start_bytepos = CHAR_TO_BYTE (vline_start);
    result->continuation_lines_width
      = (int) (vline_idx * (ptrdiff_t) win_w);
    result->vline_idx = vline_idx;
    result->chars_per_row = chars_per_row;
    return true;
  }
}

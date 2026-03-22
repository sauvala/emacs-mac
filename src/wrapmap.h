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

#ifndef EMACS_WRAPMAP_H
#define EMACS_WRAPMAP_H

#include "lisp.h"

struct window;

/* Result of a visual line estimation.  All positions are 1-based.  */
struct wrapmap_result {
  ptrdiff_t vline_start_charpos;
  ptrdiff_t vline_start_bytepos;
  int continuation_lines_width;
  ptrdiff_t vline_idx;          /* Visual line index within logical line.  */
  ptrdiff_t chars_per_row;
};

/* Estimate the visual line containing CHARPOS/BYTEPOS in window W.
   Returns true if successful.  Only meaningful when
   long_line_optimizations_p with line_wrap != TRUNCATE.  */
extern bool wrapmap_estimate_vline (struct window *w,
                                    ptrdiff_t charpos, ptrdiff_t bytepos,
                                    struct wrapmap_result *result);

/* Estimate the visual line NLINES before CHARPOS/BYTEPOS.
   Returns true if successful.  For rope buffers, this precisely
   targets max(0, vline_idx - nlines).  For gap buffers, it goes
   back nlines * chars_per_row characters and estimates from there.  */
extern bool wrapmap_estimate_backward (struct window *w,
                                       ptrdiff_t charpos, ptrdiff_t bytepos,
                                       ptrdiff_t nlines,
                                       struct wrapmap_result *result);

#endif /* EMACS_WRAPMAP_H */

/* Emacs-specific wrappers for piece table operations.

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

#ifndef EMACS_PIECETBL_H
#define EMACS_PIECETBL_H

#ifdef USE_PIECE_TABLE

#include <stddef.h>

/* Forward declaration.  */
struct buffer;

/* Create a piece table for BUFFER with initial CONTENT of LENGTH bytes.  */
extern void buffer_create_piece_table (struct buffer *buf,
				       const char *content, size_t length);

/* Destroy the piece table for BUFFER.  */
extern void buffer_destroy_piece_table (struct buffer *buf);

/* Emacs wrapper functions - these translate between Emacs's 1-based
   positions and the piece table's 0-based positions.  */

/* Return character at Emacs byte position N.  */
extern int pt_char_at_emacs (ptrdiff_t n);

/* Return pointer to contiguous data starting at Emacs byte position N.  */
extern const unsigned char *pt_get_contiguous_emacs (ptrdiff_t n);

/* Return end of contiguous region containing BYTEPOS (1-based).  */
extern ptrdiff_t pt_contiguous_end_emacs (ptrdiff_t bytepos);

/* Return start of contiguous region containing BYTEPOS (1-based).  */
extern ptrdiff_t pt_contiguous_start_emacs (ptrdiff_t bytepos);

/* Insert NBYTES bytes (NCHARS characters) of TEXT at Emacs byte
   position BYTEPOS.  */
extern int pt_insert_emacs (ptrdiff_t bytepos, const char *text,
			    ptrdiff_t nbytes, ptrdiff_t nchars);

/* Delete NBYTES bytes starting at Emacs byte position BYTEPOS.  */
extern int pt_delete_emacs (ptrdiff_t bytepos, ptrdiff_t nbytes);

/* Return total length of current buffer's piece table in bytes.  */
extern ptrdiff_t pt_length_emacs (void);

/* Return total length of current buffer's piece table in characters.  */
extern ptrdiff_t pt_charlen_emacs (void);

/* Convert Emacs character position (1-based) to byte position (1-based).  */
extern ptrdiff_t pt_emacs_charpos_to_bytepos (ptrdiff_t charpos);

/* Convert Emacs byte position (1-based) to character position (1-based).  */
extern ptrdiff_t pt_emacs_bytepos_to_charpos (ptrdiff_t bytepos);

/* Copy LENGTH bytes from Emacs byte position START into BUFFER.  */
extern ptrdiff_t pt_get_text_emacs (ptrdiff_t start, ptrdiff_t length,
				    char *buffer);

#endif /* USE_PIECE_TABLE */

#endif /* EMACS_PIECETBL_H */

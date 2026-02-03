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
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

This file provides wrapper functions that translate between Emacs's
buffer position system (1-based char/byte positions) and the piece
table's system (0-based positions).  */

#include <config.h>

#ifdef USE_PIECE_TABLE

#include "lisp.h"
#include "buffer.h"
#include "piece_table.h"
#include "piecetbl.h"

/* Return the character at byte position N in current buffer's piece
   table.  N is Emacs's 1-based byte position, which we convert to
   0-based for the piece table.  */

int
pt_char_at_emacs (ptrdiff_t n)
{
  /* Emacs byte positions are 1-based; piece table is 0-based.  */
  return pt_char_at (current_buffer->text->piece_table, n - BEG_BYTE);
}

/* Return pointer to contiguous data starting at byte position N in
   current buffer's piece table.  N is Emacs's 1-based byte position.

   WARNING: The returned pointer is only valid until the next
   modification to the piece table, and only for the contiguous region
   starting at N.  */

/* Static dummy buffer for out-of-range accesses.  This prevents crashes
   when code tries to read at the end of an empty buffer.  The buffer
   must be large enough that pointer arithmetic in search loops doesn't
   go out of bounds.  Fill with newlines to make newline searches terminate.  */
static const unsigned char empty_buffer[4096] = { '\n', '\n', '\n', '\n' };

const unsigned char *
pt_get_contiguous_emacs (ptrdiff_t n)
{
  struct PieceTable *pt = current_buffer->text->piece_table;

  /* Handle NULL piece table or empty buffer.  */
  if (!pt)
    return empty_buffer;

  /* Convert Emacs 1-based position to 0-based.  */
  ptrdiff_t pt_pos = n - BEG_BYTE;

  /* Bounds check: if position is at or beyond end, return dummy buffer.  */
  if (pt_pos < 0 || (size_t) pt_pos >= pt_length (pt))
    return empty_buffer;

  const unsigned char *result = pt_get_contiguous (pt, pt_pos, NULL);
  if (!result)
    return empty_buffer;
  return result;
}

/* Return the byte position where the contiguous region containing
   BYTEPOS ends.  BYTEPOS is Emacs's 1-based byte position.  Returns
   1-based byte position.  */

ptrdiff_t
pt_contiguous_end_emacs (ptrdiff_t bytepos)
{
  struct PieceTable *pt = current_buffer->text->piece_table;

  /* Handle NULL or empty piece table.  */
  if (!pt || pt_length (pt) == 0)
    return bytepos;

  /* Convert to 0-based.  */
  ptrdiff_t pt_pos = bytepos - BEG_BYTE;

  /* Clamp to valid range.  */
  if (pt_pos < 0)
    pt_pos = 0;
  if ((size_t) pt_pos >= pt_length (pt))
    pt_pos = pt_length (pt) - 1;

  size_t pt_end = pt_contiguous_end (pt, pt_pos);
  return pt_end + BEG_BYTE;
}

/* Return the byte position where the contiguous region containing
   BYTEPOS starts.  BYTEPOS is Emacs's 1-based byte position.  Returns
   1-based byte position.  */

ptrdiff_t
pt_contiguous_start_emacs (ptrdiff_t bytepos)
{
  struct PieceTable *pt = current_buffer->text->piece_table;

  /* Handle NULL or empty piece table.  */
  if (!pt || pt_length (pt) == 0)
    return bytepos;

  /* Convert to 0-based.  */
  ptrdiff_t pt_pos = bytepos - BEG_BYTE;

  /* Clamp to valid range.  */
  if (pt_pos < 0)
    pt_pos = 0;
  if ((size_t) pt_pos >= pt_length (pt))
    pt_pos = pt_length (pt) - 1;

  size_t pt_start = pt_contiguous_start (pt, pt_pos);
  return pt_start + BEG_BYTE;
}

/* Create a piece table for BUFFER with initial content.  This is
   called during buffer creation when piece table mode is enabled.
   CONTENT is the initial text, LENGTH is its size in bytes.  */

void
buffer_create_piece_table (struct buffer *buf, const char *content,
			   size_t length)
{
  /* Create piece table with undo disabled (Emacs has its own undo).  */
  if (length > 0)
    buf->text->piece_table = pt_create_with_content_ex (content, length, true);
  else
    buf->text->piece_table = pt_create_ex (true);

  if (buf->text->piece_table)
    buf->text->using_piece_table = true;
}

/* Destroy the piece table for BUFFER.  Called when killing a buffer.  */

void
buffer_destroy_piece_table (struct buffer *buf)
{
  if (buf->text->piece_table)
    {
      pt_destroy (buf->text->piece_table);
      buf->text->piece_table = NULL;
    }
  buf->text->using_piece_table = false;
}

/* Insert NBYTES bytes (NCHARS characters) of TEXT at byte position
   BYTEPOS in current buffer's piece table.  BYTEPOS is Emacs's
   1-based byte position.  Return 0 on success, -1 on error.  */

int
pt_insert_emacs (ptrdiff_t bytepos, const char *text,
		 ptrdiff_t nbytes, ptrdiff_t nchars)
{
  if (!current_buffer->text->using_piece_table)
    return -1;
  /* Emacs byte positions are 1-based; piece table is 0-based.  */
  return pt_insert_with_charlen (current_buffer->text->piece_table,
				 bytepos - BEG_BYTE, text, nbytes, nchars);
}

/* Insert NBYTES bytes (NCHARS characters) of TEXT at byte position
   BYTEPOS, splitting into chunks for better position conversion
   performance.  This should be used for loading large files.  */

int
pt_insert_chunked_emacs (ptrdiff_t bytepos, const char *text,
			 ptrdiff_t nbytes, ptrdiff_t nchars)
{
  if (!current_buffer->text->using_piece_table
      || !current_buffer->text->piece_table)
    return -1;

  /* Convert from 1-based Emacs position to 0-based piece table position.  */
  size_t pt_pos = (size_t) (bytepos - BEG_BYTE);

  return pt_insert_chunked (current_buffer->text->piece_table, pt_pos,
			    text, (size_t) nbytes, (size_t) nchars, 0);
}

/* Delete NBYTES bytes starting at byte position BYTEPOS in current
   buffer's piece table.  BYTEPOS is Emacs's 1-based byte position.
   Return 0 on success, -1 on error.  */

int
pt_delete_emacs (ptrdiff_t bytepos, ptrdiff_t nbytes)
{
  if (!current_buffer->text->using_piece_table)
    return -1;
  /* Emacs byte positions are 1-based; piece table is 0-based.  */
  return pt_delete (current_buffer->text->piece_table,
		    bytepos - BEG_BYTE, nbytes);
}

/* Return the total length of current buffer's piece table in bytes.  */

ptrdiff_t
pt_length_emacs (void)
{
  if (!current_buffer->text->using_piece_table)
    return 0;
  return pt_length (current_buffer->text->piece_table);
}

/* Return the total length of current buffer's piece table in
   characters.  */

ptrdiff_t
pt_charlen_emacs (void)
{
  if (!current_buffer->text->using_piece_table)
    return 0;
  return pt_charlen (current_buffer->text->piece_table);
}

/* Convert Emacs character position (1-based) to byte position
   (1-based).  */

ptrdiff_t
pt_emacs_charpos_to_bytepos (ptrdiff_t charpos)
{
  if (!current_buffer->text->using_piece_table)
    return charpos;  /* Fallback: assume 1:1 mapping.  */
  /* Convert to 0-based, call piece table, convert back to 1-based.  */
  size_t bytepos = pt_charpos_to_bytepos (current_buffer->text->piece_table,
					  charpos - BEG);
  return bytepos + BEG_BYTE;
}

/* Convert Emacs byte position (1-based) to character position
   (1-based).  */

ptrdiff_t
pt_emacs_bytepos_to_charpos (ptrdiff_t bytepos)
{
  if (!current_buffer->text->using_piece_table)
    return bytepos;  /* Fallback: assume 1:1 mapping.  */
  /* Convert to 0-based, call piece table, convert back to 1-based.  */
  size_t charpos = pt_bytepos_to_charpos (current_buffer->text->piece_table,
					  bytepos - BEG_BYTE);
  return charpos + BEG;
}

/* Copy LENGTH bytes starting at byte position START from current
   buffer's piece table into BUFFER.  START is Emacs's 1-based byte
   position.  Return number of bytes written.  */

ptrdiff_t
pt_get_text_emacs (ptrdiff_t start, ptrdiff_t length, char *buffer)
{
  if (!current_buffer->text->using_piece_table)
    return 0;
  /* Emacs byte positions are 1-based; piece table is 0-based.  */
  return pt_get_text (current_buffer->text->piece_table,
		      start - BEG_BYTE, length, buffer);
}

#endif /* USE_PIECE_TABLE */

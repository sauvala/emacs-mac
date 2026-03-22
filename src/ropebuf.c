/* Emacs-specific wrappers for rope operations.

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
buffer position system (1-based char/byte positions) and the rope's
system (0-based positions).  */

#include <config.h>

#ifdef USE_ROPE

#include "lisp.h"
#include "buffer.h"
#include "rope.h"
#include "ropebuf.h"

/* Per-buffer chunk cache to avoid repeated tree traversals during
   sequential access (display, scanning).  Caches the last accessed
   chunk's pointer and byte range.  These are exposed via ropebuf.h
   for inline fast-path checking in BYTE_POS_ADDR and FETCH_BYTE.  */
struct Rope *rope_chunk_cache_rope;        /* Which rope this cache is for.  */
ptrdiff_t rope_chunk_cache_start;          /* 0-based start of cached chunk.  */
ptrdiff_t rope_chunk_cache_end;            /* 0-based exclusive end.  */
const char *rope_chunk_cache_ptr;          /* Pointer to start of chunk data.  */

/* Per-buffer charpos↔bytepos conversion cache.  Avoids O(log n) rope
   tree traversal when the same or nearby position is converted
   repeatedly (common in display engine).  */
struct Rope *rope_pos_cache_rope;          /* Which rope this cache is for.  */
ptrdiff_t rope_pos_cache_charpos;          /* Last converted charpos (1-based).  */
ptrdiff_t rope_pos_cache_bytepos;          /* Last converted bytepos (1-based).  */

/* Invalidate all rope caches.  Must be called after any rope modification
   (insert, delete, replace) since those can restructure the tree.  */
void
rope_invalidate_cache (void)
{
  rope_chunk_cache_rope = NULL;
  rope_pos_cache_rope = NULL;
}

/* Look up byte position POS (0-based) in rope R, using the cache.
   Returns pointer to the byte at POS, or NULL if out of range.
   Sets rope_chunk_cache_start/end/ptr on cache miss.  */
static inline const char *
rope_cached_lookup (struct Rope *r, ptrdiff_t pos)
{
  /* Cache hit: position is within the cached chunk.  */
  if (r == rope_chunk_cache_rope
      && pos >= rope_chunk_cache_start
      && pos < rope_chunk_cache_end)
    return rope_chunk_cache_ptr + (pos - rope_chunk_cache_start);

  /* Cache miss: traverse the tree.  */
  size_t avail;
  const char *result = rope_get_contiguous (r, pos, &avail);
  if (!result)
    return NULL;

  /* Update cache.  */
  rope_chunk_cache_rope = r;
  rope_chunk_cache_ptr = result;
  rope_chunk_cache_start = pos;
  rope_chunk_cache_end = pos + (ptrdiff_t) avail;

  return result;
}

/* Return the character at byte position N in current buffer's rope.
   N is Emacs's 1-based byte position, which we convert to 0-based.  */

int
rope_char_at_emacs (ptrdiff_t n)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    return 0;

  ptrdiff_t pos = n - BEG_BYTE;
  if (pos < 0 || (size_t) pos >= rope_byte_len (r))
    return 0;

  const char *p = rope_cached_lookup (r, pos);
  return p ? (unsigned char) *p : 0;
}

/* Static dummy buffer for out-of-range accesses.  This prevents crashes
   when code tries to read at the end of an empty buffer.  The buffer
   must be large enough that pointer arithmetic in search loops doesn't
   go out of bounds.  Fill with newlines to make newline searches terminate.  */
static const unsigned char empty_buffer[4096] = { '\n', '\n', '\n', '\n' };

/* Return pointer to contiguous data starting at byte position N in
   current buffer's rope.  N is Emacs's 1-based byte position.

   WARNING: The returned pointer is only valid until the next
   modification to the rope, and only for the contiguous region
   starting at N (up to ~128 bytes in a rope chunk).  */

const unsigned char *
rope_get_contiguous_emacs (ptrdiff_t n)
{
  struct Rope *r = current_buffer->text->rope;

  if (!r)
    return empty_buffer;

  ptrdiff_t pos = n - BEG_BYTE;

  if (pos < 0 || (size_t) pos >= rope_byte_len (r))
    return empty_buffer;

  const char *result = rope_cached_lookup (r, pos);
  if (!result)
    return empty_buffer;
  return (const unsigned char *) result;
}

/* Return the byte position where the contiguous region containing
   BYTEPOS ends.  BYTEPOS is Emacs's 1-based byte position.  Returns
   1-based byte position.  */

ptrdiff_t
rope_contiguous_end_emacs (ptrdiff_t bytepos)
{
  struct Rope *r = current_buffer->text->rope;

  if (!r || rope_byte_len (r) == 0)
    return bytepos;

  ptrdiff_t pos = bytepos - BEG_BYTE;

  if (pos < 0)
    pos = 0;
  if ((size_t) pos >= rope_byte_len (r))
    pos = rope_byte_len (r) - 1;

  /* Use cache if available — the cached chunk range gives us the answer.  */
  if (r == rope_chunk_cache_rope
      && pos >= rope_chunk_cache_start
      && pos < rope_chunk_cache_end)
    return rope_chunk_cache_end + BEG_BYTE - 1;

  /* Cache miss: query the tree for the contiguous range.  */
  size_t chunk_start, chunk_end;
  if (rope_contiguous_range (r, pos, &chunk_start, &chunk_end) != 0)
    return bytepos;

  /* Return inclusive end (last byte in the chunk), matching the
     convention of BUFFER_CEILING_OF which returns the last contiguous
     byte position, not one past it.  */
  return (ptrdiff_t) chunk_end + BEG_BYTE - 1;
}

/* Return the byte position where the contiguous region containing
   BYTEPOS starts.  BYTEPOS is Emacs's 1-based byte position.  Returns
   1-based byte position.  */

ptrdiff_t
rope_contiguous_start_emacs (ptrdiff_t bytepos)
{
  struct Rope *r = current_buffer->text->rope;

  if (!r || rope_byte_len (r) == 0)
    return bytepos;

  ptrdiff_t pos = bytepos - BEG_BYTE;

  if (pos < 0)
    pos = 0;
  if ((size_t) pos >= rope_byte_len (r))
    pos = rope_byte_len (r) - 1;

  /* Use cache if available.  */
  if (r == rope_chunk_cache_rope
      && pos >= rope_chunk_cache_start
      && pos < rope_chunk_cache_end)
    return rope_chunk_cache_start + BEG_BYTE;

  size_t chunk_start, chunk_end;
  if (rope_contiguous_range (r, pos, &chunk_start, &chunk_end) != 0)
    return bytepos;

  return (ptrdiff_t) chunk_start + BEG_BYTE;
}

/* Create a rope for BUFFER with initial content.  This is called
   during buffer creation when rope mode is enabled.  CONTENT is the
   initial text, LENGTH is its size in bytes.  */

void
buffer_create_rope (struct buffer *buf, const char *content, size_t length)
{
  if (length > 0)
    buf->text->rope = rope_from_str (content, length);
  else
    buf->text->rope = rope_new ();

  if (buf->text->rope)
    buf->text->using_rope = true;
}

/* Destroy the rope for BUFFER.  Called when killing a buffer.  */

void
buffer_destroy_rope (struct buffer *buf)
{
  if (buf->text->rope)
    {
      rope_free (buf->text->rope);
      buf->text->rope = NULL;
    }
  buf->text->using_rope = false;
}

/* Insert NBYTES bytes (NCHARS characters) of TEXT at byte position
   BYTEPOS in current buffer's rope.  BYTEPOS is Emacs's 1-based byte
   position.  Return 0 on success, -1 on error.  */

int
rope_insert_emacs (ptrdiff_t bytepos, const char *text,
		   ptrdiff_t nbytes, ptrdiff_t nchars)
{
  if (!current_buffer->text->using_rope)
    return -1;
  (void) nchars;  /* Rope tracks chars internally.  */
  rope_invalidate_cache ();
  return rope_insert (current_buffer->text->rope,
		      bytepos - BEG_BYTE, text, nbytes);
}

/* Delete NBYTES bytes starting at byte position BYTEPOS in current
   buffer's rope.  BYTEPOS is Emacs's 1-based byte position.
   Return 0 on success, -1 on error.  */

int
rope_delete_emacs (ptrdiff_t bytepos, ptrdiff_t nbytes)
{
  if (!current_buffer->text->using_rope)
    return -1;
  rope_invalidate_cache ();
  size_t start = bytepos - BEG_BYTE;
  return rope_delete (current_buffer->text->rope, start, start + nbytes);
}

/* Return the total length of current buffer's rope in bytes.  */

ptrdiff_t
rope_length_emacs (void)
{
  if (!current_buffer->text->using_rope)
    return 0;
  return rope_byte_len (current_buffer->text->rope);
}

/* Return the total length of current buffer's rope in characters.  */

ptrdiff_t
rope_charlen_emacs (void)
{
  if (!current_buffer->text->using_rope)
    return 0;
  return rope_char_len (current_buffer->text->rope);
}

/* Convert Emacs character position (1-based) to byte position
   (1-based).  */

ptrdiff_t
rope_emacs_charpos_to_bytepos (ptrdiff_t charpos)
{
  if (!current_buffer->text->using_rope)
    return charpos;
  size_t bytepos = rope_char_to_byte (current_buffer->text->rope,
				       charpos - BEG);
  return bytepos + BEG_BYTE;
}

/* Convert Emacs byte position (1-based) to character position
   (1-based).  */

ptrdiff_t
rope_emacs_bytepos_to_charpos (ptrdiff_t bytepos)
{
  if (!current_buffer->text->using_rope)
    return bytepos;
  size_t charpos = rope_byte_to_char (current_buffer->text->rope,
				       bytepos - BEG_BYTE);
  return charpos + BEG;
}

/* Convert Emacs character position (1-based) to byte position
   (1-based) for a specific BUFFER.  O(log n) via rope tree,
   but O(1) on cache hit.  */

ptrdiff_t
rope_buf_charpos_to_bytepos (struct buffer *buf, ptrdiff_t charpos)
{
  struct Rope *r = buf->text->rope;
  if (!r)
    return charpos;

  /* Cache hit: exact match.  */
  if (r == rope_pos_cache_rope
      && charpos == rope_pos_cache_charpos)
    return rope_pos_cache_bytepos;

  size_t bytepos = rope_char_to_byte (r, charpos - BEG);
  ptrdiff_t result = bytepos + BEG_BYTE;

  /* Update cache.  */
  rope_pos_cache_rope = r;
  rope_pos_cache_charpos = charpos;
  rope_pos_cache_bytepos = result;

  return result;
}

/* Convert Emacs byte position (1-based) to character position
   (1-based) for a specific BUFFER.  O(log n) via rope tree,
   but O(1) on cache hit.  */

ptrdiff_t
rope_buf_bytepos_to_charpos (struct buffer *buf, ptrdiff_t bytepos)
{
  struct Rope *r = buf->text->rope;
  if (!r)
    return bytepos;

  /* Cache hit: exact match.  */
  if (r == rope_pos_cache_rope
      && bytepos == rope_pos_cache_bytepos)
    return rope_pos_cache_charpos;

  size_t charpos = rope_byte_to_char (r, bytepos - BEG_BYTE);
  ptrdiff_t result = charpos + BEG;

  /* Update cache.  */
  rope_pos_cache_rope = r;
  rope_pos_cache_charpos = result;
  rope_pos_cache_bytepos = bytepos;

  return result;
}

/* Copy LENGTH bytes starting at byte position START from current
   buffer's rope into BUFFER.  START is Emacs's 1-based byte
   position.  Return number of bytes written.  */

ptrdiff_t
rope_get_text_emacs (ptrdiff_t start, ptrdiff_t length, char *buffer)
{
  if (!current_buffer->text->using_rope)
    return 0;
  size_t s = start - BEG_BYTE;
  return rope_copy (current_buffer->text->rope, s, s + length,
		    buffer, length);
}

/* Replace a single byte at byte position BYTEPOS in current buffer's
   rope.  BYTEPOS is Emacs's 1-based byte position.  BYTE is the new
   byte value.  Implemented as delete(1) + insert(1).
   Return 0 on success, -1 on error.  */

int
rope_set_byte_emacs (ptrdiff_t bytepos, unsigned char byte)
{
  if (!current_buffer->text->using_rope
      || !current_buffer->text->rope)
    return -1;
  rope_invalidate_cache ();
  size_t pos = bytepos - BEG_BYTE;
  if (rope_delete (current_buffer->text->rope, pos, pos + 1) != 0)
    return -1;
  char c = (char) byte;
  return rope_insert (current_buffer->text->rope, pos, &c, 1);
}

/* Return pointer to contiguous data at BYTEPOS (1-based) and set
   *OUT_LEN to the number of contiguous bytes available starting at
   the returned pointer.  Returns dummy buffer if out of bounds.  */

const unsigned char *
rope_get_contiguous_with_len_emacs (ptrdiff_t bytepos, ptrdiff_t *out_len)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    {
      *out_len = 0;
      return empty_buffer;
    }

  ptrdiff_t pos = bytepos - BEG_BYTE;
  if (pos < 0 || (size_t) pos >= rope_byte_len (r))
    {
      *out_len = 0;
      return empty_buffer;
    }

  const char *result = rope_cached_lookup (r, pos);
  if (!result)
    {
      *out_len = 0;
      return empty_buffer;
    }
  /* The cache knows the chunk boundaries.  */
  *out_len = rope_chunk_cache_end - pos;
  return (const unsigned char *) result;
}

/* Insert NBYTES bytes (NCHARS characters) of TEXT at byte position
   BYTEPOS in buffer BUF's rope.  BYTEPOS is Emacs's 1-based byte
   position.  Return 0 on success, -1 on error.  */

int
rope_insert_for_buffer_emacs (struct buffer *buf, ptrdiff_t bytepos,
			      const char *text, ptrdiff_t nbytes,
			      ptrdiff_t nchars)
{
  if (!buf->text->using_rope || !buf->text->rope)
    return -1;
  (void) nchars;
  rope_invalidate_cache ();
  return rope_insert (buf->text->rope, bytepos - BEG_BYTE, text, nbytes);
}

/* Count newlines in the byte range [START_BYTE, END_BYTE) using the
   rope's tree-based line counting.  START_BYTE and END_BYTE are
   Emacs's 1-based byte positions.  O(log n).  */

ptrdiff_t
rope_count_newlines_emacs (ptrdiff_t start_byte, ptrdiff_t end_byte)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    return 0;

  size_t start = start_byte - BEG_BYTE;
  size_t end = end_byte - BEG_BYTE;

  return (ptrdiff_t) rope_newlines_in_range (r, start, end);
}

/* Find the byte position of the Nth newline (1-indexed) at or after
   START_BYTE.  Returns 1-based byte position after the newline, or
   Z_BYTE if not found.  */

ptrdiff_t
rope_find_nth_newline_emacs (ptrdiff_t start_byte, ptrdiff_t n)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    return Z_BYTE;

  size_t pos = rope_find_nth_newline (r, start_byte - BEG_BYTE,
				      (size_t) n);
  ptrdiff_t result = (ptrdiff_t) pos + BEG_BYTE;

  /* Clamp to Z_BYTE.  */
  if (result > Z_BYTE)
    result = Z_BYTE;
  return result;
}

/* Return the longest line length in characters.  O(1) — reads the
   tree root's aggregated summary.  */

size_t
rope_longest_row_chars_emacs (void)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    return 0;
  return rope_longest_row_chars (r);
}

/* Return 0-indexed {row, col} for Emacs byte position BYTEPOS
   (1-based).  O(log n) tree traversal.  */

RopePoint
rope_offset_to_point_emacs (ptrdiff_t bytepos)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    {
      RopePoint p = {0, 0};
      return p;
    }
  return rope_offset_to_point (r, bytepos - BEG_BYTE);
}

/* Return 0-based byte offset for 0-indexed {ROW, COL} where COL is
   in characters.  Result is 1-based Emacs byte position.  O(log n).  */

ptrdiff_t
rope_point_to_offset_emacs (uint32_t row, uint32_t col)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    return BEG_BYTE;
  RopePoint p = { row, col };
  return (ptrdiff_t) rope_point_to_offset (r, p) + BEG_BYTE;
}

/* Return total line count.  O(1) — reads the tree root's aggregated
   summary.  */

uint32_t
rope_line_count_emacs (void)
{
  struct Rope *r = current_buffer->text->rope;
  if (!r)
    return 0;
  return rope_line_count (r);
}

#endif /* USE_ROPE */

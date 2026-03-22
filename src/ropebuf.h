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
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

#ifndef EMACS_ROPEBUF_H
#define EMACS_ROPEBUF_H

#ifdef USE_ROPE

#include <stddef.h>
#include "rope.h"

/* Forward declaration.  */
struct buffer;

/* Per-buffer chunk cache — exposed for inline fast-path in BYTE_POS_ADDR.  */
extern struct Rope *rope_chunk_cache_rope;
extern ptrdiff_t rope_chunk_cache_start;
extern ptrdiff_t rope_chunk_cache_end;
extern const char *rope_chunk_cache_ptr;

/* Per-buffer charpos↔bytepos conversion cache.  */
extern struct Rope *rope_pos_cache_rope;
extern ptrdiff_t rope_pos_cache_charpos;
extern ptrdiff_t rope_pos_cache_bytepos;

extern void buffer_create_rope (struct buffer *buf, const char *content, size_t length);
extern void buffer_destroy_rope (struct buffer *buf);
extern void rope_invalidate_cache (void);
extern int rope_char_at_emacs (ptrdiff_t n);
extern const unsigned char *rope_get_contiguous_emacs (ptrdiff_t n);
extern ptrdiff_t rope_contiguous_end_emacs (ptrdiff_t bytepos);
extern ptrdiff_t rope_contiguous_start_emacs (ptrdiff_t bytepos);
extern int rope_insert_emacs (ptrdiff_t bytepos, const char *text, ptrdiff_t nbytes, ptrdiff_t nchars);
extern int rope_delete_emacs (ptrdiff_t bytepos, ptrdiff_t nbytes);
extern ptrdiff_t rope_length_emacs (void);
extern ptrdiff_t rope_charlen_emacs (void);
extern ptrdiff_t rope_emacs_charpos_to_bytepos (ptrdiff_t charpos);
extern ptrdiff_t rope_emacs_bytepos_to_charpos (ptrdiff_t bytepos);
extern ptrdiff_t rope_get_text_emacs (ptrdiff_t start, ptrdiff_t length, char *buffer);
extern int rope_set_byte_emacs (ptrdiff_t bytepos, unsigned char byte);
extern const unsigned char *rope_get_contiguous_with_len_emacs (ptrdiff_t bytepos, ptrdiff_t *out_len);
extern int rope_insert_for_buffer_emacs (struct buffer *buf, ptrdiff_t bytepos, const char *text, ptrdiff_t nbytes, ptrdiff_t nchars);
extern ptrdiff_t rope_buf_charpos_to_bytepos (struct buffer *buf, ptrdiff_t charpos);
extern ptrdiff_t rope_buf_bytepos_to_charpos (struct buffer *buf, ptrdiff_t bytepos);
extern ptrdiff_t rope_count_newlines_emacs (ptrdiff_t start_byte, ptrdiff_t end_byte);
extern ptrdiff_t rope_find_nth_newline_emacs (ptrdiff_t start_byte, ptrdiff_t n);
extern size_t rope_longest_row_chars_emacs (void);
extern RopePoint rope_offset_to_point_emacs (ptrdiff_t bytepos);
extern ptrdiff_t rope_point_to_offset_emacs (uint32_t row, uint32_t col);
extern uint32_t rope_line_count_emacs (void);

#endif /* USE_ROPE */

#endif /* EMACS_ROPEBUF_H */

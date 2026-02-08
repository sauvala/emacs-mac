/* Piece table data structure for text editing.

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

A piece table represents text as a sequence of "pieces" that reference
spans in either an original (read-only) buffer or an add (append-only)
buffer.  This allows efficient insert/delete operations and natural
undo/redo support.  */

#ifndef EMACS_PIECE_TABLE_H
#define EMACS_PIECE_TABLE_H

#include <stddef.h>
#include <stdbool.h>

/* Opaque piece table handle.  */
typedef struct PieceTable PieceTable;

/* Iterator for traversing piece table content.  */
typedef struct PieceTableIterator PieceTableIterator;

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

/* Create an empty piece table.  If DISABLE_UNDO is true, the piece
   table will not track changes for undo/redo (Emacs has its own undo
   system).  Return new piece table, or NULL on allocation failure.  */
extern PieceTable *pt_create_ex (bool disable_undo);

/* Create an empty piece table with undo enabled.  */
extern PieceTable *pt_create (void);

/* Create a piece table with initial content.  CONTENT is copied.
   LENGTH is the size in bytes.  Return new piece table, or NULL on
   allocation failure.  */
extern PieceTable *pt_create_with_content (const char *content, size_t length);

/* Create a piece table with initial content and optional undo.  */
extern PieceTable *pt_create_with_content_ex (const char *content,
					      size_t length,
					      bool disable_undo);

/* Adopt DATA as the original buffer of an empty piece table.  Takes
   ownership of DATA (which must have been allocated with malloc).
   NBYTES is the data size; NCHARS is the character count.
   Returns 0 on success, -1 on error.  */
extern int pt_adopt_original_buffer (PieceTable *pt, char *data,
				     size_t nbytes, size_t nchars);

/* Destroy a piece table and free all resources.  PT may be NULL.  */
extern void pt_destroy (PieceTable *pt);

/* ============================================================================
 * Core Operations
 * ============================================================================ */

/* Insert text at POSITION (zero-based byte position).  TEXT is the
   text to insert, LENGTH is the number of bytes.  Return 0 on
   success, -1 on error.  */
extern int pt_insert (PieceTable *pt, size_t position,
		      const char *text, size_t length);

/* Insert text at POSITION with known character count.  This is more
   efficient than pt_insert when the character count is already known
   (e.g., from Emacs).  NBYTES is the byte length, NCHARS is the
   character count.  Return 0 on success, -1 on error.  */
extern int pt_insert_with_charlen (PieceTable *pt, size_t position,
				   const char *text, size_t nbytes,
				   size_t nchars);

/* Insert text as multiple chunks for better position conversion
   performance.  Large pieces cause O(n) scans during char/byte
   position conversion; splitting into smaller chunks (default 64KB)
   makes position conversion O(log n + chunk_size).  CHUNK_SIZE is the
   maximum size of each piece (0 = use default 64KB).  Return 0 on
   success, -1 on error.  */
extern int pt_insert_chunked (PieceTable *pt, size_t position,
			      const char *text, size_t nbytes,
			      size_t nchars, size_t chunk_size);

/* Delete LENGTH bytes starting at POSITION.  Return 0 on success, -1
   on error.  */
extern int pt_delete (PieceTable *pt, size_t position, size_t length);

/* ============================================================================
 * Access
 * ============================================================================ */

/* Return the total length of the document in bytes.  */
extern size_t pt_length (const PieceTable *pt);

/* Return the total length of the document in UTF-8 characters.  */
extern size_t pt_charlen (const PieceTable *pt);

/* Convert character position to byte position.  CHARPOS is
   zero-based.  Return zero-based byte position.  */
extern size_t pt_charpos_to_bytepos (const PieceTable *pt, size_t charpos);

/* Convert byte position to character position.  BYTEPOS is
   zero-based.  Return zero-based character position.  */
extern size_t pt_bytepos_to_charpos (const PieceTable *pt, size_t bytepos);

/* Return byte at POSITION, or -1 if out of bounds.  */
extern int pt_char_at (const PieceTable *pt, size_t position);

/* Extract LENGTH bytes starting at START into BUFFER.  BUFFER must
   have room for LENGTH bytes.  Return number of bytes written, or 0
   on error.  */
extern size_t pt_get_text (const PieceTable *pt, size_t start,
			   size_t length, char *buffer);

/* Return the entire document as a newly allocated null-terminated
   string.  Caller must free the result.  Return NULL on error.  */
extern char *pt_get_all_text (const PieceTable *pt);

/* ============================================================================
 * Contiguous Access (Emacs-specific)
 * ============================================================================ */

/* Get a pointer to contiguous data starting at POSITION.  OUT_LENGTH
   receives the number of bytes available contiguously starting at the
   returned pointer.  This allows callers to access data without
   copying when possible.

   Note: The returned pointer is only valid until the next
   modification to the piece table.

   Return pointer to data, or NULL if POSITION is out of bounds.  */
extern const unsigned char *pt_get_contiguous (const PieceTable *pt,
					       size_t position,
					       size_t *out_length);

/* Return the byte position where the current contiguous region ends.
   This is used for BUFFER_CEILING_OF functionality.  Starting from
   POSITION, return the position of the last byte in the same piece,
   or the end of the document.  */
extern size_t pt_contiguous_end (const PieceTable *pt, size_t position);

/* Return the byte position where the current contiguous region
   begins.  This is used for BUFFER_FLOOR_OF functionality.  */
extern size_t pt_contiguous_start (const PieceTable *pt, size_t position);

/* ============================================================================
 * Iterator (for efficient sequential access)
 * ============================================================================ */

/* Create an iterator starting at POSITION.  Return NULL on error.  */
extern PieceTableIterator *pt_iterator_create (const PieceTable *pt,
					       size_t position);

/* Destroy an iterator.  */
extern void pt_iterator_destroy (PieceTableIterator *iter);

/* Get the current byte and advance the iterator.  Return -1 at end of
   document.  */
extern int pt_iterator_next (PieceTableIterator *iter);

/* Get the current byte without advancing.  Return -1 at end of
   document.  */
extern int pt_iterator_peek (const PieceTableIterator *iter);

/* Get current position of the iterator.  */
extern size_t pt_iterator_position (const PieceTableIterator *iter);

/* Move iterator to POSITION.  Return 0 on success, -1 if out of
   bounds.  */
extern int pt_iterator_seek (PieceTableIterator *iter, size_t position);

/* ============================================================================
 * Line Operations
 * ============================================================================ */

/* Return total number of lines (minimum 1 for empty document).  */
extern size_t pt_line_count (const PieceTable *pt);

/* Return byte position where LINE_NUMBER (zero-based) starts.  */
extern size_t pt_line_start (const PieceTable *pt, size_t line_number);

/* Return length of LINE_NUMBER in bytes (including newline if
   present).  */
extern size_t pt_line_length (const PieceTable *pt, size_t line_number);

/* Get content of LINE_NUMBER (without trailing newline) into BUFFER.
   BUFFER_SIZE is the size of BUFFER.  Return number of bytes written
   (not including null terminator).  */
extern size_t pt_get_line (const PieceTable *pt, size_t line_number,
			   char *buffer, size_t buffer_size);

/* Convert byte POSITION to line and column.  LINE and COL are
   zero-based.  */
extern void pt_position_to_line_col (const PieceTable *pt, size_t position,
				     size_t *line, size_t *col);

/* Count newlines in bytes [0, POSITION) using the tree structure.
   O(log n) tree walk + O(piece_size) scan within one piece.  */
extern size_t pt_newlines_before (const PieceTable *pt, size_t position);

/* Find byte position of the Nth newline (0-indexed) at or after
   START_POS.  Returns position after the newline, or total_length
   if not found.  */
extern size_t pt_find_nth_newline_after (const PieceTable *pt,
					  size_t start_pos, size_t n);

/* ============================================================================
 * Undo/Redo (only available if undo was not disabled at creation)
 * ============================================================================ */

/* Return non-zero if undo is available.  */
extern int pt_can_undo (const PieceTable *pt);

/* Return non-zero if redo is available.  */
extern int pt_can_redo (const PieceTable *pt);

/* Undo the last operation.  Return 0 on success, -1 if nothing to
   undo or undo disabled.  */
extern int pt_undo (PieceTable *pt);

/* Redo the last undone operation.  Return 0 on success, -1 if nothing
   to redo or undo disabled.  */
extern int pt_redo (PieceTable *pt);

/* ============================================================================
 * Debug
 * ============================================================================ */

/* Print piece table structure for debugging.  */
extern void pt_debug_print (const PieceTable *pt);

#endif /* EMACS_PIECE_TABLE_H */

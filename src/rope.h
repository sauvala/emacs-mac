#ifndef SUMTREE_ROPE_H
#define SUMTREE_ROPE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Rope Rope;
typedef struct RopeCursor RopeCursor;

typedef struct RopePoint {
    uint32_t row;
    uint32_t col;
} RopePoint;

typedef struct TextSummary {
    size_t bytes;
    size_t chars;
    size_t chars_utf16;
    RopePoint lines;
    size_t first_line_chars;
    size_t last_line_chars;
    size_t longest_row;
    size_t longest_row_chars;
} TextSummary;

#define ROPE_ITER_CHUNK_BYTES 1024

typedef struct RopeChunkIter {
    const Rope *rope;
    size_t start;
    size_t end;
    size_t cursor;
    char buffer[ROPE_ITER_CHUNK_BYTES];
} RopeChunkIter;

Rope *rope_new(void);
Rope *rope_from_str(const char *text, size_t len);
void rope_free(Rope *rope);

int rope_insert(Rope *rope, size_t offset, const char *text, size_t len);
int rope_delete(Rope *rope, size_t start, size_t end);
int rope_replace(Rope *rope, size_t start, size_t end, const char *text, size_t len);
void rope_append(Rope *rope, Rope *other);

size_t rope_byte_len(const Rope *rope);
size_t rope_char_len(const Rope *rope);
uint32_t rope_line_count(const Rope *rope);
size_t rope_longest_row(const Rope *rope);
size_t rope_longest_row_chars(const Rope *rope);
TextSummary rope_summary(const Rope *rope);

RopePoint rope_offset_to_point(const Rope *rope, size_t byte_offset);
size_t rope_point_to_offset(const Rope *rope, RopePoint point);
size_t rope_char_to_byte(const Rope *rope, size_t char_offset);
size_t rope_byte_to_char(const Rope *rope, size_t byte_offset);

size_t rope_copy(const Rope *rope, size_t start, size_t end, char *buf, size_t buf_len);
char *rope_to_str(const Rope *rope);

RopeChunkIter rope_chunks(const Rope *rope, size_t start, size_t end);
bool rope_chunks_next(RopeChunkIter *iter, const char **text, size_t *len);

/* Return a pointer to the contiguous chunk data containing byte OFFSET.
   Set *OUT_LEN to the number of contiguous bytes available from the
   returned pointer (at most one chunk's worth, i.e. 128 bytes).
   Returns NULL if OFFSET is out of bounds.  O(log n).  */
const char *rope_get_contiguous(const Rope *rope, size_t offset, size_t *out_len);

/* Return the byte value at OFFSET, or -1 if out of bounds.  O(log n).  */
int rope_byte_at(const Rope *rope, size_t offset);

/* Return the rope-level byte offsets of the contiguous chunk containing
   OFFSET.  Sets *OUT_START and *OUT_END to the chunk boundaries.
   Returns 0 on success, -1 if out of bounds.  O(log n).  */
int rope_contiguous_range(const Rope *rope, size_t offset,
                          size_t *out_start, size_t *out_end);

/* Count newlines in byte range [START, END).  O(log n).  */
size_t rope_newlines_in_range(const Rope *rope, size_t start, size_t end);

/* Find byte position immediately after the Nth newline (1-indexed) at or
   after START.  Returns rope_byte_len(rope) if not found.  O(log n).  */
size_t rope_find_nth_newline(const Rope *rope, size_t start, size_t n);

RopeCursor *rope_cursor_new(const Rope *rope);
void rope_cursor_free(RopeCursor *cursor);
void rope_cursor_seek_byte(RopeCursor *cursor, size_t offset);
void rope_cursor_seek_point(RopeCursor *cursor, RopePoint point);
TextSummary rope_cursor_start(const RopeCursor *cursor);

#ifdef __cplusplus
}
#endif

#endif

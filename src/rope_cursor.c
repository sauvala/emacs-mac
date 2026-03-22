#include <config.h>
#include "rope_internal.h"

#include <stdlib.h>

RopeCursor *rope_cursor_new(const Rope *rope) {
    RopeCursor *cursor = (RopeCursor *)calloc(1, sizeof(RopeCursor));
    if (!cursor) {
        return NULL;
    }
    cursor->rope = rope;
    cursor->byte_offset = 0;
    cursor->position = summary_zero();
    return cursor;
}

void rope_cursor_free(RopeCursor *cursor) {
    free(cursor);
}

void rope_cursor_seek_byte(RopeCursor *cursor, size_t offset) {
    if (!cursor || !cursor->rope || !cursor->rope->root) {
        return;
    }
    const size_t len = cursor->rope->root->summary.bytes;
    if (offset > len) {
        offset = len;
    }
    cursor->byte_offset = offset;
    cursor->position = summary_zero();
    cursor->position.bytes = offset;
    cursor->position.chars = node_byte_to_char(cursor->rope->root, offset);
    cursor->position.chars_utf16 = node_byte_to_utf16(cursor->rope->root, offset);
    cursor->position.lines = node_offset_to_point(cursor->rope->root, offset);
}

void rope_cursor_seek_point(RopeCursor *cursor, RopePoint point) {
    if (!cursor || !cursor->rope || !cursor->rope->root) {
        return;
    }
    const size_t off = node_point_to_offset(cursor->rope->root, point);
    rope_cursor_seek_byte(cursor, off);
}

TextSummary rope_cursor_start(const RopeCursor *cursor) {
    if (!cursor) {
        return summary_zero();
    }
    return cursor->position;
}

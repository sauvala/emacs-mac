#include <config.h>
#include "rope_internal.h"

#include <stdlib.h>
#include <string.h>

Rope *rope_new(void) {
    Rope *rope = (Rope *)calloc(1, sizeof(Rope));
    if (!rope) {
        return NULL;
    }
    rope->root = node_build_from_text(NULL, 0);
    if (!rope->root) {
        free(rope);
        return NULL;
    }
    return rope;
}

Rope *rope_from_str(const char *text, size_t len) {
    Rope *rope = (Rope *)calloc(1, sizeof(Rope));
    if (!rope) {
        return NULL;
    }
    if (text && len && !utf8_validate(text, len)) {
        free(rope);
        return NULL;
    }
    rope->root = node_build_from_text(text, len);
    if (!rope->root) {
        free(rope);
        return NULL;
    }
    return rope;
}

void rope_free(Rope *rope) {
    if (!rope) {
        return;
    }
    node_free(rope->root);
    free(rope);
}

size_t rope_byte_len(const Rope *rope) {
    return rope && rope->root ? rope->root->summary.bytes : 0;
}

size_t rope_char_len(const Rope *rope) {
    return rope && rope->root ? rope->root->summary.chars : 0;
}

uint32_t rope_line_count(const Rope *rope) {
    return rope && rope->root ? rope->root->summary.lines.row + 1 : 1;
}

size_t rope_longest_row(const Rope *rope) {
    return rope && rope->root ? rope->root->summary.longest_row : 0;
}

size_t rope_longest_row_chars(const Rope *rope) {
    return rope && rope->root ? rope->root->summary.longest_row_chars : 0;
}

TextSummary rope_summary(const Rope *rope) {
    return (rope && rope->root) ? rope->root->summary : summary_zero();
}

RopePoint rope_offset_to_point(const Rope *rope, size_t byte_offset) {
    if (!rope || !rope->root) {
        RopePoint p = {0, 0};
        return p;
    }
    return node_offset_to_point(rope->root, byte_offset);
}

size_t rope_point_to_offset(const Rope *rope, RopePoint point) {
    if (!rope || !rope->root) {
        return 0;
    }
    return node_point_to_offset(rope->root, point);
}

size_t rope_char_to_byte(const Rope *rope, size_t char_offset) {
    if (!rope || !rope->root) {
        return 0;
    }
    return node_char_to_byte(rope->root, char_offset);
}

size_t rope_byte_to_char(const Rope *rope, size_t byte_offset) {
    if (!rope || !rope->root) {
        return 0;
    }
    return node_byte_to_char(rope->root, byte_offset);
}

char *rope_to_str(const Rope *rope) {
    const size_t len = rope_byte_len(rope);
    char *out = (char *)calloc(len + 1, 1);
    if (!out) {
        return NULL;
    }
    if (len > 0) {
        node_copy_range(rope->root, 0, len, out, len);
    }
    out[len] = '\0';
    return out;
}

size_t rope_copy(const Rope *rope, size_t start, size_t end, char *buf, size_t buf_len) {
    if (!rope || !rope->root || !buf || buf_len == 0 || start >= end) {
        return 0;
    }
    const size_t copied = node_copy_range(rope->root, start, end, buf, buf_len);
    return copied;
}

RopeChunkIter rope_chunks(const Rope *rope, size_t start, size_t end) {
    const size_t len = rope_byte_len(rope);
    if (start > len) {
        start = len;
    }
    if (end > len) {
        end = len;
    }
    RopeChunkIter iter = {.rope = rope, .start = start, .end = end, .cursor = start};
    return iter;
}

bool rope_chunks_next(RopeChunkIter *iter, const char **text, size_t *len) {
    if (!iter || !iter->rope || !text || !len || iter->cursor >= iter->end) {
        return false;
    }

    const size_t chunk = ROPE_ITER_CHUNK_BYTES;
    const size_t rem = iter->end - iter->cursor;
    const size_t n = rem < chunk ? rem : chunk;
    const size_t copied = rope_copy(iter->rope, iter->cursor, iter->cursor + n, iter->buffer, n);
    if (copied == 0) {
        return false;
    }
    iter->cursor += copied;
    *text = iter->buffer;
    *len = copied;
    return true;
}

int rope_insert(Rope *rope, size_t offset, const char *text, size_t len) {
    if (!rope || !rope->root) {
        return -1;
    }
    if (!text || len == 0) {
        return 0;
    }
    if (!utf8_validate(text, len)) {
        return -1;
    }
    const size_t cur_len = rope->root->summary.bytes;
    if (offset > cur_len) {
        offset = cur_len;
    }

    /* Split at offset, build new tree from inserted text, concat */
    NodePair halves = node_split_at(rope->root, offset);
    Node *middle = node_build_from_text(text, len);
    if (!middle) {
        rope->root = node_concat(halves.left, halves.right);
        return -1;
    }
    rope->root = node_concat(node_concat(halves.left, middle), halves.right);
    return 0;
}

int rope_delete(Rope *rope, size_t start, size_t end) {
    if (!rope || !rope->root) {
        return -1;
    }
    const size_t cur_len = rope->root->summary.bytes;
    if (start > cur_len) {
        start = cur_len;
    }
    if (end > cur_len) {
        end = cur_len;
    }
    if (start > end) {
        return -1;
    }
    if (start == end) {
        return 0;
    }

    /* Split at start, split right at (end-start), discard middle, concat */
    NodePair first = node_split_at(rope->root, start);
    NodePair second = node_split_at(first.right, end - start);
    node_free(second.left); /* discard deleted range */
    rope->root = node_concat(first.left, second.right);
    return 0;
}

int rope_replace(Rope *rope, size_t start, size_t end, const char *text, size_t len) {
    if (!rope || !rope->root) {
        return -1;
    }
    const size_t cur_len = rope->root->summary.bytes;
    if (start > cur_len) {
        start = cur_len;
    }
    if (end > cur_len) {
        end = cur_len;
    }
    if (start > end) {
        return -1;
    }
    if (text && len > 0 && !utf8_validate(text, len)) {
        return -1;
    }

    /* Split at start, split right at (end-start), discard middle,
     * build new tree from replacement text, concat all three */
    NodePair first = node_split_at(rope->root, start);
    NodePair second = node_split_at(first.right, end - start);
    node_free(second.left);

    if (text && len > 0) {
        Node *middle = node_build_from_text(text, len);
        if (!middle) {
            rope->root = node_concat(first.left, second.right);
            return -1;
        }
        rope->root = node_concat(node_concat(first.left, middle), second.right);
    } else {
        rope->root = node_concat(first.left, second.right);
    }
    return 0;
}

/* ===== Contiguous access and line-counting functions ===== */

const char *rope_get_contiguous(const Rope *rope, size_t offset, size_t *out_len) {
    if (!rope || !rope->root) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    if (offset >= rope->root->summary.bytes) {
        if (out_len) *out_len = 0;
        return NULL;
    }

    const Node *node = rope->root;
    size_t remaining = offset;

    /* Descend through internal nodes. */
    while (node->height > 0) {
        bool found = false;
        for (uint8_t i = 0; i < node->count; ++i) {
            size_t child_bytes = node->as.internal.child_summaries[i].bytes;
            if (remaining < child_bytes) {
                node = node->as.internal.children[i];
                found = true;
                break;
            }
            remaining -= child_bytes;
        }
        if (!found) {
            if (out_len) *out_len = 0;
            return NULL;
        }
    }

    /* At leaf level, find the chunk. */
    for (uint8_t i = 0; i < node->count; ++i) {
        const Chunk *chunk = &node->as.leaf.items[i];
        if (remaining < chunk->len) {
            if (out_len) *out_len = chunk->len - remaining;
            return &chunk->text[remaining];
        }
        remaining -= chunk->len;
    }

    if (out_len) *out_len = 0;
    return NULL;
}

int rope_byte_at(const Rope *rope, size_t offset) {
    size_t len;
    const char *p = rope_get_contiguous(rope, offset, &len);
    if (!p || len == 0)
        return -1;
    return (unsigned char)*p;
}

int rope_contiguous_range(const Rope *rope, size_t offset,
                          size_t *out_start, size_t *out_end) {
    if (!rope || !rope->root || offset >= rope->root->summary.bytes)
        return -1;

    const Node *node = rope->root;
    size_t base = 0;  /* Byte offset of the current node's start. */
    size_t remaining = offset;

    while (node->height > 0) {
        bool found = false;
        for (uint8_t i = 0; i < node->count; ++i) {
            size_t child_bytes = node->as.internal.child_summaries[i].bytes;
            if (remaining < child_bytes) {
                node = node->as.internal.children[i];
                found = true;
                break;
            }
            base += child_bytes;
            remaining -= child_bytes;
        }
        if (!found)
            return -1;
    }

    /* At leaf level, find the chunk. */
    for (uint8_t i = 0; i < node->count; ++i) {
        const Chunk *chunk = &node->as.leaf.items[i];
        if (remaining < chunk->len) {
            if (out_start) *out_start = base;
            if (out_end) *out_end = base + chunk->len;
            return 0;
        }
        base += chunk->len;
        remaining -= chunk->len;
    }
    return -1;
}

/* Count newlines in [0, offset) within a subtree.  O(log n). */
static size_t node_newlines_before(const Node *node, size_t offset) {
    if (!node || offset == 0)
        return 0;
    if (offset >= node->summary.bytes)
        return node->summary.lines.row;

    if (node->height == 0) {
        size_t consumed = 0;
        size_t newlines = 0;
        for (uint8_t i = 0; i < node->count; ++i) {
            const Chunk *chunk = &node->as.leaf.items[i];
            if (offset >= consumed + chunk->len) {
                newlines += node->as.leaf.item_summaries[i].lines.row;
                consumed += chunk->len;
                continue;
            }
            /* Partial chunk: count newlines up to local offset. */
            ChunkPoint cp = chunk_offset_to_point(chunk, offset - consumed);
            newlines += cp.row;
            break;
        }
        return newlines;
    }

    size_t consumed = 0;
    size_t newlines = 0;
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary *cs = &node->as.internal.child_summaries[i];
        if (offset >= consumed + cs->bytes) {
            newlines += cs->lines.row;
            consumed += cs->bytes;
            continue;
        }
        newlines += node_newlines_before(node->as.internal.children[i],
                                         offset - consumed);
        break;
    }
    return newlines;
}

size_t rope_newlines_in_range(const Rope *rope, size_t start, size_t end) {
    if (!rope || !rope->root || start >= end)
        return 0;
    size_t nl_end = node_newlines_before(rope->root, end);
    size_t nl_start = node_newlines_before(rope->root, start);
    return nl_end - nl_start;
}

/* Find the byte position immediately after the Nth newline (1-indexed)
   within a subtree.  Returns the subtree's total bytes if not found. */
static size_t node_find_nth_newline_pos(const Node *node, size_t n) {
    if (!node || n == 0)
        return 0;
    if (n > node->summary.lines.row)
        return node->summary.bytes;

    if (node->height == 0) {
        size_t consumed = 0;
        size_t nl_seen = 0;
        for (uint8_t i = 0; i < node->count; ++i) {
            const Chunk *chunk = &node->as.leaf.items[i];
            size_t chunk_nls = node->as.leaf.item_summaries[i].lines.row;
            if (nl_seen + chunk_nls >= n) {
                /* The target newline is in this chunk. */
                size_t target = n - nl_seen;
                size_t local_nl = 0;
                for (size_t j = 0; j < chunk->len; ++j) {
                    if (chunk->text[j] == '\n') {
                        ++local_nl;
                        if (local_nl == target)
                            return consumed + j + 1;
                    }
                }
                return consumed + chunk->len;
            }
            nl_seen += chunk_nls;
            consumed += chunk->len;
        }
        return consumed;
    }

    size_t consumed = 0;
    size_t nl_seen = 0;
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary *cs = &node->as.internal.child_summaries[i];
        if (nl_seen + cs->lines.row >= n) {
            return consumed +
                   node_find_nth_newline_pos(node->as.internal.children[i],
                                             n - nl_seen);
        }
        nl_seen += cs->lines.row;
        consumed += cs->bytes;
    }
    return consumed;
}

size_t rope_find_nth_newline(const Rope *rope, size_t start, size_t n) {
    if (!rope || !rope->root || n == 0)
        return start;

    size_t total_bytes = rope->root->summary.bytes;
    if (start >= total_bytes)
        return total_bytes;

    /* Count newlines before start, then find the (skip+n)th overall. */
    size_t skip = node_newlines_before(rope->root, start);
    size_t target = skip + n;

    if (target > rope->root->summary.lines.row)
        return total_bytes;

    return node_find_nth_newline_pos(rope->root, target);
}

void rope_append(Rope *rope, Rope *other) {
    if (!rope || !other || !other->root || other->root->summary.bytes == 0) {
        return;
    }
    /* Build a fresh copy of other's text to avoid ownership issues */
    char *text = rope_to_str(other);
    if (!text) {
        return;
    }
    const size_t len = other->root->summary.bytes;
    (void)rope_insert(rope, rope_byte_len(rope), text, len);
    free(text);
}

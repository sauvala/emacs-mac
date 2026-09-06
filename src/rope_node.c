#include <config.h>
#include "rope_internal.h"

#include <stdlib.h>
#include <string.h>

Node *node_new_leaf(void) {
    Node *node = (Node *)calloc(1, sizeof(Node));
    if (!node) {
        return NULL;
    }
    node->height = 0;
    node->count = 0;
    node->summary = summary_zero();
    return node;
}

Node *node_new_internal(uint8_t height) {
    Node *node = (Node *)calloc(1, sizeof(Node));
    if (!node) {
        return NULL;
    }
    node->height = height;
    node->count = 0;
    node->summary = summary_zero();
    return node;
}

void node_free(Node *node) {
    if (!node) {
        return;
    }
    if (node->height > 0) {
        for (uint8_t i = 0; i < node->count; ++i) {
            node_free(node->as.internal.children[i]);
        }
    }
    free(node);
}

TextSummary node_summary(const Node *node) {
    if (!node) {
        return summary_zero();
    }
    return node->summary;
}

size_t node_height(const Node *node) {
    return node ? node->height : 0;
}

void node_refresh_summary(Node *node) {
    if (!node) {
        return;
    }
    TextSummary sum = summary_zero();
    if (node->height == 0) {
        for (uint8_t i = 0; i < node->count; ++i) {
            sum = summary_add(sum, node->as.leaf.item_summaries[i]);
        }
    } else {
        for (uint8_t i = 0; i < node->count; ++i) {
            node->as.internal.child_summaries[i] = node_summary(node->as.internal.children[i]);
            sum = summary_add(sum, node->as.internal.child_summaries[i]);
        }
    }
    node->summary = sum;
}

/*
 * Compute the largest prefix of text[0..max_len) that does not split a
 * multi-byte UTF-8 character.  Returns a value <= max_len that sits on
 * a character boundary.
 */
static size_t utf8_safe_split(const char *text, size_t len, size_t max_len) {
    if (max_len >= len) {
        return len;
    }
    /* Walk backwards from max_len to find a char boundary */
    size_t pos = max_len;
    while (pos > 0 && !utf8_is_char_boundary((unsigned char)text[pos])) {
        --pos;
    }
    return pos;
}

static size_t fill_chunks(const char *text, size_t len, Chunk **out_chunks, TextSummary **out_summaries) {
    if (len == 0) {
        *out_chunks = NULL;
        *out_summaries = NULL;
        return 0;
    }

    /* First pass: count chunks needed (respecting UTF-8 boundaries) */
    size_t count = 0;
    {
        size_t pos = 0;
        while (pos < len) {
            const size_t chunk_len = utf8_safe_split(text + pos, len - pos, CHUNK_SIZE);
            if (chunk_len == 0) {
                break; /* safety: should not happen with valid UTF-8 */
            }
            ++count;
            pos += chunk_len;
        }
    }

    if (count == 0) {
        *out_chunks = NULL;
        *out_summaries = NULL;
        return 0;
    }

    Chunk *chunks = (Chunk *)calloc(count, sizeof(Chunk));
    TextSummary *summaries = (TextSummary *)calloc(count, sizeof(TextSummary));
    if (!chunks || !summaries) {
        free(chunks);
        free(summaries);
        *out_chunks = NULL;
        *out_summaries = NULL;
        return 0;
    }

    /* Second pass: build chunks at UTF-8-safe boundaries.
     * row_base=0: each chunk summary uses local row indices;
     * summary_add offsets longest_row by left.lines.row when combining. */
    size_t pos = 0;
    for (size_t i = 0; i < count; ++i) {
        const size_t chunk_len = utf8_safe_split(text + pos, len - pos, CHUNK_SIZE);
        chunks[i] = chunk_from_text(text + pos, chunk_len);
        summaries[i] = chunk_summary(&chunks[i], 0);
        pos += chunk_len;
    }

    *out_chunks = chunks;
    *out_summaries = summaries;
    return count;
}

static Node **build_leaf_level(Chunk *chunks, TextSummary *summaries, size_t chunks_len, size_t *out_count) {
    const size_t leaf_count = (chunks_len + MAX_CHILDREN - 1) / MAX_CHILDREN;
    Node **level = (Node **)calloc(leaf_count, sizeof(Node *));
    if (!level) {
        return NULL;
    }

    size_t chunk_ix = 0;
    for (size_t i = 0; i < leaf_count; ++i) {
        Node *leaf = node_new_leaf();
        if (!leaf) {
            for (size_t j = 0; j < i; ++j) {
                node_free(level[j]);
            }
            free(level);
            return NULL;
        }

        /* Distribute the remainder instead of leaving an underfull last leaf.  */
        size_t count = chunks_len / leaf_count + (i < chunks_len % leaf_count);
        while (leaf->count < count) {
            const uint8_t slot = leaf->count++;
            leaf->as.leaf.items[slot] = chunks[chunk_ix];
            leaf->as.leaf.item_summaries[slot] = summaries[chunk_ix];
            chunk_ix += 1;
        }
        node_refresh_summary(leaf);
        level[i] = leaf;
    }

    *out_count = leaf_count;
    return level;
}

/*
 * Build the next level of internal nodes from a list of children.
 * On success, all children in the array are adopted by the new parents.
 * On failure, ALL children (consumed and unconsumed) are freed before
 * returning NULL so the caller does not need to clean up.
 */
static Node **build_next_level(Node **children, size_t children_len, size_t *out_len, uint8_t height) {
    const size_t parents_len = (children_len + MAX_CHILDREN - 1) / MAX_CHILDREN;
    Node **parents = (Node **)calloc(parents_len, sizeof(Node *));
    if (!parents) {
        /* Free all children since caller will not be able to */
        for (size_t k = 0; k < children_len; ++k) {
            node_free(children[k]);
        }
        return NULL;
    }

    size_t child_ix = 0;
    for (size_t i = 0; i < parents_len; ++i) {
        Node *parent = node_new_internal(height);
        if (!parent) {
            /* Free already-built parents (which recursively frees their children) */
            for (size_t j = 0; j < i; ++j) {
                node_free(parents[j]);
            }
            /* Free remaining unconsumed children */
            for (size_t k = child_ix; k < children_len; ++k) {
                node_free(children[k]);
            }
            free(parents);
            return NULL;
        }

        size_t count = children_len / parents_len + (i < children_len % parents_len);
        while (parent->count < count) {
            const uint8_t slot = parent->count++;
            parent->as.internal.children[slot] = children[child_ix];
            parent->as.internal.child_summaries[slot] = node_summary(children[child_ix]);
            child_ix += 1;
        }
        node_refresh_summary(parent);
        parents[i] = parent;
    }

    *out_len = parents_len;
    return parents;
}

Node *node_build_from_text(const char *text, size_t len) {
    Node *empty = node_new_leaf();
    if (!text || len == 0) {
        return empty;
    }

    Chunk *chunks = NULL;
    TextSummary *summaries = NULL;
    const size_t chunks_len = fill_chunks(text, len, &chunks, &summaries);
    if (chunks_len == 0 || !chunks || !summaries) {
        node_free(empty);
        return NULL;
    }
    node_free(empty);

    size_t level_len = 0;
    Node **level = build_leaf_level(chunks, summaries, chunks_len, &level_len);
    free(chunks);
    free(summaries);
    if (!level) {
        return NULL;
    }

    uint8_t height = 1;
    while (level_len > 1) {
        size_t next_len = 0;
        /*
         * build_next_level takes ownership of children in level[]:
         * on success it adopts them all into parents; on failure it
         * frees everything (consumed and unconsumed children).
         * Either way, the caller must only free the level pointer array.
         */
        Node **next = build_next_level(level, level_len, &next_len, height);
        free(level); /* free the pointer array only */
        if (!next) {
            return NULL; /* children already freed by build_next_level */
        }
        level = next;
        level_len = next_len;
        height += 1;
    }

    Node *root = level[0];
    free(level);
    return root;
}

static size_t node_copy_range_recursive(const Node *node, size_t start, size_t end, char *buf, size_t cap, size_t wrote) {
    if (!node || start >= end || wrote >= cap) {
        return wrote;
    }

    if (node->height == 0) {
        size_t offset = 0;
        for (uint8_t i = 0; i < node->count; ++i) {
            const Chunk *chunk = &node->as.leaf.items[i];
            const size_t chunk_start = offset;
            const size_t chunk_end = offset + chunk->len;
            offset = chunk_end;
            if (end <= chunk_start || start >= chunk_end) {
                continue;
            }

            size_t local_start = start > chunk_start ? start - chunk_start : 0;
            size_t local_end = end < chunk_end ? end - chunk_start : chunk->len;
            if (local_end > chunk->len) {
                local_end = chunk->len;
            }
            if (local_start > local_end) {
                continue;
            }

            const size_t to_copy = local_end - local_start;
            const size_t rem = cap - wrote;
            const size_t n = to_copy < rem ? to_copy : rem;
            memcpy(buf + wrote, chunk->text + local_start, n);
            wrote += n;
            if (n < to_copy) {
                break;
            }
        }
        return wrote;
    }

    size_t offset = 0;
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary child_summary = node->as.internal.child_summaries[i];
        const size_t child_start = offset;
        const size_t child_end = offset + child_summary.bytes;
        offset = child_end;
        if (end <= child_start || start >= child_end) {
            continue;
        }
        const size_t sub_start = start > child_start ? start - child_start : 0;
        const size_t sub_end = end < child_end ? end - child_start : child_summary.bytes;
        wrote = node_copy_range_recursive(node->as.internal.children[i], sub_start, sub_end, buf, cap, wrote);
        if (wrote >= cap) {
            break;
        }
    }
    return wrote;
}

size_t node_copy_range(const Node *node, size_t start, size_t end, char *buf, size_t cap) {
    if (!node || !buf || cap == 0 || start >= end) {
        return 0;
    }
    const size_t len = node->summary.bytes;
    if (start > len) {
        start = len;
    }
    if (end > len) {
        end = len;
    }
    return node_copy_range_recursive(node, start, end, buf, cap, 0);
}

RopePoint node_offset_to_point(const Node *node, size_t offset) {
    RopePoint out = {0, 0};
    if (!node) {
        return out;
    }

    if (offset >= node->summary.bytes) {
        return node->summary.lines;
    }

    if (node->height == 0) {
        size_t consumed = 0;
        TextSummary acc = summary_zero();
        for (uint8_t i = 0; i < node->count; ++i) {
            const Chunk *chunk = &node->as.leaf.items[i];
            if (offset >= consumed + chunk->len) {
                const TextSummary ss = node->as.leaf.item_summaries[i];
                acc = summary_add(acc, ss);
                out = acc.lines;
                consumed += chunk->len;
                continue;
            }

            const ChunkPoint cp = chunk_offset_to_point(chunk, offset - consumed);
            out.row += (uint32_t)cp.row;
            if (cp.row == 0) {
                out.col += (uint32_t)cp.col;
            } else {
                out.col = (uint32_t)cp.col;
            }
            break;
        }
        return out;
    }

    size_t consumed = 0;
    TextSummary acc = summary_zero();
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary child = node->as.internal.child_summaries[i];
        if (offset >= consumed + child.bytes) {
            acc = summary_add(acc, child);
            consumed += child.bytes;
            continue;
        }

        RopePoint inner = node_offset_to_point(node->as.internal.children[i], offset - consumed);
        out = acc.lines;
        out.row += inner.row;
        if (inner.row == 0) {
            out.col += inner.col;
        } else {
            out.col = inner.col;
        }
        return out;
    }

    return node->summary.lines;
}

size_t node_point_to_offset(const Node *node, RopePoint point) {
    if (!node) {
        return 0;
    }
    if (point.row >= node->summary.lines.row) {
        if (point.row > node->summary.lines.row) {
            return node->summary.bytes;
        }
        if (point.col >= node->summary.lines.col) {
            return node->summary.bytes;
        }
    }

    if (node->height == 0) {
        size_t offset = 0;
        RopePoint current = {0, 0};
        for (uint8_t i = 0; i < node->count; ++i) {
            const TextSummary ss = node->as.leaf.item_summaries[i];
            RopePoint next;
            next.row = current.row + ss.lines.row;
            if (ss.lines.row == 0) {
                next.col = current.col + ss.lines.col;
            } else {
                next.col = ss.lines.col;
            }
            if (point.row < next.row || (point.row == next.row && point.col <= next.col)) {
                const size_t local_row = point.row - current.row;
                const size_t local_col = local_row == 0 ? point.col - current.col : point.col;
                ChunkOffsetResult cr = chunk_point_to_offset(&node->as.leaf.items[i], local_row, local_col);
                return offset + cr.byte_offset;
            }
            current = next;
            offset += node->as.leaf.items[i].len;
        }
        return offset;
    }

    size_t offset = 0;
    RopePoint current = {0, 0};
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary child = node->as.internal.child_summaries[i];
        RopePoint next;
        next.row = current.row + child.lines.row;
        if (child.lines.row == 0) {
            next.col = current.col + child.lines.col;
        } else {
            next.col = child.lines.col;
        }

        if (point.row < next.row || (point.row == next.row && point.col <= next.col)) {
            RopePoint local;
            local.row = point.row - current.row;
            local.col = (local.row == 0) ? (point.col - current.col) : point.col;
            return offset + node_point_to_offset(node->as.internal.children[i], local);
        }

        current = next;
        offset += child.bytes;
    }
    return node->summary.bytes;
}

size_t node_char_to_byte(const Node *node, size_t char_offset) {
    if (!node) {
        return 0;
    }
    if (char_offset >= node->summary.chars) {
        return node->summary.bytes;
    }

    if (node->height == 0) {
        size_t chars = 0;
        size_t bytes = 0;
        for (uint8_t i = 0; i < node->count; ++i) {
            const TextSummary ss = node->as.leaf.item_summaries[i];
            if (char_offset >= chars + ss.chars) {
                chars += ss.chars;
                bytes += ss.bytes;
                continue;
            }
            return bytes + chunk_char_to_byte(&node->as.leaf.items[i], char_offset - chars);
        }
        return bytes;
    }

    size_t chars = 0;
    size_t bytes = 0;
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary child = node->as.internal.child_summaries[i];
        if (char_offset >= chars + child.chars) {
            chars += child.chars;
            bytes += child.bytes;
            continue;
        }
        return bytes + node_char_to_byte(node->as.internal.children[i], char_offset - chars);
    }
    return node->summary.bytes;
}

size_t node_byte_to_char(const Node *node, size_t byte_offset) {
    if (!node) {
        return 0;
    }
    if (byte_offset >= node->summary.bytes) {
        return node->summary.chars;
    }

    if (node->height == 0) {
        size_t chars = 0;
        size_t bytes = 0;
        for (uint8_t i = 0; i < node->count; ++i) {
            const TextSummary ss = node->as.leaf.item_summaries[i];
            if (byte_offset >= bytes + ss.bytes) {
                chars += ss.chars;
                bytes += ss.bytes;
                continue;
            }
            return chars + chunk_byte_to_char(&node->as.leaf.items[i], byte_offset - bytes);
        }
        return chars;
    }

    size_t chars = 0;
    size_t bytes = 0;
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary child = node->as.internal.child_summaries[i];
        if (byte_offset >= bytes + child.bytes) {
            chars += child.chars;
            bytes += child.bytes;
            continue;
        }
        return chars + node_byte_to_char(node->as.internal.children[i], byte_offset - bytes);
    }
    return node->summary.chars;
}

size_t node_byte_to_utf16(const Node *node, size_t byte_offset) {
    if (!node) {
        return 0;
    }
    if (byte_offset >= node->summary.bytes) {
        return node->summary.chars_utf16;
    }

    if (node->height == 0) {
        size_t utf16 = 0;
        size_t bytes = 0;
        for (uint8_t i = 0; i < node->count; ++i) {
            const TextSummary ss = node->as.leaf.item_summaries[i];
            if (byte_offset >= bytes + ss.bytes) {
                utf16 += ss.chars_utf16;
                bytes += ss.bytes;
                continue;
            }
            return utf16 + chunk_byte_to_utf16(&node->as.leaf.items[i], byte_offset - bytes);
        }
        return utf16;
    }

    size_t utf16 = 0;
    size_t bytes = 0;
    for (uint8_t i = 0; i < node->count; ++i) {
        const TextSummary child = node->as.internal.child_summaries[i];
        if (byte_offset >= bytes + child.bytes) {
            utf16 += child.chars_utf16;
            bytes += child.bytes;
            continue;
        }
        return utf16 + node_byte_to_utf16(node->as.internal.children[i], byte_offset - bytes);
    }
    return node->summary.chars_utf16;
}

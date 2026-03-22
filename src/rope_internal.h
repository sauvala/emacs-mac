#ifndef SUMTREE_ROPE_INTERNAL_H
#define SUMTREE_ROPE_INTERNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "rope.h"  /* Public API — same directory after copy. */

#define CHUNK_SIZE 128
#define TREE_BASE 4
#define MAX_CHILDREN (2 * TREE_BASE)
#define MIN_CHILDREN TREE_BASE

typedef unsigned __int128 rope_u128;

typedef struct Chunk {
    char text[CHUNK_SIZE];
    uint8_t len;
    rope_u128 newlines;
    rope_u128 chars;
    rope_u128 tabs;
} Chunk;

typedef struct Node {
    uint8_t height;
    uint8_t count;
    TextSummary summary;
    union {
        struct {
            struct Node *children[MAX_CHILDREN];
            TextSummary child_summaries[MAX_CHILDREN];
        } internal;
        struct {
            Chunk items[MAX_CHILDREN];
            TextSummary item_summaries[MAX_CHILDREN];
        } leaf;
    } as;
} Node;

struct Rope {
    Node *root;
};

struct RopeCursor {
    const Rope *rope;
    size_t byte_offset;
    TextSummary position;
};

typedef struct ChunkPoint {
    size_t row;
    size_t col;
} ChunkPoint;

typedef struct ChunkOffsetResult {
    size_t byte_offset;
    bool clamped;
} ChunkOffsetResult;

/* rope_summary.c */
TextSummary summary_zero(void);
TextSummary summary_from_bytes(const char *text, size_t len, size_t row_base);
TextSummary summary_add(TextSummary left, TextSummary right);

/* rope_utf8.c */
bool utf8_validate(const char *text, size_t len);
size_t utf8_count_chars(const char *text, size_t len);
size_t utf8_count_utf16(const char *text, size_t len);
bool utf8_is_char_boundary(unsigned char byte);
size_t utf8_next_len(unsigned char first_byte);

/* rope_chunk.c */
Chunk chunk_from_text(const char *text, size_t len);
TextSummary chunk_summary(const Chunk *chunk, size_t row_base);
ChunkPoint chunk_offset_to_point(const Chunk *chunk, size_t offset);
ChunkOffsetResult chunk_point_to_offset(const Chunk *chunk, size_t row, size_t col);
size_t chunk_char_to_byte(const Chunk *chunk, size_t char_offset);
size_t chunk_byte_to_char(const Chunk *chunk, size_t byte_offset);
size_t chunk_byte_to_utf16(const Chunk *chunk, size_t byte_offset);

typedef struct NodePair {
    Node *left;
    Node *right;
} NodePair;

/* rope_node.c — tree construction, queries, summary management */
Node *node_new_leaf(void);
Node *node_new_internal(uint8_t height);
void node_free(Node *node);
void node_refresh_summary(Node *node);
Node *node_build_from_text(const char *text, size_t len);
size_t node_copy_range(const Node *node, size_t start, size_t end, char *buf, size_t cap);
TextSummary node_summary(const Node *node);
size_t node_height(const Node *node);

RopePoint node_offset_to_point(const Node *node, size_t offset);
size_t node_point_to_offset(const Node *node, RopePoint point);
size_t node_char_to_byte(const Node *node, size_t char_offset);
size_t node_byte_to_char(const Node *node, size_t byte_offset);
size_t node_byte_to_utf16(const Node *node, size_t byte_offset);

/* rope_node_edit.c — split/concat/rebalancing */
NodePair node_split_at(Node *node, size_t offset);
Node *node_concat(Node *left, Node *right);

#endif

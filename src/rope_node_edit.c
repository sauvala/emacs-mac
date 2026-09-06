#include <config.h>
#include "rope_internal.h"

#include <stdlib.h>
#include <string.h>

/* ===== Split & Concat for O(log n) edits ===== */

static bool node_is_empty(const Node *n) {
    return !n || (n->count == 0 && n->summary.bytes == 0);
}

/*
 * Split a leaf node at the given byte offset.
 * Consumes (frees) the original node.
 */
static NodePair split_leaf(Node *leaf, size_t offset) {
    Node *left = node_new_leaf();
    Node *right = node_new_leaf();
    if (!left || !right) {
        node_free(left);
        node_free(right);
        node_free(leaf);
        return (NodePair){node_new_leaf(), node_new_leaf()};
    }

    size_t consumed = 0;
    for (uint8_t i = 0; i < leaf->count; ++i) {
        const Chunk *chunk = &leaf->as.leaf.items[i];
        const size_t chunk_end = consumed + chunk->len;

        if (chunk_end <= offset) {
            /* entire chunk goes left */
            uint8_t slot = left->count++;
            left->as.leaf.items[slot] = *chunk;
            left->as.leaf.item_summaries[slot] = leaf->as.leaf.item_summaries[i];
        } else if (consumed >= offset) {
            /* entire chunk goes right */
            uint8_t slot = right->count++;
            right->as.leaf.items[slot] = *chunk;
            right->as.leaf.item_summaries[slot] = chunk_summary(chunk, 0);
        } else {
            /* split this chunk at the local offset */
            size_t local = offset - consumed;
            if (local > 0) {
                Chunk lc = chunk_from_text(chunk->text, local);
                uint8_t slot = left->count++;
                left->as.leaf.items[slot] = lc;
                left->as.leaf.item_summaries[slot] = chunk_summary(&lc, 0);
            }
            if (local < chunk->len) {
                Chunk rc = chunk_from_text(chunk->text + local, chunk->len - local);
                uint8_t slot = right->count++;
                right->as.leaf.items[slot] = rc;
                right->as.leaf.item_summaries[slot] = chunk_summary(&rc, 0);
            }
        }
        consumed = chunk_end;
    }

    node_refresh_summary(left);
    node_refresh_summary(right);
    free(leaf); /* leaf owns no heap children */
    return (NodePair){left, right};
}

/*
 * Split an internal node at the given byte offset.
 * Consumes (frees) the original node shell; children are distributed.
 */
static NodePair split_internal(Node *node, size_t offset) {
    /* Find which child contains the split point */
    size_t consumed = 0;
    uint8_t split_idx = 0;
    for (uint8_t i = 0; i < node->count; ++i) {
        const size_t cb = node->as.internal.child_summaries[i].bytes;
        if (consumed + cb > offset) {
            split_idx = i;
            break;
        }
        consumed += cb;
        if (i == node->count - 1) {
            split_idx = i;
        }
    }

    size_t local_offset = offset - consumed;
    NodePair child_pair = node_split_at(node->as.internal.children[split_idx], local_offset);

    /* Join the surviving subtrees rather than retaining the old height.
       A split can leave only one child at several levels.  Keeping those
       shells lets repeated edits grow the tree independently of its size.  */
    Node *left = child_pair.left;
    for (int i = split_idx - 1; i >= 0; --i)
        left = node_concat(node->as.internal.children[i], left);
    Node *right = child_pair.right;
    for (int i = split_idx + 1; i < node->count; ++i)
        right = node_concat(right, node->as.internal.children[i]);

    node->count = 0;
    free(node);
    return (NodePair){left, right};
}

NodePair node_split_at(Node *node, size_t offset) {
    if (!node) {
        return (NodePair){node_new_leaf(), node_new_leaf()};
    }
    if (offset == 0) {
        return (NodePair){node_new_leaf(), node};
    }
    if (offset >= node->summary.bytes) {
        return (NodePair){node, node_new_leaf()};
    }
    if (node->height == 0) {
        return split_leaf(node, offset);
    }
    return split_internal(node, offset);
}

/*
 * Merge two nodes of the same height into one node if they fit,
 * or wrap them in a new parent of height+1.
 */
static Node *merge_same_height(Node *left, Node *right) {
    const uint8_t h = left->height;
    const uint8_t total = left->count + right->count;

    if (h == 0 && total <= MAX_CHILDREN) {
        /* Merge leaf items into left */
        for (uint8_t i = 0; i < right->count; ++i) {
            left->as.leaf.items[left->count] = right->as.leaf.items[i];
            left->as.leaf.item_summaries[left->count] = right->as.leaf.item_summaries[i];
            left->count++;
        }
        node_refresh_summary(left);
        free(right); /* leaf, no children to free */
        return left;
    }

    if (h > 0 && total <= MAX_CHILDREN) {
        /* Merge internal children into left */
        for (uint8_t i = 0; i < right->count; ++i) {
            left->as.internal.children[left->count] = right->as.internal.children[i];
            left->as.internal.child_summaries[left->count] = right->as.internal.child_summaries[i];
            left->count++;
        }
        node_refresh_summary(left);
        right->count = 0; /* children transferred */
        node_free(right);
        return left;
    }

    /* Redistribute before making these roots into children.  Either root
       may have fewer than MIN_CHILDREN entries after a split.  */
    const uint8_t mid = total / 2;
    if (h == 0) {
        Chunk items[2 * MAX_CHILDREN];
        memcpy(items, left->as.leaf.items, left->count * sizeof *items);
        memcpy(items + left->count, right->as.leaf.items,
               right->count * sizeof *items);
        memcpy(left->as.leaf.items, items, mid * sizeof *items);
        memcpy(right->as.leaf.items, items + mid, (total - mid) * sizeof *items);
        left->count = mid;
        right->count = total - mid;
        for (int i = 0; i < left->count; ++i)
            left->as.leaf.item_summaries[i] = chunk_summary(&left->as.leaf.items[i], 0);
        for (int i = 0; i < right->count; ++i)
            right->as.leaf.item_summaries[i] = chunk_summary(&right->as.leaf.items[i], 0);
    } else {
        Node *children[2 * MAX_CHILDREN];
        memcpy(children, left->as.internal.children, left->count * sizeof *children);
        memcpy(children + left->count, right->as.internal.children,
               right->count * sizeof *children);
        memcpy(left->as.internal.children, children, mid * sizeof *children);
        memcpy(right->as.internal.children, children + mid,
               (total - mid) * sizeof *children);
        left->count = mid;
        right->count = total - mid;
    }
    node_refresh_summary(left);
    node_refresh_summary(right);

    /* Can't merge, wrap in a new parent */
    Node *parent = node_new_internal(h + 1);
    if (!parent) {
        node_free(right);
        return left;
    }
    parent->as.internal.children[0] = left;
    parent->as.internal.children[1] = right;
    parent->count = 2;
    node_refresh_summary(parent);
    return parent;
}

/*
 * Graft `short_node` onto the right edge of `tall`.
 * tall->height > short_node->height. Consumes both.
 */
static Node *concat_graft_right(Node *tall, Node *short_node) {
    /* Recurse into rightmost child */
    uint8_t last = tall->count - 1;
    uint8_t orig_height = tall->as.internal.children[last]->height;
    Node *merged = node_concat(tall->as.internal.children[last], short_node);

    if (merged->height == orig_height) {
        /* Same height, just replace */
        tall->as.internal.children[last] = merged;
        node_refresh_summary(tall);
        return tall;
    }

    /* merged grew by 1 level: it has 2 children we need to absorb */
    tall->as.internal.children[last] = merged->as.internal.children[0];

    Node *extra = merged->as.internal.children[1];
    merged->count = 0;
    node_free(merged);

    if (tall->count < MAX_CHILDREN) {
        tall->as.internal.children[tall->count] = extra;
        tall->count++;
        node_refresh_summary(tall);
        return tall;
    }

    /* Overflow: split tall */
    Node *sibling = node_new_internal(tall->height);
    if (!sibling) {
        node_free(extra);
        return tall;
    }
    uint8_t mid = tall->count / 2;
    for (uint8_t i = mid; i < tall->count; ++i) {
        sibling->as.internal.children[sibling->count] = tall->as.internal.children[i];
        sibling->count++;
    }
    sibling->as.internal.children[sibling->count] = extra;
    sibling->count++;
    tall->count = mid;
    node_refresh_summary(tall);
    node_refresh_summary(sibling);

    Node *parent = node_new_internal(tall->height + 1);
    if (!parent) {
        node_free(sibling);
        return tall;
    }
    parent->as.internal.children[0] = tall;
    parent->as.internal.children[1] = sibling;
    parent->count = 2;
    node_refresh_summary(parent);
    return parent;
}

/*
 * Graft `short_node` onto the left edge of `tall`.
 * Mirror of concat_graft_right.
 */
static Node *concat_graft_left(Node *tall, Node *short_node) {
    /* Recurse into leftmost child */
    uint8_t orig_height = tall->as.internal.children[0]->height;
    Node *merged = node_concat(short_node, tall->as.internal.children[0]);

    if (merged->height == orig_height) {
        tall->as.internal.children[0] = merged;
        node_refresh_summary(tall);
        return tall;
    }

    /* merged grew: absorb its 2 children */
    tall->as.internal.children[0] = merged->as.internal.children[1];
    Node *extra = merged->as.internal.children[0];
    merged->count = 0;
    node_free(merged);

    if (tall->count < MAX_CHILDREN) {
        for (uint8_t i = tall->count; i > 0; --i) {
            tall->as.internal.children[i] = tall->as.internal.children[i - 1];
        }
        tall->as.internal.children[0] = extra;
        tall->count++;
        node_refresh_summary(tall);
        return tall;
    }

    Node *sibling = node_new_internal(tall->height);
    if (!sibling) {
        node_free(extra);
        return tall;
    }
    sibling->as.internal.children[0] = extra;
    sibling->count = 1;
    uint8_t mid = tall->count / 2;
    for (uint8_t i = 0; i < mid; ++i) {
        sibling->as.internal.children[sibling->count] = tall->as.internal.children[i];
        sibling->count++;
    }
    uint8_t new_count = tall->count - mid;
    for (uint8_t i = 0; i < new_count; ++i) {
        tall->as.internal.children[i] = tall->as.internal.children[mid + i];
    }
    tall->count = new_count;
    node_refresh_summary(tall);
    node_refresh_summary(sibling);

    Node *parent = node_new_internal(tall->height + 1);
    if (!parent) {
        node_free(sibling);
        return tall;
    }
    parent->as.internal.children[0] = sibling;
    parent->as.internal.children[1] = tall;
    parent->count = 2;
    node_refresh_summary(parent);
    return parent;
}

Node *node_concat(Node *left, Node *right) {
    if (node_is_empty(left)) {
        node_free(left);
        return right ? right : node_new_leaf();
    }
    if (node_is_empty(right)) {
        node_free(right);
        return left;
    }
    if (left->height == right->height) {
        return merge_same_height(left, right);
    }
    if (left->height > right->height) {
        return concat_graft_right(left, right);
    }
    return concat_graft_left(right, left);
}

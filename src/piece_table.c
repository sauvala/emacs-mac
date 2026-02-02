/* Piece table implementation using red-black tree for O(log n) lookups.

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

#include <config.h>

#ifdef USE_PIECE_TABLE

#include "piece_table.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ============================================================================
 * Internal Types
 * ============================================================================ */

typedef enum
{
  BUFFER_ORIGINAL,
  BUFFER_ADD
} BufferType;

typedef enum
{
  COLOR_RED,
  COLOR_BLACK
} NodeColor;

typedef struct Piece
{
  BufferType buffer_type;
  size_t start;			/* Start offset in buffer.  */
  size_t length;		/* Length of this piece.  */

  /* Red-black tree structure.  */
  struct Piece *left;
  struct Piece *right;
  struct Piece *parent;
  NodeColor color;

  /* Cached subtree metadata for O(log n) position lookup.  */
  size_t left_subtree_length;	/* Total length of all pieces in left
				   subtree.  */

  /* Line count caching for O(log n) line operations.  */
  size_t line_count;		/* Number of '\n' characters in this
				   piece.  */
  size_t left_subtree_lines;	/* Total line breaks in left subtree.  */
} Piece;

typedef enum
{
  CHANGE_INSERT,
  CHANGE_DELETE
} ChangeType;

typedef struct Change
{
  ChangeType type;
  size_t position;
  size_t length;
  /* For undo: store the text that was deleted or inserted.  */
  Piece *saved_piece;		/* Reference to saved text in add buffer.  */
  size_t add_buffer_len;	/* Add buffer length before this change.  */
  struct Change *next;
} Change;

struct PieceTable
{
  /* Original buffer (read-only after creation).  */
  char *original_buffer;
  size_t original_length;

  /* Add buffer (append-only).  */
  char *add_buffer;
  size_t add_length;
  size_t add_capacity;

  /* Red-black tree root.  */
  Piece *root;

  /* Sentinel nil node (simplifies tree operations).  */
  Piece *nil;

  /* Cached total length.  */
  size_t total_length;

  /* Undo/redo stacks.  */
  Change *undo_stack;
  Change *redo_stack;

  /* If true, don't track changes for undo/redo.  */
  bool undo_disabled;
};

/* Iterator for sequential access.  */
struct PieceTableIterator
{
  const PieceTable *pt;
  Piece *current_piece;
  size_t offset_in_piece;	/* Offset within current piece.  */
  size_t position;		/* Absolute position in document.  */
};

/* ============================================================================
 * Red-Black Tree Helpers
 * ============================================================================ */

/* Count newlines in a buffer range.  */
static size_t
count_newlines (const char *buffer, size_t start, size_t length)
{
  size_t count = 0;
  for (size_t i = 0; i < length; i++)
    {
      if (buffer[start + i] == '\n')
	count++;
    }
  return count;
}

/* Update a piece's line_count based on its current start/length.  */
static void
piece_update_line_count (const PieceTable *pt, Piece *p)
{
  const char *buffer = (p->buffer_type == BUFFER_ORIGINAL)
    ? pt->original_buffer : pt->add_buffer;
  p->line_count = count_newlines (buffer, p->start, p->length);
}

static Piece *
piece_create (PieceTable *pt, BufferType type, size_t start, size_t length)
{
  Piece *p = malloc (sizeof (Piece));
  if (!p)
    return NULL;
  p->buffer_type = type;
  p->start = start;
  p->length = length;
  p->left = pt->nil;
  p->right = pt->nil;
  p->parent = pt->nil;
  p->color = COLOR_RED;		/* New nodes are red.  */
  p->left_subtree_length = 0;
  p->left_subtree_lines = 0;

  /* Count newlines in this piece.  */
  const char *buffer = (type == BUFFER_ORIGINAL)
    ? pt->original_buffer : pt->add_buffer;
  p->line_count = count_newlines (buffer, start, length);

  return p;
}

static void
piece_free (Piece *p)
{
  free (p);
}

/* Free entire subtree (not including nil sentinel).  */
static void
tree_free (PieceTable *pt, Piece *node)
{
  if (node == pt->nil)
    return;
  tree_free (pt, node->left);
  tree_free (pt, node->right);
  piece_free (node);
}

/* Get total length of subtree rooted at node.  */
static size_t
subtree_length (const PieceTable *pt, const Piece *node)
{
  if (node == pt->nil)
    return 0;
  return node->left_subtree_length + node->length
    + subtree_length (pt, node->right);
}

/* Get total line count of subtree rooted at node.  */
static size_t
subtree_lines (const PieceTable *pt, const Piece *node)
{
  if (node == pt->nil)
    return 0;
  return node->left_subtree_lines + node->line_count
    + subtree_lines (pt, node->right);
}

/* Update left_subtree_length and left_subtree_lines for a single
   node.  */
static void
update_subtree_metadata (PieceTable *pt, Piece *node)
{
  if (node == pt->nil)
    return;
  node->left_subtree_length = subtree_length (pt, node->left);
  node->left_subtree_lines = subtree_lines (pt, node->left);
}

/* Update subtree metadata from node up to root.  */
static void
update_metadata_to_root (PieceTable *pt, Piece *node)
{
  while (node != pt->nil)
    {
      update_subtree_metadata (pt, node);
      node = node->parent;
    }
}

/* Left rotation.  */
static void
rotate_left (PieceTable *pt, Piece *x)
{
  Piece *y = x->right;

  /* Turn y's left subtree into x's right subtree.  */
  x->right = y->left;
  if (y->left != pt->nil)
    y->left->parent = x;

  /* Link x's parent to y.  */
  y->parent = x->parent;
  if (x->parent == pt->nil)
    pt->root = y;
  else if (x == x->parent->left)
    x->parent->left = y;
  else
    x->parent->right = y;

  /* Put x on y's left.  */
  y->left = x;
  x->parent = y;

  /* Update cached lengths.  */
  update_subtree_metadata (pt, x);
  update_subtree_metadata (pt, y);
}

/* Right rotation.  */
static void
rotate_right (PieceTable *pt, Piece *y)
{
  Piece *x = y->left;

  /* Turn x's right subtree into y's left subtree.  */
  y->left = x->right;
  if (x->right != pt->nil)
    x->right->parent = y;

  /* Link y's parent to x.  */
  x->parent = y->parent;
  if (y->parent == pt->nil)
    pt->root = x;
  else if (y == y->parent->right)
    y->parent->right = x;
  else
    y->parent->left = x;

  /* Put y on x's right.  */
  x->right = y;
  y->parent = x;

  /* Update cached lengths.  */
  update_subtree_metadata (pt, y);
  update_subtree_metadata (pt, x);
}

/* Fix red-black properties after insertion.  */
static void
insert_fixup (PieceTable *pt, Piece *z)
{
  while (z->parent->color == COLOR_RED)
    {
      if (z->parent == z->parent->parent->left)
	{
	  Piece *y = z->parent->parent->right;	/* Uncle.  */
	  if (y->color == COLOR_RED)
	    {
	      /* Case 1: Uncle is red.  */
	      z->parent->color = COLOR_BLACK;
	      y->color = COLOR_BLACK;
	      z->parent->parent->color = COLOR_RED;
	      z = z->parent->parent;
	    }
	  else
	    {
	      if (z == z->parent->right)
		{
		  /* Case 2: Uncle is black, z is right child.  */
		  z = z->parent;
		  rotate_left (pt, z);
		}
	      /* Case 3: Uncle is black, z is left child.  */
	      z->parent->color = COLOR_BLACK;
	      z->parent->parent->color = COLOR_RED;
	      rotate_right (pt, z->parent->parent);
	    }
	}
      else
	{
	  /* Mirror cases for right side.  */
	  Piece *y = z->parent->parent->left;	/* Uncle.  */
	  if (y->color == COLOR_RED)
	    {
	      z->parent->color = COLOR_BLACK;
	      y->color = COLOR_BLACK;
	      z->parent->parent->color = COLOR_RED;
	      z = z->parent->parent;
	    }
	  else
	    {
	      if (z == z->parent->left)
		{
		  z = z->parent;
		  rotate_right (pt, z);
		}
	      z->parent->color = COLOR_BLACK;
	      z->parent->parent->color = COLOR_RED;
	      rotate_left (pt, z->parent->parent);
	    }
	}
    }
  pt->root->color = COLOR_BLACK;
}

/* Find minimum node in subtree.  */
static Piece *
tree_minimum (PieceTable *pt, Piece *node)
{
  while (node->left != pt->nil)
    node = node->left;
  return node;
}

/* Transplant: replace subtree rooted at u with subtree rooted at v.  */
static void
transplant (PieceTable *pt, Piece *u, Piece *v)
{
  if (u->parent == pt->nil)
    pt->root = v;
  else if (u == u->parent->left)
    u->parent->left = v;
  else
    u->parent->right = v;
  v->parent = u->parent;
}

/* Fix red-black properties after deletion.  */
static void
delete_fixup (PieceTable *pt, Piece *x)
{
  while (x != pt->root && x->color == COLOR_BLACK)
    {
      if (x == x->parent->left)
	{
	  Piece *w = x->parent->right;	/* Sibling.  */
	  if (w->color == COLOR_RED)
	    {
	      /* Case 1: Sibling is red.  */
	      w->color = COLOR_BLACK;
	      x->parent->color = COLOR_RED;
	      rotate_left (pt, x->parent);
	      w = x->parent->right;
	    }
	  if (w->left->color == COLOR_BLACK
	      && w->right->color == COLOR_BLACK)
	    {
	      /* Case 2: Sibling's children are both black.  */
	      w->color = COLOR_RED;
	      x = x->parent;
	    }
	  else
	    {
	      if (w->right->color == COLOR_BLACK)
		{
		  /* Case 3: Sibling's right child is black.  */
		  w->left->color = COLOR_BLACK;
		  w->color = COLOR_RED;
		  rotate_right (pt, w);
		  w = x->parent->right;
		}
	      /* Case 4: Sibling's right child is red.  */
	      w->color = x->parent->color;
	      x->parent->color = COLOR_BLACK;
	      w->right->color = COLOR_BLACK;
	      rotate_left (pt, x->parent);
	      x = pt->root;
	    }
	}
      else
	{
	  /* Mirror cases.  */
	  Piece *w = x->parent->left;
	  if (w->color == COLOR_RED)
	    {
	      w->color = COLOR_BLACK;
	      x->parent->color = COLOR_RED;
	      rotate_right (pt, x->parent);
	      w = x->parent->left;
	    }
	  if (w->right->color == COLOR_BLACK
	      && w->left->color == COLOR_BLACK)
	    {
	      w->color = COLOR_RED;
	      x = x->parent;
	    }
	  else
	    {
	      if (w->left->color == COLOR_BLACK)
		{
		  w->right->color = COLOR_BLACK;
		  w->color = COLOR_RED;
		  rotate_left (pt, w);
		  w = x->parent->left;
		}
	      w->color = x->parent->color;
	      x->parent->color = COLOR_BLACK;
	      w->left->color = COLOR_BLACK;
	      rotate_right (pt, x->parent);
	      x = pt->root;
	    }
	}
    }
  x->color = COLOR_BLACK;
}

/* Delete a node from the tree.  */
static void
tree_delete (PieceTable *pt, Piece *z)
{
  Piece *y = z;
  Piece *x;
  NodeColor y_original_color = y->color;

  if (z->left == pt->nil)
    {
      x = z->right;
      transplant (pt, z, z->right);
      update_metadata_to_root (pt, x->parent);
    }
  else if (z->right == pt->nil)
    {
      x = z->left;
      transplant (pt, z, z->left);
      update_metadata_to_root (pt, x->parent);
    }
  else
    {
      y = tree_minimum (pt, z->right);
      y_original_color = y->color;
      x = y->right;
      if (y->parent == z)
	x->parent = y;
      else
	{
	  transplant (pt, y, y->right);
	  y->right = z->right;
	  y->right->parent = y;
	}
      transplant (pt, z, y);
      y->left = z->left;
      y->left->parent = y;
      y->color = z->color;
      update_metadata_to_root (pt, x->parent != pt->nil ? x->parent : y);
    }

  if (y_original_color == COLOR_BLACK)
    delete_fixup (pt, x);
}

/* Find piece at position and compute offset within piece - O(log n).  */
static Piece *
find_piece_at (PieceTable *pt, size_t position, size_t *offset_in_piece)
{
  Piece *node = pt->root;
  size_t current_pos = 0;

  while (node != pt->nil)
    {
      size_t left_len = node->left_subtree_length;

      if (position < current_pos + left_len)
	{
	  /* Position is in left subtree.  */
	  node = node->left;
	}
      else if (position < current_pos + left_len + node->length)
	{
	  /* Position is in this node.  */
	  *offset_in_piece = position - current_pos - left_len;
	  return node;
	}
      else
	{
	  /* Position is in right subtree.  */
	  current_pos += left_len + node->length;
	  node = node->right;
	}
    }

  return NULL;
}

/* Insert new_piece immediately after 'after' in tree order.  */
static void
insert_piece_after (PieceTable *pt, Piece *after, Piece *new_piece)
{
  if (after->right == pt->nil)
    {
      after->right = new_piece;
      new_piece->parent = after;
    }
  else
    {
      Piece *successor = tree_minimum (pt, after->right);
      successor->left = new_piece;
      new_piece->parent = successor;
    }

  update_metadata_to_root (pt, new_piece->parent);
  insert_fixup (pt, new_piece);
}

/* Insert new_piece immediately before 'before' in tree order.  */
static void
insert_piece_before (PieceTable *pt, Piece *before, Piece *new_piece)
{
  if (before->left == pt->nil)
    {
      before->left = new_piece;
      new_piece->parent = before;
    }
  else
    {
      Piece *predecessor = before->left;
      while (predecessor->right != pt->nil)
	predecessor = predecessor->right;
      predecessor->right = new_piece;
      new_piece->parent = predecessor;
    }

  update_metadata_to_root (pt, new_piece->parent);
  insert_fixup (pt, new_piece);
}

/* ============================================================================
 * Buffer Helpers
 * ============================================================================ */

static const char *
pt_get_buffer (const PieceTable *pt, BufferType type)
{
  return (type == BUFFER_ORIGINAL) ? pt->original_buffer : pt->add_buffer;
}

static int
ensure_add_capacity (PieceTable *pt, size_t additional)
{
  size_t needed = pt->add_length + additional;
  if (needed <= pt->add_capacity)
    return 0;

  size_t new_capacity = pt->add_capacity ? pt->add_capacity * 2 : 256;
  while (new_capacity < needed)
    new_capacity *= 2;

  char *new_buffer = realloc (pt->add_buffer, new_capacity);
  if (!new_buffer)
    return -1;

  pt->add_buffer = new_buffer;
  pt->add_capacity = new_capacity;
  return 0;
}

/* ============================================================================
 * Change Stack Helpers
 * ============================================================================ */

static void
change_free (Change *c)
{
  if (c)
    {
      if (c->saved_piece)
	piece_free (c->saved_piece);
      free (c);
    }
}

static void
change_stack_free (Change *stack)
{
  while (stack)
    {
      Change *next = stack->next;
      change_free (stack);
      stack = next;
    }
}

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

PieceTable *
pt_create_ex (bool disable_undo)
{
  PieceTable *pt = calloc (1, sizeof (PieceTable));
  if (!pt)
    return NULL;

  /* Create sentinel nil node.  */
  pt->nil = malloc (sizeof (Piece));
  if (!pt->nil)
    {
      free (pt);
      return NULL;
    }
  memset (pt->nil, 0, sizeof (Piece));
  pt->nil->color = COLOR_BLACK;
  pt->nil->left = pt->nil;
  pt->nil->right = pt->nil;
  pt->nil->parent = pt->nil;

  pt->root = pt->nil;
  pt->undo_disabled = disable_undo;

  return pt;
}

PieceTable *
pt_create (void)
{
  return pt_create_ex (false);
}

PieceTable *
pt_create_with_content_ex (const char *content, size_t length,
			   bool disable_undo)
{
  if (!content && length > 0)
    return NULL;

  PieceTable *pt = pt_create_ex (disable_undo);
  if (!pt)
    return NULL;

  if (length > 0)
    {
      pt->original_buffer = malloc (length);
      if (!pt->original_buffer)
	{
	  pt_destroy (pt);
	  return NULL;
	}
      memcpy (pt->original_buffer, content, length);
      pt->original_length = length;

      /* Create single piece spanning entire original buffer.  */
      Piece *p = piece_create (pt, BUFFER_ORIGINAL, 0, length);
      if (!p)
	{
	  pt_destroy (pt);
	  return NULL;
	}
      p->color = COLOR_BLACK;	/* Root is black.  */
      pt->root = p;
      pt->total_length = length;
    }

  return pt;
}

PieceTable *
pt_create_with_content (const char *content, size_t length)
{
  return pt_create_with_content_ex (content, length, false);
}

void
pt_destroy (PieceTable *pt)
{
  if (!pt)
    return;

  free (pt->original_buffer);
  free (pt->add_buffer);
  tree_free (pt, pt->root);
  free (pt->nil);
  change_stack_free (pt->undo_stack);
  change_stack_free (pt->redo_stack);
  free (pt);
}

/* ============================================================================
 * Core Operations
 * ============================================================================ */

int
pt_insert (PieceTable *pt, size_t position, const char *text, size_t length)
{
  if (!pt || !text || length == 0)
    return -1;

  if (position > pt->total_length)
    return -1;

  /* Ensure add buffer capacity.  */
  if (ensure_add_capacity (pt, length) != 0)
    return -1;

  /* Record for undo (if enabled).  */
  Change *change = NULL;
  if (!pt->undo_disabled)
    {
      change = calloc (1, sizeof (Change));
      if (!change)
	return -1;
      change->type = CHANGE_INSERT;
      change->position = position;
      change->length = length;
      change->add_buffer_len = pt->add_length;
    }

  /* Append text to add buffer.  */
  size_t add_start = pt->add_length;
  memcpy (pt->add_buffer + pt->add_length, text, length);
  pt->add_length += length;

  /* Create new piece for inserted text.  */
  Piece *new_piece = piece_create (pt, BUFFER_ADD, add_start, length);
  if (!new_piece)
    {
      if (change)
	free (change);
      return -1;
    }

  if (pt->root == pt->nil)
    {
      /* Empty document.  */
      pt->root = new_piece;
      new_piece->color = COLOR_BLACK;
    }
  else if (position == 0)
    {
      /* Insert at beginning - before first piece.  */
      Piece *first = pt->root;
      while (first->left != pt->nil)
	first = first->left;
      insert_piece_before (pt, first, new_piece);
    }
  else if (position == pt->total_length)
    {
      /* Insert at end - after last piece.  */
      Piece *last = pt->root;
      while (last->right != pt->nil)
	last = last->right;
      insert_piece_after (pt, last, new_piece);
    }
  else
    {
      /* Insert in middle - find and possibly split.  */
      size_t offset;
      Piece *p = find_piece_at (pt, position, &offset);

      if (!p)
	{
	  piece_free (new_piece);
	  if (change)
	    free (change);
	  return -1;
	}

      if (offset == 0)
	{
	  /* Insert at piece boundary (before this piece).  */
	  insert_piece_before (pt, p, new_piece);
	}
      else
	{
	  /* Split the piece.  */
	  Piece *second_half = piece_create (pt, p->buffer_type,
					     p->start + offset,
					     p->length - offset);
	  if (!second_half)
	    {
	      piece_free (new_piece);
	      if (change)
		free (change);
	      return -1;
	    }

	  /* Shrink first piece.  */
	  p->length = offset;
	  piece_update_line_count (pt, p);
	  update_metadata_to_root (pt, p);

	  /* Insert new piece after first half.  */
	  insert_piece_after (pt, p, new_piece);
	  /* Insert second half after new piece.  */
	  insert_piece_after (pt, new_piece, second_half);
	}
    }

  pt->total_length += length;

  /* Update undo stack (if enabled).  */
  if (!pt->undo_disabled)
    {
      change_stack_free (pt->redo_stack);
      pt->redo_stack = NULL;
      change->next = pt->undo_stack;
      pt->undo_stack = change;
    }

  return 0;
}

int
pt_delete (PieceTable *pt, size_t position, size_t length)
{
  if (!pt || length == 0)
    return -1;

  if (position + length > pt->total_length)
    return -1;

  /* Record for undo (if enabled).  */
  Change *change = NULL;
  if (!pt->undo_disabled)
    {
      change = calloc (1, sizeof (Change));
      if (!change)
	return -1;
      change->type = CHANGE_DELETE;
      change->position = position;
      change->length = length;
      change->add_buffer_len = pt->add_length;

      /* Save deleted text to add buffer for undo.  */
      if (ensure_add_capacity (pt, length) != 0)
	{
	  free (change);
	  return -1;
	}

      pt_get_text (pt, position, length, pt->add_buffer + pt->add_length);
      size_t deleted_text_start = pt->add_length;
      pt->add_length += length;

      /* Create a pseudo-piece to track the deleted text.  */
      change->saved_piece = malloc (sizeof (Piece));
      if (!change->saved_piece)
	{
	  free (change);
	  return -1;
	}
      change->saved_piece->buffer_type = BUFFER_ADD;
      change->saved_piece->start = deleted_text_start;
      change->saved_piece->length = length;
    }

  /* Find and delete affected pieces.  */
  size_t remaining = length;
  size_t current_pos = position;

  while (remaining > 0)
    {
      size_t offset;
      Piece *p = find_piece_at (pt, current_pos, &offset);
      if (!p)
	break;

      size_t delete_in_piece = p->length - offset;
      if (delete_in_piece > remaining)
	delete_in_piece = remaining;

      if (offset == 0 && delete_in_piece == p->length)
	{
	  /* Delete entire piece.  */
	  tree_delete (pt, p);
	  piece_free (p);
	}
      else if (offset == 0)
	{
	  /* Delete from start of piece.  */
	  p->start += delete_in_piece;
	  p->length -= delete_in_piece;
	  piece_update_line_count (pt, p);
	  update_metadata_to_root (pt, p);
	}
      else if (offset + delete_in_piece == p->length)
	{
	  /* Delete to end of piece.  */
	  p->length = offset;
	  piece_update_line_count (pt, p);
	  update_metadata_to_root (pt, p);
	}
      else
	{
	  /* Delete from middle - split piece.  */
	  Piece *second_half = piece_create (pt, p->buffer_type,
					     p->start + offset + delete_in_piece,
					     p->length - offset - delete_in_piece);
	  if (!second_half)
	    {
	      if (change)
		change_free (change);
	      return -1;
	    }
	  p->length = offset;
	  piece_update_line_count (pt, p);
	  update_metadata_to_root (pt, p);
	  insert_piece_after (pt, p, second_half);
	}

      remaining -= delete_in_piece;
    }

  pt->total_length -= length;

  /* Update undo stack (if enabled).  */
  if (!pt->undo_disabled)
    {
      change_stack_free (pt->redo_stack);
      pt->redo_stack = NULL;
      change->next = pt->undo_stack;
      pt->undo_stack = change;
    }

  return 0;
}

/* ============================================================================
 * Access
 * ============================================================================ */

size_t
pt_length (const PieceTable *pt)
{
  return pt ? pt->total_length : 0;
}

int
pt_char_at (const PieceTable *pt, size_t position)
{
  if (!pt || position >= pt->total_length)
    return -1;

  size_t offset;
  Piece *p = find_piece_at ((PieceTable *) pt, position, &offset);
  if (!p)
    return -1;

  const char *buffer = pt_get_buffer (pt, p->buffer_type);
  return (unsigned char) buffer[p->start + offset];
}

/* In-order traversal helper for get_text.  */
static size_t
get_text_recursive (const PieceTable *pt, Piece *node,
		    size_t start, size_t length,
		    size_t node_start, char *buffer, size_t written)
{
  if (node == pt->nil || written >= length)
    return written;

  size_t left_end = node_start + node->left_subtree_length;
  size_t node_end = left_end + node->length;

  /* Process left subtree if it overlaps with requested range.  */
  if (start < left_end)
    written = get_text_recursive (pt, node->left, start, length,
				  node_start, buffer, written);

  /* Process this node if it overlaps.  */
  if (written < length && start < node_end && start + length > left_end)
    {
      size_t copy_start = (start > left_end) ? start - left_end : 0;
      size_t copy_end = (start + length < node_end)
	? start + length - left_end : node->length;

      if (copy_start < node->length && copy_end > copy_start)
	{
	  size_t copy_len = copy_end - copy_start;
	  if (written + copy_len > length)
	    copy_len = length - written;

	  const char *src = pt_get_buffer (pt, node->buffer_type);
	  memcpy (buffer + written, src + node->start + copy_start, copy_len);
	  written += copy_len;
	}
    }

  /* Process right subtree if it overlaps.  */
  if (written < length && start + length > node_end)
    written = get_text_recursive (pt, node->right, start, length,
				  node_end, buffer, written);

  return written;
}

size_t
pt_get_text (const PieceTable *pt, size_t start, size_t length, char *buffer)
{
  if (!pt || !buffer || start >= pt->total_length)
    return 0;

  /* Clamp length.  */
  if (start + length > pt->total_length)
    length = pt->total_length - start;

  return get_text_recursive (pt, pt->root, start, length, 0, buffer, 0);
}

char *
pt_get_all_text (const PieceTable *pt)
{
  if (!pt)
    return NULL;

  char *buffer = malloc (pt->total_length + 1);
  if (!buffer)
    return NULL;

  pt_get_text (pt, 0, pt->total_length, buffer);
  buffer[pt->total_length] = '\0';

  return buffer;
}

/* ============================================================================
 * Contiguous Access (Emacs-specific)
 * ============================================================================ */

const unsigned char *
pt_get_contiguous (const PieceTable *pt, size_t position, size_t *out_length)
{
  if (!pt || position >= pt->total_length)
    return NULL;

  size_t offset;
  Piece *p = find_piece_at ((PieceTable *) pt, position, &offset);
  if (!p)
    return NULL;

  const char *buffer = pt_get_buffer (pt, p->buffer_type);
  if (out_length)
    *out_length = p->length - offset;

  return (const unsigned char *) (buffer + p->start + offset);
}

size_t
pt_contiguous_end (const PieceTable *pt, size_t position)
{
  if (!pt || pt->total_length == 0)
    return 0;

  if (position >= pt->total_length)
    return pt->total_length - 1;

  size_t offset;
  Piece *p = find_piece_at ((PieceTable *) pt, position, &offset);
  if (!p)
    return pt->total_length - 1;

  /* Find absolute position of this piece's start.  */
  size_t piece_start = position - offset;
  /* Return last byte position in this piece.  */
  return piece_start + p->length - 1;
}

size_t
pt_contiguous_start (const PieceTable *pt, size_t position)
{
  if (!pt || pt->total_length == 0)
    return 0;

  if (position >= pt->total_length)
    position = pt->total_length - 1;

  size_t offset;
  Piece *p = find_piece_at ((PieceTable *) pt, position, &offset);
  if (!p)
    return 0;

  /* Return first byte position in this piece.  */
  return position - offset;
}

/* ============================================================================
 * Iterator
 * ============================================================================ */

/* Find the in-order successor of a piece.  */
static Piece *
find_next_piece (const PieceTable *pt, Piece *current)
{
  if (current->right != pt->nil)
    return tree_minimum ((PieceTable *) pt, current->right);

  Piece *parent = current->parent;
  while (parent != pt->nil && current == parent->right)
    {
      current = parent;
      parent = parent->parent;
    }
  return parent != pt->nil ? parent : NULL;
}

PieceTableIterator *
pt_iterator_create (const PieceTable *pt, size_t position)
{
  if (!pt || position > pt->total_length)
    return NULL;

  PieceTableIterator *iter = malloc (sizeof (PieceTableIterator));
  if (!iter)
    return NULL;

  iter->pt = pt;
  iter->position = position;

  if (position >= pt->total_length)
    {
      /* At end of document.  */
      iter->current_piece = NULL;
      iter->offset_in_piece = 0;
    }
  else
    {
      iter->current_piece = find_piece_at ((PieceTable *) pt, position,
					   &iter->offset_in_piece);
    }

  return iter;
}

void
pt_iterator_destroy (PieceTableIterator *iter)
{
  free (iter);
}

int
pt_iterator_next (PieceTableIterator *iter)
{
  if (!iter || !iter->current_piece)
    return -1;

  const char *buffer = pt_get_buffer (iter->pt,
				      iter->current_piece->buffer_type);
  int result = (unsigned char) buffer[iter->current_piece->start
				      + iter->offset_in_piece];

  iter->offset_in_piece++;
  iter->position++;

  /* Move to next piece if needed.  */
  if (iter->offset_in_piece >= iter->current_piece->length)
    {
      iter->current_piece = find_next_piece (iter->pt, iter->current_piece);
      iter->offset_in_piece = 0;
    }

  return result;
}

int
pt_iterator_peek (const PieceTableIterator *iter)
{
  if (!iter || !iter->current_piece)
    return -1;

  const char *buffer = pt_get_buffer (iter->pt,
				      iter->current_piece->buffer_type);
  return (unsigned char) buffer[iter->current_piece->start
				+ iter->offset_in_piece];
}

size_t
pt_iterator_position (const PieceTableIterator *iter)
{
  return iter ? iter->position : 0;
}

int
pt_iterator_seek (PieceTableIterator *iter, size_t position)
{
  if (!iter || position > iter->pt->total_length)
    return -1;

  iter->position = position;

  if (position >= iter->pt->total_length)
    {
      iter->current_piece = NULL;
      iter->offset_in_piece = 0;
    }
  else
    {
      iter->current_piece = find_piece_at ((PieceTable *) iter->pt, position,
					   &iter->offset_in_piece);
    }

  return 0;
}

/* ============================================================================
 * Undo/Redo
 * ============================================================================ */

int
pt_can_undo (const PieceTable *pt)
{
  return pt && !pt->undo_disabled && pt->undo_stack != NULL;
}

int
pt_can_redo (const PieceTable *pt)
{
  return pt && !pt->undo_disabled && pt->redo_stack != NULL;
}

int
pt_undo (PieceTable *pt)
{
  if (!pt || pt->undo_disabled || !pt->undo_stack)
    return -1;

  Change *change = pt->undo_stack;
  pt->undo_stack = change->next;

  if (change->type == CHANGE_INSERT)
    {
      /* Undo insert = delete.  */
      size_t position = change->position;
      size_t length = change->length;
      size_t remaining = length;

      while (remaining > 0)
	{
	  size_t offset;
	  Piece *p = find_piece_at (pt, position, &offset);
	  if (!p)
	    break;

	  size_t delete_in_piece = p->length - offset;
	  if (delete_in_piece > remaining)
	    delete_in_piece = remaining;

	  if (offset == 0 && delete_in_piece == p->length)
	    {
	      tree_delete (pt, p);
	      piece_free (p);
	    }
	  else if (offset == 0)
	    {
	      p->start += delete_in_piece;
	      p->length -= delete_in_piece;
	      piece_update_line_count (pt, p);
	      update_metadata_to_root (pt, p);
	    }
	  else if (offset + delete_in_piece == p->length)
	    {
	      p->length = offset;
	      piece_update_line_count (pt, p);
	      update_metadata_to_root (pt, p);
	    }
	  else
	    {
	      Piece *second_half = piece_create (pt, p->buffer_type,
						 p->start + offset
						 + delete_in_piece,
						 p->length - offset
						 - delete_in_piece);
	      p->length = offset;
	      piece_update_line_count (pt, p);
	      update_metadata_to_root (pt, p);
	      insert_piece_after (pt, p, second_half);
	    }

	  remaining -= delete_in_piece;
	}

      pt->total_length -= length;
    }
  else
    {
      /* Undo delete = insert the saved text back.  */
      if (change->saved_piece)
	{
	  Piece *new_piece = piece_create (pt, change->saved_piece->buffer_type,
					   change->saved_piece->start,
					   change->saved_piece->length);

	  size_t position = change->position;

	  if (pt->root == pt->nil)
	    {
	      pt->root = new_piece;
	      new_piece->color = COLOR_BLACK;
	    }
	  else if (position == 0)
	    {
	      Piece *first = pt->root;
	      while (first->left != pt->nil)
		first = first->left;
	      insert_piece_before (pt, first, new_piece);
	    }
	  else if (position >= pt->total_length)
	    {
	      Piece *last = pt->root;
	      while (last->right != pt->nil)
		last = last->right;
	      insert_piece_after (pt, last, new_piece);
	    }
	  else
	    {
	      size_t offset;
	      Piece *p = find_piece_at (pt, position, &offset);

	      if (offset == 0)
		insert_piece_before (pt, p, new_piece);
	      else
		{
		  Piece *second_half = piece_create (pt, p->buffer_type,
						     p->start + offset,
						     p->length - offset);
		  p->length = offset;
		  update_metadata_to_root (pt, p);
		  insert_piece_after (pt, p, new_piece);
		  insert_piece_after (pt, new_piece, second_half);
		}
	    }

	  pt->total_length += change->saved_piece->length;
	}
    }

  /* Move to redo stack.  */
  change->next = pt->redo_stack;
  pt->redo_stack = change;

  return 0;
}

int
pt_redo (PieceTable *pt)
{
  if (!pt || pt->undo_disabled || !pt->redo_stack)
    return -1;

  Change *change = pt->redo_stack;
  pt->redo_stack = change->next;

  if (change->type == CHANGE_INSERT)
    {
      /* Redo insert.  */
      Piece *new_piece = piece_create (pt, BUFFER_ADD,
				       change->add_buffer_len,
				       change->length);

      size_t position = change->position;

      if (pt->root == pt->nil)
	{
	  pt->root = new_piece;
	  new_piece->color = COLOR_BLACK;
	}
      else if (position == 0)
	{
	  Piece *first = pt->root;
	  while (first->left != pt->nil)
	    first = first->left;
	  insert_piece_before (pt, first, new_piece);
	}
      else if (position >= pt->total_length)
	{
	  Piece *last = pt->root;
	  while (last->right != pt->nil)
	    last = last->right;
	  insert_piece_after (pt, last, new_piece);
	}
      else
	{
	  size_t offset;
	  Piece *p = find_piece_at (pt, position, &offset);

	  if (offset == 0)
	    insert_piece_before (pt, p, new_piece);
	  else
	    {
	      Piece *second_half = piece_create (pt, p->buffer_type,
						 p->start + offset,
						 p->length - offset);
	      p->length = offset;
	      update_metadata_to_root (pt, p);
	      insert_piece_after (pt, p, new_piece);
	      insert_piece_after (pt, new_piece, second_half);
	    }
	}

      pt->total_length += change->length;
    }
  else
    {
      /* Redo delete.  */
      size_t position = change->position;
      size_t length = change->length;
      size_t remaining = length;

      while (remaining > 0)
	{
	  size_t offset;
	  Piece *p = find_piece_at (pt, position, &offset);
	  if (!p)
	    break;

	  size_t delete_in_piece = p->length - offset;
	  if (delete_in_piece > remaining)
	    delete_in_piece = remaining;

	  if (offset == 0 && delete_in_piece == p->length)
	    {
	      tree_delete (pt, p);
	      piece_free (p);
	    }
	  else if (offset == 0)
	    {
	      p->start += delete_in_piece;
	      p->length -= delete_in_piece;
	      piece_update_line_count (pt, p);
	      update_metadata_to_root (pt, p);
	    }
	  else if (offset + delete_in_piece == p->length)
	    {
	      p->length = offset;
	      piece_update_line_count (pt, p);
	      update_metadata_to_root (pt, p);
	    }
	  else
	    {
	      Piece *second_half = piece_create (pt, p->buffer_type,
						 p->start + offset
						 + delete_in_piece,
						 p->length - offset
						 - delete_in_piece);
	      p->length = offset;
	      piece_update_line_count (pt, p);
	      update_metadata_to_root (pt, p);
	      insert_piece_after (pt, p, second_half);
	    }

	  remaining -= delete_in_piece;
	}

      pt->total_length -= length;
    }

  /* Move back to undo stack.  */
  change->next = pt->undo_stack;
  pt->undo_stack = change;

  return 0;
}

/* ============================================================================
 * Line Operations
 * ============================================================================ */

size_t
pt_line_count (const PieceTable *pt)
{
  if (!pt || pt->root == pt->nil)
    return 1;			/* Empty document has 1 line.  */
  /* Total lines = total newlines + 1.  */
  return subtree_lines (pt, pt->root) + 1;
}

/* Find the byte position where a given line starts (0-indexed line
   number).  */
size_t
pt_line_start (const PieceTable *pt, size_t line_number)
{
  if (!pt || pt->root == pt->nil)
    return 0;

  if (line_number == 0)
    return 0;

  /* We need to find the position after the (line_number)th newline.  */
  size_t lines_to_skip = line_number;
  size_t position = 0;
  Piece *node = pt->root;

  while (node != pt->nil)
    {
      size_t left_lines = node->left_subtree_lines;
      size_t left_length = node->left_subtree_length;

      if (lines_to_skip <= left_lines)
	{
	  /* Target line is in left subtree.  */
	  node = node->left;
	}
      else
	{
	  /* Skip left subtree.  */
	  position += left_length;
	  lines_to_skip -= left_lines;

	  if (lines_to_skip <= node->line_count)
	    {
	      /* Target line starts within this piece.  */
	      /* Find the exact newline position.  */
	      const char *buffer = pt_get_buffer (pt, node->buffer_type);
	      size_t newlines_found = 0;
	      for (size_t i = 0; i < node->length; i++)
		{
		  if (buffer[node->start + i] == '\n')
		    {
		      newlines_found++;
		      if (newlines_found == lines_to_skip)
			return position + i + 1;	/* Position after the
							   newline.  */
		    }
		}
	      /* Shouldn't reach here if line counts are correct.  */
	      return position + node->length;
	    }

	  /* Skip this node and go to right subtree.  */
	  position += node->length;
	  lines_to_skip -= node->line_count;
	  node = node->right;
	}
    }

  /* Line number exceeds document - return end of document.  */
  return pt->total_length;
}

size_t
pt_line_length (const PieceTable *pt, size_t line_number)
{
  if (!pt)
    return 0;

  size_t start = pt_line_start (pt, line_number);
  size_t next_start = pt_line_start (pt, line_number + 1);

  if (next_start <= start)
    {
      /* Last line - goes to end of document.  */
      return pt->total_length - start;
    }

  /* Length includes the newline if present.  */
  return next_start - start;
}

size_t
pt_get_line (const PieceTable *pt, size_t line_number,
	     char *buffer, size_t buffer_size)
{
  if (!pt || !buffer || buffer_size == 0)
    return 0;

  size_t start = pt_line_start (pt, line_number);
  size_t line_len = pt_line_length (pt, line_number);

  /* Don't include trailing newline.  */
  if (line_len > 0)
    {
      char last_char;
      if (pt_get_text (pt, start + line_len - 1, 1, &last_char) > 0
	  && last_char == '\n')
	line_len--;
    }

  /* Clamp to buffer size (leave room for null terminator).  */
  size_t copy_len = (line_len < buffer_size - 1) ? line_len : buffer_size - 1;

  size_t written = pt_get_text (pt, start, copy_len, buffer);
  buffer[written] = '\0';

  return written;
}

/* Find line and column for a given byte position.  */
void
pt_position_to_line_col (const PieceTable *pt, size_t position,
			 size_t *line, size_t *col)
{
  if (!pt || !line || !col)
    return;

  if (position >= pt->total_length)
    position = pt->total_length > 0 ? pt->total_length - 1 : 0;

  /* Count newlines before position using tree structure.  */
  size_t line_count = 0;
  size_t last_newline_pos = 0;	/* Position after the last newline we've
				   passed.  */
  size_t current_pos = 0;
  Piece *node = pt->root;

  /* In-order traversal to count lines up to position.  */
  while (node != pt->nil)
    {
      size_t left_length = node->left_subtree_length;
      size_t left_lines = node->left_subtree_lines;

      if (position < current_pos + left_length)
	{
	  /* Position is in left subtree.  */
	  node = node->left;
	}
      else if (position < current_pos + left_length + node->length)
	{
	  /* Position is in this node.  */
	  line_count += left_lines;
	  size_t offset_in_piece = position - current_pos - left_length;

	  /* Count newlines within this piece up to offset.  */
	  const char *buffer = pt_get_buffer (pt, node->buffer_type);
	  for (size_t i = 0; i < offset_in_piece; i++)
	    {
	      if (buffer[node->start + i] == '\n')
		{
		  line_count++;
		  last_newline_pos = current_pos + left_length + i + 1;
		}
	    }

	  *line = line_count;
	  *col = position - last_newline_pos;
	  return;
	}
      else
	{
	  /* Position is in right subtree.  */
	  line_count += left_lines + node->line_count;

	  /* Find last newline position in this node if any.  */
	  if (node->line_count > 0)
	    {
	      const char *buffer = pt_get_buffer (pt, node->buffer_type);
	      for (size_t i = node->length; i > 0; i--)
		{
		  if (buffer[node->start + i - 1] == '\n')
		    {
		      last_newline_pos = current_pos + left_length + i;
		      break;
		    }
		}
	    }
	  /* No newlines in this node, last_newline_pos stays as is.  */

	  current_pos += left_length + node->length;
	  node = node->right;
	}
    }

  *line = line_count;
  *col = position - last_newline_pos;
}

/* ============================================================================
 * Debug
 * ============================================================================ */

static void
debug_print_tree (const PieceTable *pt, const Piece *node, int depth)
{
  if (node == pt->nil)
    return;

  debug_print_tree (pt, node->right, depth + 1);

  for (int i = 0; i < depth; i++)
    printf ("    ");

  const char *buf_name =
    (node->buffer_type == BUFFER_ORIGINAL) ? "ORIG" : "ADD";
  const char *color = (node->color == COLOR_RED) ? "R" : "B";
  printf ("[%s:%s] start=%zu len=%zu left_len=%zu lines=%zu left_lines=%zu",
	  color, buf_name, node->start, node->length,
	  node->left_subtree_length,
	  node->line_count, node->left_subtree_lines);

  /* Print content preview.  */
  const char *buffer = pt_get_buffer (pt, node->buffer_type);
  printf (" \"");
  size_t print_len = node->length < 15 ? node->length : 15;
  for (size_t j = 0; j < print_len; j++)
    {
      char c = buffer[node->start + j];
      if (c == '\n')
	printf ("\\n");
      else if (c == '\t')
	printf ("\\t");
      else
	printf ("%c", c);
    }
  if (node->length > 15)
    printf ("...");
  printf ("\"\n");

  debug_print_tree (pt, node->left, depth + 1);
}

void
pt_debug_print (const PieceTable *pt)
{
  if (!pt)
    {
      printf ("PieceTable: NULL\n");
      return;
    }

  printf ("PieceTable (Red-Black Tree) {\n");
  printf ("  total_length: %zu\n", pt->total_length);
  printf ("  original_length: %zu\n", pt->original_length);
  printf ("  add_length: %zu (capacity: %zu)\n",
	  pt->add_length, pt->add_capacity);
  printf ("  undo_disabled: %s\n", pt->undo_disabled ? "yes" : "no");
  printf ("  tree structure (sideways, right=up):\n");

  if (pt->root == pt->nil)
    printf ("    (empty)\n");
  else
    debug_print_tree (pt, pt->root, 2);

  printf ("  undo_stack: %s\n", pt->undo_stack ? "has items" : "empty");
  printf ("  redo_stack: %s\n", pt->redo_stack ? "has items" : "empty");
  printf ("}\n");
}

#endif /* USE_PIECE_TABLE */

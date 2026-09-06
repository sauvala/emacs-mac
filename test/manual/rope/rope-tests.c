/* Standalone regression tests for the Nemesis rope backend.  */
#include "rope_internal.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t state = 42;
static uint32_t random_value (void)
{
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

static void
check_tree (const Node *node, bool root)
{
  assert (node->count <= MAX_CHILDREN);
  assert (root || node->count >= MIN_CHILDREN);
  if (node->height)
    {
      assert (!root || node->count >= 2);
      for (int i = 0; i < node->count; ++i)
        {
          assert (node->as.internal.children[i]->height + 1 == node->height);
          check_tree (node->as.internal.children[i], false);
        }
    }
}

int main (void)
{
  char expected[100000], actual[100000];
  /* Cover bulk construction at leaf and internal-node boundaries too.  */
  memset (expected, 'a', sizeof expected);
  for (size_t n = 1; n < sizeof expected; n += 127)
    {
      Rope *built = rope_from_str (expected, n);
      check_tree (built->root, true);
      assert (rope_insert (built, n / 2, "xyz", 3) == 0);
      check_tree (built->root, true);
      assert (rope_delete (built, 1, n + 2) == 0);
      check_tree (built->root, true);
      assert (rope_byte_len (built) == 2);
      rope_free (built);
    }
  size_t len = 0;
  Rope *rope = rope_new ();
  for (int step = 0; step < 20000; ++step)
    {
      size_t at = random_value () % (len + 1);
      if (len < 100 || random_value () % 2)
        {
          char text[80];
          size_t n = 1 + random_value () % sizeof text;
          for (size_t j = 0; j < n; ++j)
            text[j] = random_value () % 17 == 0 ? '\n' : 'a' + random_value () % 26;
          assert (len + n < sizeof expected);
          memmove (expected + at + n, expected + at, len - at);
          memcpy (expected + at, text, n);
          len += n;
          assert (rope_insert (rope, at, text, n) == 0);
        }
      else
        {
          size_t n = random_value () % (len - at + 1);
          memmove (expected + at, expected + at + n, len - at - n);
          len -= n;
          assert (rope_delete (rope, at, at + n) == 0);
        }
      assert (rope_byte_len (rope) == len);
      assert (rope_char_len (rope) == len);
      assert (rope_copy (rope, 0, len, actual, sizeof actual) == len);
      assert (memcmp (actual, expected, len) == 0);
      size_t lines = 1;
      for (size_t j = 0; j < len; ++j)
        lines += expected[j] == '\n';
      assert (rope_line_count (rope) == lines);
      check_tree (rope->root, true);
    }
  rope_free (rope);
  puts ("20,000 rope edit and tree-invariant checks passed");
}

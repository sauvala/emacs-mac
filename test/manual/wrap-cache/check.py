#!/usr/bin/env python3
"""Compile the production cache functions with a small display-state fixture.

This exercises cache decisions without requiring GUI redisplay or exposing
additional Lisp primitives.  The cache layout and function bodies come from
source, so the fixture cannot accidentally test a copy of the implementation.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]

def function(file, name):
    source = (root / 'src' / file).read_text()
    start = re.search(r'\n(?:static )?(?:bool|void)\n' + name + r' \(', source).start()
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

header = (root / 'src/window.h').read_text()
cache = re.search(r'    struct \{\n      ptrdiff_t \*charpos;.*?} wrap_cache;',
                  header, re.S).group()
fixture = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef long modiff_count;
typedef void *Lisp_Object;
struct buffer { modiff_count modiff, overlay_modiff; ptrdiff_t begv, zv; bool prevent_redisplay_optimizations_p; };
struct frame { bool face_change; struct window *root_window; };
struct window {
  Lisp_Object contents, next, start, pointm;
  struct frame *frame;
  void *current_matrix, *desired_matrix;
  bool window_end_valid;
  int width;
CACHE
};
struct glyph_row {
  struct { struct { ptrdiff_t charpos, bytepos; } pos; } start;
  int continuation_lines_width;
};
static bool face_change;
static struct frame *test_frames[2];
#define FOR_EACH_FRAME(tail, frame) \
  for (int frame_index = 0; frame_index < 2 \
       && ((frame) = test_frames[frame_index], true); frame_index++)
#define BUF_MODIFF(b) ((b)->modiff)
#define BUF_OVERLAY_MODIFF(b) ((b)->overlay_modiff)
#define BUF_BEGV(b) ((b)->begv)
#define BUF_ZV(b) ((b)->zv)
#define XBUFFER(b) ((struct buffer *)(b))
#define XFRAME(f) ((struct frame *)(f))
#define XWINDOW(w) ((struct window *)(w))
#define WINDOWP(x) false
#define BUFFERP(x) ((x) != NULL)
#define MARKERP(x) true
#define NILP(x) ((x) == NULL)
#define EQ(a,b) ((a) == (b))
#define eassert assert
#define xrealloc realloc
static int window_body_width (struct window *w, bool pixels) { return w->width; }
static ptrdiff_t find_newline_no_quit (ptrdiff_t c, ptrdiff_t b, int n, void *p) { return 1; }
static void adjust_window_count (struct window *w, int n) { w->window_end_valid = false; }
static void clear_glyph_matrix (void *m) {}
'''.replace('CACHE', cache)
fixture += function('xdisp.c', 'wrap_cache_valid_p')
fixture += function('xdisp.c', 'invalidate_wrap_caches_in_window_tree')
fixture += function('xdisp.c', 'invalidate_wrap_caches_for_buffer')
fixture += function('xdisp.c', 'wrap_cache_record')
fixture += function('window.c', 'wset_buffer')
fixture += function('dispnew.c', 'clear_window_matrices')
fixture += r'''
int main (void) {
  struct buffer a = {2, 1, 1, 1000}, b = a;
  struct frame f = {0};
  struct frame g = {0};
  struct window w = {.contents = &a, .frame = &f, .width = 800};
  struct window other = {.contents = &a, .frame = &g, .width = 800};
  f.root_window = &w; g.root_window = &other;
  test_frames[0] = &f; test_frames[1] = &g;
  struct glyph_row row = {.start.pos = {100,100}, .continuation_lines_width = 800};
  wrap_cache_record (&w, &row);
  wrap_cache_record (&other, &row);
  a.prevent_redisplay_optimizations_p = true;
  invalidate_wrap_caches_for_buffer (&a);
  a.prevent_redisplay_optimizations_p = false;
  assert (w.wrap_cache.count == 0);
  assert (other.wrap_cache.count == 0);
  wrap_cache_record (&w, &row);
  assert (wrap_cache_valid_p (&w, &a));
  assert (!wrap_cache_valid_p (&w, &b));
  a.begv = 50;
  assert (!wrap_cache_valid_p (&w, &a));
  a.begv = 1; a.zv = 900;
  assert (!wrap_cache_valid_p (&w, &a));
  a.zv = 1000;
  f.face_change = true;
  assert (!wrap_cache_valid_p (&w, &a));
  f.face_change = false; face_change = true;
  assert (!wrap_cache_valid_p (&w, &a));
  face_change = false;
  a.prevent_redisplay_optimizations_p = true;
  assert (!wrap_cache_valid_p (&w, &a));
  wrap_cache_record (&w, &row);
  assert (w.wrap_cache.count == 0);
  a.prevent_redisplay_optimizations_p = false;
  wrap_cache_record (&w, &row);
  w.width = 400;
  assert (!wrap_cache_valid_p (&w, &a));
  w.width = 800;
  a.modiff++;
  assert (!wrap_cache_valid_p (&w, &a));
  a.modiff--; a.overlay_modiff++;
  assert (!wrap_cache_valid_p (&w, &a));
  a.overlay_modiff--;
  assert (wrap_cache_valid_p (&w, &a));
  wset_buffer (&w, &b);
  assert (w.wrap_cache.count == 0);
  wrap_cache_record (&w, &row);
  assert (wrap_cache_valid_p (&w, &b));
  clear_window_matrices (&w, false);
  assert (w.wrap_cache.count == 0);
  wrap_cache_record (&w, &row);
  b.begv = 50;
  row.start.pos.charpos = row.start.pos.bytepos = 200;
  wrap_cache_record (&w, &row);
  assert (w.wrap_cache.count == 1);
  assert (w.wrap_cache.charpos[0] == 200);
  free (w.wrap_cache.charpos); free (w.wrap_cache.bytepos); free (w.wrap_cache.cont_width);
  free (other.wrap_cache.charpos); free (other.wrap_cache.bytepos); free (other.wrap_cache.cont_width);
  puts ("Wrap cache identity, narrowing, face, width and lifecycle checks passed");
}
'''
with tempfile.TemporaryDirectory(prefix='emacs-wrap-test-') as tmp:
    source = Path(tmp) / 'check.c'
    source.write_text(fixture)
    binary = Path(tmp) / 'check'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-g',
                    '-fsanitize=address,undefined', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

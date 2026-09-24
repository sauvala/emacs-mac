#!/usr/bin/env python3
"""Compile menu-bar snapshot functions with a small Lisp-object fixture."""

from pathlib import Path
import os
import re
import subprocess
import tempfile


root = Path(__file__).resolve().parents[3]
source = (root / "src" / "macmenu.c").read_text()


def function(name):
    start = re.search(
        r"\n(?:static\s+)?(?:Lisp_Object|unsigned long|void|bool)\n"
        + re.escape(name)
        + r"\s*\(",
        source,
    ).start()
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


state_start = source.index("static Lisp_Object menu_bar_snapshots;")
state_end = source.index("static Lisp_Object\nmenu_bar_snapshot_entry", state_start)

fixture = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uintptr_t Lisp_Object;
enum object_kind { CONS_OBJECT, VECTOR_OBJECT, FRAME_OBJECT, WINDOW_OBJECT };
struct object { enum object_kind kind; };
struct cons { enum object_kind kind; Lisp_Object car, cdr; };
struct vector { enum object_kind kind; int size; Lisp_Object *items; };
struct mac_output { void *menubar_widget; };
struct frame {
  enum object_kind kind;
  bool live, mac;
  Lisp_Object menu_bar_vector;
  int menu_bar_items_used;
  Lisp_Object selected_window;
  struct { struct mac_output *mac; } output_data;
};
struct window { enum object_kind kind; Lisp_Object contents; };

#define Qnil ((Lisp_Object) 0)
#define Qt make_fixnum (0)
#define MOST_POSITIVE_FIXNUM 63
#define FIXNATP(value) ((value) & 1)
#define XFIXNAT(value) ((long) ((value) >> 1))
#define HEAPP(value) ((value) != Qnil && !FIXNATP (value))
#define CONSP(value) (HEAPP (value) && object_kind (value) == CONS_OBJECT)
#define VECTORP(value) (HEAPP (value) && object_kind (value) == VECTOR_OBJECT)
#define FRAMEP(value) (HEAPP (value) && object_kind (value) == FRAME_OBJECT)
#define NILP(value) ((value) == Qnil)
#define XCAR(value) (((struct cons *) (uintptr_t) (value))->car)
#define XCDR(value) (((struct cons *) (uintptr_t) (value))->cdr)
#define XSETCDR(value, newcdr) (XCDR (value) = (newcdr))
#define AREF(value, index) (((struct vector *) (uintptr_t) (value))->items[index])
#define ASET(value, index, item) (AREF (value, index) = (item))
#define ASIZE(value) (((struct vector *) (uintptr_t) (value))->size)
#define XFRAME(value) ((struct frame *) (uintptr_t) (value))
#define FRAME_LIVE_P(frame) ((frame)->live)
#define FRAME_MAC_P(frame) ((frame)->mac)
#define FRAME_SELECTED_WINDOW(frame) ((frame)->selected_window)
#define WINDOWP(value) (HEAPP (value) && object_kind (value) == WINDOW_OBJECT)
#define XWINDOW(value) ((struct window *) (uintptr_t) (value))
#define XSETFRAME(value, frame) ((value) = (Lisp_Object) (uintptr_t) (frame))
#define EQ(a, b) ((a) == (b))

static enum object_kind
object_kind (Lisp_Object value)
{
  assert (value && !FIXNATP (value));
  return ((struct object *) (uintptr_t) value)->kind;
}

static Lisp_Object
make_fixnum (unsigned long value)
{
  return (value << 1) | 1;
}

static Lisp_Object
Fcons (Lisp_Object car, Lisp_Object cdr)
{
  struct cons *result = calloc (1, sizeof *result);
  assert (result);
  result->kind = CONS_OBJECT;
  result->car = car;
  result->cdr = cdr;
  return (Lisp_Object) (uintptr_t) result;
}

static Lisp_Object
make_vector (int size, Lisp_Object initial)
{
  struct vector *result = calloc (1, sizeof *result);
  assert (result);
  result->kind = VECTOR_OBJECT;
  result->size = size;
  result->items = calloc (size, sizeof *result->items);
  assert (result->items);
  for (int i = 0; i < size; ++i) result->items[i] = initial;
  return (Lisp_Object) (uintptr_t) result;
}

static Lisp_Object
Fcopy_sequence (Lisp_Object value)
{
  Lisp_Object result = make_vector (ASIZE (value), Qnil);
  for (int i = 0; i < ASIZE (value); ++i) ASET (result, i, AREF (value, i));
  return result;
}

static Lisp_Object
Fassq (Lisp_Object key, Lisp_Object list)
{
  for (; CONSP (list); list = XCDR (list))
    if (CONSP (XCAR (list)) && XCAR (XCAR (list)) == key)
      return XCAR (list);
  return Qnil;
}


static unsigned long restamped_from, restamped_to;
static void
mac_restamp_menu_bar_generation (unsigned long from, unsigned long to)
{
  restamped_from = from;
  restamped_to = to;
}

'''

fixture += source[state_start:state_end]
for name in (
    "menu_bar_snapshot_entry",
    "release_menu_bar_snapshot",
    "next_menu_bar_snapshot_generation",
    "mac_trim_menu_bar_snapshots",
    "publish_menu_bar_snapshot",
    "mac_publish_menu_bar_snapshot",
    "mac_refresh_menu_bar_snapshot",
    "mac_menu_bar_snapshot_live_p",
    "free_frame_menubar",
):
    fixture += function(name)

fixture += r'''
static Lisp_Object
make_frame (int items_used, unsigned long marker)
{
  struct frame *frame = calloc (1, sizeof *frame);
  assert (frame);
  frame->kind = FRAME_OBJECT;
  frame->live = frame->mac = true;
  frame->menu_bar_vector = make_vector (items_used + 2, Qnil);
  frame->menu_bar_items_used = items_used;
  ASET (frame->menu_bar_vector, 3, make_fixnum (marker));
  frame->output_data.mac = calloc (1, sizeof *frame->output_data.mac);
  assert (frame->output_data.mac);
  return (Lisp_Object) (uintptr_t) frame;
}

static Lisp_Object
make_window (Lisp_Object buffer)
{
  struct window *window = calloc (1, sizeof *window);
  assert (window);
  window->kind = WINDOW_OBJECT;
  window->contents = buffer;
  return (Lisp_Object) (uintptr_t) window;
}

static int
snapshot_count (void)
{
  int n = 0;
  for (Lisp_Object tail = menu_bar_snapshots; CONSP (tail);
       tail = XCDR (tail))
    n++;
  return n;
}

/* The table: publication, trimming to the newest
   MENU_BAR_SNAPSHOT_KEEP generations, restamping on a window or
   buffer change, and retraction when a frame is deleted.  */

static void
check_persistent_snapshots (void)
{
  Lisp_Object first = make_frame (8, 31), second = make_frame (6, 32);
  Lisp_Object buffer_a = make_fixnum (40), buffer_b = make_fixnum (41);
  Lisp_Object window = make_window (buffer_a);

  XFRAME (first)->selected_window = window;
  XFRAME (second)->selected_window = make_window (buffer_b);

  unsigned long oldest = mac_publish_menu_bar_snapshot (XFRAME (first));
  assert (oldest && mac_menu_bar_snapshot_live_p (oldest));
  Lisp_Object snapshot = XCDR (menu_bar_snapshot_entry (oldest));
  assert (AREF (snapshot, MENU_BAR_SNAPSHOT_WINDOW) == window);
  assert (AREF (snapshot, MENU_BAR_SNAPSHOT_BUFFER) == buffer_a);
  assert (AREF (snapshot, MENU_BAR_SNAPSHOT_VECTOR)
          != XFRAME (first)->menu_bar_vector);

  /* A frame that is not live, or has no menu-bar vector, publishes
     nothing.  */
  XFRAME (second)->live = false;
  assert (mac_publish_menu_bar_snapshot (XFRAME (second)) == 0);
  XFRAME (second)->live = true;

  unsigned long newest = oldest;
  for (int i = 1; i < MENU_BAR_SNAPSHOT_KEEP; i++)
    newest = mac_publish_menu_bar_snapshot (XFRAME (first));
  assert (snapshot_count () == MENU_BAR_SNAPSHOT_KEEP);
  assert (mac_menu_bar_snapshot_live_p (oldest));

  /* One more drops exactly the oldest generation.  */
  newest = mac_publish_menu_bar_snapshot (XFRAME (first));
  assert (snapshot_count () == MENU_BAR_SNAPSHOT_KEEP);
  assert (!mac_menu_bar_snapshot_live_p (oldest));
  assert (mac_menu_bar_snapshot_live_p (newest));
  assert (!mac_menu_bar_snapshot_live_p (0));

  /* An unchanged window and buffer publish nothing new.  */
  mac_refresh_menu_bar_snapshot (XFRAME (first));
  assert (restamped_to == 0);

  /* A buffer change publishes a new generation and restamps the root
     from the newest one; the old snapshot keeps its context.  */
  XWINDOW (window)->contents = buffer_b;
  mac_refresh_menu_bar_snapshot (XFRAME (first));
  assert (restamped_from == newest && restamped_to != newest);
  assert (AREF (XCDR (menu_bar_snapshot_entry (newest)),
                MENU_BAR_SNAPSHOT_BUFFER) == buffer_a);
  assert (AREF (XCDR (menu_bar_snapshot_entry (restamped_to)),
                MENU_BAR_SNAPSHOT_BUFFER) == buffer_b);
  assert (snapshot_count () == MENU_BAR_SNAPSHOT_KEEP);

  /* Deleting a frame retracts its snapshots but keeps the entries (so
     a queued selection is rejected as "frame closed"); another
     frame's snapshot is untouched.  */
  unsigned long other = mac_publish_menu_bar_snapshot (XFRAME (second));
  free_frame_menubar (XFRAME (first));
  assert (!mac_menu_bar_snapshot_live_p (restamped_to));
  Lisp_Object retracted = XCDR (menu_bar_snapshot_entry (restamped_to));
  assert (AREF (retracted, MENU_BAR_SNAPSHOT_FRAME) == first);
  assert (NILP (AREF (retracted, MENU_BAR_SNAPSHOT_VECTOR)));
  assert (NILP (AREF (retracted, MENU_BAR_SNAPSHOT_WINDOW)));
  assert (NILP (AREF (retracted, MENU_BAR_SNAPSHOT_BUFFER)));
  assert (mac_menu_bar_snapshot_live_p (other));

  menu_bar_snapshots = Qnil;
}

int
main (void)
{
  check_persistent_snapshots ();

  /* Generations wrap around to 1 after MOST_POSITIVE_FIXNUM, skipping
     ones still in the table; an explicit release removes one entry.  */
  Lisp_Object frame = make_frame (4, 50);
  XFRAME (frame)->selected_window = make_window (make_fixnum (51));
  unsigned long kept = mac_publish_menu_bar_snapshot (XFRAME (frame));
  assert (kept == 1 || kept > 0);
  menu_bar_snapshot_generation = MOST_POSITIVE_FIXNUM;
  unsigned long wrapped = mac_publish_menu_bar_snapshot (XFRAME (frame));
  assert (wrapped == (kept == 1 ? 2 : 1));
  release_menu_bar_snapshot (wrapped);
  assert (NILP (menu_bar_snapshot_entry (wrapped)));
  assert (!NILP (menu_bar_snapshot_entry (kept)));
  release_menu_bar_snapshot (kept);
  assert (NILP (menu_bar_snapshots));

  puts ("Menu-bar snapshot lifetime checks passed");
}
'''

with tempfile.TemporaryDirectory(prefix="emacs-mac-menu-test-") as tmp:
    test_source = Path(tmp) / "check.c"
    test_source.write_text(fixture)
    binary = Path(tmp) / "check"
    subprocess.run(
        [
            os.environ.get("CC", "cc"),
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            str(test_source),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True)

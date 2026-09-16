#!/usr/bin/env python3
"""Compile native menu snapshot functions with a small Lisp-object fixture."""

from pathlib import Path
import os
import re
import subprocess
import tempfile


root = Path(__file__).resolve().parents[3]
source = (root / "src" / "macmenu.c").read_text()


def function(name):
    start = re.search(
        r"\n(?:static\s+)?(?:Lisp_Object|unsigned long|void)\n"
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


state_start = source.index("static Lisp_Object native_menu_snapshots;")
state_end = source.index("static Lisp_Object\nnative_menu_snapshot_entry", state_start)

fixture = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uintptr_t Lisp_Object;
enum object_kind { CONS_OBJECT, VECTOR_OBJECT, FRAME_OBJECT };
struct object { enum object_kind kind; };
struct cons { enum object_kind kind; Lisp_Object car, cdr; };
struct vector { enum object_kind kind; int size; Lisp_Object *items; };
struct frame {
  enum object_kind kind;
  bool live, mac;
  Lisp_Object menu_bar_vector;
  int menu_bar_items_used;
};

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

static Lisp_Object selected_frame;
static void
set_frame_menubar (struct frame *frame, bool deep)
{
  (void) frame;
  (void) deep;
}
static Lisp_Object
internal_condition_case_1 (Lisp_Object (*body) (Lisp_Object), Lisp_Object arg,
                           Lisp_Object conditions,
                           Lisp_Object (*handler) (Lisp_Object))
{
  (void) conditions;
  (void) handler;
  return body (arg);
}

static int calls, called_selection, called_items_used;
static struct frame *called_frame;
static Lisp_Object called_vector;
static void
find_and_call_menu_selection (struct frame *frame, int items_used,
                              Lisp_Object vector, void *selection)
{
  ++calls;
  called_frame = frame;
  called_items_used = items_used;
  called_vector = vector;
  called_selection = (int) (intptr_t) selection;
}
'''

fixture += source[state_start:state_end]
for name in (
    "native_menu_snapshot_entry",
    "release_native_menu_snapshot",
    "next_native_menu_generation",
    "prepare_native_menubar",
    "native_menubar_error",
    "mac_prepare_native_menubar",
    "mac_native_menubar_selection",
    "mac_release_native_menubar",
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
  return (Lisp_Object) (uintptr_t) frame;
}

int
main (void)
{
  Lisp_Object first = make_frame (8, 21);
  Lisp_Object second = make_frame (9, 22);

  selected_frame = first;
  unsigned long first_generation = mac_prepare_native_menubar ();
  Lisp_Object first_snapshot
    = XCDR (native_menu_snapshot_entry (first_generation));
  Lisp_Object first_vector = AREF (first_snapshot, NATIVE_MENU_SNAPSHOT_VECTOR);

  selected_frame = second;
  unsigned long second_generation = mac_prepare_native_menubar ();
  assert (second_generation != first_generation);

  selected_frame = second;
  unsigned long third_generation = mac_prepare_native_menubar ();
  assert (third_generation != second_generation);

  ASET (XFRAME (first)->menu_bar_vector, 3, make_fixnum (99));
  mac_native_menubar_selection (first_generation, 3);
  assert (calls == 1 && called_frame == XFRAME (first));
  assert (called_vector == first_vector && called_items_used == 8);
  assert (called_selection == 3 && XFIXNAT (AREF (called_vector, 3)) == 21);

  mac_release_native_menubar (second_generation);
  mac_release_native_menubar (second_generation);
  mac_native_menubar_selection (second_generation, 3);
  assert (calls == 1);
  assert (!NILP (native_menu_snapshot_entry (first_generation)));
  assert (!NILP (native_menu_snapshot_entry (third_generation)));

  XFRAME (first)->live = false;
  mac_native_menubar_selection (first_generation, 3);
  assert (calls == 1);
  XFRAME (first)->live = true;
  mac_native_menubar_selection (first_generation, -1);
  mac_native_menubar_selection (first_generation, 0);
  mac_native_menubar_selection (first_generation, 8);
  assert (calls == 1);

  ASET (first_snapshot, NATIVE_MENU_SNAPSHOT_ITEMS_USED, make_fixnum (20));
  mac_native_menubar_selection (first_generation, 3);
  assert (calls == 1);

  native_menu_generation = MOST_POSITIVE_FIXNUM;
  selected_frame = second;
  unsigned long wrapped_generation = mac_prepare_native_menubar ();
  assert (wrapped_generation == 2);

  mac_release_native_menubar (first_generation);
  assert (NILP (native_menu_snapshot_entry (first_generation)));
  assert (!NILP (native_menu_snapshot_entry (third_generation)));
  assert (!NILP (native_menu_snapshot_entry (wrapped_generation)));
  mac_release_native_menubar (third_generation);
  assert (NILP (native_menu_snapshot_entry (third_generation)));
  assert (!NILP (native_menu_snapshot_entry (wrapped_generation)));
  mac_release_native_menubar (wrapped_generation);
  assert (NILP (native_menu_snapshots));
  puts ("Native menu snapshot lifetime checks passed");
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

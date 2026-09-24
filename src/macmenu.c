/* Menu support for GNU Emacs on macOS.
   Copyright (C) 2000-2008  Free Software Foundation, Inc.
   Copyright (C) 2009-2025  YAMAMOTO Mitsuharu

This file is part of GNU Emacs Mac port.

GNU Emacs Mac port is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs Mac port is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs Mac port.  If not, see <https://www.gnu.org/licenses/>.  */

/* Originally contributed by Andrew Choi (akochoi@mac.com) for Emacs 21.  */

#include <config.h>

#include <stdio.h>

#include "lisp.h"
#include "keyboard.h"
#include "frame.h"
#include "termhooks.h"
#include "window.h"
#include "blockinput.h"
#include "buffer.h"
#include "coding.h"

/* This may include sys/types.h, and that somehow loses
   if this is not done before the other system files.  */
#include "macterm.h"

/* Load sys/types.h if not already loaded.
   In some systems loading it twice is suicidal.  */
#ifndef makedev
#include <sys/types.h>
#endif

#undef HAVE_MULTILINGUAL_MENU

#include "menu.h"
#include "keymap.h"


/* Nonzero means a menu is currently active.  */
static int popup_activated_flag;

/* Root command tables independently of redisplay's current menu vector.
   Native AppKit actions, and persistent-loop menu-bar actions, can
   arrive after a later menu preparation.  Each entry is
   (GENERATION . [FRAME VECTOR ITEMS-USED WINDOW BUFFER]).  WINDOW and
   BUFFER are only filled in by the persistent-loop publisher
   (mac_publish_menu_bar_snapshot); the native path leaves them nil,
   since mac_native_menubar_selection does not consult them.  AppKit
   releases a native entry explicitly when a generation can no longer
   issue an action; the persistent-loop path instead keeps only the
   most recent NATIVE_MENU_SNAPSHOT_KEEP generations (see
   mac_trim_menu_bar_snapshots) since it has no explicit release point
   analogous to menu preparation.  */
static Lisp_Object native_menu_snapshots;
static unsigned long native_menu_generation;

enum native_menu_snapshot_slot
  {
    NATIVE_MENU_SNAPSHOT_FRAME,
    NATIVE_MENU_SNAPSHOT_VECTOR,
    NATIVE_MENU_SNAPSHOT_ITEMS_USED,
    NATIVE_MENU_SNAPSHOT_WINDOW,
    NATIVE_MENU_SNAPSHOT_BUFFER,
    NATIVE_MENU_SNAPSHOT_SIZE
  };

/* Number of past menu-bar-snapshot generations to keep once they are
   superseded, so that an action queued just before a menu-bar rebuild
   can still be revalidated.  A simple fixed count is used instead of
   a reference count on pending actions: the persistent loop's queued
   actions are drained promptly (the next Lisp-thread wakeup), so a
   handful of generations is enough in practice, and this keeps the
   lifetime rule simple to state and to check in
   test/manual/mac-menu/check.py.  */
#define NATIVE_MENU_SNAPSHOT_KEEP 16

static Lisp_Object
native_menu_snapshot_entry (unsigned long generation)
{
  return Fassq (make_fixnum (generation), native_menu_snapshots);
}

static void
release_native_menu_snapshot (unsigned long generation)
{
  Lisp_Object previous = Qnil;

  for (Lisp_Object tail = native_menu_snapshots; CONSP (tail);
       previous = tail, tail = XCDR (tail))
    {
      Lisp_Object entry = XCAR (tail);
      if (CONSP (entry)
          && FIXNATP (XCAR (entry))
          && (unsigned long) XFIXNAT (XCAR (entry)) == generation)
	{
	  if (NILP (previous))
	    native_menu_snapshots = XCDR (tail);
	  else
	    XSETCDR (previous, XCDR (tail));
	  return;
	}
    }
}

static unsigned long
next_native_menu_generation (void)
{
  do
    native_menu_generation
      = (native_menu_generation == MOST_POSITIVE_FIXNUM
	 ? 1 : native_menu_generation + 1);
  while (!NILP (native_menu_snapshot_entry (native_menu_generation)));

  return native_menu_generation;
}

static Lisp_Object
prepare_native_menubar (Lisp_Object frame)
{
  struct frame *f = XFRAME (frame);
  if (!FRAME_LIVE_P (f) || !FRAME_MAC_P (f))
    return Qnil;
  set_frame_menubar (f, true);
  if (!FRAME_LIVE_P (f))
    return Qnil;

  Lisp_Object snapshot = make_vector (NATIVE_MENU_SNAPSHOT_SIZE, Qnil);
  unsigned long generation = next_native_menu_generation ();

  ASET (snapshot, NATIVE_MENU_SNAPSHOT_FRAME, frame);
  ASET (snapshot, NATIVE_MENU_SNAPSHOT_VECTOR,
	Fcopy_sequence (f->menu_bar_vector));
  ASET (snapshot, NATIVE_MENU_SNAPSHOT_ITEMS_USED,
	make_fixnum (f->menu_bar_items_used));
  native_menu_snapshots
    = Fcons (Fcons (make_fixnum (generation), snapshot),
	     native_menu_snapshots);
  return make_fixnum (generation);
}

static Lisp_Object
native_menubar_error (Lisp_Object error)
{
  (void) error;
  return Qnil;
}

unsigned long
mac_prepare_native_menubar (void)
{
  /* Never unwind past the synchronous GUI/Lisp bridge on a Lisp error.  */
  Lisp_Object generation
    = internal_condition_case_1 (prepare_native_menubar, selected_frame, Qt,
				 native_menubar_error);
  return FIXNATP (generation) ? XFIXNAT (generation) : 0;
}

void
mac_native_menubar_selection (unsigned long generation, int selection)
{
  Lisp_Object entry = native_menu_snapshot_entry (generation);
  if (!CONSP (entry))
    return;

  Lisp_Object snapshot = XCDR (entry);
  if (!VECTORP (snapshot) || ASIZE (snapshot) != NATIVE_MENU_SNAPSHOT_SIZE)
    return;

  Lisp_Object frame = AREF (snapshot, NATIVE_MENU_SNAPSHOT_FRAME);
  Lisp_Object vector = AREF (snapshot, NATIVE_MENU_SNAPSHOT_VECTOR);
  Lisp_Object items_used
    = AREF (snapshot, NATIVE_MENU_SNAPSHOT_ITEMS_USED);
  if (selection > 0 && FRAMEP (frame) && FRAME_LIVE_P (XFRAME (frame))
      && VECTORP (vector) && FIXNATP (items_used)
      && selection < XFIXNAT (items_used)
      && XFIXNAT (items_used) <= ASIZE (vector))
    find_and_call_menu_selection (XFRAME (frame), XFIXNAT (items_used), vector,
				 (void *) (intptr_t) selection);
}

void
mac_release_native_menubar (unsigned long generation)
{
  if (generation)
    release_native_menu_snapshot (generation);
}

/* Drop snapshot entries beyond the most recent
   NATIVE_MENU_SNAPSHOT_KEEP once NEWEST_GENERATION has been added, so
   the alist does not grow without bound across repeated menu-bar
   rebuilds.  native_menu_snapshots is newest-first (each publish
   conses to the front), so this walks it in that order.  */

static void
mac_trim_menu_bar_snapshots (void)
{
  int index = 0;
  Lisp_Object tail = native_menu_snapshots, previous = Qnil;

  while (CONSP (tail))
    {
      Lisp_Object next = XCDR (tail);

      if (index >= NATIVE_MENU_SNAPSHOT_KEEP)
	{
	  if (NILP (previous))
	    native_menu_snapshots = next;
	  else
	    XSETCDR (previous, next);
	}
      else
	{
	  previous = tail;
	  index++;
	}
      tail = next;
    }
}

/* Publish a snapshot of the first USED entries of the menu-items
   VECTOR for the menu bar of the live frame F, and return its
   generation.  */

static unsigned long
publish_menu_bar_snapshot (struct frame *f, Lisp_Object vector, int used)
{
  Lisp_Object frame;
  XSETFRAME (frame, f);

  Lisp_Object window = FRAME_SELECTED_WINDOW (f);
  Lisp_Object buffer = WINDOWP (window) ? XWINDOW (window)->contents : Qnil;
  Lisp_Object snapshot = make_vector (NATIVE_MENU_SNAPSHOT_SIZE, Qnil);
  unsigned long generation = next_native_menu_generation ();

  ASET (snapshot, NATIVE_MENU_SNAPSHOT_FRAME, frame);
  ASET (snapshot, NATIVE_MENU_SNAPSHOT_VECTOR, Fcopy_sequence (vector));
  ASET (snapshot, NATIVE_MENU_SNAPSHOT_ITEMS_USED, make_fixnum (used));
  ASET (snapshot, NATIVE_MENU_SNAPSHOT_WINDOW, window);
  ASET (snapshot, NATIVE_MENU_SNAPSHOT_BUFFER, buffer);
  native_menu_snapshots
    = Fcons (Fcons (make_fixnum (generation), snapshot),
	     native_menu_snapshots);
  mac_trim_menu_bar_snapshots ();

  return generation;
}

/* Publish a menu-bar snapshot for F's *current* menu_bar_vector /
   menu_bar_items_used (the caller, set_frame_menubar, has just
   finished (re)computing them) together with F's selected window and
   that window's buffer.  Used only under the persistent event loop;
   see mac_persistent_menubar_selection and D4/D5/D16 in
   .wayfinder/comments/menu-callbacks/2026-09-23-discussion.md.  */

unsigned long
mac_publish_menu_bar_snapshot (struct frame *f)
{
  if (!FRAME_LIVE_P (f) || !FRAME_MAC_P (f) || !VECTORP (f->menu_bar_vector))
    return 0;

  return publish_menu_bar_snapshot (f, f->menu_bar_vector,
				    f->menu_bar_items_used);
}

/* The menu bar of F did not change, but its selected window or that
   window's buffer may have.  Actions already queued for the installed
   root must keep the context they were chosen in (D5), so publish a
   new generation for the new context and restamp the root with it
   rather than updating the old snapshot.  */

static void
mac_refresh_menu_bar_snapshot (struct frame *f)
{
  Lisp_Object frame, window = FRAME_SELECTED_WINDOW (f);
  Lisp_Object buffer = WINDOWP (window) ? XWINDOW (window)->contents : Qnil;

  XSETFRAME (frame, f);
  for (Lisp_Object tail = native_menu_snapshots; CONSP (tail);
       tail = XCDR (tail))
    {
      Lisp_Object snapshot = XCDR (XCAR (tail));

      if (VECTORP (snapshot) && ASIZE (snapshot) == NATIVE_MENU_SNAPSHOT_SIZE
	  && EQ (AREF (snapshot, NATIVE_MENU_SNAPSHOT_FRAME), frame))
	{
	  if (EQ (AREF (snapshot, NATIVE_MENU_SNAPSHOT_WINDOW), window)
	      && EQ (AREF (snapshot, NATIVE_MENU_SNAPSHOT_BUFFER), buffer))
	    return;

	  unsigned long old = XFIXNAT (XCAR (XCAR (tail)));
	  unsigned long generation = mac_publish_menu_bar_snapshot (f);

	  if (generation)
	    mac_restamp_menu_bar_generation (old, generation);
	  return;
	}
    }
}

/* Return true if the snapshot of GENERATION still exists and has not
   been retracted.  Its copy of the menu-bar vector keeps the help
   strings of the menu installed with it reachable (D13).  */

bool
mac_menu_bar_snapshot_live_p (unsigned long generation)
{
  Lisp_Object entry
    = generation ? native_menu_snapshot_entry (generation) : Qnil;

  return (CONSP (entry) && VECTORP (XCDR (entry))
	  && ASIZE (XCDR (entry)) == NATIVE_MENU_SNAPSHOT_SIZE
	  && VECTORP (AREF (XCDR (entry), NATIVE_MENU_SNAPSHOT_VECTOR)));
}

/* Queue a persistent-loop menu-bar action chosen from the root menu
   of GENERATION (D5).  Runs on the Lisp thread when the GUI's queued
   items are drained, which can happen in the middle of a command, so
   only store one `mac-menu-bar-selection' event here; its handler
   in `special-event-map' revalidates when the command loop reads it.  */

void
mac_persistent_menubar_selection (unsigned long generation, int selection)
{
  Lisp_Object entry = native_menu_snapshot_entry (generation);
  Lisp_Object frame = selected_frame;
  struct input_event buf;

  if (CONSP (entry) && VECTORP (XCDR (entry))
      && ASIZE (XCDR (entry)) == NATIVE_MENU_SNAPSHOT_SIZE
      && FRAMEP (AREF (XCDR (entry), NATIVE_MENU_SNAPSHOT_FRAME))
      && FRAME_LIVE_P (XFRAME (AREF (XCDR (entry),
				     NATIVE_MENU_SNAPSHOT_FRAME))))
    frame = AREF (XCDR (entry), NATIVE_MENU_SNAPSHOT_FRAME);

  EVENT_INIT (buf);
  buf.kind = MENU_BAR_EVENT;
  buf.frame_or_window = frame;
  buf.arg = list3 (Qmac_menu_bar_selection, make_fixnum (generation),
		   make_fixnum (selection));
  kbd_buffer_store_event (&buf);
}

/* Lisp thread: queue a `mac-menu-bar-refresh' special event, which
   applies menu-bar updates held back while the menu bar was tracked
   under the persistent loop.  */

void
mac_queue_menu_bar_refresh (void)
{
  struct input_event buf;

  EVENT_INIT (buf);
  buf.kind = MENU_BAR_EVENT;
  buf.frame_or_window = selected_frame;
  buf.arg = list1 (Qmac_menu_bar_refresh);
  kbd_buffer_store_event (&buf);
}

/* Lisp thread: queue a `mac-menu-bar-open-refresh' special event for
   the open-time refresh request SERIAL (D3), which asks for the
   top-level menu at INDEX of the menu bar published as GENERATION.
   Like the events above, this is only stored here because queued
   items can be drained in the middle of a command; the special event
   runs when the command loop reads it.  */

void
mac_queue_menu_bar_open_refresh (unsigned long serial,
				 unsigned long generation, int index)
{
  struct input_event buf;

  EVENT_INIT (buf);
  buf.kind = MENU_BAR_EVENT;
  buf.frame_or_window = selected_frame;
  buf.arg = list4 (Qmac_menu_bar_open_refresh, make_fixnum (serial),
		   make_fixnum (generation), make_fixnum (index));
  kbd_buffer_store_event (&buf);
}

/* Return the key path of item N in the menu-bar VECTOR of USED
   entries, in the order find_and_call_menu_selection queues its
   events, without the leading `menu-bar'.  Return nil if N does not
   start an item.  */

static Lisp_Object
menu_bar_selection_keys (Lisp_Object vector, int used, int n)
{
  Lisp_Object prefix = Qnil, entry = Qnil, stack = Qnil;
  int i = 0;

  while (i < used)
    {
      if (NILP (AREF (vector, i)))
	{
	  stack = Fcons (prefix, stack);
	  prefix = entry;
	  i++;
	}
      else if (EQ (AREF (vector, i), Qlambda))
	{
	  if (CONSP (stack))
	    {
	      prefix = XCAR (stack);
	      stack = XCDR (stack);
	    }
	  i++;
	}
      else if (EQ (AREF (vector, i), Qt))
	{
	  prefix = AREF (vector, i + MENU_ITEMS_PANE_PREFIX);
	  i += MENU_ITEMS_PANE_LENGTH;
	}
      else
	{
	  entry = AREF (vector, i + MENU_ITEMS_ITEM_VALUE);
	  if (i == n)
	    {
	      Lisp_Object keys = list1 (entry);
	      if (!NILP (prefix))
		keys = Fcons (prefix, keys);
	      for (; CONSP (stack); stack = XCDR (stack))
		if (!NILP (XCAR (stack)))
		  keys = Fcons (XCAR (stack), keys);
	      return keys;
	    }
	  i += MENU_ITEMS_ITEM_LENGTH;
	}
    }
  return Qnil;
}

struct menu_bar_raw_binding
{
  Lisp_Object key, binding;
  bool found;
};

static void
find_menu_bar_raw_binding (Lisp_Object key, Lisp_Object val,
			   Lisp_Object args, void *data)
{
  struct menu_bar_raw_binding *b = data;

  if (!b->found && EQ (key, b->key))
    {
      b->binding = val;
      b->found = true;
    }
}

static void
restore_selected_window (Lisp_Object window)
{
  if (WINDOW_LIVE_P (window))
    Fselect_window (window, Qt);
}

/* Return true if the menu-bar item at KEYS (see
   menu_bar_selection_keys) is still bound, visible and enabled in the
   current buffer and selected window.  The raw binding is found in
   the active maps as redisplay's menu-bar code sees it, so :filter,
   :visible and :enable (or a command's `menu-enable' property) are
   evaluated by parse_menu_item just as when the menu was built.  */

static bool
menu_bar_item_enabled_p (Lisp_Object keys)
{
  Lisp_Object prefix = Fvconcat (1, &keys);
  ptrdiff_t n = ASIZE (prefix);
  Lisp_Object key = AREF (prefix, n - 1);

  /* Replace the item's own key with `menu-bar' at the front.  */
  memmove (XVECTOR (prefix)->contents + 1, XVECTOR (prefix)->contents,
	   (n - 1) * word_size);
  ASET (prefix, 0, Qmenu_bar);
  Lisp_Object map = Fkey_binding (prefix, Qnil, Qnil, Qnil);

  if (!CONSP (get_keymap (map, 0, 1)))
    return false;

  struct menu_bar_raw_binding b = { key, Qnil, false };
  map_keymap (map, find_menu_bar_raw_binding, Qnil, &b, true);
  if (!b.found || NILP (b.binding))
    return false;
  if (!CONSP (b.binding))
    return true;
  if (!parse_menu_item (b.binding, 0))
    return false;
  return !NILP (AREF (item_properties, ITEM_PROPERTY_ENABLE));
}

DEFUN ("mac-menu-bar-execute-selection", Fmac_menu_bar_execute_selection,
       Smac_menu_bar_execute_selection, 2, 2, 0,
       doc: /* Run menu-bar item SELECTION of the snapshot GENERATION.
Used by the persistent event loop.  If the snapshot's frame, window or
buffer changed since the menu was shown, do nothing and return a string
naming the reason.  Do the same if the item is no longer enabled when
its conditions are evaluated in the snapshot's window and buffer.
Otherwise select the snapshot's window, queue the item's events and
return nil.  */)
  (Lisp_Object generation, Lisp_Object selection)
{
  CHECK_FIXNAT (generation);
  CHECK_FIXNAT (selection);

  Lisp_Object entry = native_menu_snapshot_entry (XFIXNAT (generation));
  Lisp_Object snapshot = CONSP (entry) ? XCDR (entry) : Qnil;

  if (!(VECTORP (snapshot) && ASIZE (snapshot) == NATIVE_MENU_SNAPSHOT_SIZE))
    return build_string ("menu changed");

  Lisp_Object frame = AREF (snapshot, NATIVE_MENU_SNAPSHOT_FRAME);
  Lisp_Object vector = AREF (snapshot, NATIVE_MENU_SNAPSHOT_VECTOR);
  Lisp_Object items_used = AREF (snapshot, NATIVE_MENU_SNAPSHOT_ITEMS_USED);
  Lisp_Object window = AREF (snapshot, NATIVE_MENU_SNAPSHOT_WINDOW);
  Lisp_Object buffer = AREF (snapshot, NATIVE_MENU_SNAPSHOT_BUFFER);
  EMACS_INT n = XFIXNAT (selection);

  if (!(FRAMEP (frame) && FRAME_LIVE_P (XFRAME (frame))))
    return build_string ("frame closed");
  if (!WINDOW_LIVE_P (window) || !EQ (WINDOW_FRAME (XWINDOW (window)), frame))
    return build_string ("window closed");
  if (!EQ (XWINDOW (window)->contents, buffer))
    return build_string ("buffer changed");
  if (!(n > 0 && VECTORP (vector) && FIXNATP (items_used)
	&& n < XFIXNAT (items_used) && XFIXNAT (items_used) <= ASIZE (vector)))
    return build_string ("item unavailable");

  Lisp_Object keys = menu_bar_selection_keys (vector, XFIXNAT (items_used), n);
  if (NILP (keys))
    return build_string ("item unavailable");

  specpdl_ref count = SPECPDL_INDEX ();
  record_unwind_current_buffer ();
  record_unwind_protect (restore_selected_window, selected_window);
  Fselect_window (window, Qt);
  bool enabled = menu_bar_item_enabled_p (keys);
  unbind_to (count, Qnil);
  if (!enabled)
    return build_string ("item disabled");

  Fselect_window (window, Qnil);
  find_and_call_menu_selection (XFRAME (frame), XFIXNAT (items_used), vector,
				(void *) (intptr_t) n);
  return Qnil;
}


/* Set menu_items_inuse so no other popup menu or dialog is created.  */

void
mac_menu_set_in_use (bool in_use)
{
  Lisp_Object frames, frame;

  menu_items_inuse = in_use;
  popup_activated_flag = in_use;

  /* Don't let frames in `above' z-group obscure popups.  */
  FOR_EACH_FRAME (frames, frame)
    {
      struct frame *f = XFRAME (frame);

      if (in_use && FRAME_Z_GROUP_ABOVE (f))
	mac_set_z_group (f, Qabove_suspended, Qabove);
      else if (!in_use && FRAME_Z_GROUP_ABOVE_SUSPENDED (f))
	mac_set_z_group (f, Qabove, Qabove_suspended);
    }
}


DEFUN ("mac-update-pending-menu-bars", Fmac_update_pending_menu_bars,
       Smac_update_pending_menu_bars, 0, 0, 0,
       doc: /* Update menu bars whose update was postponed while busy.
Under the persistent event loop, redisplay only notes that a frame's
menu bar needs an update while a command runs, and this function,
called from an idle timer, does it.  Internal use only.  */)
  (void)
{
  Lisp_Object tail, frame;

  /* Menus must not change while displayed; the end of tracking queues
     a `mac-menu-bar-refresh' event that calls this again.  */
  if (mac_menu_bar_tracking_p ())
    {
      mac_note_menu_bar_refresh_needed ();
      return Qnil;
    }
  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_LIVE_P (f) && FRAME_MAC_P (f)
	  && f->output_data.mac->menu_bar_deep_pending)
	set_frame_menubar (f, true);
    }
  return Qnil;
}

/* Serial number of the open-time refresh request being answered, or
0 once it has been.  */
static unsigned long mac_menu_open_refresh_pending;

/* Drop the open-time refresh request SERIAL unless it was answered,
   so that the GUI does not wait for it again after a nonlocal exit.
   The normal path answers it itself: another round trip would wait
   for the GUI thread while it tracks the displayed menu.  */

static void
mac_menu_open_refresh_unwind (Lisp_Object serial)
{
  if (mac_menu_open_refresh_pending == XFIXNAT (serial))
    mac_fill_menu_bar_submenu (XFIXNAT (serial), NULL, 0);
  mac_menu_open_refresh_pending = 0;
}

DEFUN ("mac-menu-bar-refresh-submenu", Fmac_menu_bar_refresh_submenu,
       Smac_menu_bar_refresh_submenu, 3, 3, 0,
       doc: /* Answer the open-time menu refresh request SERIAL.
Under the persistent event loop, the GUI sends a special event when
the user opens the top-level menu at INDEX of the menu bar published
as GENERATION while Emacs waits for input.  Run `menu-bar-update-hook',
expand only that menu and give it to the GUI.  Internal use only.  */)
  (Lisp_Object serial, Lisp_Object generation, Lisp_Object index)
{
  CHECK_FIXNAT (serial);
  CHECK_FIXNAT (generation);
  CHECK_FIXNAT (index);

  Lisp_Object entry = native_menu_snapshot_entry (XFIXNAT (generation));
  Lisp_Object frame = (CONSP (entry) && VECTORP (XCDR (entry))
		       && ASIZE (XCDR (entry)) == NATIVE_MENU_SNAPSHOT_SIZE
		       ? AREF (XCDR (entry), NATIVE_MENU_SNAPSHOT_FRAME)
		       : Qnil);
  struct frame *f = FRAMEP (frame) ? XFRAME (frame) : NULL;

  /* The GUI stops waiting when the request is answered, so answer
     even when there is nothing to fill: a NULL tree drops it.  */
  if (!f || !FRAME_LIVE_P (f) || !FRAME_MAC_P (f)
      || !f->output_data.mac->menubar_widget)
    {
      mac_fill_menu_bar_submenu (XFIXNAT (serial), NULL, 0);
      return Qnil;
    }

  double start = mac_system_uptime ();
  specpdl_ref count = SPECPDL_INDEX ();
  Lisp_Object buffer = XWINDOW (FRAME_SELECTED_WINDOW (f))->contents;

  mac_menu_open_refresh_pending = XFIXNAT (serial);
  record_unwind_protect (mac_menu_open_refresh_unwind, serial);
  /* As the deep update in set_frame_menubar.  */
  XSETFRAME (Vmenu_updating_frame, f);
  specbind (Qinhibit_quit, Qt);
  specbind (Qdebug_on_next_call, Qnil);
  record_unwind_save_match_data ();
  if (NILP (Voverriding_local_map_menu_flag))
    {
      specbind (Qoverriding_terminal_local_map, Qnil);
      specbind (Qoverriding_local_map, Qnil);
    }
  record_unwind_current_buffer ();
  set_buffer_internal_1 (XBUFFER (buffer));
  safe_run_hooks (Qactivate_menubar_hook);
  safe_run_hooks (Qmenu_bar_update_hook);

  /* A fresh vector: the frame's own describes the installed root.  */
  Lisp_Object items = menu_bar_items (Qnil);
  Lisp_Object key = Qnil, string = Qnil, maps = Qnil;
  EMACS_INT n = 0;

  for (ptrdiff_t i = 0; i < ASIZE (items); i += 4)
    {
      if (NILP (AREF (items, i + 1)))
	break;
      if (n++ == XFIXNAT (index))
	{
	  key = AREF (items, i);
	  string = AREF (items, i + 1);
	  maps = AREF (items, i + 2);
	  break;
	}
    }

  enum mac_menu_open_refresh_result result;
  unsigned long new_generation = 0;

  if (NILP (string))
    {
      result = mac_fill_menu_bar_submenu (XFIXNAT (serial), NULL, 0);
      mac_menu_open_refresh_pending = 0;
    }
  else
    {
      save_menu_items ();
      init_menu_items ();
      menu_items_n_panes = 0;
      bool top_level_items = parse_single_submenu (key, string, maps);
      finish_menu_items ();

      /* No Lisp runs from here on, so the string data that the widget
	 values point to stay put.  */
      new_generation = publish_menu_bar_snapshot (f, menu_items,
						  menu_items_used);
      widget_value *wv = digest_single_submenu (0, menu_items_used,
						top_level_items);
      wv->name = SSDATA (string);
      update_submenu_strings (wv->contents);
      block_input ();
      result = mac_fill_menu_bar_submenu (XFIXNAT (serial), wv,
					  new_generation);
      mac_menu_open_refresh_pending = 0;
      unblock_input ();
      free_menubar_widget_value_tree (wv);
    }
  unbind_to (count, Qnil);

  if (result != MAC_MENU_OPEN_REFRESH_APPLIED && new_generation)
    release_native_menu_snapshot (new_generation);
  if (result == MAC_MENU_OPEN_REFRESH_APPLIED
      || result == MAC_MENU_OPEN_REFRESH_DISPLAYED)
    {
      /* The menu bar now differs from, or is behind, the frame's
	 command table.  Rebuild the root, which ends the menu's own
	 generation, once tracking ends.  */
      f->menu_bar_items_used = 0;
      f->output_data.mac->menu_bar_deep_pending = true;
      if (mac_menu_bar_tracking_p ())
	mac_note_menu_bar_refresh_needed ();
      else
	mac_queue_menu_bar_refresh ();
    }
  if (mac_persistent_event_loop_active () && getenv ("EMACS_MAC_TRACE_LOOP"))
    fprintf (stderr, "mac-loop: menu open refresh %"pI"d: result %d, "
	     "%.1f ms in Lisp\n", (EMACS_INT) XFIXNAT (serial), (int) result,
	     (mac_system_uptime () - start) * 1000);
  return Qnil;
}

DEFUN ("mac-menu-bar-open-internal", Fmac_menu_bar_open_internal,
       Smac_menu_bar_open_internal, 0, 1, "i",
       doc: /* Start key navigation of the menu bar in FRAME.
This initially opens the first menu bar item and you can then navigate with the
arrow keys, select a menu entry with the return key or cancel with the
escape key.  If FRAME has no menu bar this function does nothing.

If FRAME is nil or not given, use the selected frame.  */)
  (Lisp_Object frame)
{
  struct frame *f = decode_window_system_frame (frame);

  if (!mac_focus_native_menubar (f))
    mac_activate_menubar (f);

  return Qnil;
}


/* Return true if the first PREVIOUS_USED entries of PREVIOUS, a
   menu-items vector saved as a C array, would show and run the same
   menu bar as the first USED entries of CURRENT.  Under the persistent
   loop every update is a deep rebuild, which conses fresh strings and
   stores each :enable and :selected form's value (for example a list
   of files), so compare strings by their text and those values by
   truthiness.  */

static bool
menu_items_equivalent_p (Lisp_Object *previous, int previous_used,
			 Lisp_Object current, int used)
{
  if (previous_used != used || used == 0)
    return false;

  for (int i = 0; i < used; )
    {
      Lisp_Object old = previous[i], new = AREF (current, i);
      int length;

      if (NILP (new) || EQ (new, Qlambda))
	length = 1;
      else if (EQ (new, Qt))
	length = MENU_ITEMS_PANE_LENGTH;
      else
	length = MENU_ITEMS_ITEM_LENGTH;
      if (i + length > used)
	return false;

      for (int j = 0; j < length; j++)
	{
	  old = previous[i + j];
	  new = AREF (current, i + j);
	  if (EQ (old, new))
	    continue;
	  if (length == MENU_ITEMS_ITEM_LENGTH
	      && (j == MENU_ITEMS_ITEM_ENABLE || j == MENU_ITEMS_ITEM_SELECTED))
	    {
	      if (NILP (old) != NILP (new))
		return false;
	    }
	  else if (!(STRINGP (old) && STRINGP (new)
		     && !NILP (Fstring_equal (old, new))))
	    return false;
	}
      i += length;
    }
  return true;
}

/* Set the contents of the menubar widgets of frame F.  */

void
set_frame_menubar (struct frame *f, bool deep_p)
{
  int menubar_widget = f->output_data.mac->menubar_widget;
  Lisp_Object items;
  widget_value *wv, *first_wv, *prev_wv = 0;
  int i;
  int *submenu_start, *submenu_end;
  int *submenu_top_level_items, *submenu_n_panes;

  eassert (FRAME_MAC_P (f));

  XSETFRAME (Vmenu_updating_frame, f);

  /* The persistent loop does not intercept menu-bar tracking, so it
     publishes the whole tree (D6); a menu opened while Lisp waits for
     input is refreshed alone (D3, mac-menu-bar-refresh-submenu).  A
     deep update costs tens of milliseconds, so while a command runs,
     only note that an update is due and keep the installed menus:
     `mac-update-pending-menu-bars' does it from an idle timer.  Menus
     opened while Lisp is busy are stale meanwhile; selections are
     revalidated when executed (D5).  */
  if (mac_persistent_event_loop_active ())
    {
      if (!deep_p && menubar_widget && NILP (Fcurrent_idle_time ()))
	{
	  f->output_data.mac->menu_bar_deep_pending = true;
	  return;
	}
      deep_p = true;
      f->output_data.mac->menu_bar_deep_pending = false;
    }

  /* This seems to be unnecessary for Carbon.  */
#if 0
  if (! menubar_widget)
    deep_p = true;
#endif

  if (deep_p)
    {
      /* Make a widget-value tree representing the entire menu trees.  */

      struct buffer *prev = current_buffer;
      Lisp_Object buffer;
      specpdl_ref specpdl_count = SPECPDL_INDEX ();
      int previous_menu_items_used = f->menu_bar_items_used;
      Lisp_Object *previous_items
	= alloca (previous_menu_items_used * sizeof *previous_items);
      int subitems;

      /* If we are making a new widget, its contents are empty,
	 do always reinitialize them.  */
      if (! menubar_widget)
	previous_menu_items_used = 0;

      buffer = XWINDOW (FRAME_SELECTED_WINDOW (f))->contents;
      specbind (Qinhibit_quit, Qt);
      /* Don't let the debugger step into this code
	 because it is not reentrant.  */
      specbind (Qdebug_on_next_call, Qnil);

      record_unwind_save_match_data ();
      if (NILP (Voverriding_local_map_menu_flag))
	{
	  specbind (Qoverriding_terminal_local_map, Qnil);
	  specbind (Qoverriding_local_map, Qnil);
	}

      set_buffer_internal_1 (XBUFFER (buffer));

      /* Run the Lucid hook.  */
      safe_run_hooks (Qactivate_menubar_hook);

      /* If it has changed current-menubar from previous value,
	 really recompute the menubar from the value.  */
      safe_run_hooks (Qmenu_bar_update_hook);
      fset_menu_bar_items (f, menu_bar_items (FRAME_MENU_BAR_ITEMS (f)));

      items = FRAME_MENU_BAR_ITEMS (f);

      /* Save the frame's previous menu bar contents data.  */
      if (previous_menu_items_used)
	memcpy (previous_items, xvector_contents (f->menu_bar_vector),
		previous_menu_items_used * word_size);

      /* Fill in menu_items with the current menu bar contents.
	 This can evaluate Lisp code.  */
      save_menu_items ();

      menu_items = f->menu_bar_vector;
      menu_items_allocated = VECTORP (menu_items) ? ASIZE (menu_items) : 0;
      subitems = ASIZE (items) / 4;
      submenu_start = alloca ((subitems + 1) * sizeof *submenu_start);
      submenu_end = alloca (subitems * sizeof *submenu_end);
      submenu_n_panes = alloca (subitems * sizeof *submenu_n_panes);
      submenu_top_level_items = alloca (subitems
					* sizeof *submenu_top_level_items);
      init_menu_items ();
      for (i = 0; i < subitems; i++)
	{
	  Lisp_Object key, string, maps;

	  key = AREF (items, 4 * i);
	  string = AREF (items, 4 * i + 1);
	  maps = AREF (items, 4 * i + 2);
	  if (NILP (string))
	    break;

	  submenu_start[i] = menu_items_used;

	  menu_items_n_panes = 0;
	  submenu_top_level_items[i]
	    = parse_single_submenu (key, string, maps);
	  submenu_n_panes[i] = menu_items_n_panes;

	  submenu_end[i] = menu_items_used;
	}

      submenu_start[i] = -1;
      finish_menu_items ();

      /* Convert menu_items into widget_value trees
	 to display the menu.  This cannot evaluate Lisp code.  */

      wv = make_widget_value ("menubar", NULL, true, Qnil);
      wv->button_type = BUTTON_TYPE_NONE;
      first_wv = wv;

      for (i = 0; submenu_start[i] >= 0; i++)
	{
	  menu_items_n_panes = submenu_n_panes[i];
	  wv = digest_single_submenu (submenu_start[i], submenu_end[i],
				      submenu_top_level_items[i]);
	  if (prev_wv)
	    prev_wv->next = wv;
	  else
	    first_wv->contents = wv;
	  /* Don't set wv->name here; GC during the loop might relocate it.  */
	  wv->enabled = true;
	  wv->button_type = BUTTON_TYPE_NONE;
	  prev_wv = wv;
	}

      set_buffer_internal_1 (prev);

      /* If there has been no change in the Lisp-level contents
	 of the menu bar, skip redisplaying it.  Just exit.  */

      /* Compare the new menu items with the ones computed last time.  */
      if (mac_persistent_event_loop_active ())
	i = (menu_items_equivalent_p (previous_items, previous_menu_items_used,
				      menu_items, menu_items_used)
	     ? menu_items_used : 0);
      else
	for (i = 0; i < previous_menu_items_used; i++)
	  if (menu_items_used == i
	      || (!EQ (previous_items[i], AREF (menu_items, i))))
	    break;
      if (i == menu_items_used && i == previous_menu_items_used && i != 0)
	{
	  /* The menu items have not changed.  Don't bother updating
	     the menus in any form, since it would be a no-op.  */
	  free_menubar_widget_value_tree (first_wv);
	  discard_menu_items ();
	  unbind_to (specpdl_count, Qnil);
	  if (mac_persistent_event_loop_active ())
	    mac_refresh_menu_bar_snapshot (f);
	  return;
	}

      /* The menu items are different, so store them in the frame.  */
      fset_menu_bar_vector (f, menu_items);
      f->menu_bar_items_used = menu_items_used;

      /* This undoes save_menu_items.  */
      unbind_to (specpdl_count, Qnil);

      /* Now GC cannot happen during the lifetime of the widget_value,
	 so it's safe to store data from a Lisp_String.  */
      wv = first_wv->contents;
      for (i = 0; i < ASIZE (items); i += 4)
	{
	  Lisp_Object string;
	  string = AREF (items, i + 1);
	  if (NILP (string))
            break;
          wv->name = SSDATA (string);
          update_submenu_strings (wv->contents);
          wv = wv->next;
	}

    }
  else
    {
      /* Make a widget-value tree containing
	 just the top level menu bar strings.  */

      wv = make_widget_value ("menubar", NULL, true, Qnil);
      wv->button_type = BUTTON_TYPE_NONE;
      first_wv = wv;

      items = FRAME_MENU_BAR_ITEMS (f);
      for (i = 0; i < ASIZE (items); i += 4)
	{
	  Lisp_Object string;

	  string = AREF (items, i + 1);
	  if (NILP (string))
	    break;

	  wv = make_widget_value (SSDATA (string), NULL, true, Qnil);
	  wv->button_type = BUTTON_TYPE_NONE;
	  /* This prevents lwlib from assuming this
	     menu item is really supposed to be empty.  */
	  /* The intptr_t cast avoids a warning.
	     This value just has to be different from small integers.  */
	  wv->call_data = (void *) (intptr_t) (-1);

	  if (prev_wv)
	    prev_wv->next = wv;
	  else
	    first_wv->contents = wv;
	  prev_wv = wv;
	}

      /* Forget what we thought we knew about what is in the
	 detailed contents of the menu bar menus.
	 Changing the top level always destroys the contents.  */
      f->menu_bar_items_used = 0;
    }

  /* Create or update the menu bar widget.  */

  block_input ();

  /* Non-null value to indicate menubar has already been "created".  */
  f->output_data.mac->menubar_widget = 1;

  /* Under the persistent loop, publish a snapshot of the command
     table just stored into F (D4/D5/D16) before filling the GUI menu,
     so that mac_fill_menubar can stamp the generation on the new root
     menu.  A deep fill always installs a new root; a shallow one has
     no items to select.  */
  unsigned long snapshot_generation
    = (deep_p && mac_persistent_event_loop_active ()
       ? mac_publish_menu_bar_snapshot (f) : 0);

  if (!mac_fill_menubar (first_wv->contents, deep_p, snapshot_generation))
    {
      /* The Lisp vector was rebuilt, but AppKit kept the menu it is
	 currently tracking.  Invalidate the comparison cache so the
	 next deep update retries applying these contents, and under
	 the persistent loop let the idle timer do it.  */
      f->menu_bar_items_used = 0;
      if (mac_persistent_event_loop_active ())
	f->output_data.mac->menu_bar_deep_pending = true;
    }

  free_menubar_widget_value_tree (first_wv);

  unblock_input ();
}

/* Get rid of the menu bar of frame F, and free its storage.
   This is used when deleting a frame, and when turning off the menu bar.  */

void
free_frame_menubar (struct frame *f)
{
  f->output_data.mac->menubar_widget = 0;

  /* Retract F's menu-bar snapshots (D16).  Keep each entry and its
     frame so that a queued or still-open selection is rejected as
     "frame closed", but release the command table, window and buffer
     now instead of when the generation is trimmed.  */
  for (Lisp_Object tail = native_menu_snapshots; CONSP (tail);
       tail = XCDR (tail))
    {
      Lisp_Object snapshot = XCDR (XCAR (tail));

      if (VECTORP (snapshot) && ASIZE (snapshot) == NATIVE_MENU_SNAPSHOT_SIZE
	  && FRAMEP (AREF (snapshot, NATIVE_MENU_SNAPSHOT_FRAME))
	  && XFRAME (AREF (snapshot, NATIVE_MENU_SNAPSHOT_FRAME)) == f)
	{
	  ASET (snapshot, NATIVE_MENU_SNAPSHOT_VECTOR, Qnil);
	  ASET (snapshot, NATIVE_MENU_SNAPSHOT_ITEMS_USED, make_fixnum (0));
	  ASET (snapshot, NATIVE_MENU_SNAPSHOT_WINDOW, Qnil);
	  ASET (snapshot, NATIVE_MENU_SNAPSHOT_BUFFER, Qnil);
	}
    }
}


/* Mac_menu_show actually displays a menu using the panes and items in
   menu_items and returns the value selected from it; we assume input
   is blocked by the caller.  */

/* F is the frame the menu is for.
   X and Y are the frame-relative specified position,
   relative to the inside upper left corner of the frame F.
   Bitfield MENUFLAGS bits are:
   MENU_FOR_CLICK is set if this menu was invoked for a mouse click.
   MENU_KEYMAPS is set if this menu was specified with keymaps;
    in that case, we return a list containing the chosen item's value
    and perhaps also the pane's prefix.
   TITLE is the specified menu title.
   ERROR is a place to store an error message string in case of failure.
   (We return nil on failure, but the value doesn't actually matter.)  */

Lisp_Object
mac_menu_show (struct frame *f, int x, int y, int menuflags,
	       Lisp_Object title, const char **error_name)
{
  int i, selection;
  widget_value *wv, *save_wv = 0, *first_wv = 0, *prev_wv = 0;
  widget_value **submenu_stack;
  Lisp_Object *subprefix_stack;
  int submenu_depth = 0;

  USE_SAFE_ALLOCA;

  submenu_stack = SAFE_ALLOCA (menu_items_used
			       * sizeof *submenu_stack);
  subprefix_stack = SAFE_ALLOCA (menu_items_used
				 * sizeof *subprefix_stack);

  eassert (FRAME_MAC_P (f));

  *error_name = NULL;

  if (menu_items_used <= MENU_ITEMS_PANE_LENGTH)
    {
      *error_name = "Empty menu";
      SAFE_FREE ();
      return Qnil;
    }

  if (display_hourglass_p)
    cancel_hourglass ();

  block_input ();

  /* Create a tree of widget_value objects
     representing the panes and their items.  */
  wv = make_widget_value ("menu", NULL, true, Qnil);
  wv->button_type = BUTTON_TYPE_NONE;
  first_wv = wv;
  bool first_pane = true;

  /* Loop over all panes and items, filling in the tree.  */
  i = 0;
  while (i < menu_items_used)
    {
      if (NILP (AREF (menu_items, i)))
	{
	  submenu_stack[submenu_depth++] = save_wv;
	  save_wv = prev_wv;
	  prev_wv = 0;
	  first_pane = true;
	  i++;
	}
      else if (EQ (AREF (menu_items, i), Qlambda))
	{
	  prev_wv = save_wv;
	  save_wv = submenu_stack[--submenu_depth];
	  first_pane = false;
	  i++;
	}
      else if (EQ (AREF (menu_items, i), Qt)
	       && submenu_depth != 0)
	i += MENU_ITEMS_PANE_LENGTH;
      /* Ignore a nil in the item list.
	 It's meaningful only for dialog boxes.  */
      else if (EQ (AREF (menu_items, i), Qquote))
	i += 1;
      else if (EQ (AREF (menu_items, i), Qt))
	{
	  /* Create a new pane.  */
	  Lisp_Object pane_name, prefix;
	  const char *pane_string;

	  pane_name = AREF (menu_items, i + MENU_ITEMS_PANE_NAME);
	  prefix = AREF (menu_items, i + MENU_ITEMS_PANE_PREFIX);

#ifndef HAVE_MULTILINGUAL_MENU
	  if (STRINGP (pane_name) && STRING_MULTIBYTE (pane_name))
	    {
	      pane_name = ENCODE_MENU_STRING (pane_name);
	      ASET (menu_items, i + MENU_ITEMS_PANE_NAME, pane_name);
	    }
#endif
	  pane_string = (NILP (pane_name)
			 ? "" : SSDATA (pane_name));
	  /* If there is just one top-level pane, put all its items directly
	     under the top-level menu.  */
	  if (menu_items_n_panes == 1)
	    pane_string = "";

	  /* If the pane has a meaningful name,
	     make the pane a top-level menu item
	     with its items as a submenu beneath it.  */
	  if (!(menuflags & MENU_KEYMAPS) && strcmp (pane_string, ""))
	    {
	      wv = make_widget_value (pane_string, NULL, true, Qnil);
	      if (save_wv)
		save_wv->next = wv;
	      else
		first_wv->contents = wv;
	      if ((menuflags & MENU_KEYMAPS) && !NILP (prefix))
		wv->name++;
	      wv->button_type = BUTTON_TYPE_NONE;
	      save_wv = wv;
	      prev_wv = 0;
	    }
	  else if (first_pane)
	    {
	      save_wv = wv;
	      prev_wv = 0;
	    }
	  first_pane = false;
	  i += MENU_ITEMS_PANE_LENGTH;
	}
      else
	{
	  /* Create a new item within current pane.  */
	  Lisp_Object item_name, enable, descrip, def, type, selected, help;
	  item_name = AREF (menu_items, i + MENU_ITEMS_ITEM_NAME);
	  enable = AREF (menu_items, i + MENU_ITEMS_ITEM_ENABLE);
	  descrip = AREF (menu_items, i + MENU_ITEMS_ITEM_EQUIV_KEY);
	  def = AREF (menu_items, i + MENU_ITEMS_ITEM_DEFINITION);
	  type = AREF (menu_items, i + MENU_ITEMS_ITEM_TYPE);
	  selected = AREF (menu_items, i + MENU_ITEMS_ITEM_SELECTED);
	  help = AREF (menu_items, i + MENU_ITEMS_ITEM_HELP);

#ifndef HAVE_MULTILINGUAL_MENU
          if (STRINGP (item_name) && STRING_MULTIBYTE (item_name))
	    {
	      item_name = ENCODE_MENU_STRING (item_name);
	      ASET (menu_items, i + MENU_ITEMS_ITEM_NAME, item_name);
	    }

          if (STRINGP (descrip) && STRING_MULTIBYTE (descrip))
	    {
	      descrip = ENCODE_MENU_STRING (descrip);
	      ASET (menu_items, i + MENU_ITEMS_ITEM_EQUIV_KEY, descrip);
	    }
#endif /* not HAVE_MULTILINGUAL_MENU */

	  wv = make_widget_value (SSDATA (item_name), NULL, !NILP (enable),
				  STRINGP (help) ? help : Qnil);
	  if (prev_wv)
	    prev_wv->next = wv;
	  else if (!save_wv)
	    {
	      /* This emacs_abort call pacifies gcc 11.2.1 when Emacs
		 is configured with --enable-gcc-warnings.  FIXME: If
		 save_wv can be null, do something better; otherwise,
		 explain why save_wv cannot be null.  */
	      emacs_abort ();
	    }
	  else
	    save_wv->contents = wv;
	  if (!NILP (descrip))
	    wv->key = SSDATA (descrip);
	  /* Use the contents index as call_data, since we are
             restricted to 16-bits.  */
	  wv->call_data = !NILP (def) ? (void *) (intptr_t) i : 0;

	  if (NILP (type))
	    wv->button_type = BUTTON_TYPE_NONE;
	  else if (EQ (type, QCtoggle))
	    wv->button_type = BUTTON_TYPE_TOGGLE;
	  else if (EQ (type, QCradio))
	    wv->button_type = BUTTON_TYPE_RADIO;
	  else
	    emacs_abort ();

	  wv->selected = !NILP (selected);

	  prev_wv = wv;

	  i += MENU_ITEMS_ITEM_LENGTH;
	}
    }

  /* Deal with the title, if it is non-nil.  */
  if (!NILP (title))
    {
      widget_value *wv_title;
      widget_value *wv_sep = make_widget_value ("--", NULL, false, Qnil);

      wv_sep->next = first_wv->contents;

#ifndef HAVE_MULTILINGUAL_MENU
      if (STRING_MULTIBYTE (title))
	title = ENCODE_MENU_STRING (title);
#endif

      wv_title = make_widget_value (SSDATA (title), NULL, false, Qnil);
      wv_title->button_type = BUTTON_TYPE_NONE;
      wv_title->next = wv_sep;
      first_wv->contents = wv_title;
    }

  /* Actually create and show the menu until popped down.  */
  selection = create_and_show_popup_menu (f, first_wv, x, y,
					  menuflags & MENU_FOR_CLICK);

  /* Free the widget_value objects we used to specify the contents.  */
  free_menubar_widget_value_tree (first_wv);

  /* Find the selected item, and its pane, to return
     the proper value.  */
  if (selection != 0)
    {
      Lisp_Object prefix, entry;

      prefix = entry = Qnil;
      i = 0;
      while (i < menu_items_used)
	{
	  if (NILP (AREF (menu_items, i)))
	    {
	      subprefix_stack[submenu_depth++] = prefix;
	      prefix = entry;
	      i++;
	    }
	  else if (EQ (AREF (menu_items, i), Qlambda))
	    {
	      prefix = subprefix_stack[--submenu_depth];
	      i++;
	    }
	  else if (EQ (AREF (menu_items, i), Qt))
	    {
	      prefix
		= AREF (menu_items, i + MENU_ITEMS_PANE_PREFIX);
	      i += MENU_ITEMS_PANE_LENGTH;
	    }
	  /* Ignore a nil in the item list.
	     It's meaningful only for dialog boxes.  */
	  else if (EQ (AREF (menu_items, i), Qquote))
	    i += 1;
	  else
	    {
	      entry
		= AREF (menu_items, i + MENU_ITEMS_ITEM_VALUE);
	      if (selection == i)
		{
		  if (menuflags & MENU_KEYMAPS)
		    {
		      int j;

		      entry = list1 (entry);
		      if (!NILP (prefix))
			entry = Fcons (prefix, entry);
		      for (j = submenu_depth - 1; j >= 0; j--)
			if (!NILP (subprefix_stack[j]))
			  entry = Fcons (subprefix_stack[j], entry);
		    }
		  unblock_input ();

		  SAFE_FREE ();
		  return entry;
		}
	      i += MENU_ITEMS_ITEM_LENGTH;
	    }
	}
    }
  else if (!(menuflags & MENU_FOR_CLICK))
    {
      unblock_input ();
      /* Make "Cancel" equivalent to C-g.  */
      quit ();
    }

  unblock_input ();

  SAFE_FREE ();
  return Qnil;
}


/* Construct native macOS dialog based on widget_value tree.  */

static const char * button_names [] = {
  "button1", "button2", "button3", "button4", "button5",
  "button6", "button7", "button8", "button9", "button10" };

static void
cleanup_widget_value_tree (void *arg)
{
  free_menubar_widget_value_tree (arg);
}

static Lisp_Object
mac_dialog_show (struct frame *f, Lisp_Object title,
		 Lisp_Object header, const char **error_name)
{
  int i, selection, nb_buttons=0;
  char dialog_name[6];

  widget_value *wv, *first_wv = 0, *prev_wv = 0;

  /* Number of elements seen so far, before boundary.  */
  int left_count = 0;
  /* Whether we've seen the boundary between left-hand elts and right-hand.  */
  bool boundary_seen = false;

  specpdl_ref specpdl_count = SPECPDL_INDEX ();

  eassert (FRAME_MAC_P (f));

  *error_name = NULL;

  if (menu_items_n_panes > 1)
    {
      *error_name = "Multiple panes in dialog box";
      return Qnil;
    }

  /* Create a tree of widget_value objects
     representing the text label and buttons.  */
  {
    Lisp_Object pane_name;
    const char *pane_string;
    pane_name = AREF (menu_items, MENU_ITEMS_PANE_NAME);
    pane_string = (NILP (pane_name)
		   ? "" : SSDATA (pane_name));
    prev_wv = make_widget_value ("message", (char *) pane_string, true, Qnil);
    first_wv = prev_wv;

    /* Loop over all panes and items, filling in the tree.  */
    i = MENU_ITEMS_PANE_LENGTH;
    while (i < menu_items_used)
      {

	/* Create a new item within current pane.  */
	Lisp_Object item_name, enable, descrip;
	item_name = AREF (menu_items, i + MENU_ITEMS_ITEM_NAME);
	enable = AREF (menu_items, i + MENU_ITEMS_ITEM_ENABLE);
	descrip
	  = AREF (menu_items, i + MENU_ITEMS_ITEM_EQUIV_KEY);

	if (NILP (item_name))
	  {
	    free_menubar_widget_value_tree (first_wv);
	    *error_name = "Submenu in dialog items";
	    return Qnil;
	  }
	if (EQ (item_name, Qquote))
	  {
	    /* This is the boundary between left-side elts
	       and right-side elts.  Stop incrementing right_count.  */
	    boundary_seen = true;
	    i++;
	    continue;
	  }
	if (nb_buttons >= 9)
	  {
	    free_menubar_widget_value_tree (first_wv);
	    *error_name = "Too many dialog items";
	    return Qnil;
	  }

	wv = make_widget_value (button_names[nb_buttons],
				SSDATA (item_name),
				!NILP (enable), Qnil);
	prev_wv->next = wv;
	if (!NILP (descrip))
	  wv->key = SSDATA (descrip);
	wv->call_data = (void *) (intptr_t) i;
	  /* menu item is identified by its index in menu_items table */
	prev_wv = wv;

	if (! boundary_seen)
	  left_count++;

	nb_buttons++;
	i += MENU_ITEMS_ITEM_LENGTH;
      }

    /* If the boundary was not specified,
       by default put half on the left and half on the right.  */
    if (! boundary_seen)
      left_count = nb_buttons - nb_buttons / 2;

    wv = make_widget_value (dialog_name, NULL, false, Qnil);

    /*  Frame title: 'Q' = Question, 'I' = Information.
        Can also have 'E' = Error if, one day, we want
        a popup for errors. */
    if (NILP (header))
      dialog_name[0] = 'Q';
    else
      dialog_name[0] = 'I';

    /* Dialog boxes use a really stupid name encoding
       which specifies how many buttons to use
       and how many buttons are on the right. */
    dialog_name[1] = '0' + nb_buttons;
    dialog_name[2] = 'B';
    dialog_name[3] = 'R';
    /* Number of buttons to put on the right.  */
    dialog_name[4] = '0' + nb_buttons - left_count;
    dialog_name[5] = 0;
    wv->contents = first_wv;
    first_wv = wv;
  }

  /* Make sure to free the widget_value objects we used to specify the
     contents even with longjmp.  */
  record_unwind_protect_ptr (cleanup_widget_value_tree, first_wv);

  /* Actually create and show the dialog.  */
  selection = create_and_show_dialog (f, first_wv);

  unbind_to (specpdl_count, Qnil);

  /* Find the selected item, and its pane, to return
     the proper value.  */
  if (selection != 0)
    {
      i = 0;
      while (i < menu_items_used)
	{
	  Lisp_Object entry;

	  if (EQ (AREF (menu_items, i), Qt))
	    i += MENU_ITEMS_PANE_LENGTH;
	  else if (EQ (AREF (menu_items, i), Qquote))
	    {
	      /* This is the boundary between left-side elts and
		 right-side elts.  */
	      ++i;
	    }
	  else
	    {
	      entry
		= AREF (menu_items, i + MENU_ITEMS_ITEM_VALUE);
	      if (selection == i)
		return entry;
	      i += MENU_ITEMS_ITEM_LENGTH;
	    }
	}
    }
  else
    /* Make "Cancel" equivalent to C-g.  */
    quit ();

  return Qnil;
}

Lisp_Object
mac_popup_dialog (struct frame *f, Lisp_Object header, Lisp_Object contents)
{
  Lisp_Object title;
  const char *error_name;
  Lisp_Object selection;
  specpdl_ref specpdl_count = SPECPDL_INDEX ();

  check_window_system (f);

  /* Decode the dialog items from what was specified.  */
  title = Fcar (contents);
  CHECK_STRING (title);
  record_unwind_protect_void (unuse_menu_items);

  list_of_panes (list1 (contents));

  /* Display them in a dialog box.  */
  block_input ();
  selection = mac_dialog_show (f, title, header, &error_name);
  unblock_input ();

  unbind_to (specpdl_count, Qnil);
  discard_menu_items ();

  if (error_name) error ("%s", error_name);
  return selection;
}



/* Is this item a separator? */
bool
name_is_separator (const char *name)
{
  const char *start = name;

  /* Check if name string consists of only dashes ('-').  */
  while (*name == '-') name++;
  /* Separators can also be of the form "--:TripleSuperMegaEtched"
     or "--deep-shadow".  We don't implement them yet, se we just treat
     them like normal separators.  */
  return (*name == '\0' || start + 2 == name);
}

/* Detect if a menu is currently active.  */

int
popup_activated (void)
{
  return popup_activated_flag;
}

/* The following is used by delayed window autoselection.  */

DEFUN ("menu-or-popup-active-p", Fmenu_or_popup_active_p, Smenu_or_popup_active_p, 0, 0, 0,
       doc: /* Return t if a menu or popup dialog is active.
\(On MS Windows, this refers to the selected frame.)  */)
  (void)
{
  return (popup_activated ()) ? Qt : Qnil;
}

void
syms_of_macmenu (void)
{
  staticpro (&native_menu_snapshots);
  native_menu_snapshots = Qnil;
  DEFSYM (Qdebug_on_next_call, "debug-on-next-call");
  defsubr (&Smenu_or_popup_active_p);

  defsubr (&Smac_menu_bar_open_internal);
  defsubr (&Smac_menu_bar_execute_selection);
  defsubr (&Smac_update_pending_menu_bars);
  defsubr (&Smac_menu_bar_refresh_submenu);
  DEFSYM (Qmac_menu_bar_selection, "mac-menu-bar-selection");
  DEFSYM (Qmac_menu_bar_refresh, "mac-menu-bar-refresh");
  DEFSYM (Qmac_menu_bar_open_refresh, "mac-menu-bar-open-refresh");
  Ffset (intern_c_string ("accelerate-menu"),
	 intern_c_string (Smac_menu_bar_open_internal.s.symbol_name));

  DEFVAR_LISP ("mac-help-topics", Vmac_help_topics,
    doc: /* List of strings shown as Help topics by Help menu search.
Each element should be a unibyte string in UTF-8.  The special value t
means not to recalculate help topics.  */);
  Vmac_help_topics = Qt;

  DEFVAR_BOOL ("mac-popup-menu-add-contextual-menu",
	       mac_popup_menu_add_contextual_menu,
    doc: /* Non-nil means contextual menu is added to popup menu.  */);
  mac_popup_menu_add_contextual_menu = 0;
}

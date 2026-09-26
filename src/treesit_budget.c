/* Budgeted tree-sitter parsing.

Copyright (C) 2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

/* Fork-local.  treesit.c calls into this file through a few narrow
   hooks, listed under "Budgeted tree-sitter parsing" in AGENTS.md, so
   that syncs with GNU master touch as little of treesit.c as possible.

   Every parse is timed.  A parse that runs past
   treesit-budget-parse-limit is halted, and its parser gives up: from
   then on it parses an empty input instead of the buffer, so that a
   pathological grammar or input cannot freeze Emacs again at every
   edit.  Readers of the tree, such as font-lock, indentation and
   syntax-ppss, then find nothing but raise no errors.
   treesit-budget-retry lets the parser try again.  */

#include <config.h>

#include "lisp.h"
#include "treesit.h"

#if HAVE_TREE_SITTER && !defined WINDOWSNT

#include <time.h>

/* Parse statistics since the last reset.  A first parse has no
   previous tree; the other fields cover only reparses.  OVER[I] counts
   the reparses that took longer than OVER_LIMITS[I] seconds.  */
static const double over_limits[] = { 0.001, 0.003, 0.008 };
static struct
{
  uintmax_t parses;
  uintmax_t first_parses;
  double first_seconds;
  double first_max_seconds;
  double seconds;
  double max_seconds;
  uintmax_t progress_calls;
  uintmax_t halts;
  uintmax_t over[countof (over_limits)];
} stats;

static double
monotonic_seconds (void)
{
  struct timespec now;
  clock_gettime (CLOCK_MONOTONIC, &now);
  return now.tv_sec + now.tv_nsec / 1e9;
}

#if TREE_SITTER_LANGUAGE_VERSION >= 15
/* Tree-sitter calls this about every 100 parse operations; returning
   true halts the parse.  The payload points to the time at which to
   halt, or is NULL for no limit.  It must not call Lisp, check for
   quits or read input.  */
static bool
parse_progress (TSParseState *state)
{
  stats.progress_calls++;
  double *deadline = state->payload;
  return deadline && *deadline < monotonic_seconds ();
}
#endif

static const char *
read_nothing (void *payload, uint32_t byte_index, TSPoint position,
	      uint32_t *bytes_read)
{
  *bytes_read = 0;
  return "";
}

/* Return PARSER's tree for an empty input, the tree of a parser that
   has given up.  */
static TSTree *
parse_nothing (TSParser *parser)
{
  TSInput input = { NULL, read_nothing, TSInputEncodingUTF8 };
  return ts_parser_parse (parser, NULL, input);
}

/* Give up on LISP_PARSER after its parser PARSER halted.  */
static void
give_up (struct Lisp_TS_Parser *lisp_parser, TSParser *parser)
{
  /* A halted parse would otherwise resume at the next call.  */
  ts_parser_reset (parser);
  lisp_parser->budget_gave_up = true;
  stats.halts++;
  CALLN (Fmessage,
	 build_string ("Tree-sitter parse of %s stopped after %s s,"
		       " parser disabled; M-x treesit-budget-retry"
		       " to try again"),
	 BVAR (XBUFFER (lisp_parser->buffer), name),
	 Vtreesit_budget_parse_limit);
}

/* Parse PARSER's input incrementally from OLD_TREE, like
   ts_parser_parse, and record the parse in the statistics.  PARSER
   belongs to LISP_PARSER.  If LISP_PARSER has given up, or gives up
   now because the parse runs past the limit, return the tree of an
   empty input.  */
TSTree *
treesit_budget_parse (struct Lisp_TS_Parser *lisp_parser, TSParser *parser,
		      const TSTree *old_tree, TSInput input)
{
  if (lisp_parser->budget_gave_up)
    return parse_nothing (parser);

  double start = monotonic_seconds ();
#if TREE_SITTER_LANGUAGE_VERSION >= 15
  double deadline;
  bool limited = NUMBERP (Vtreesit_budget_parse_limit);
  if (limited)
    deadline = start + XFLOATINT (Vtreesit_budget_parse_limit);
  TSParseOptions options = { .payload = limited ? &deadline : NULL,
			     .progress_callback = parse_progress };
  TSTree *tree
    = ts_parser_parse_with_options (parser, old_tree, input, options);
#else
  TSTree *tree = ts_parser_parse (parser, old_tree, input);
#endif
  double seconds = monotonic_seconds () - start;

#if TREE_SITTER_LANGUAGE_VERSION >= 15
  if (!tree && limited)
    {
      give_up (lisp_parser, parser);
      tree = parse_nothing (parser);
    }
#endif

  stats.parses++;
  if (!old_tree)
    {
      stats.first_parses++;
      stats.first_seconds += seconds;
      if (stats.first_max_seconds < seconds)
	stats.first_max_seconds = seconds;
      return tree;
    }
  stats.seconds += seconds;
  if (stats.max_seconds < seconds)
    stats.max_seconds = seconds;
  for (int i = 0; i < countof (over_limits); i++)
    stats.over[i] += over_limits[i] < seconds;
  return tree;
}

#endif	/* HAVE_TREE_SITTER && !WINDOWSNT */

DEFUN ("treesit-budget-gave-up-p", Ftreesit_budget_gave_up_p,
       Streesit_budget_gave_up_p, 1, 1, 0,
       doc: /* Return non-nil if PARSER has given up parsing.
A parser gives up when a parse runs longer than
`treesit-budget-parse-limit'.  Until `treesit-budget-retry' is called,
it then parses an empty input instead of its buffer, so its tree has
no nodes but the root.  */)
  (Lisp_Object parser)
{
#if HAVE_TREE_SITTER
  CHECK_TS_PARSER (parser);
  return XTS_PARSER (parser)->budget_gave_up ? Qt : Qnil;
#else
  return Qnil;
#endif
}

DEFUN ("treesit-budget-retry", Ftreesit_budget_retry,
       Streesit_budget_retry, 0, 1, "",
       doc: /* Let the tree-sitter parsers of BUFFER that gave up parse again.
BUFFER defaults to the current buffer.  A parser gives up when a parse
runs longer than `treesit-budget-parse-limit'; raise the limit first if
the parse needs more time.  Return the number of parsers that had given
up.  */)
  (Lisp_Object buffer)
{
  intmax_t count = 0;
#if HAVE_TREE_SITTER
  if (NILP (buffer))
    XSETBUFFER (buffer, current_buffer);
  CHECK_BUFFER (buffer);
  struct buffer *base = XBUFFER (buffer);
  if (base->base_buffer)
    base = base->base_buffer;
  for (Lisp_Object tail = BVAR (base, ts_parser_list);
       CONSP (tail); tail = XCDR (tail))
    {
      struct Lisp_TS_Parser *p = XTS_PARSER (XCAR (tail));
      if (!p->budget_gave_up)
	continue;
      p->budget_gave_up = false;
      /* The tree of the empty input is no base for an incremental
	 parse; parse from scratch, as for a new parser.  The new
	 timestamp outdates the nodes of the dropped tree, as a reparse
	 does.  */
      if (p->tree)
	ts_tree_delete (p->tree);
      p->tree = NULL;
      p->need_reparse = true;
      p->timestamp++;
      count++;
    }
  /* Text fontified while the parser had given up got no tree-sitter
     faces; fontify it again.  */
  if (count && BUFFER_LIVE_P (XBUFFER (buffer)))
    {
      specpdl_ref specpdl_count = SPECPDL_INDEX ();
      record_unwind_current_buffer ();
      set_buffer_internal (XBUFFER (buffer));
      safe_calln (Qfont_lock_flush);
      unbind_to (specpdl_count, Qnil);
    }
#endif
  return make_int (count);
}

DEFUN ("treesit-budget-stats", Ftreesit_budget_stats,
       Streesit_budget_stats, 0, 1, 0,
       doc: /* Return tree-sitter parse statistics as a plist.
If optional RESET is non-nil, reset the statistics after reading them.

:parses is the number of parses since the last reset.  :first-parses
counts those that had no previous tree, such as the parse when a file
is visited; :first-seconds is their total time and :first-max-seconds
the longest.  The other entries cover only reparses: :seconds is their
total time, :max-seconds the longest, and :over-1ms, :over-3ms and
:over-8ms count the reparses that took longer than 1, 3 and 8 ms.
:progress-calls counts the calls of the progress callback, which
tree-sitter makes about every 100 parse operations from ABI 15 on.
:halts counts the parses stopped by `treesit-budget-parse-limit'.  All
are zero where parses are not timed (MS-Windows).  */)
  (Lisp_Object reset)
{
#if HAVE_TREE_SITTER && !defined WINDOWSNT
  Lisp_Object result
    = list (QCparses, make_uint (stats.parses),
	    QCfirst_parses, make_uint (stats.first_parses),
	    QCfirst_seconds, make_float (stats.first_seconds),
	    QCfirst_max_seconds, make_float (stats.first_max_seconds),
	    QCseconds, make_float (stats.seconds),
	    QCmax_seconds, make_float (stats.max_seconds),
	    QCprogress_calls, make_uint (stats.progress_calls),
	    QChalts, make_uint (stats.halts),
	    QCover_1ms, make_uint (stats.over[0]),
	    QCover_3ms, make_uint (stats.over[1]),
	    QCover_8ms, make_uint (stats.over[2]));
  if (!NILP (reset))
    memset (&stats, 0, sizeof stats);
  return result;
#else
  return list (QCparses, make_fixnum (0),
	       QCfirst_parses, make_fixnum (0),
	       QCfirst_seconds, make_float (0),
	       QCfirst_max_seconds, make_float (0),
	       QCseconds, make_float (0),
	       QCmax_seconds, make_float (0),
	       QCprogress_calls, make_fixnum (0),
	       QChalts, make_fixnum (0),
	       QCover_1ms, make_fixnum (0),
	       QCover_3ms, make_fixnum (0),
	       QCover_8ms, make_fixnum (0));
#endif
}

void
syms_of_treesit_budget (void)
{
  DEFSYM (QCparses, ":parses");
  DEFSYM (QCfirst_parses, ":first-parses");
  DEFSYM (QCfirst_seconds, ":first-seconds");
  DEFSYM (QCfirst_max_seconds, ":first-max-seconds");
  DEFSYM (QCseconds, ":seconds");
  DEFSYM (QCmax_seconds, ":max-seconds");
  DEFSYM (QCprogress_calls, ":progress-calls");
  DEFSYM (QCover_1ms, ":over-1ms");
  DEFSYM (QCover_3ms, ":over-3ms");
  DEFSYM (QCover_8ms, ":over-8ms");
  DEFSYM (QChalts, ":halts");
  DEFSYM (Qfont_lock_flush, "font-lock-flush");
  defsubr (&Streesit_budget_stats);
  defsubr (&Streesit_budget_gave_up_p);
  defsubr (&Streesit_budget_retry);

  DEFVAR_LISP ("treesit-budget-parse-limit", Vtreesit_budget_parse_limit,
	       doc: /* Seconds after which a tree-sitter parse is stopped, or nil.
A parse that runs longer, which only a faulty grammar or a pathological
input should cause, is stopped and its parser gives up: until
\\[treesit-budget-retry] is used, it parses an empty input instead of its
buffer, so that tree-sitter fontification, indentation and navigation
find nothing in the buffer.  nil means no limit.  The limit needs
tree-sitter 0.25 or later; it is ignored on MS-Windows.  */);
  Vtreesit_budget_parse_limit = make_float (2.0);
}

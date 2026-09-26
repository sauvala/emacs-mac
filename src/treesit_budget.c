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
   Stage 1 only counts and times parses; nothing halts.  */

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
   true would halt the parse.  It must not call Lisp, check for quits
   or read input.  */
static bool
parse_progress (TSParseState *state)
{
  stats.progress_calls++;
  return false;
}
#endif

/* Parse PARSER's input incrementally from OLD_TREE, like
   ts_parser_parse, and record the parse in the statistics.  */
TSTree *
treesit_budget_parse (TSParser *parser, const TSTree *old_tree,
		      TSInput input)
{
  double start = monotonic_seconds ();
#if TREE_SITTER_LANGUAGE_VERSION >= 15
  TSParseOptions options = { .progress_callback = parse_progress };
  TSTree *tree
    = ts_parser_parse_with_options (parser, old_tree, input, options);
#else
  TSTree *tree = ts_parser_parse (parser, old_tree, input);
#endif
  double seconds = monotonic_seconds () - start;

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
tree-sitter makes about every 100 parse operations from ABI 15 on.  All
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
  defsubr (&Streesit_budget_stats);
}

#!/bin/bash
# Print the indentation guide glyphs Emacs produces for a piece of text.
#
# Redisplay does not run in batch mode, and dump-glyph-matrix writes to
# stderr rather than returning a value, so guide placement cannot be
# asserted from ERT in batch.  This script drives a real Emacs, renders
# one buffer, and reports the guide glyphs found in the glyph matrix,
# which is enough to check columns, depths and preserved buffer
# positions from a shell.
#
# Requires a build configured with --enable-checking=yes,glyphs, so that
# dump-glyph-matrix is available and the glyph assertions are live.
#
# Usage:
#   test/manual/indent-guides-probe.sh SETUP TEXT [HSCROLL]
#
# SETUP is Lisp evaluated in the buffer, TEXT is a Lisp string.
#
# Examples:
#   test/manual/indent-guides-probe.sh '(ignore)' '"        foo\n"'
#   test/manual/indent-guides-probe.sh '(setq-local tab-width 4)' '"\t\tfoo\n"'
#   test/manual/indent-guides-probe.sh '(setq-local auto-hscroll-mode nil)' \
#       '"                    foo\n"' 10
#
# Output is one line per guide glyph:
#   hpos=N charpos=N depth=N
#
# dump_glyph prints indentation guides with type 'V' and the guide depth
# in the Code column.

set -u

if [ $# -lt 2 ]; then
  sed -n '2,30p' "$0"
  exit 1
fi

setup="$1"
text="$2"
hscroll="${3:-0}"

emacs="${EMACS:-./src/emacs}"

"$emacs" -Q --eval "(progn
  (with-current-buffer (get-buffer-create \"*indent-guides-probe*\")
    (insert $text)
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    $setup
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min))
    (set-window-hscroll (selected-window) $hscroll)
    (redisplay t)
    (dump-glyph-matrix 2))
  (kill-emacs 0))" 2>&1 \
  | awk '$2 == "V" { d = $6; sub(/^0x0*/, "", d); if (d == "") d = "0";
                     printf "hpos=%s charpos=%s depth=%s\n", $1, $3, d }'

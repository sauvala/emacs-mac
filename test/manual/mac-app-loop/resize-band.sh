#!/bin/sh
# Record a scripted 8 ms-step drag and measure the undrawn band at the
# growing edge (ticket 18).  Usage: resize-band.sh [WAIT_MS...]
# Each WAIT_MS is passed as EMACS_MAC_RESIZE_WAIT_MS (0 disables
# synchronous presentation); default "0 30".  Needs screen recording
# permission for the terminal, ffmpeg, and a visible desktop below the
# window's start position.
set -u
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
app=${EMACS_APP:-"$repo_root/mac/Emacs.app"}
out=${TMPDIR:-/tmp}/mac-app-loop
mkdir -p "$out"
for w in ${*:-0 30}; do
  rec="$out/resize-band-$w.mov"; rm -f "$rec"
  EMACS_MAC_RESIZE_WAIT_MS=$w \
    "$app/Contents/MacOS/Emacs" -Q -l "$script_dir/resize-band.el" 2>/dev/null &
  pid=$!
  sleep 2.6
  screencapture -x -v -V 3 "$rec" >/dev/null 2>&1
  wait $pid
  echo "wait $w ms: $(python3 "$script_dir/resize-band.py" "$rec")"
done

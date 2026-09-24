#!/bin/sh
# Run scripted persistent-loop scenarios in fresh GUI processes.
# Usage: run-scenarios.sh [old|new|both] [scenario...]
# Results: $MAC_LOOP_RESULTS_DIR (default ${TMPDIR:-/tmp}/mac-app-loop/results)/<scenario>-<mode>.eld
set -u
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
app=${EMACS_APP:-"$repo_root/mac/Emacs.app"}
bin="$app/Contents/MacOS/Emacs"
out="${MAC_LOOP_RESULTS_DIR:-${TMPDIR:-/tmp}/mac-app-loop/results}"
mkdir -p "$out"
modes=${1:-both}; [ $# -gt 0 ] && shift
[ "$modes" = both ] && modes="old new"
scenarios=${*:-"idle-typing busy-typing quit busy-native idle-resize live-resize close-busy stress-requests thread-busy fullscreen-idle fullscreen-busy menu-idle menu-busy menu-stale win-close-dedupe win-close-indicator win-quit-idle win-quit-dedupe"}
if [ ! -d "$app/Contents/Resources/lisp" ]; then
  EMACSLOADPATH="$repo_root/lisp"; export EMACSLOADPATH
fi
for mode in $modes; do
  case $mode in old) v=0 ;; new) v=1 ;; *) echo "bad mode $mode" >&2; exit 2 ;; esac
  for s in $scenarios; do
    result="$out/$s-$mode.eld"; rm -f "$result"
    EMACS_MAC_PERSISTENT_LOOP=$v EMACS_MAC_TRACE_LOOP=1 MAC_LOOP_RESULT="$result" \
      timeout 60 "$bin" -Q -l "$script_dir/scenarios.el" \
      --eval "(mac-loop-scenario-run '$s)" 2>"$out/$s-$mode.stderr"
    status=$?
    if [ -f "$result" ]; then echo "$s/$mode: exit $status, $result"
    else echo "$s/$mode: exit $status, NO RESULT (see $out/$s-$mode.stderr)"; fi
  done
done

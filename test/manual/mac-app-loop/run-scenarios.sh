#!/bin/sh
# Run scripted persistent-loop scenarios in fresh GUI processes.
# Usage: run-scenarios.sh [scenario...]
# Results: $MAC_LOOP_RESULTS_DIR (default ${TMPDIR:-/tmp}/mac-app-loop/results)/<scenario>.eld
set -u
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
app=${EMACS_APP:-"$repo_root/mac/Emacs.app"}
bin="$app/Contents/MacOS/Emacs"
out="${MAC_LOOP_RESULTS_DIR:-${TMPDIR:-/tmp}/mac-app-loop/results}"
mkdir -p "$out"
scenarios=${*:-"idle-typing busy-typing quit busy-native idle-scroll busy-scroll idle-resize live-resize resize-burst busy-resize-layer idle-resize-layer stalled-resize-layer text-idle text-busy menu-tracking-update menu-open-refresh close-busy stress-requests thread-busy fullscreen-idle fullscreen-busy menu-idle menu-busy menu-stale menu-disabled menu-nested menu-frame-deleted win-close-dedupe win-close-indicator win-quit-idle win-quit-dedupe"}
if [ ! -d "$app/Contents/Resources/lisp" ]; then
  EMACSLOADPATH="$repo_root/lisp"; export EMACSLOADPATH
fi
for s in $scenarios; do
  result="$out/$s.eld"; rm -f "$result"
  EMACS_MAC_TRACE_LOOP=1 MAC_LOOP_RESULT="$result" \
    timeout 60 "$bin" -Q -l "$script_dir/scenarios.el" \
    --eval "(mac-loop-scenario-run '$s)" 2>"$out/$s.stderr"
  status=$?
  if [ -f "$result" ]; then echo "$s: exit $status, $result"
  else echo "$s: exit $status, NO RESULT (see $out/$s.stderr)"; fi
done

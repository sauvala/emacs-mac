#!/bin/sh
# run.sh - launch the mac-app-loop S0 fixture in the old or new event loop.
#
# Usage: run.sh [old|new] [extra emacs args...]
#
#   old   EMACS_MAC_PERSISTENT_LOOP=0 (unset also means old; this makes the
#         choice explicit in the log and the invocation)
#   new   EMACS_MAC_PERSISTENT_LOOP=1
#
# With no mode argument, defaults to "old".
#
# Always sets EMACS_MAC_TRACE_LOOP=1 so C traces ("mac-loop:" lines, added
# separately) go to stderr, and MAC_APP_LOOP_LOG to a fresh scratch path so
# each run gets its own Lisp-level log alongside its own stderr capture.
#
# Env overrides:
#   EMACS_APP   - path to the .app bundle to launch
#                 (default: $REPO/mac/Emacs.app, where $REPO is this
#                 checkout's root, found from this script's location)
#
# This is fork-local test tooling (see AGENTS.md); no upstream contribution
# policy applies to it.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)

mode=${1:-old}
if [ "$#" -ge 1 ]; then
    shift
fi

case "$mode" in
    old)
        persistent_loop=0
        ;;
    new)
        persistent_loop=1
        ;;
    *)
        echo "run.sh: unknown mode '$mode' (expected 'old' or 'new')" >&2
        echo "usage: run.sh [old|new] [extra emacs args...]" >&2
        exit 2
        ;;
esac

app=${EMACS_APP:-"$repo_root/mac/Emacs.app"}
emacs_bin="$app/Contents/MacOS/Emacs"

if [ ! -x "$emacs_bin" ]; then
    echo "run.sh: no executable Emacs found at $emacs_bin" >&2
    echo "run.sh: build it, or set EMACS_APP to point at a built bundle" >&2
    exit 1
fi

# AGENTS.md: a self-contained build (Contents/Resources/lisp present) needs
# no EMACSLOADPATH; a plain development build does, pointed at this
# checkout's own lisp directory.
loadpath_args=""
if [ ! -d "$app/Contents/Resources/lisp" ]; then
    EMACSLOADPATH="$repo_root/lisp"
    export EMACSLOADPATH
    loadpath_args=" (EMACSLOADPATH=$EMACSLOADPATH)"
fi

scratch_dir="${TMPDIR:-/tmp}/mac-app-loop"
mkdir -p "$scratch_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log_file="$scratch_dir/${stamp}-${mode}.log"
stderr_file="$scratch_dir/${stamp}-${mode}.stderr"

EMACS_MAC_PERSISTENT_LOOP=$persistent_loop
EMACS_MAC_TRACE_LOOP=1
MAC_APP_LOOP_LOG=$log_file
export EMACS_MAC_PERSISTENT_LOOP EMACS_MAC_TRACE_LOOP MAC_APP_LOOP_LOG

echo "run.sh: mode=$mode EMACS_MAC_PERSISTENT_LOOP=$persistent_loop"
echo "run.sh: app=$app$loadpath_args"
echo "run.sh: lisp log:   $log_file"
echo "run.sh: stderr log: $stderr_file"

exec "$emacs_bin" -Q -l "$script_dir/fixture.el" -f mac-app-loop-start "$@" 2>"$stderr_file"

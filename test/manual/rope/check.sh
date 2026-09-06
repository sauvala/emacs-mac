#!/bin/sh
# Run the standalone rope tests without a working Emacs executable.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/emacs-rope-test.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
: > "$build/config.h"
"${CC:-cc}" -std=c11 -O1 -g -fsanitize=address,undefined \
  -I"$build" -I"$root/src" "$root/test/manual/rope/rope-tests.c" \
  "$root/src/rope.c" "$root/src/rope_node.c" \
  "$root/src/rope_node_edit.c" "$root/src/rope_chunk.c" \
  "$root/src/rope_summary.c" "$root/src/rope_utf8.c" \
  "$root/src/rope_cursor.c" -o "$build/rope-tests"
"$build/rope-tests"

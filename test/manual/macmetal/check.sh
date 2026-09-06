#!/bin/sh
# Native offscreen GPU regression test; requires macOS and a Metal device.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/emacs-metal-test.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
printf '#define USE_METAL_RENDERING 1\n' > "$build/config.h"
"${CC:-clang}" -fobjc-arc -fblocks -I"$build" \
  -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
  -framework CoreText "$root/test/manual/macmetal/blending.m" -o "$build/blending"
"$build/blending"

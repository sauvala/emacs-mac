#!/bin/sh
# Build the mac port with profile-guided optimization and ThinLTO.
#
# Usage, from the top of the source tree, after ./autogen.sh:
#
#   CFLAGS="-O2 -mcpu=native" mac/pgo-build.sh [CONFIGURE-ARGUMENT...]
#
# 1. Configure with the given arguments plus --without-native-compilation
#    and -fprofile-instr-generate, and build an instrumented Emacs.
# 2. Train it: the GUI benchmark harness (all scenarios and key latency),
#    the redisplay benchmark, and batch fontification.  This opens Emacs
#    windows for several minutes; it needs a logged-in GUI session.
# 3. Merge the profiles into mac/pgo/emacs.profdata.
# 4. Configure with the given arguments, -fprofile-instr-use and
#    -flto=thin, and build again.  Install as usual afterwards.
#
# Set PGO_PROFILE to an existing .profdata file to skip steps 1-3.
# The profile only describes the C code; native-compiled Lisp is not
# affected.  See docs/nemesis-performance-roadmap.md, item 11.

set -eu

top=$(pwd)
[ -f "$top/src/emacs.c" ] || { echo "run from the top of the tree" >&2; exit 1; }
pgo="$top/mac/pgo"
base_cflags=${CFLAGS:--O2}
base_ldflags=${LDFLAGS:-}
jobs=$(sysctl -n hw.ncpu)
profdata=${PGO_PROFILE:-$pgo/emacs.profdata}
emacs="$top/mac/Emacs.app/Contents/MacOS/Emacs"
mkdir -p "$pgo"

if [ -z "${PGO_PROFILE:-}" ]; then
  echo "pgo: instrumented build"
  ./configure "$@" --without-native-compilation \
    CFLAGS="$base_cflags -fprofile-instr-generate" \
    LDFLAGS="$base_ldflags -fprofile-instr-generate" > "$pgo/configure-1.log" 2>&1
  make clean > /dev/null
  # Profiles written while building are not part of the training.
  LLVM_PROFILE_FILE="$pgo/build-%p.profraw" make -j"$jobs" > "$pgo/build-1.log" 2>&1
  rm -f "$pgo"/build-*.profraw "$pgo"/train-*.profraw

  echo "pgo: training"
  EMACSLOADPATH="$top/lisp"
  LLVM_PROFILE_FILE="$pgo/train-%p.profraw"
  export EMACSLOADPATH LLVM_PROFILE_FILE
  out=$(mktemp -d)
  "$emacs" -Q -l "$top/test/src/mac-performance-benchmark.el" \
    --eval "(mac-performance-run-benchmarks-and-exit \"$out/bench.eld\" 40)" \
    2> /dev/null || echo "pgo: harness failed" >&2
  REPO="$top" PERF_OUT="$out/perf.eld" "$emacs" -Q \
    -l "$top/test/manual/redisplay-bench/perf.el" --eval '(perf-run)' \
    2> /dev/null || echo "pgo: perf.el failed" >&2
  "$emacs" -Q --batch --eval "
(dolist (f '(\"src/xdisp.c\" \"src/keyboard.c\" \"lisp/simple.el\"
             \"lisp/files.el\"))
  (with-current-buffer (find-file-noselect (expand-file-name f \"$top\"))
    (font-lock-mode 1)
    (font-lock-ensure)
    (kill-buffer)))" 2> /dev/null || echo "pgo: batch training failed" >&2
  rm -rf "$out"
  unset LLVM_PROFILE_FILE

  echo "pgo: merging profiles"
  xcrun llvm-profdata merge -output="$profdata" "$pgo"/train-*.profraw
fi

echo "pgo: optimized build"
./configure "$@" \
  CFLAGS="$base_cflags -fprofile-instr-use=$profdata -flto=thin -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date" \
  LDFLAGS="$base_ldflags -flto=thin" > "$pgo/configure-2.log" 2>&1
make clean > /dev/null
make -j"$jobs" > "$pgo/build-2.log" 2>&1
echo "pgo: done; profile in $profdata"

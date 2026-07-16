# Emacs Mac Performance Handoff

This branch is for incremental, measured responsiveness and rendering work in
the emacs-mac fork.

## Current Context

- Worktree: `/Users/janne/.codex/worktrees/bb3c/emacs-mac`
- Branch: `codex/responsive-coding-bb3c`
- Remote push target: `fork/codex/responsive-coding-bb3c`
- Primary backlog: `docs/emacs-mac-performance-findings.md`
- Broader idea bank: `docs/emacs-mac-snappiness-optimization-ideas.md`

Keep this work in a persistent worktree.  Do not move active work to `/tmp` or
`/private/tmp`.

## Operating Rule

For each slice:

1. Inspect the current branch state and the backlog before choosing work.
2. Pick the item with the highest expected responsiveness or rendering benefit.
3. Implement a narrow, independently reviewable change.
4. Measure the effect with the most relevant benchmark or source invariant.
5. Commit and push only changes that are correct and either improve performance,
   improve measurement quality, or unblock a higher-value measurement.
6. Update `docs/emacs-mac-performance-findings.md` with what was learned.

Do not claim "parallel Elisp" broadly without checking the runtime model.  Lisp
threads are pthread-backed, but Lisp execution is still serialized by
`global_lock`.

## Current Top Priorities

The current prioritized list lives in
`docs/emacs-mac-performance-findings.md`, especially the `Still open` and
`Suggested Order` sections.

As of this handoff, the next best work is:

1. Finish hardening the presenter-queue Metal presentation prototype.
   Add a final-frame or visual correctness check for async presentation, then
   repeat the GUI Metal benchmarks now that render stats are atomic.
2. Compare bounded direct scroll-copy chunks against the staging path.
   Keep the chunked path only if repeated benchmarks and interactive traces show
   lower byte traffic without worse command-buffer latency.
3. Investigate direct-drawable or dirty-region rendering for changed frames
   after coalesced presentation has been measured.
4. Add a targeted no-op redisplay/presentation benchmark if no-op update cycles
   become a suspected source of interactive latency.
5. Defer glyph prewarming, atlas separation, and batched atlas uploads until
   traces show higher glyph-cache miss or upload pressure.
6. Profile `macfont_draw` before adding metric caches or longer-run scratch
   arenas.

## Recent State

The latest completed slice made Metal render statistics thread-safe:

- `src/macmetal.m` now uses an internal atomic stats accumulator.
- `mac-metal-render-stats` keeps the same public API.
- `test/misc/macmetal-tests/source-invariants.el` verifies the atomic stats
  structure and helper usage.
- The performance findings doc now treats atomic render stats as done and moves
  visual/final-frame checking to the remaining presenter hardening work.

This was a measurement-quality and hardening change, not a direct user-visible
speedup.  Its purpose is to make the next Metal benchmark comparison trustworthy
after presentation work moved onto a presenter queue and completion handlers.

## Useful Verification Commands

Run source-invariant tests against this worktree by setting `source-directory`
explicitly.  Otherwise the built Emacs may read source from another configured
checkout.

```sh
/Users/janne/Projects/emacs-mac/src/emacs -Q --batch \
  --eval '(setq source-directory "/Users/janne/.codex/worktrees/bb3c/emacs-mac/")' \
  -l /Users/janne/.codex/worktrees/bb3c/emacs-mac/test/misc/macmetal-tests/source-invariants.el \
  -f ert-run-tests-batch-and-exit
```

For Objective-C syntax checks of `src/macmetal.m` from this source-only worktree:

```sh
gcc -std=gnu23 -fsyntax-only -x objective-c -fobjc-arc \
  -DUSE_METAL_RENDERING \
  -I/Users/janne/Projects/emacs-mac/src \
  -I/Users/janne/Projects/emacs-mac/lib \
  -I/Users/janne/.codex/worktrees/bb3c/emacs-mac/src \
  -I/Users/janne/.codex/worktrees/bb3c/emacs-mac/lib \
  -I/usr/local/opt/openssl/include \
  /Users/janne/.codex/worktrees/bb3c/emacs-mac/src/macmetal.m
```

Always run:

```sh
git diff --check
git status --short --branch
```

## Benchmarking Guidance

Use the benchmark harness in `test/src/mac-performance-benchmark.el` and record
results in `docs/emacs-mac-performance-findings.md`.

When evaluating Metal presentation work, compare:

- elapsed scenario time
- `nextDrawable` wait
- command-buffer time
- presentation requests, coalesced requests, task runs, and final reschedules
- presentation vs scroll-preservation blit counts and bytes
- event-to-present or frame latency when available

Do repeated runs before accepting small differences.  Keep negative results in
the findings doc if they rule out a tempting optimization.

## Commit Discipline

Use small commits with focused messages, then push:

```sh
git push fork HEAD:codex/responsive-coding-bb3c
```

Prefer committing:

- a benchmark or invariant before a risky implementation, when it makes the next
  result measurable;
- a narrow implementation only after verification;
- the findings-doc update together with the code it documents.

Avoid committing speculative changes that do not measure well unless they are
needed to make the next measurement reliable.

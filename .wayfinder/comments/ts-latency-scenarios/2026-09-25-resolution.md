# Resolution: Tree-sitter latency scenarios for the benchmark harness

Resolved 2026-09-25 (AFK task).

- **What was done:** added `test/manual/redisplay-bench/ts-perf.el`. It
  times open, scroll-page, keystroke and quote for python-ts-mode and
  typescript-ts-mode, with `jit-lock-defer-on-input` nil and a
  fontification check. It generates deterministic 800 KB and 50 KB
  fixtures, or times real files given in `TS_PERF_FILES`.
- **Baseline:** [research/ts-latency-baseline.md](../../research/ts-latency-baseline.md).
- **Facts the gates depend on:**
  - A quote at the start of a line reparses in 4-5 ms at 50-100 KB, 9 ms
    at 240 KB, and 63 ms in the 800 KB generated Python file.
  - Keystrokes and scrolls stay at 1-3 ms.
  - Opening a file takes 14-45 ms below 250 KB, and 135-196 ms at 800 KB.
- The quote case is larger than the roadmap's item 13 measurement
  (3-7 ms), which typed at the end of a line.
